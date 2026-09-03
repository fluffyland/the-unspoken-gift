-- ============================================================================
-- migration_app_v35.sql — 每一条账本记录都写明「属于哪一年」
--
-- 用户原话：
--   「let the leave have a tag, for example this leave is 2025 leave, so that the system
--     recognise it and when click new year 2026, it will calculate 2025 remaining leave and
--     carry forward to 2026, then the other leave like SL or HL tagged as 2025 will be reset
--     then credit 2026 leave」
--
-- 为什么以前会出错 —— 系统从来没有记下过「这一行属于哪一年」，它每次都在**猜**：
--   · 按 created_at 的年份猜（一月补录十二月的假 → 算进一月那一年）
--   · 按 reason 的文字猜（'2026 annual allowance' 认得，别的措辞一律认不出）
--
-- 那次 2026 年初操作之所以出事，就是这个猜法：
--   「去年剩多少」= 年假余额 − 措辞正好是 '2026 annual allowance' 的那一行。
--   八月全公司加的那 3.5 天措辞不一样，减不掉，于是被当成「2025 年剩下的」结转到 2026 ——
--   而这套系统里根本没有 2025 年的数据。有人 3.5、有人 0、有人 4，就是这么来的。
--   同一次运行又把其它假别按余额清零，再调 grant_annual_entitlements 补发；
--   而补发那一步看到七月已经有 '2026 年度配额' 就跳过了 —— 清了不发，全部归零。
--
-- 这个迁移把「哪一年」从猜测变成事实：
--   leave_year —— 这一笔属于哪个假期年度
--   kind       —— 这一笔是什么：grant 发放 / carry_in 结转 / taken 请假 /
--                 refund 销假退回 / adjust 调整 / writeoff 年结冲销
-- 于是所有算法都变成一句话，全系统再没有一处按文字判断年份或性质。
--
-- 幂等：重复执行没有副作用。回填**不改任何 delta_days**，没有人多一天或少一天，
-- 迁移末尾会逐人逐假别核对这一点，对不上就整笔回滚。
-- ============================================================================

-- ---------- 0. 前置：这个迁移读到的列，老库里可能没有 ----------
-- HANDOVER 第一条教训：绝不写一个假设前一个迁移跑过的迁移。
alter table employees    add column if not exists carry_cap    numeric(5,1);
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table leave_types  add column if not exists resets_yearly boolean not null default true;

-- ---------- 1. 两个字段 ----------
alter table leave_ledger add column if not exists leave_year int;
alter table leave_ledger add column if not exists kind       text;

comment on column leave_ledger.leave_year is
  'The leave year this entry belongs to. For leave taken or refunded it is the year of the LEAVE DATES, not the day it was keyed in — so December leave entered in January still comes out of December''s allowance.';
comment on column leave_ledger.kind is
  'What this entry is: grant (the year''s allowance) · carry_in (days carried from last year) · taken · refund · adjust (a correction) · writeoff (year-end clearing, forfeiture, offboarding). Before v35 this was guessed from the wording, in 23 different places.';

-- ---------- 2. 从一行记录推出它的年份和性质 ----------
-- 这两个函数是**唯一**的推断处，而且只在没有明写的时候才用得上。
-- 新代码一律直接写 leave_year / kind，不经过它们。

create or replace function ledger_kind_of(p_reason text, p_ref uuid, p_delta numeric)
returns text language sql immutable as $$
  select case
    -- 跟某一张申请挂钩的，就是请假或销假退回。这比看文字可靠：退回是**正数**。
    when p_ref is not null and p_delta < 0 then 'taken'
    when p_ref is not null                 then 'refund'
    -- 同样的两句措辞，但没有挂申请：手工补录、旧数据、测试脚本都会这样写。
    -- 认不出来它就会被当成「额度」，于是「把 SL 设成 62」变成给这个人发 67 天。
    when coalesce(p_reason,'') like 'Leave taken%'  then 'taken'
    when coalesce(p_reason,'') like 'Refunded%'     then 'refund'
    -- 结转：措辞由 v35 的 run_year_start 自己写，独一无二，先认它
    when coalesce(p_reason,'') like 'Carried forward from %' then 'carry_in'
    -- 年结家务事。必须排在 grant 前面：'2025 年假…作废' 也是 4 位数字开头的。
    when coalesce(p_reason,'') ~* '(expired \(unused\)|above the carry-over cap|reset — use it or lose it|expired carry-over|excess forfeited|forfeited)' then 'writeoff'
    when coalesce(p_reason,'') like 'Offboarding%' then 'writeoff'
    when coalesce(p_reason,'') like '%结转%' or coalesce(p_reason,'') like '%作废%' then 'writeoff'
    -- 年度发放：措辞是系统写的，中英两种
    when coalesce(p_reason,'') ~ '^[0-9]{4} (annual allowance|年度配额)$' then 'grant'
    else 'adjust'
  end;
$$;
comment on function ledger_kind_of(text, uuid, numeric) is
  'Last-resort classifier for rows written before v35, and for any code path that still inserts without saying what it is. New code sets kind directly.';

create or replace function ledger_year_of(p_reason text, p_ref uuid, p_created timestamptz)
returns int language plpgsql stable security definer set search_path = public as $$
declare y int;
begin
  -- 1) 请假／销假：以**假期日期**的年份为准
  if p_ref is not null then
    select extract(year from a.start_date)::int into y from applications a where a.id = p_ref;
    if y is not null then return y; end if;
  end if;
  -- 2) 措辞以 4 位年份开头 —— 全系统的发放、清零、调整都是这个格式
  y := nullif(substring(coalesce(p_reason, '') from '^([0-9]{4})'), '')::int;
  if y between 2000 and 2100 then return y; end if;
  -- 3) 都不是：按写进来的那一天算
  return extract(year from coalesce(p_created, now()))::int;
end $$;

-- ---------- 3. 触发器：任何一条新记录都带着标签落地 ----------
-- 全系统有几十处 insert into leave_ledger。**不逐一改**：漏掉一处就又多一条
-- 没有年份的记录，而且要到明年一月才会发作。写在数据真正落地的地方，一条都跑不掉。
create or replace function tag_leave_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind is null then
    new.kind := ledger_kind_of(new.reason, new.ref_application, new.delta_days);
  end if;
  if new.leave_year is null then
    new.leave_year := ledger_year_of(new.reason, new.ref_application, coalesce(new.created_at, now()));
  end if;
  return new;
end $$;
drop trigger if exists trg_ledger_tag on leave_ledger;
create trigger trg_ledger_tag before insert or update on leave_ledger
  for each row execute function tag_leave_ledger();

-- ---------- 4. 回填 ----------
-- 先把「今年每个人每种假别的额度」按**旧规则**记下来。回填之后要一模一样。
drop table if exists _v35_before;
create table _v35_before as
select l.emp_id, l.leave_type,
       sum(l.delta_days) as total,
       sum(l.delta_days) filter (
         where l.ref_application is null
           and extract(year from l.created_at)::int = extract(year from current_date)::int
           and l.reason not like '%expired (unused)%'
           and l.reason not like '%above the carry-over cap%'
           and l.reason not like '%reset — use it or lose it%'
           and l.reason not like '%excess forfeited%'
           and l.reason not like '%expired carry-over%'
           and l.reason not like 'Offboarding%'
           and l.reason not like '%结转%'
           and l.reason not like '%作废%') as entitled_now
from leave_ledger l group by l.emp_id, l.leave_type;

update leave_ledger set
  kind       = coalesce(kind,       ledger_kind_of(reason, ref_application, delta_days)),
  leave_year = coalesce(leave_year, ledger_year_of(reason, ref_application, created_at))
where kind is null or leave_year is null;

-- ---------- 5. 一年一个人一种假别，只能有一条「发放」 ----------
-- 用户看到的「sick 变成 28」「hosp 变成 118」就是同一年发了两次。
-- 多出来的那几条**不删**（删了就是凭空扣人天数），改标成 adjust：
-- 天数一天不动，但从此 grant 是唯一的，再也不可能发第二次。
-- 想把它们抹平：Leave types 里把天数填成想要的数字按保存，v35 的 amend_leave_type_days
-- 会把每个人的当年额度**对账到**那个数字。
do $$
declare n int;
begin
  with ranked as (
    select id, row_number() over (partition by emp_id, leave_type, leave_year
                                  order by created_at, id) as rn
      from leave_ledger where kind = 'grant')
  update leave_ledger l set kind = 'adjust'
    from ranked r where r.id = l.id and r.rn > 1;
  get diagnostics n = row_count;
  if n > 0 then
    raise warning 'v35: % duplicate allowance row(s) found — a leave type was granted more than once in the same year. The days were left exactly as they are and the extra rows are now marked as corrections. To bring everyone back to the figure on the Leave types tab, open that tab, retype the number and save.', n;
  end if;
end $$;

create unique index if not exists ux_ledger_one_grant
  on leave_ledger (emp_id, leave_type, leave_year) where kind = 'grant';

-- ---------- 6. 约束和索引 ----------
alter table leave_ledger alter column leave_year set not null;
alter table leave_ledger alter column kind       set not null;
alter table leave_ledger drop constraint if exists leave_ledger_kind_chk;
alter table leave_ledger add  constraint leave_ledger_kind_chk
  check (kind in ('grant','carry_in','taken','refund','adjust','writeoff'));
alter table leave_ledger drop constraint if exists leave_ledger_year_chk;
alter table leave_ledger add  constraint leave_ledger_year_chk
  check (leave_year between 2000 and 2100);
create index if not exists ix_ledger_year on leave_ledger (emp_id, leave_type, leave_year);

-- ---------- 7. 取数：一句话，没有一处按文字判断 ----------
create or replace function entitled_in_year(p_emp uuid, p_code text, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(delta_days), 0) from leave_ledger
   where emp_id = p_emp and leave_type = p_code and leave_year = p_year
     and kind in ('grant', 'adjust');
$$;
comment on function entitled_in_year(uuid, text, int) is
  'This year''s ENTITLEMENT for one leave type: the allowance plus every correction. Carried-forward days are not entitlement (they are last year''s days) and leave taken is not entitlement — both are excluded by kind, not by wording.';
revoke execute on function entitled_in_year(uuid, text, int) from anon;
grant  execute on function entitled_in_year(uuid, text, int) to authenticated;

create or replace function annual_entitled_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$ select entitled_in_year(p_emp, 'annual', p_year); $$;
comment on function annual_entitled_in_year(uuid, int) is
  'Annual leave entitled for the year — entitled_in_year for the annual type. Kept as its own name because the app and several migrations call it.';

create or replace function annual_used_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(-sum(delta_days), 0) from leave_ledger
   where emp_id = p_emp and leave_type = 'annual' and leave_year = p_year
     and kind in ('taken', 'refund');
$$;
comment on function annual_used_in_year(uuid, int) is
  'Annual leave actually taken in a leave year, net of cancellations. Reads the ledger (one source of truth) and uses the leave dates, so December leave keyed in January still counts against December''s year.';

-- 这一年公司开过没有 —— 不再靠某一句措辞
create or replace function year_has_started(p_year int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from leave_ledger l join employees e on e.id = l.emp_id
                  where e.active and l.leave_year = p_year and l.kind in ('grant', 'carry_in'));
$$;
revoke execute on function year_has_started(int) from anon, public;
grant  execute on function year_has_started(int) to authenticated;

-- ---------- 8. 发放：靠标签认「发过没有」 ----------
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
                        and l.leave_year = p_year and l.kind = 'grant')
  loop
    amt := case when r.code = 'annual' then annual_entitlement_for(r.emp_id, p_year) else r.default_days end;
    if amt > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
      values (r.emp_id, r.code, amt, p_year || ' annual allowance', current_emp_id(), p_year, 'grant');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function grant_annual_entitlements(int) from anon, public;
grant  execute on function grant_annual_entitlements(int) to authenticated;

-- ---------- 9. 年假额度：按标签认「今年发过没有」 ----------
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; ent numeric; adj numeric;
        y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if p_days is null or p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', fmt_days(cap);
  end if;

  before_days := e.annual_base;
  update employees set annual_base = p_days where id = p_emp;

  -- 今年一天额度都还没发过的人：不补。年初发放时自然就是新数字。
  if not exists (select 1 from leave_ledger
                  where emp_id = p_emp and leave_type = 'annual'
                    and leave_year = y and kind in ('grant', 'adjust')) then
    perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, 0, 1, '');
    return 0;
  end if;

  ent := annual_entitled_in_year(p_emp, y);
  adj := p_days - ent;                      -- 对账：把当年额度**补成**填进去的数字
  if adj <> 0 then
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
    values (p_emp, 'annual', adj,
            y || ' annual entitlement set to ' || fmt_days(p_days), current_emp_id(), y, 'adjust');
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, adj, 1, '');
  return adj;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 10. 全公司加年假：同样按标签 ----------
create or replace function bump_annual_all(p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cap numeric; r record; n int := 0; credited int := 0;
        skipped text[] := '{}'; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit annual leave'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  cap := (select annual_cap from org_settings where id = 1);

  for r in select id, name, annual_base from employees where active order by name loop
    if (cap is not null and r.annual_base + p_days > cap) or r.annual_base + p_days < 0 then
      skipped := skipped || r.name;
      continue;
    end if;
    n := n + 1;
    if exists (select 1 from leave_ledger
                where emp_id = r.id and leave_type = 'annual'
                  and leave_year = y and kind in ('grant', 'adjust')) then
      credited := credited + 1;
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, 'annual', p_days,
                y || ' annual leave ' || case when p_days > 0 then '+' else '' end ||
                fmt_days(p_days) || ' — company-wide', current_emp_id(), y, 'adjust');
      end if;
    end if;
    if not p_preview then
      update employees set annual_base = annual_base + p_days where id = r.id;
    end if;
  end loop;

  if not p_preview and n > 0 then
    perform log_amendment(null, null, 'annual', 'annual_bump', null, null, p_days, n,
      'Company annual leave amendment — ' || case when p_days > 0 then '+' else '' end ||
      fmt_days(p_days) || ' day' || case when abs(p_days) = 1 then '' else 's' end ||
      ' to every employee');
  end if;
  return jsonb_build_object('days', p_days, 'affected', n, 'credited', credited,
                            'skipped', to_jsonb(skipped));
end $$;
revoke execute on function bump_annual_all(numeric, boolean) from anon, public;
grant  execute on function bump_annual_all(numeric, boolean) to authenticated;

-- ---------- 11. 改假别天数：对账到那个数字 ----------
-- 用户两句话，以前只做到了第一句：
--   「60 改成 62 就给所有人加 2 天，已经休掉的不受影响」
--   「if I set 14 everything follow 14」
-- 「补差额」只做到第一句：谁的额度因为别的原因偏了，就一直偏下去
--   —— 同一年发了两次的人，SL 是 28，你把 14 存一遍，它还是 28。
-- 「对账到目标」两句都做到：**额度**变成那个数字，**已休掉的天数一天不动**。
create or replace function amend_leave_type_days(p_code text, p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t leave_types%rowtype; diff numeric; n int := 0; adj numeric; r record;
        y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change a leave type'; end if;
  select * into t from leave_types where code = p_code;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if p_days is null or p_days < 0 then raise exception 'Days per year cannot be negative'; end if;
  diff := p_days - t.default_days;

  if p_code = 'annual' then
    raise exception 'Annual leave is set per employee, in Edit employee — not here';
  end if;
  if p_code = 'oil' then
    raise exception 'Off-in-lieu is earned, not granted — credit it per employee in Edit employee';
  end if;
  if t.no_deduct then
    if not p_preview then update leave_types set default_days = p_days where code = p_code; end if;
    return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
      'after', p_days, 'delta', diff, 'affected', 0, 'credited', false);
  end if;

  -- 只动「今年已经发过这种假」的人。还没发的人不用补 —— 年初发放时就是新数字。
  for r in
    select e.id, entitled_in_year(e.id, p_code, y) as have
      from employees e
     where e.active
       and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
       and exists (select 1 from leave_ledger l
                    where l.emp_id = e.id and l.leave_type = p_code
                      and l.leave_year = y and l.kind = 'grant')
     order by e.name
  loop
    adj := p_days - r.have;
    if adj <> 0 then
      n := n + 1;
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, p_code, adj,
                y || ' ' || t.name_en || ' set to ' || fmt_days(p_days), current_emp_id(), y, 'adjust');
      end if;
    end if;
  end loop;

  if not p_preview then
    update leave_types set default_days = p_days where code = p_code;
    if n > 0 or diff <> 0 then
      -- 措辞照用户当初定的那一句，一个字不改：
      -- 「Company leave amendment — Hospitalisation Leave +2 days」。
      -- 它说的是**这个假别**改了多少，那一点没有变。
      perform log_amendment(null, null, p_code, 'type_days', t.default_days, p_days, diff, n,
        'Company leave amendment — ' || t.name_en || ' ' ||
        case when diff > 0 then '+' else '' end || fmt_days(diff) || ' days');
    end if;
  end if;
  return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
    'after', p_days, 'delta', diff, 'affected', n, 'credited', n > 0);
end $$;
revoke execute on function amend_leave_type_days(text, numeric, boolean) from anon, public;
grant  execute on function amend_leave_type_days(text, numeric, boolean) to authenticated;

-- ---------- 12. 年初：三步，全部按标签 ----------
--   结转 = 上一年剩下的（夹到上限）
--   清零 = 把上一年及更早的余额写掉
--   发放 = 写上今年的额度
-- 上一年一条记录都没有 ⇒ 剩下的就是 0 ⇒ 结转 0。不是靠某条规则记得拦住，
-- 而是**根本没有东西可以结转**。
create or replace function run_year_start(p_year int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; t record;
  v_mode text; v_expires date;
  v_left numeric; v_cap numeric; v_carry numeric; v_excess numeric;
  v_taken numeric; v_exp numeric; v_tb numeric;
  v_resets jsonb; v_reset_days numeric;
  v_rows jsonb := '[]'::jsonb;
  v_people int := 0; v_carry_people int := 0; v_carry_days numeric := 0;
  v_forfeit_people int := 0; v_forfeit_days numeric := 0;
  v_expired_people int := 0; v_expired_days numeric := 0;
  v_reset_people int := 0; v_granted int := 0;
  v_block jsonb := '[]'::jsonb;
  v_started boolean; v_started_n int := 0; v_why text := null;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

  -- v35：这一年已经发过额度了 ⇒ 这不是「开新的一年」。
  -- 硬开会把已经发下去的天数当成「去年剩的」结转，再把其它假别清光却不补发。
  -- 那正是 2026 年那一次出的事。
  v_started := year_has_started(p_year);
  if v_started then
    select count(distinct l.emp_id) into v_started_n
      from leave_ledger l join employees e on e.id = l.emp_id
     where e.active and l.leave_year = p_year and l.kind in ('grant', 'carry_in');
    v_why := p_year || ' has already been credited — ' || v_started_n || ' employee(s) already hold '
          || p_year || ' leave. Start a new year sets up the year AHEAD. To change figures for a '
          || 'year already running, use Edit employee (one person) or the Leave types tab (everyone).';
    if not p_preview then raise exception '%', v_why; end if;
  end if;

  -- v27：上一年还挂着没批的假 ⇒ 那些天数会被当成「没用掉」结转/作废，
  -- 等审批人回来一批，又从新一年的余额里扣一次 —— 员工凭空少几天。
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', e.name, 'start', a.start_date, 'end', a.end_date,
           'days', a.days, 'status', a.status) order by e.name, a.start_date), '[]'::jsonb)
    into v_block
    from applications a join employees e on e.id = a.emp_id
   where e.active
     and a.status in ('pending', 'cancel_requested')
     and extract(year from a.start_date)::int = p_year - 1;
  if jsonb_array_length(v_block) > 0 and not p_preview then
    raise exception '% application(s) dated in % are still waiting: %. Approve, reject or cancel them first — otherwise those days count as unused and the people lose them.',
      jsonb_array_length(v_block), p_year - 1,
      (select string_agg(distinct x->>'name', ', ') from jsonb_array_elements(v_block) x);
  end if;

  select accrual_mode into v_mode from org_settings where id = 1;
  v_expires := carry_expiry_for(p_year);

  -- 步骤 1：把已经到期的结转落成账本条目（预览不写 —— 下面用 due_unwritten_carry 补上）
  if not p_preview then perform expire_due_carry(); end if;

  for r in select e.id, e.name, coalesce(e.carry_cap, 0) as cap
           from employees e where e.active order by e.name loop

    if exists (select 1 from year_start_log y where y.year = p_year and y.emp_id = r.id) then
      continue;
    end if;
    v_people := v_people + 1;
    v_cap := r.cap;

    -- 上一年（含更早还没结清的年份）留下的年假。**只看标签**，措辞完全不参与。
    -- 减 due_unwritten_carry：预览时上面那一步没写账，这样两条路数字一致；
    -- 执行时它已经落了账，这个函数返回 0，不会重复扣。
    v_left := coalesce((select sum(l.delta_days) from leave_ledger l
                         where l.emp_id = r.id and l.leave_type = 'annual'
                           and l.leave_year < p_year), 0)
            - due_unwritten_carry(r.id, 'annual');

    select coalesce(case
             when ac.expires_on is null then 0
             when ac.expired_at is not null then ac.expired_days
             else greatest(0, ac.carry_in - annual_used_between(r.id, make_date(ac.year,1,1), ac.expires_on))
           end, 0)
      into v_exp
      from annual_carry ac where ac.emp_id = r.id and ac.year = p_year - 1;
    v_exp := coalesce(v_exp, 0);
    if v_exp > 0 then v_expired_people := v_expired_people + 1; v_expired_days := v_expired_days + v_exp; end if;

    -- 结转夹到上限。**不夹 0**：欠着的天数（余额是负的）必须跟着进新一年，
    -- 否则一开年那笔债就凭空消失了。
    v_carry  := least(v_cap, v_left);
    v_excess := greatest(0, v_left - v_cap);
    v_taken  := annual_used_in_year(r.id, p_year - 1);
    if v_carry  > 0 then v_carry_people := v_carry_people + 1; v_carry_days := v_carry_days + v_carry; end if;
    if v_excess > 0 then v_forfeit_people := v_forfeit_people + 1; v_forfeit_days := v_forfeit_days + v_excess; end if;

    -- 步骤 2：其余假别清零。清多少 = 上一年（及更早）这种假的余额。
    v_resets := '[]'::jsonb; v_reset_days := 0;
    for t in select code, name_en, default_days from leave_types
             where resets_yearly and not no_deduct order by sort loop
      select coalesce(sum(l.delta_days), 0) into v_tb from leave_ledger l
        where l.emp_id = r.id and l.leave_type = t.code and l.leave_year < p_year;
      if v_tb <> 0 then
        v_resets := v_resets || jsonb_build_object(
          'code', t.code, 'name', t.name_en, 'cleared', v_tb, 'credits', t.default_days);
        v_reset_days := v_reset_days + v_tb;
        if not p_preview then
          insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
          values (r.id, t.code, -v_tb,
                  (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id(),
                  p_year - 1, 'writeoff');
        end if;
      end if;
    end loop;
    if jsonb_array_length(v_resets) > 0 then v_reset_people := v_reset_people + 1; end if;

    if not p_preview then
      -- 关掉上一年的年假：写掉全部余额，于是 leave_year < p_year 的年假合计正好是 0。
      if v_left <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, 'annual', -v_left,
                (p_year - 1) || ' annual leave closed — ' || fmt_days(greatest(0, v_carry))
                  || ' carried forward'
                  || case when v_excess > 0
                          then ', ' || fmt_days(v_excess) || ' above the carry-over cap ('
                               || fmt_days(v_cap) || ') — forfeited'
                          else '' end,
                current_emp_id(), p_year - 1, 'writeoff');
      end if;
      -- 结转变成一条真正的账本条目，属于新的一年。
      if v_carry <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, 'annual', v_carry,
                'Carried forward from ' || (p_year - 1)
                  || case when v_expires is not null
                          then ' (expires ' || to_char(v_expires, 'DD Mon YYYY') || ')' else '' end,
                current_emp_id(), p_year, 'carry_in');
      end if;
      insert into annual_carry (emp_id, year, carry_in, expires_on)
      values (r.id, p_year, greatest(0, v_carry), v_expires)
      on conflict (emp_id, year) do nothing;
      insert into year_start_log (year, emp_id, emp_name, annual_taken_prev, annual_left,
                                  cap_applied, carried, forfeited, expired, expires_on,
                                  resets, reset_days, run_by)
      values (p_year, r.id, r.name, v_taken, v_left, v_cap, greatest(0, v_carry), v_excess, v_exp,
              v_expires, v_resets, v_reset_days, current_emp_id());
    end if;

    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'taken_prev', v_taken, 'left', v_left, 'cap', v_cap,
      'carried', v_carry, 'forfeited', v_excess, 'expired', v_exp,
      'expires_on', v_expires, 'reset_days', v_reset_days, 'resets', v_resets);
  end loop;

  -- 步骤 3：发放新一年的额度。**必须在清零之后**，否则刚发的立刻被抹掉。
  if v_mode = 'monthly' then
    v_granted := 0;
  elsif p_preview then
    v_granted := (select count(distinct e.id) from employees e cross join leave_types lt
                  where e.active and lt.code <> 'oil' and (lt.default_days > 0 or lt.code = 'annual')
                    and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender)
                    and not exists (select 1 from leave_ledger l
                                    where l.emp_id = e.id and l.leave_type = lt.code
                                      and l.leave_year = p_year and l.kind = 'grant'));
  else
    v_granted := grant_annual_entitlements(p_year);
  end if;

  return jsonb_build_object(
    'year', p_year, 'preview', p_preview, 'people', v_people,
    'blockers', v_block,
    'already_started', v_started, 'blocked_reason', v_why,
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 13. 自检：回填之后，没有人多一天或少一天 ----------
do $$
declare bad int; r record;
begin
  select count(*) into bad from leave_ledger where leave_year is null or kind is null;
  if bad > 0 then raise exception 'v35 FAILED: % ledger row(s) still have no year or no kind', bad; end if;

  -- 余额：回填只写标签，不碰 delta_days，所以每个人每种假别的合计必须一模一样
  select count(*) into bad
    from _v35_before b
    join (select emp_id, leave_type, sum(delta_days) as total
            from leave_ledger group by emp_id, leave_type) a
      on a.emp_id = b.emp_id and a.leave_type = b.leave_type
   where a.total is distinct from b.total;
  if bad > 0 then raise exception 'v35 FAILED: % balance(s) changed during the backfill', bad; end if;

  -- 今年的额度：新旧两套规则必须给出同一个数字
  select count(*) into bad
    from _v35_before b
   where coalesce(b.entitled_now, 0)
         is distinct from entitled_in_year(b.emp_id, b.leave_type,
                                           extract(year from current_date)::int);
  if bad > 0 then
    for r in
      select e.name, b.leave_type, coalesce(b.entitled_now, 0) as was,
             entitled_in_year(b.emp_id, b.leave_type, extract(year from current_date)::int) as now
        from _v35_before b join employees e on e.id = b.emp_id
       where coalesce(b.entitled_now, 0)
             is distinct from entitled_in_year(b.emp_id, b.leave_type, extract(year from current_date)::int)
    loop
      raise warning '  % / % : % → %', r.name, r.leave_type, r.was, r.now;
    end loop;
    raise exception 'v35 FAILED: % entitlement figure(s) moved during the backfill', bad;
  end if;

  -- 规则里不该再出现按年份猜的写法
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public'
                and p.proname in ('annual_entitled_in_year', 'annual_used_in_year',
                                  'grant_annual_entitlements', 'entitled_in_year')
                and pg_get_functiondef(p.oid) like '%extract(year from%created_at%') then
    raise exception 'v35 FAILED: a year function still reads the year off created_at';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'run_year_start'
                and pg_get_functiondef(p.oid) like '%annual allowance%') then
    raise exception 'v35 FAILED: run_year_start still matches an allowance by its wording';
  end if;

  raise notice 'v35 installed: every ledger entry now records the leave year it belongs to.';
end $$;

drop table if exists _v35_before;
