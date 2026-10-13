-- =============================================================
-- LeaveDesk SG — migration v18
--   年假=直接填写的总额／假别天数改动=按差额补发／HR 代申请／人工改动记录
--
-- 【为什么】（2026-08-27 用户实测）
--   1. 「Leave types」页改了 Days per year，**对已在职的人毫无作用** —— 只影响下一次
--      年度发放。那个页面看起来是控制项，实际是一张便条。用户原话：
--      「what is the purpose of this page. how can i change the number of days for
--        each leave and update them?」——这是本次最核心的缺陷。
--   2. 年假额度 = annual_base + 工龄年数，界面上写着 14、实际拿 20，没有任何一处解释。
--   3. 「Balance adjustments」应该是「HR 代员工请假」，不是加减数字。
--
-- 【本迁移】
--   1. annual_entitlement_for → 就是 annual_base（受公司上限约束）。
--      **取消工龄递增，取消新人首年按月折算** —— 新人多少天由 HR 自己算了填进去。
--   2. set_annual_entitlement()：改额度立刻按差额调整**当年**余额，并写一条人工记录。
--   3. amend_leave_type_days()：把 60→62 的**差额 +2 补发给每一位适用员工**，
--      已经休掉的天数不受影响，**不是**把所有人重设成 62。全公司只写一条记录。
--   4. submit_application 增加 p_for_emp：HR 代申请，即时批准，事件里写明是 HR 代的。
--      **复用同一个函数**，工作日/余额/重叠规则全系统仍只有一处。
--   5. hr_amendments：所有人工改动的记录（额度调整、OIL 补发、全公司假别改动）。
--   6. 年初清零的措辞改成 expired（用户要的字）。
--
-- 依赖 v16。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 0. 前置迁移可能没跑过（HANDOVER 第一条教训） ----------
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table org_settings add column if not exists accrual_mode text not null default 'annual';
alter table employees    add column if not exists carry_cap    numeric(5,1);

-- ---------- 1. 年假额度 = 填进去的数字 ----------
-- 工龄递增（annual_base + 工龄）和新人首年折算都去掉了。公司上限仍然生效：
-- 它现在约束的是「你填的那个数字」，而不是一段看不见的算式。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select least(e.annual_base,
               coalesce((select annual_cap from org_settings where id = 1), 1e9))
  from employees e where e.id = p_emp;
$$;

-- ---------- 1b. 给人看的天数写法 ----------
-- numeric(5,1) 直接拼进字符串会写出 "14.0 → 16.0"、"+2.0 days"。人不这么写数字。
create or replace function fmt_days(v numeric) returns text language sql immutable as $$
  select case when v is null then '' else trim_scale(v)::text end;
$$;

-- ---------- 2. 人工改动记录 ----------
-- 和请假记录**分开**的第二本账：所有 HR 手动改过的东西都在这里。
-- emp_id 为 NULL = 全公司范围的改动（例如把住院假从 60 改成 62），
-- 按用户要求只写一条，不逐个员工列名字。
create table if not exists hr_amendments (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  by_emp      uuid references employees (id),
  by_name     text not null default '',     -- 姓名存副本：人被删掉后记录仍看得懂
  emp_id      uuid references employees (id),
  emp_name    text,                          -- NULL = 全公司
  leave_type  text references leave_types (code),
  kind        text not null,                 -- entitlement | oil_credit | type_days | correction
  before_days numeric(6,1),
  after_days  numeric(6,1),
  delta_days  numeric(6,1),
  affected    int,                           -- 全公司改动影响到几个人
  reason      text not null default ''
);
comment on table hr_amendments is
  'Second record book: every manual change HR makes to a balance. Leave applications live in `applications`; this is everything else.';
alter table hr_amendments enable row level security;
drop policy if exists hramd_read on hr_amendments;
create policy hramd_read on hr_amendments for select to authenticated using (is_hr());

create or replace function log_amendment(
  p_emp uuid, p_emp_name text, p_type text, p_kind text,
  p_before numeric, p_after numeric, p_delta numeric, p_affected int, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare who uuid := current_emp_id();
begin
  insert into hr_amendments (by_emp, by_name, emp_id, emp_name, leave_type, kind,
                             before_days, after_days, delta_days, affected, reason)
  values (who, coalesce((select name from employees where id = who), 'System'),
          p_emp, p_emp_name, p_type, p_kind, p_before, p_after, p_delta, p_affected,
          coalesce(p_reason, ''));
end $$;

-- ---------- 3. 改额度 → 立刻调整当年余额 ----------
-- 以前改了只影响「下一次发放」，当年余额纹丝不动 —— 界面上还写着一行字叫你去用
-- Balance adjustments。现在改了就是改了，差额当场入账，全站同步。
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; diff numeric; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', cap;
  end if;
  if p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  before_days := e.annual_base;
  if p_days = before_days then return 0; end if;

  update employees set annual_base = p_days where id = p_emp;

  -- 只有本年度已经发过额度的人才需要补差额；没发过的，下次发放自然就是新数字。
  if exists (select 1 from leave_ledger where emp_id = p_emp and leave_type = 'annual'
             and reason in (y || ' 年度配额', y || ' annual allowance')) then
    diff := p_days - before_days;
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
    values (p_emp, 'annual', diff,
            y || ' entitlement changed ' || fmt_days(before_days) || ' → ' || fmt_days(p_days), current_emp_id());
  else
    diff := 0;
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, diff, 1, '');
  return diff;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 4. 改假别天数 → 按差额补发给所有人 ----------
-- 用户原话：「if previously i set as 60days for Hospitalization leave, then i change to
-- 62 and click save changes it should credit 2 days to all employee ... who already taken
-- the leave will not be affected do not reset the whole thing to 62」。
-- 所以是**差额**，不是重设。已休掉的天数完全不受影响。
create or replace function amend_leave_type_days(p_code text, p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t leave_types%rowtype; diff numeric; n int := 0; r record; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change a leave type'; end if;
  select * into t from leave_types where code = p_code;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if p_days < 0 then raise exception 'Days per year cannot be negative'; end if;
  diff := p_days - t.default_days;

  -- 年假：额度是**每人一个数字**（Edit employee 里填），全公司统一补发会和它打架。
  -- 补休：是加班换来的，没有「每年多少天」这回事。两者都不参与差额补发。
  -- no_deduct 的类型（无薪假、NS 等）根本没有余额，补发也没有意义。
  -- 年假：每人一个数字（Edit employee 里填）。补休：加班换来的，没有「每年多少天」。
  -- 这两个连 default_days 都不该存 —— 之前只是不补发、却照样把数字写下去，
  -- 结果年度发放看到 oil.default_days = 3 就发给了所有人（测试里 OIL 从 1.5 变 4.5）。
  -- 所以直接拒绝，而不是默默存一个没有意义、还会被别处读到的数字。
  if p_code = 'annual' then
    raise exception 'Annual leave is set per employee, in Edit employee — not here';
  end if;
  if p_code = 'oil' then
    raise exception 'Off-in-lieu is earned, not granted — credit it per employee in Edit employee';
  end if;
  if t.no_deduct or diff = 0 then
    if not p_preview then
      update leave_types set default_days = p_days where code = p_code;
    end if;
    return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
      'after', p_days, 'delta', diff, 'affected', 0, 'credited', false);
  end if;

  for r in select e.id from employees e
           where e.active
             and (t.gender_eligibility is null or t.gender_eligibility = e.gender) loop
    n := n + 1;
    if not p_preview then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.id, p_code, diff,
              y || ' ' || t.name_en || ' amended ' || fmt_days(t.default_days) || ' → ' || fmt_days(p_days),
              current_emp_id());
    end if;
  end loop;

  if not p_preview then
    update leave_types set default_days = p_days where code = p_code;
    -- 全公司一条记录，不逐个列名字（用户明确要求）。
    perform log_amendment(null, null, p_code, 'type_days', t.default_days, p_days, diff, n,
      'Company leave amendment — ' || t.name_en || ' ' ||
      case when diff > 0 then '+' else '' end || fmt_days(diff) || ' days');
  end if;
  return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
    'after', p_days, 'delta', diff, 'affected', n, 'credited', true);
end $$;
revoke execute on function amend_leave_type_days(text, numeric, boolean) from anon, public;
grant  execute on function amend_leave_type_days(text, numeric, boolean) to authenticated;

-- ---------- 5. OIL 补发（Edit employee 里的按钮） ----------
create or replace function credit_oil(p_emp uuid, p_days numeric, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit off-in-lieu'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
  values (p_emp, 'oil', p_days, 'Off-in-lieu: ' || btrim(p_reason), current_emp_id());
  perform log_amendment(p_emp, e.name, 'oil', 'oil_credit', null, null, p_days, 1, btrim(p_reason));
  return p_days;
end $$;
revoke execute on function credit_oil(uuid, numeric, text) from anon, public;
grant  execute on function credit_oil(uuid, numeric, text) to authenticated;

-- ---------- 6. HR 代员工请假：同一个函数，多一个参数 ----------
create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false,
  p_for_emp uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
        actor uuid; on_behalf boolean := p_for_emp is not null;
begin
  -- v18：HR 可以代员工申请。**刻意复用这同一个函数**，而不是另写一份：
  -- 工作日计算、余额校验、重叠检查、次年只读、附件必填……全系统只有这一处。
  -- 另写一份 = 两套规则，早晚不一致。
  if on_behalf then
    if not is_hr() then raise exception 'Only HR can apply for another employee'; end if;
    select * into me from employees where id = p_for_emp and active;
    if me.id is null then raise exception 'That employee is not on the active list'; end if;
    actor := current_emp_id();
  else
    select * into me from employees where auth_user_id = auth.uid() and active;
    if me.id is null then raise exception 'Employee profile not found'; end if;
    actor := me.id;
  end if;
  -- 串行化同一员工的并发提交：消除余额/重叠「查后写」竞态（锁在事务提交时自动释放）
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception 'Not eligible for this leave type'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception 'This leave type requires an attachment (e.g. MC)'; end if;
  -- 范围夹取：进逐日循环前拦掉超大区间，防 CPU DoS
  if p_end < p_start or p_end - p_start > 366 then
    raise exception 'Invalid date range (maximum about one year)'; end if;
  -- 次年日历只读：次年额度要到 1 月 1 日才发放，此前不能申请落在次年的假
  if extract(year from p_start)::int > extract(year from current_date)::int
     or extract(year from p_end)::int > extract(year from current_date)::int then
    raise exception 'Next year''s leave opens for application on 1 Jan (until then the calendar is view-only)';
  end if;
  -- 半天假仅对允许的假期类型生效；其余类型忽略半天明细，一律按整天计
  if not coalesce(t.allow_half_day, false) then hd := '[]'::jsonb; end if;
  d := case when jsonb_array_length(hd) > 0
            then working_days_hd(me.id, p_start, p_end, hd)
            else working_days(me.id, p_start, p_end, p_sh, p_eh) end;
  if d <= 0 then raise exception 'The selected dates contain no working days'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances
      where emp_id = me.id and leave_type = p_type;
    if coalesce(avail, 0) < d then raise exception 'Not enough balance: % day(s) needed, only % available', d, coalesce(avail,0); end if;
  end if;
  if exists (select 1 from applications a where a.emp_id = me.id
             and a.id is distinct from p_resubmit_id
             and a.status in ('pending','approved','cancel_requested')
             and not (a.end_date < p_start or a.start_date > p_end)) then
    raise exception 'These dates overlap an existing application';
  end if;

  if p_resubmit_id is not null then
    update applications set leave_type=p_type, start_date=p_start, end_date=p_end,
      start_half=p_sh, end_half=p_eh, half_days=hd, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception 'Only a returned application can be resubmitted'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,half_days,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,hd,d,p_reason,p_attachment,p_start<current_date)
    returning id into app_id;
  end if;

  insert into application_events (application_id, actor, action, comment)
  values (app_id, actor, case when p_resubmit_id is null then 'submitted' else 'resubmitted' end,
          case when on_behalf then 'Applied by HR on behalf' else null end);

  -- HR 代申请一律即时批准（这就是「代申请」的意思：HR 已经决定了）。
  if me.approver1 is null or on_behalf then
    -- 无审批人（Managing Director）：提交即自动批准、记账，事件流通知 HR 备案
    update applications set status='approved', updated_at=now() where id=app_id;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (me.id, p_type, -d, 'Leave taken', app_id, actor);
    end if;
    insert into application_events (application_id, actor, action, comment)
    values (app_id, actor, 'auto_approved',
            case when on_behalf then 'Applied by HR on behalf' else 'No approver required' end);
  else
    -- 按员工档案生成审批链（一级或两级）；在途申请不受之后档案变更影响
    insert into approval_steps (application_id, step_order, approver_id, status)
    values (app_id, 1, me.approver1, 'pending');
    if me.two_level and me.approver2 is not null then
      insert into approval_steps (application_id, step_order, approver_id, status)
      values (app_id, 2, me.approver2, 'waiting');
    end if;
  end if;
  return app_id;
end $$;

-- ---------- 7. 年初清零的措辞：expired ----------
-- 用户的原话：「just remove how much leave remained label as expired and add back the
-- default date set by user」。机制不变（v16 已经对了），只是把措辞改成他要的字。
create or replace function reset_statutory_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; t record; b numeric; n int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can reset the yearly leave balances'; end if;
  for r in select id from employees where active loop
    for t in select code, name_en from leave_types where resets_yearly and not no_deduct order by sort loop
      select coalesce(balance, 0) into b from leave_balances where emp_id = r.id and leave_type = t.code;
      if coalesce(b, 0) <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, t.code, -b, (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id());
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke execute on function reset_statutory_leave(int) from anon, public;
grant  execute on function reset_statutory_leave(int) to authenticated;

-- run_year_start 里的清零措辞也要跟着改 —— 它自己内联了那段循环，不是调用上面的函数。
-- 两处写同一句话本来就是隐患，这里至少让它们一次改齐。
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
                  (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id());
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

-- ---------- 8. 年度发放永远不碰补休 ----------
-- 上面已经拦住了「把 oil 的 default_days 改成非 0」这条路，但这个函数是账目的最后一关：
-- 就算数据库里靠别的途径塞进去一个数字，补休也不该被年度发放批量补给所有人。
-- 两道防线，因为这一条错了是**给所有人凭空多发假**，不会有任何人报错。
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
  for r in
    select e.id as emp_id, t.code, t.default_days
    from employees e cross join leave_types t
    where e.active and t.code <> 'oil' and (t.default_days > 0 or t.code = 'annual')
      and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
      and not exists (select 1 from leave_ledger l
                      where l.emp_id = e.id and l.leave_type = t.code
                        and l.reason in (p_year || ' 年度配额', p_year || ' annual allowance'))
  loop
    amt := case when r.code = 'annual' then annual_entitlement_for(r.emp_id, p_year) else r.default_days end;
    if amt > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.emp_id, r.code, amt, p_year || ' annual allowance', current_emp_id());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function grant_annual_entitlements(int) from anon, public;
grant  execute on function grant_annual_entitlements(int) to authenticated;
