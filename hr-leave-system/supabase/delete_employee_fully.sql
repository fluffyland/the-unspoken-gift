-- LeaveDesk SG — 彻底删除某个员工（连同登录账号与其所有痕迹）
-- ⚠ 仅用于「测试账号 / 建错的记录」。真实离职员工请用应用里的 Offboard（保留历史，合规更稳妥）。
-- 用法：Supabase → SQL Editor → 把下面 'gary@yourcompany.sg' 换成该员工邮箱 → Run。
--
-- 会删除：该员工的所有申请（连带审批步骤/事件）、其请假账目、员工档案本身、其登录账号；
--         并把「其他员工把他设为审批人」的引用清空、把「他给别人记的账目」的 created_by 置空
--         （不会误删别人的余额/记录）。

do $$
declare v_id uuid; v_uid uuid;
begin
  select id, auth_user_id into v_id, v_uid from employees where lower(email) = lower('gary@yourcompany.sg');
  if v_id is null then raise notice 'No employee with that email — nothing deleted.'; return; end if;

  -- 1) 别人把他当审批人的引用先解开
  update employees set approver1 = null where approver1 = v_id;
  update employees set approver2 = null, two_level = false where approver2 = v_id;

  -- 2) 他给别人记账时的 created_by 置空（保留别人的账目）
  update leave_ledger set created_by = null where created_by = v_id;

  -- 3) 他自己的申请（approval_steps / application_events 会级联删除）、账目、结转、公告已读
  delete from applications where emp_id = v_id;
  delete from leave_ledger where emp_id = v_id;
  delete from annual_carry where emp_id = v_id;
  delete from announcement_reads where emp_id = v_id;

  -- 4) 他在别人申请上留下的审批步骤/事件（审计痕迹，彻底清除时一并删）
  delete from approval_steps where approver_id = v_id;
  delete from application_events where actor = v_id;

  -- 5) 员工档案 + 登录账号
  delete from employees where id = v_id;
  if v_uid is not null then delete from auth.users where id = v_uid; end if;

  raise notice 'Fully deleted employee % (auth user %).', v_id, v_uid;
end $$;

-- 提示：若该员工是别人待审申请的审批人，删除后那些申请的对应审批步骤也会消失，
--       相关申请可能卡住——彻底删除前，最好先在应用里把这些员工的审批人改掉。
