-- LeaveDesk SG — 清空某个员工的所有请假记录，但保留其档案与登录账号
-- 用途：某人记录乱了想从零开始（清掉所有申请与账目），但人还在、还能登录。
-- 用法：Supabase → SQL Editor → 把 'gary@yourcompany.sg' 换成该员工邮箱 → Run。
-- 效果：删除其全部申请（连带审批步骤/事件）与请假账目 → 各项余额归零；
--       员工档案、登录账号、审批关系全部保留。
--
-- 想清空后重新发放额度：再执行一次 grant（会按其入职日期/额度补上年假等），例如：
--   select grant_annual_entitlements(extract(year from current_date)::int);

do $$
declare v_id uuid;
begin
  select id into v_id from employees where lower(email) = lower('gary@yourcompany.sg');
  if v_id is null then raise notice 'No employee with that email — nothing cleared.'; return; end if;

  delete from applications where emp_id = v_id;   -- 连带 approval_steps / application_events
  delete from leave_ledger where emp_id = v_id;   -- 清空账目 → 余额归零

  raise notice 'Cleared all leave records for employee %. Account kept.', v_id;
end $$;
