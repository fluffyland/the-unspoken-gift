-- =============================================================
-- LeaveDesk — v9：新员工首年年假「按月折算」封顶（可选）
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 只加一列 + 更新一个函数。跑完后「Company settings」会出现
-- 「Cap pro-rated annual leave at」一栏；留空 = 不封顶。
-- =============================================================
alter table org_settings add column if not exists prorate_cap numeric(5,1);

-- 首年 pro-rate 的结果不超过 org_settings.prorate_cap（为空则不封顶）。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select case
    when extract(year from e.join_date) >= p_year
      then least(
             ceil(e.annual_base * (12 - extract(month from e.join_date) + 1) / 12 * 2) / 2,
             coalesce((select prorate_cap from org_settings where id = 1), 1e9))
    else e.annual_base + greatest(0, p_year - extract(year from e.join_date) - 1)
  end
  from employees e where e.id = p_emp;
$$;
