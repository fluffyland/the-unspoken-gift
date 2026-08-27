-- =============================================================
-- LeaveDesk migration v19 —— 年假额度：填进去的数字**就是**当年的总额度
--
-- 这一版修的是 v18 留下的一个真问题：
--   set_annual_entitlement 只在找到 reason 恰好等于 '2026 annual allowance'
--   的那一行时才补差额。可是**从系统里「Add employee」加进来的人**，那一行的
--   reason 是 'Pro-rated leave allowance (joined ...)' —— 对不上，于是什么都不写。
--   屏幕上却写着「This year's balance moves from 19 to 20, and it is recorded」。
--   承诺了一件数据库根本没做的事，这是最坏的一类错。
--
-- 用户的决定（原话：「the system should total should change to 15 days」）：
--   **填 15，当年的年假额度就正好是 15**，而不是「在现有基础上加 1」。
--   剩余 = 15 + 上年结转 − 已休。于是：
--     · 不再靠 reason 字符串猜，谁都适用；
--     · 之前重复发放撑出来的 972 / 19 这类数字，保存一次额度就自动纠正回来。
--
-- 本版内容：
--   1. annual_entitled_in_year()：当年「算作额度」的天数。请假扣减和销假返还
--      都带 ref_application，直接排除；年末失效/超上限作废按文字排除。
--   2. set_annual_entitlement()：对账到填进去的数字（不是加差额）。
--   3. bump_annual_all()：一键给全公司每人加 N 天年假 —— 额度**永久**加 N，
--      当年余额同时补 N。超过公司上限的人跳过并列出名字。
--
-- 依赖 v18。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 0. 前置迁移可能没跑过（HANDOVER 第一条教训） ----------
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table employees    add column if not exists carry_cap    numeric(5,1);

-- ---------- 1. 当年「算作额度」的天数 ----------
-- 什么算额度：年度发放、入职发放、历次额度调整、按月累积。
-- 什么不算：
--   · 请假扣减、销假返还 —— 这两种都写了 ref_application，一并排除，
--     这比按文字匹配可靠（返还是**正数**，不排除就会被当成额度）。
--   · 年末清零、结转到期、超出结转上限作废、离职结算 —— 是账务，不是额度。
create or replace function annual_entitled_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(delta_days), 0)
    from leave_ledger
   where emp_id = p_emp
     and leave_type = 'annual'
     and extract(year from created_at)::int = p_year
     and ref_application is null
     and reason not like '%expired (unused)%'
     and reason not like '%above the carry-over cap%'
     and reason not like '%reset — use it or lose it%'
     and reason not like '%excess forfeited%'
     and reason not like '%expired carry-over%'
     and reason not like 'Offboarding%'
     and reason not like '%结转%'
     and reason not like '%作废%';
$$;
comment on function annual_entitled_in_year(uuid, int) is
  'Days credited as ENTITLEMENT this year — grants, joining credits and entitlement changes. Leave taken and refunds carry ref_application and are excluded; year-end write-offs are excluded by wording.';
revoke execute on function annual_entitled_in_year(uuid, int) from anon;
grant  execute on function annual_entitled_in_year(uuid, int) to authenticated;

-- ---------- 2. 设定年假额度：对账到这个数字 ----------
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

  -- 今年还一天额度都没发过的人：不补。等年初发放时自然就是新数字。
  -- （v18 是拿 reason 字符串去认那一行，认不出来就整个跳过 —— 这就是「系统里加进来的人
  --   改了额度却什么都没发生」的原因。现在按**总额**判断，与措辞无关。）
  if not exists (select 1 from leave_ledger
                  where emp_id = p_emp and leave_type = 'annual'
                    and extract(year from created_at)::int = y
                    and ref_application is null) then
    perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, 0, 1, '');
    return 0;
  end if;

  ent := annual_entitled_in_year(p_emp, y);
  adj := p_days - ent;                      -- 对账：把当年额度**补成**填进去的数字
  if adj <> 0 then
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
    values (p_emp, 'annual', adj,
            y || ' annual entitlement set to ' || fmt_days(p_days), current_emp_id());
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, adj, 1, '');
  return adj;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 3. 一键给全公司加年假 ----------
-- 用户原话：「one click then it will credit whole company with one day of annual leave」，
-- 并选了「永久」：每人的 Annual Leave Entitled / Yr 加 N（明年自动就是新数字），
-- 当年余额同时补 N。会超过公司上限的人**跳过并列名**，不静默截断 ——
-- 「max AL is link, it cannot goes over the max AL i set」。
create or replace function bump_annual_all(p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cap numeric; r record; n int := 0; credited int := 0;
        skipped text[] := '{}'; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit annual leave'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  cap := (select annual_cap from org_settings where id = 1);

  for r in select id, name, annual_base from employees where active order by name loop
    if cap is not null and r.annual_base + p_days > cap then
      skipped := skipped || r.name;
      continue;
    end if;
    if r.annual_base + p_days < 0 then
      skipped := skipped || r.name;
      continue;
    end if;
    n := n + 1;
    -- 只给今年已经发过额度的人补当年余额；没发过的，改额度就够了。
    if exists (select 1 from leave_ledger
                where emp_id = r.id and leave_type = 'annual'
                  and extract(year from created_at)::int = y
                  and ref_application is null) then
      credited := credited + 1;
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', p_days,
                y || ' annual leave ' || case when p_days > 0 then '+' else '' end ||
                fmt_days(p_days) || ' — company-wide', current_emp_id());
      end if;
    end if;
    if not p_preview then
      update employees set annual_base = annual_base + p_days where id = r.id;
    end if;
  end loop;

  -- n = 0 表示一个人都没加成（例如全部卡在公司上限）。这种情况**不写记录**：
  -- 否则修订记录里会留下一条「+1 day to every employee」，而实际上谁都没拿到。
  if not p_preview and n > 0 then
    -- 全公司一条记录，不逐个列名字（用户明确要求）。
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

-- ---------- 4. 自检 ----------
do $$
begin
  raise notice 'v19 installed: % / % / %',
    (select count(*) from pg_proc where proname = 'annual_entitled_in_year'),
    (select count(*) from pg_proc where proname = 'set_annual_entitlement'),
    (select count(*) from pg_proc where proname = 'bump_annual_all');
end $$;
