-- =============================================================
-- LeaveDesk — 正式版接线补丁（在已跑过 schema.sql + seed.sql 之后执行一次）
-- 作用：给正式版 app.html 补两样东西
--   1) employees.title（职位/job title 列）
--   2) leave_available()（让审批人能看到申请人余额数字，受权限保护）
-- 在 Supabase → SQL Editor 里整段粘贴 → Run 即可（可重复执行，安全）。
-- =============================================================

-- 1) 职位列（HR 新增/编辑员工时填写）
alter table employees add column if not exists title text;

-- 2) 审批人查看申请人可用天数（RLS 不让非 HR 读别人账本，用受控 definer 函数）
create or replace function leave_available(p_emp uuid, p_code text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare allowed boolean;
begin
  select is_hr() or exists (
    select 1 from applications a join approval_steps s on s.application_id = a.id
    where a.emp_id = p_emp and s.approver_id = current_emp_id()
  ) into allowed;
  if not allowed then raise exception '无权查看该员工余额'; end if;
  return coalesce((select balance from leave_balances where emp_id = p_emp and leave_type = p_code), 0)
       - coalesce((select sum(days) from applications
                   where emp_id = p_emp and leave_type = p_code and status = 'pending'), 0);
end $$;

-- 3) 修复：申请/审批步骤/事件的读取策略原来在 policy 里查自己的表，
--    导致 Postgres 报 "infinite recursion detected in policy"。改为封装进
--    security definer 函数（函数内绕过 RLS），三张表的读取策略都指向它。
create or replace function can_view_application(p_app uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from applications a where a.id = p_app
      and (a.emp_id = current_emp_id() or is_hr()
           or exists (select 1 from approval_steps s
                      where s.application_id = a.id and s.approver_id = current_emp_id())));
$$;

drop policy if exists app_read    on applications;
drop policy if exists steps_read  on approval_steps;
drop policy if exists events_read on application_events;
create policy app_read    on applications        for select to authenticated using (can_view_application(id));
create policy steps_read  on approval_steps      for select to authenticated using (can_view_application(application_id));
create policy events_read on application_events  for select to authenticated using (can_view_application(application_id));

-- 4) 清理集成测试期间插入的临时部门（如不存在则无操作）
delete from departments where name = 'ZZ Temp Test';
