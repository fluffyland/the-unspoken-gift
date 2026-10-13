-- LeaveDesk SG — migration v10：员工「彻底删除」「清空记录」+ 离职/删除的安全加固
-- 幂等，可重复执行。SQL Editor 粘贴 → Run 一次即可。
--
-- 包含：
--   1. purge_employee(uuid)          彻底删除员工（供应用「Delete permanently」按钮调用）
--   2. clear_employee_records(uuid)  清空员工的请假记录但保留账号（「Clear leave records」按钮）
--   3. offboard_employee 加固        HR 不能离职结算 Owner；离职者不再挂着别人的审批链
--   4. guard_employee_self_edit 加固 允许上述服务端函数内部整理审批人引用（GUC 旁路）
--
-- 安全设计：
--   · 三个函数都是 security definer，但内部先校验调用者是 HR；
--   · 目标是 Owner / Super Admin 时，只有另一位 Owner 才能操作（防 HR 越权接管/清除 Owner）；
--   · 不能对自己执行删除/离职；
--   · 待审批环节不会被删成「悬空」：目标员工名下待审的环节自动转给执行操作的 HR。

-- ---------- 0. 自我编辑守卫：加服务端旁路 ----------
-- purge/offboard 需要把「别人以目标为审批人」的引用置空；若其中恰好包括执行者自己的行，
-- 原触发器会拦下（不能改自己的审批人）。函数内先设 leavedesk.svc=1（事务内有效）即可放行。
create or replace function guard_employee_self_edit() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return new; end if;      -- SQL Editor / 后台任务放行
  if coalesce(current_setting('leavedesk.svc', true), '') = '1' then return new; end if;  -- 服务端函数内部放行
  if is_admin() then return new; end if;       -- Owner 可改任何人任何字段
  if new.role = 'admin' and (tg_op = 'INSERT' or old.role is distinct from 'admin') then
    raise exception '只有 Owner 能设置 Owner / Super Admin 账号';
  end if;
  if tg_op = 'UPDATE' and new.id = me and (
       new.approver1   is distinct from old.approver1
    or new.approver2   is distinct from old.approver2
    or new.two_level   is distinct from old.two_level
    or new.annual_base is distinct from old.annual_base
    or new.role        is distinct from old.role) then
    raise exception '不能修改自己的审批人 / 年假基数 / 账号类型，请由 Owner 代改';
  end if;
  return new;
end $$;
drop trigger if exists trg_employee_self_edit on employees;
create trigger trg_employee_self_edit before insert or update on employees
  for each row execute function guard_employee_self_edit();

-- ---------- 1. 彻底删除一个员工 ----------
-- 清掉：其申请（级联审批步骤/事件）、账目、公告已读、年假结转、审批人引用、
--       他给别人记账的 created_by、他在别人申请上的已决审批步骤与事件；
-- 转移：他名下「待审 / 等待中」的别人申请环节 → 执行操作的 HR（避免申请卡死）；
-- 最后删除员工档案本身。登录账号由应用侧 create-login 函数的 remove 动作先行删除。
create or replace function purge_employee(p_emp uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); tgt employees%rowtype;
begin
  if not is_hr() then raise exception 'Only HR can delete employees'; end if;
  if p_emp = me_id then raise exception 'You cannot delete your own account'; end if;
  select * into tgt from employees where id = p_emp;
  if tgt.id is null then raise exception 'Employee not found'; end if;
  if tgt.role = 'admin' and not is_admin() then
    raise exception 'Only the Owner / Super Admin can delete an Owner account';
  end if;

  perform set_config('leavedesk.svc', '1', true);   -- 本事务内放行守卫触发器

  -- 1) 别人把他当审批人的引用先解开（这些员工此后改为自动批准/单级，可再指派）
  update employees set approver1 = null where approver1 = p_emp;
  update employees set approver2 = null, two_level = false where approver2 = p_emp;

  -- 2) 他给别人记账时的 created_by 置空（保留别人的账目）
  update leave_ledger set created_by = null where created_by = p_emp;

  -- 3) 他自己的申请（approval_steps / application_events 会级联删除）与账目、结转、公告已读
  delete from applications where emp_id = p_emp;
  delete from leave_ledger where emp_id = p_emp;
  delete from annual_carry where emp_id = p_emp;
  delete from announcement_reads where emp_id = p_emp;

  -- 4) 他在别人申请上的审批环节：待审/等待中的转给执行操作的 HR（申请不卡死），已决的删除
  update approval_steps set approver_id = me_id
    where approver_id = p_emp and status in ('pending', 'waiting');
  delete from approval_steps where approver_id = p_emp;
  delete from application_events where actor = p_emp;

  -- 5) 员工档案
  delete from employees where id = p_emp;
end $$;

-- ---------- 2. 清空一个员工的请假记录（保留档案与登录账号） ----------
create or replace function clear_employee_records(p_emp uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tgt employees%rowtype;
begin
  if not is_hr() then raise exception 'Only HR can clear records'; end if;
  select * into tgt from employees where id = p_emp;
  if tgt.id is null then raise exception 'Employee not found'; end if;
  if tgt.role = 'admin' and not is_admin() then
    raise exception 'Only the Owner / Super Admin can clear an Owner account''s records';
  end if;
  delete from applications where emp_id = p_emp;   -- 级联 approval_steps + application_events
  delete from leave_ledger where emp_id = p_emp;   -- 清空账目 → 余额归零
  delete from annual_carry where emp_id = p_emp;   -- 结转记录属于请假记录，一并清
end $$;

-- ---------- 3. 离职结算加固 ----------
-- 新增：目标是 Owner 时只有 Owner 能操作；离职者名下待审环节转给执行操作的 HR；
--       别人把他当审批人的引用解开（否则申请会送到一个再也无法登录的人手里）。
create or replace function offboard_employee(p_emp uuid, p_last_day date, p_mode text)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); r record; tgt employees%rowtype;
begin
  if not is_hr() then raise exception '只有 HR 能执行离职结算'; end if;
  if p_mode not in ('encash','clear') then raise exception 'mode 必须是 encash 或 clear'; end if;
  if p_emp = me_id then raise exception '不能对自己执行离职结算'; end if;
  select * into tgt from employees where id = p_emp;
  if tgt.id is null then raise exception 'Employee not found'; end if;
  if tgt.role = 'admin' and not is_admin() then
    raise exception 'Only the Owner / Super Admin can offboard an Owner account';
  end if;

  perform set_config('leavedesk.svc', '1', true);

  update applications set status='withdrawn', updated_at=now()
    where emp_id=p_emp and status='pending';
  insert into application_events (application_id, actor, action, comment)
    select id, me_id, 'withdrawn', 'Offboarding' from applications
    where emp_id=p_emp and status='withdrawn' and updated_at >= now() - interval '5 seconds';

  for r in select leave_type, sum(delta_days) as balance from leave_ledger
           where emp_id=p_emp group by leave_type having sum(delta_days) <> 0
  loop
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
    values (p_emp, r.leave_type, -r.balance,
            'Offboarding (last day ' || p_last_day || ') — balance ' ||
            case when p_mode='encash' then 'encashed' else 'cleared' end, me_id);
  end loop;

  -- 他名下待审的别人申请 → 转给执行操作的 HR；把他从别人的审批链上摘下来
  update approval_steps set approver_id = me_id
    where approver_id = p_emp and status in ('pending', 'waiting');
  update employees set approver1 = null where approver1 = p_emp;
  update employees set approver2 = null, two_level = false where approver2 = p_emp;

  update employees set active=false, last_working_day=p_last_day where id=p_emp;
end $$;

grant execute on function purge_employee(uuid) to authenticated;
grant execute on function clear_employee_records(uuid) to authenticated;
