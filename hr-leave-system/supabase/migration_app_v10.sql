-- LeaveDesk SG — migration v10：员工「彻底删除」与「清空记录」的服务端函数（供应用按钮调用）
-- 幂等，可重复执行。SQL Editor 粘贴 → Run 一次即可。
-- 说明：这两个函数用 security definer 绕过 RLS 完成级联清理，但函数内部先校验调用者是 HR；
--       不会删除 auth 登录账号（登录账号由应用侧的 create-login 函数 remove 动作删除）。

-- 彻底删除一个员工：清掉其申请（连带审批步骤/事件）、账目、审批人引用、他给别人记账的 created_by，
-- 最后删除员工档案本身。不会误删别人的余额；不能删自己。
create or replace function purge_employee(p_emp uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_hr() then raise exception 'Only HR can delete employees'; end if;
  if p_emp = current_emp_id() then raise exception 'You cannot delete your own account'; end if;
  if not exists (select 1 from employees where id = p_emp) then raise exception 'Employee not found'; end if;

  update employees set approver1 = null where approver1 = p_emp;
  update employees set approver2 = null, two_level = false where approver2 = p_emp;
  update leave_ledger set created_by = null where created_by = p_emp;   -- 保留别人的账目
  delete from applications where emp_id = p_emp;      -- 级联 approval_steps + application_events
  delete from leave_ledger where emp_id = p_emp;
  delete from approval_steps where approver_id = p_emp;    -- 他在别人申请上的审批步骤
  delete from application_events where actor = p_emp;      -- 他在别人申请上的操作事件
  delete from employees where id = p_emp;
end $$;

-- 清空一个员工的所有请假记录（申请 + 账目 → 余额归零），但保留档案与登录账号。
create or replace function clear_employee_records(p_emp uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_hr() then raise exception 'Only HR can clear records'; end if;
  if not exists (select 1 from employees where id = p_emp) then raise exception 'Employee not found'; end if;
  delete from applications where emp_id = p_emp;   -- 级联 approval_steps + application_events
  delete from leave_ledger where emp_id = p_emp;
end $$;

grant execute on function purge_employee(uuid) to authenticated;
grant execute on function clear_employee_records(uuid) to authenticated;
