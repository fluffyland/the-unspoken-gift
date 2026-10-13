-- ============================================================================
-- migration_app_v31.sql — 年假不再有任何自动增长；并把 annual_base 对回真实账本
--
-- 用户原话：
--   「remove all automation of crediting one annualleave every year」
--   「first year HR will calculate by themself and will credit them via edit employee」
--   「the balance sheet tab MUST show the REAL value ... then under edit employee the box
--     it should follow the Real values」
--
-- 背景（Barry 的例子，真实数据）：
--   2026-07-09  +17     「2026 年度配额」   ← 旧规则：annual_base(14) + 3 年年资
--   2026-08-28  +3.5     全公司统一加
--   账本合计 20.5，而 employees.annual_base 只有 17.5 —— 差的正是那 3 天年资。
--   Edit employee 显示的是 annual_base，一按 Save 就把真实的 20.5 拉到 14，凭空少 6.5 天。
--
-- 这个脚本做三件事，都不动任何人的天数：
--   1. annual_entitlement_for → 只取 annual_base（年资、首年折算全部去掉）
--   2. 删掉 org_settings.prorate_cap（首年折算的封顶，已无人使用）
--   3. 把 annual_base 修正成本年度**实际发放**的天数，让两个数字从此一致
--
-- 幂等：重复执行没有副作用。第 3 步只改 employees 这一列，**不写任何 leave_ledger**。
-- ============================================================================

-- ---------- 1. 唯一的年假规则：就是那个数字 ----------
-- v18 已经在正式库里这么改了，这里重申一次，好让任何一套旧库执行后也对齐。
-- schema.sql 里那份（年资 + 首年折算）同步删掉了 —— 否则新装一套系统会把规则带回来。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select least(e.annual_base,
               coalesce((select annual_cap from org_settings where id = 1), 1e9))
  from employees e where e.id = p_emp;
$$;

comment on function annual_entitlement_for(uuid, int) is
  'This year''s annual leave = the employee''s annual_base, capped by org_settings.annual_cap. Nothing is added for length of service and no first-year pro-rate: HR types the figure they want, in Edit employee or on the Leave types tab.';

-- ---------- 2. 首年折算封顶：连列一起删 ----------
-- 留着它，下一个读代码的人会以为首年折算还在。
alter table org_settings drop column if exists prorate_cap;

-- ---------- 3. 把 annual_base 对回真实账本 ----------
-- 只改「今年确实发过年假」的在职员工。没发过的人账本没有意见，保持原样。
-- 不写账本 = 没有人多一天或少一天，只是那一列不再说谎。
do $$
declare y int := extract(year from current_date)::int;
        n int := 0; over_cap text[] := '{}'; r record; cap numeric;
begin
  cap := (select annual_cap from org_settings where id = 1);

  for r in
    select e.id, e.name, e.annual_base as was, annual_entitled_in_year(e.id, y) as truth
      from employees e
     where e.active
       and exists (select 1 from leave_ledger l
                    where l.emp_id = e.id and l.leave_type = 'annual'
                      and extract(year from l.created_at)::int = y
                      and l.ref_application is null)
       and annual_entitled_in_year(e.id, y) <> e.annual_base
  loop
    update employees set annual_base = r.truth where id = r.id;
    n := n + 1;
    raise notice '  % : % → %  (Edit employee now agrees with Balances)',
      r.name, trim_scale(r.was), trim_scale(r.truth);
    if cap is not null and r.truth > cap then
      over_cap := over_cap || (r.name || ' (' || trim_scale(r.truth) || ')');
    end if;
  end loop;

  raise notice 'v31: % employee(s) corrected. No ledger rows were written — nobody gained or lost a day.', n;

  -- 真实发放数高于公司上限的人：不静默截断（那才是真的扣人天数），只报出来。
  if array_length(over_cap, 1) > 0 then
    raise warning 'Above the company maximum of % days: %. Their days are untouched, but Edit employee will refuse to save them at that figure until you raise the maximum.',
      trim_scale(cap), array_to_string(over_cap, ', ');
  end if;
end $$;

-- ---------- 4. 自检 ----------
do $$
declare bad int;
begin
  -- 规则里不该再出现 join_date
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'annual_entitlement_for'
                and pg_get_functiondef(p.oid) like '%join_date%') then
    raise exception 'v31 FAILED: annual_entitlement_for still refers to join_date';
  end if;
  if exists (select 1 from information_schema.columns
              where table_name = 'org_settings' and column_name = 'prorate_cap') then
    raise exception 'v31 FAILED: org_settings.prorate_cap is still there';
  end if;
  select count(*) into bad
    from employees e
   where e.active
     and exists (select 1 from leave_ledger l
                  where l.emp_id = e.id and l.leave_type = 'annual'
                    and extract(year from l.created_at)::int = extract(year from current_date)::int
                    and l.ref_application is null)
     and annual_entitled_in_year(e.id, extract(year from current_date)::int) <> e.annual_base;
  if bad > 0 then raise exception 'v31 FAILED: % employee(s) still disagree with their ledger', bad; end if;
  raise notice 'v31 installed: no automatic yearly day, no first-year pro-rate, every stored figure matches its ledger.';
end $$;
