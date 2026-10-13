-- =============================================================
-- LeaveDesk SG — migration v16
--   年假结转（每人上限 + 可设到期）／其余假别每年重置／年初一键执行 + 永久记录
--
-- 【为什么要有这个】（2026-08-27 用户发现）
--   余额 = 该员工账本 **全部** 条目之和，没有任何年度边界（leave_balances）。
--   grant_annual_entitlements 每年再发一次配额，**但从来没有东西把上一年的清掉**。
--   于是 2027 年一个 2026 只请了 2 天病假的人会显示 26 天，而不是 14 天。
--   这不是谁设计的功能，而是「缺了一步」——缺的那一步就是本迁移的第 4 节。
--
--   用户要的是：病假之类每年重置回 HR 设定的天数；只有年假结转、补休不动。
--
-- 【本迁移做了什么】
--   1. 每人各自的结转上限 employees.carry_cap（旧的全公司 leave_types.carry_over_cap
--      会被回填进来，上线当天数字不变）+ org_settings.default_carry_cap（只用于
--      「新员工默认值」，和 default_annual_base 语义一致，不影响已有员工）。
--   2. 结转到期日 annual_carry.expires_on（真实日期，取代写死的 12-31），
--      公司级 org_settings.carry_expiry_months（NULL = 永不过期）。
--   3. 到期自动生效：leave_balances **立刻**扣掉「已过期但还没写账」的结转天数，
--      所以 submit_application 的余额校验天然正确，不必改那个函数；
--      expire_due_carry() 再把它落成账本条目（keepalive 每天调一次）。
--      两者不会重复扣：写账时 expired_at 落地，视图那一半立刻归零。
--   4. leave_types.resets_yearly（年假、补休为 false，其余全 true）+
--      年初把这些假别清零，再由 grant_annual_entitlements 按 HR 设定的
--      default_days 重新发放 —— 天数一律读设置，不硬编码。
--   5. run_year_start(year, preview) 一个函数同时负责「预览」和「执行」：
--      同一段算术，preview 只是不写。预览和实际结果不可能对不上。
--   6. year_start_log：每人每年一行的永久记录（去年请了多少、剩多少、上限多少、
--      结转多少、超额作废多少、过期多少、各假别清了多少、谁在什么时候按的）。
--
-- 依赖 v11 及以前全部迁移。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 0. 前置迁移可能没跑过 ----------
-- HANDOVER 第一条教训：**绝不要写一个假设前一个迁移跑过的迁移**。v14 加的这两列
-- 本函数要读，而 schema.sql（从零重建时用的那份）里并没有。补一次，代价为零。
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table org_settings add column if not exists accrual_mode text not null default 'annual';

-- ---------- 1. 字段 ----------
alter table employees   add column if not exists carry_cap           numeric(5,1);
alter table org_settings add column if not exists default_carry_cap  numeric(5,1);
alter table org_settings add column if not exists carry_expiry_months int;
alter table annual_carry add column if not exists expires_on         date;
alter table leave_types  add column if not exists resets_yearly      boolean not null default true;

comment on column employees.carry_cap is
  'Max annual-leave days this person may carry into the next year. Per employee on purpose: different staff carry different amounts.';
comment on column org_settings.default_carry_cap is
  'Pre-fills the Add employee form only. Changing it never moves anyone already in the system (same rule as default_annual_base).';
comment on column org_settings.carry_expiry_months is
  'Months from 1 January until carried days expire. NULL = they never expire.';
comment on column leave_types.resets_yearly is
  'True for every type that goes back to its yearly allowance each January. False for annual (it carries) and off-in-lieu (it was earned).';

-- 回填：上线当天任何数字都不许变
update employees set carry_cap =
  coalesce((select carry_over_cap from leave_types where code = 'annual'), 0)
  where carry_cap is null;
update org_settings set default_carry_cap =
  coalesce((select carry_over_cap from leave_types where code = 'annual'), 0)
  where id = 1 and default_carry_cap is null;
-- 旧行为 = 当年 12-31 到期 = 从 1 月 1 日起 12 个月
update org_settings set carry_expiry_months = 12 where id = 1 and carry_expiry_months is null;
update annual_carry set expires_on = (year || '-12-31')::date where expires_on is null;
update leave_types set resets_yearly = false where code in ('annual', 'oil');

-- ---------- 2. 取数辅助 ----------
-- 某人在某个日期区间内**实际休掉**的年假天数。结转天数「先用先扣」就是靠它：
-- 到期时作废的只是「到期日之前没用掉的那部分」，已经休了的永远不会被倒扣。
create or replace function annual_used_between(p_emp uuid, p_from date, p_to date)
returns numeric language sql stable as $$
  select coalesce(sum(a.days), 0) from applications a
  where a.emp_id = p_emp and a.leave_type = 'annual' and a.status = 'approved'
    and a.start_date >= p_from and a.start_date <= p_to;
$$;

-- 「已经过了到期日、但还没写进账本」的结转天数。
-- 视图立刻扣掉它 ⇒ 即使所有定时任务都死了，也没人能用到已经过期的天数。
-- 一旦 expire_due_carry() 把它落成账本条目（expired_at 落地），这里立刻返回 0，
-- 不会重复扣。
create or replace function due_unwritten_carry(p_emp uuid, p_code text)
returns numeric language sql stable as $$
  select case when p_code <> 'annual' then 0 else coalesce((
    select sum(greatest(0, ac.carry_in
                 - annual_used_between(ac.emp_id, make_date(ac.year, 1, 1), ac.expires_on)))
    from annual_carry ac
    where ac.emp_id = p_emp
      and ac.expired_at is null
      and ac.expires_on is not null
      and ac.expires_on < current_date
  ), 0) end;
$$;

-- ---------- 3. 余额视图：扣掉已过期的结转 ----------
create or replace view leave_balances as
select l.emp_id, l.leave_type,
       sum(l.delta_days) filter (where l.delta_days > 0)  as granted,
       -sum(l.delta_days) filter (where l.delta_days < 0) as used,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type) as balance,
       coalesce((select sum(a.days) from applications a
                 where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                   and a.status = 'pending'), 0)          as pending,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type)
         - coalesce((select sum(a.days) from applications a
                     where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                       and a.status = 'pending'), 0)      as available
from leave_ledger l
group by l.emp_id, l.leave_type;

-- ---------- 4. 到期落账 ----------
create or replace function expire_due_carry(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; rem numeric; n int := 0;
begin
  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on
    from annual_carry ac
    where ac.expired_at is null
      and ac.expires_on is not null
      and ac.expires_on < current_date
      and (p_emp is null or ac.emp_id = p_emp)
  loop
    rem := greatest(0, r.carry_in - annual_used_between(r.emp_id, make_date(r.year, 1, 1), r.expires_on));
    if rem > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.emp_id, 'annual', -rem, r.year || ' carry-over expired (unused)', null);
    end if;
    update annual_carry set expired_days = rem, expired_at = now()
      where emp_id = r.emp_id and year = r.year;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_carry(uuid) from anon, public;
grant  execute on function expire_due_carry(uuid) to authenticated;

-- ---------- 5. 年初记录表 ----------
create table if not exists year_start_log (
  year               int  not null,
  emp_id             uuid not null references employees (id),
  -- 姓名存一份副本：员工被删掉之后这份记录还要能看懂
  emp_name           text not null,
  annual_taken_prev  numeric(6,1) not null default 0,
  annual_left        numeric(6,1) not null default 0,
  cap_applied        numeric(5,1) not null default 0,
  carried            numeric(6,1) not null default 0,
  forfeited          numeric(6,1) not null default 0,
  expired            numeric(6,1) not null default 0,
  expires_on         date,
  resets             jsonb not null default '[]'::jsonb,
  reset_days         numeric(6,1) not null default 0,
  run_at             timestamptz not null default now(),
  run_by             uuid references employees (id),
  primary key (year, emp_id)
);
comment on table year_start_log is
  'One permanent row per employee per year-start run. Never overwritten. This is what HR reads years later.';
alter table year_start_log enable row level security;
drop policy if exists yslog_read on year_start_log;
create policy yslog_read on year_start_log for select to authenticated using (is_hr());

-- ---------- 6. 年初一键执行（p_preview = true 时只算不写） ----------
-- 预览和执行**共用同一段算术**，preview 只是把写入跳过。所以「预览显示的」和
-- 「实际记录的」不可能对不上 —— 那是构造上的保证，不是靠两处代码维持一致。
create or replace function run_year_start(p_year int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; t record;
  v_months int; v_mode text; v_expires date;
  v_bal numeric; v_cap numeric; v_carry numeric; v_excess numeric;
  v_taken numeric; v_exp numeric; v_tb numeric;
  v_resets jsonb; v_reset_days numeric;
  v_rows jsonb := '[]'::jsonb;
  v_people int := 0; v_carry_people int := 0; v_carry_days numeric := 0;
  v_forfeit_people int := 0; v_forfeit_days numeric := 0;
  v_expired_people int := 0; v_expired_days numeric := 0;
  v_reset_people int := 0; v_granted int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

  select carry_expiry_months, accrual_mode into v_months, v_mode from org_settings where id = 1;
  v_expires := case when v_months is null then null
                    else (make_date(p_year, 1, 1) + (v_months || ' months')::interval)::date - 1 end;

  -- 步骤 1：把已经到期的结转落成账本条目（预览不写）
  if not p_preview then perform expire_due_carry(); end if;

  for r in select e.id, e.name, coalesce(e.carry_cap, 0) as cap
           from employees e where e.active order by e.name loop

    -- 已经处理过这一年的人直接跳过 ⇒ 按第二次只会报 0，不会重复扣
    if exists (select 1 from year_start_log y where y.year = p_year and y.emp_id = r.id) then
      continue;
    end if;
    v_people := v_people + 1;
    v_cap := r.cap;

    -- 去年结转的到期情况（预览时按「将会作废多少」算，执行后按已落账的算 —— 同一个数）
    select coalesce(case
             when ac.expires_on is null then 0
             when ac.expired_at is not null then ac.expired_days
             else greatest(0, ac.carry_in - annual_used_between(r.id, make_date(ac.year,1,1), ac.expires_on))
           end, 0)
      into v_exp
      from annual_carry ac where ac.emp_id = r.id and ac.year = p_year - 1;
    v_exp := coalesce(v_exp, 0);
    if v_exp > 0 then v_expired_people := v_expired_people + 1; v_expired_days := v_expired_days + v_exp; end if;

    -- 步骤 2：年假结转。先减掉「本年度配额」——即使有人先跑了发放，结转也只按去年剩余算。
    v_bal := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
    v_bal := v_bal - coalesce((select sum(delta_days) from leave_ledger
                               where emp_id = r.id and leave_type = 'annual'
                                 and reason in (p_year || ' 年度配额', p_year || ' annual allowance')), 0);
    -- 预览时上面那 expire 还没写账，视图已经替我们扣掉了 due_unwritten_carry，所以两条路数字一致
    v_carry  := least(v_cap, greatest(0, v_bal));
    v_excess := greatest(0, v_bal - v_cap);
    v_taken  := annual_used_in_year(r.id, p_year - 1);
    if v_carry  > 0 then v_carry_people := v_carry_people + 1; v_carry_days := v_carry_days + v_carry; end if;
    if v_excess > 0 then v_forfeit_people := v_forfeit_people + 1; v_forfeit_days := v_forfeit_days + v_excess; end if;

    -- 步骤 3：其余假别清零。清多少读余额，发多少读 leave_types.default_days —— 都不硬编码。
    v_resets := '[]'::jsonb; v_reset_days := 0;
    for t in select code, name_en, default_days from leave_types
             where resets_yearly and not no_deduct order by sort loop
      select coalesce(balance, 0) into v_tb from leave_balances
        where emp_id = r.id and leave_type = t.code;
      v_tb := coalesce(v_tb, 0);
      if v_tb <> 0 then
        v_resets := v_resets || jsonb_build_object(
          'code', t.code, 'name', t.name_en, 'cleared', v_tb, 'credits', t.default_days);
        v_reset_days := v_reset_days + v_tb;
        if not p_preview then
          insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
          values (r.id, t.code, -v_tb,
                  (p_year - 1) || ' ' || t.name_en || ' reset — use it or lose it', current_emp_id());
        end if;
      end if;
    end loop;
    if jsonb_array_length(v_resets) > 0 then v_reset_people := v_reset_people + 1; end if;

    if not p_preview then
      if v_excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -v_excess,
                (p_year - 1) || ' annual leave above the carry-over cap (' || v_cap || ') — forfeited',
                current_emp_id());
      end if;
      insert into annual_carry (emp_id, year, carry_in, expires_on)
      values (r.id, p_year, v_carry, v_expires)
      on conflict (emp_id, year) do nothing;
      insert into year_start_log (year, emp_id, emp_name, annual_taken_prev, annual_left,
                                  cap_applied, carried, forfeited, expired, expires_on,
                                  resets, reset_days, run_by)
      values (p_year, r.id, r.name, v_taken, v_bal, v_cap, v_carry, v_excess, v_exp, v_expires,
              v_resets, v_reset_days, current_emp_id());
    end if;

    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'taken_prev', v_taken, 'left', v_bal, 'cap', v_cap,
      'carried', v_carry, 'forfeited', v_excess, 'expired', v_exp,
      'expires_on', v_expires, 'reset_days', v_reset_days, 'resets', v_resets);
  end loop;

  -- 步骤 4：发放新一年的配额。**必须在清零之后**，否则刚发的立刻被抹掉。
  if v_mode = 'monthly' then
    v_granted := 0;
  elsif p_preview then
    -- 别名不能叫 t：上面声明了 record t，PL/pgSQL 会把它当变量替换进查询，
    -- 报 "record t is not assigned yet"。这类冲突不会在编译期发现，只在跑到时才炸。
    v_granted := (select count(distinct e.id) from employees e cross join leave_types lt
                  where e.active and (lt.default_days > 0 or lt.code = 'annual')
                    and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender)
                    and not exists (select 1 from leave_ledger l
                                    where l.emp_id = e.id and l.leave_type = lt.code
                                      and l.reason in (p_year || ' 年度配额', p_year || ' annual allowance')));
  else
    v_granted := grant_annual_entitlements(p_year);
  end if;

  return jsonb_build_object(
    'year', p_year, 'preview', p_preview, 'people', v_people,
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 7. 旧的 rollover 改成薄壳，避免两处算术 ----------
-- 保留函数名：YEARLY_CHECKLIST 和旧文档里写过它，别让老步骤突然报「函数不存在」。
create or replace function rollover_annual_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  v := run_year_start(p_year, false);
  return (v ->> 'carried_people')::int;
end $$;
revoke execute on function rollover_annual_leave(int) from anon, public;
grant  execute on function rollover_annual_leave(int) to authenticated;

-- ---------- 8. 员工看得到的结转视图：真实到期日 ----------
create or replace view my_annual_carry as
select ac.year, ac.carry_in,
       greatest(0, ac.carry_in - annual_used_in_year(ac.emp_id, ac.year)) as remaining,
       ac.expires_on
from annual_carry ac
where ac.emp_id = current_emp_id() and ac.year = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;
