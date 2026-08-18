-- =============================================================
-- LeaveDesk SG — migration v14：年假上限 + 「按月累计 / 一次发放」
--
-- 与 v12 / v13 互不依赖，先后顺序随意。幂等，可重复执行。
--
-- 1) 年假上限（每家公司自己设）
--    现状：`annual_base + (年份 - 入职年 - 1)` **没有任何封顶**，
--    工龄 20 年、基数 14 的人会拿到 33 天，而且是一年一天悄悄涨上去的。
--    （org_settings.prorate_cap 只管新人**第一年**的折算，管不到这里。）
--    默认 NULL = 不封顶 —— 迁移当天不会有任何人的额度被改动。
--
-- 2) 年假发放方式：一次发放（annual）或按月累计（monthly）
--    按月累计做成**12 笔小额账本流水**，而不是「实时算出来的数字」。
--    本系统的根本不变量是「余额 = 所有流水之和」；如果改成实时计算，
--    所有读取路径都得跟着改，且这条不变量就没了。
-- =============================================================

alter table org_settings add column if not exists annual_cap numeric(5,1);
comment on column org_settings.annual_cap is
  'Maximum annual leave after long-service increments. NULL = no maximum (previous behaviour). Does not affect a new joiner first-year pro-rate, which uses prorate_cap.';

alter table org_settings add column if not exists accrual_mode text not null default 'annual';
do $$ begin
  alter table org_settings add constraint org_settings_accrual_mode_ck
    check (accrual_mode in ('annual','monthly'));
exception when duplicate_object then null; end $$;
comment on column org_settings.accrual_mode is
  'annual = whole entitlement credited once (1 Jan). monthly = credited in 12 instalments as it is earned; employees can then go negative if they take more than accrued so far.';

-- ---------- 1. 上限只加在「工龄递增」那一支 ----------
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select case
    when extract(year from e.join_date) >= p_year
      then least(
             ceil(e.annual_base * (12 - extract(month from e.join_date) + 1) / 12 * 2) / 2,
             coalesce((select prorate_cap from org_settings where id = 1), 1e9))
    else least(
           e.annual_base + greatest(0, p_year - extract(year from e.join_date) - 1),
           coalesce((select annual_cap from org_settings where id = 1), 1e9))
  end
  from employees e where e.id = p_emp;
$$;

-- ---------- 2. 按月累计 ----------
-- 每月发放 = 「到本月为止应得的累计额」减「今年已经发过的」。
-- 用累计差额而不是每月 annual/12，四舍五入就不会越滚越偏，12 月正好落在全年额度上。
create or replace function accrue_monthly_leave(p_year int, p_month int)
returns int language plpgsql security definer set search_path = public as $$
declare
  n int := 0; r record;
  v_full numeric; v_target numeric; v_already numeric; v_add numeric;
  v_start_month int;
begin
  if not is_hr() and session_user <> 'postgres' and current_user <> 'service_role' then
    raise exception 'Only HR or the scheduled job can accrue monthly leave'; end if;
  if coalesce((select accrual_mode from org_settings where id = 1), 'annual') <> 'monthly' then
    return 0;   -- 一次发放模式下什么都不做，避免两种方式同时记账
  end if;
  if p_month < 1 or p_month > 12 then raise exception 'Month must be 1-12'; end if;

  for r in select e.id as emp_id, e.join_date from employees e where e.active loop
    v_full := annual_entitlement_for(r.emp_id, p_year);
    if v_full is null or v_full <= 0 then continue; end if;

    -- 年中入职的人从入职当月开始累计
    v_start_month := case when extract(year from r.join_date)::int = p_year
                          then extract(month from r.join_date)::int else 1 end;
    if p_month < v_start_month then continue; end if;

    v_target := round(v_full * (p_month - v_start_month + 1)
                      / (12 - v_start_month + 1), 2);

    select coalesce(sum(delta_days), 0) into v_already
      from leave_ledger
      where emp_id = r.emp_id and leave_type = 'annual'
        and reason like p_year || ' monthly accrual%';

    v_add := v_target - v_already;
    if v_add > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.emp_id, 'annual', v_add,
              p_year || ' monthly accrual — month ' || p_month, current_emp_id());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function accrue_monthly_leave(int, int) from anon, public;
grant  execute on function accrue_monthly_leave(int, int) to authenticated, service_role;

-- ---------- 3. 一次发放的函数在 monthly 模式下必须让路 ----------
-- 否则切换模式的当年会被记两次账。
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
  if coalesce((select accrual_mode from org_settings where id = 1), 'annual') = 'monthly' then
    raise exception 'This company credits annual leave monthly. Use accrue_monthly_leave(), or switch the mode in Company settings first.';
  end if;
  for r in
    select e.id as emp_id, t.code, t.default_days
    from employees e cross join leave_types t
    where e.active and (t.default_days > 0 or t.code = 'annual')
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

-- ---------- 验证 ----------
select 'columns' as check,
  (select count(*) from information_schema.columns where table_name='org_settings' and column_name='annual_cap')   as cap,
  (select count(*) from information_schema.columns where table_name='org_settings' and column_name='accrual_mode') as mode;
select 'current settings' as check, annual_cap, accrual_mode from org_settings where id = 1;
