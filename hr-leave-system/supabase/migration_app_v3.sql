-- =============================================================
-- LeaveDesk — v3 安全加固(第一性原理:信任锚点 = 登录账号↔在职员工档案)
-- SQL Editor 整段执行一次;可重复执行。
-- 修复(均经 live 实测坐实):
--   A. leave_balances 视图绕过 RLS:未登录都能读全公司余额 → security_invoker
--   B. "已登录"被当成信任边界:任何自助注册的陌生账号可读员工名录/日历
--      → 一切只读策略改为"在职员工才可读"(is_staff)
--   C. 离职员工仍能登录读数据 → 身份地基函数加 active,服务器层等于登出
-- =============================================================

-- ---------- 1. 身份地基:调用者作为【在职】员工的身份 ----------
-- 整个权限体系唯一的信任锚点;加 active 后,离职者在数据库层全部策略自动失效。
create or replace function current_emp_id() returns uuid
language sql stable security definer set search_path = public as
$$ select id from employees where auth_user_id = auth.uid() and active $$;

create or replace function is_hr() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from employees
                  where auth_user_id = auth.uid() and role in ('hr','admin') and active) $$;

-- "是本公司在职员工吗?"——所有全员可读数据的统一门禁
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select current_emp_id() is not null $$;

-- ---------- 2. 全员可读的数据:从"登录即可读"收紧为"在职员工才可读" ----------
drop policy if exists emp_read  on employees;
drop policy if exists lt_read   on leave_types;
drop policy if exists ph_read   on public_holidays;
drop policy if exists dept_read on departments;
drop policy if exists org_read  on org_settings;
create policy emp_read  on employees       for select to authenticated using (is_staff());
create policy lt_read   on leave_types     for select to authenticated using (is_staff());
create policy ph_read   on public_holidays for select to authenticated using (is_staff());
create policy dept_read on departments     for select to authenticated using (is_staff());
create policy org_read  on org_settings    for select to authenticated using (is_staff());

-- ---------- 3. 视图漏洞 ----------
-- leave_balances:改为以调用者身份执行 → 底层账本的 RLS(本人/HR)自动生效。
-- 存储过程(submit/leave_available/offboard)以属主身份查询,不受影响。
alter view leave_balances set (security_invoker = true);

-- leave_calendar:本来就要给全员看(姓名/日期/状态),保持属主执行,
-- 但在查询体内加 is_staff() 门 —— 非在职员工得到空集。
create or replace view leave_calendar as
select e.name, e.dept, a.start_date, a.end_date,
       case when a.status = 'pending' then 'pending' else 'approved' end as status
from applications a join employees e on e.id = a.emp_id
where a.status in ('pending','approved','cancel_requested') and e.active
  and is_staff();

-- 未登录(anon)通道彻底斩断
revoke select on leave_balances from anon;
revoke select on leave_calendar from anon;
