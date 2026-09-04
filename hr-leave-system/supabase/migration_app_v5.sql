-- =============================================================
-- LeaveDesk — v5 对抗式审查修复
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 修复（均可被脚本触发）：
--   A.【中高】并发下余额双花：submit 的「先查余额/重叠→再插入」竞态
--        → 按员工事务级 advisory lock 串行化；并对巨型日期范围做夹取（防 working_days 逐日循环 DoS）
--   B.【中】批准落账前不复核余额 → 提交与批准之间余额变化可扣成负数 → approve 前复核 balance
--   C.【中】审批人离职后其名下 pending 申请无人可批 → 允许 HR 代批他人（但不能自批）
-- =============================================================

-- ---------- A. submit_application：advisory lock + 范围夹取 ----------
create or replace function submit_application(
  p_type text, p_start date, p_end date, p_sh boolean, p_eh boolean,
  p_reason text, p_attachment text default null, p_resubmit_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
begin
  select * into me from employees where auth_user_id = auth.uid() and active;
  if me.id is null then raise exception '未找到员工档案'; end if;
  -- 串行化同一员工的并发提交：消除余额/重叠「查后写」竞态（锁在事务提交时自动释放）
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception '假期类型不存在'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception '不符合该假期的资格条件'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception '该假期类型必须上传证明（MC）'; end if;
  -- 范围夹取：进逐日循环前拦掉超大区间，防 CPU DoS
  if p_end < p_start or p_end - p_start > 366 then
    raise exception '请假区间无效或过长（最多约一年）'; end if;
  d := working_days(p_start, p_end, p_sh, p_eh);
  if d <= 0 then raise exception '所选日期不含工作日'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances
      where emp_id = me.id and leave_type = p_type;
    if coalesce(avail, 0) < d then raise exception '余额不足：需 % 天，可用 % 天', d, coalesce(avail,0); end if;
  end if;
  if exists (select 1 from applications a where a.emp_id = me.id
             and a.id is distinct from p_resubmit_id
             and a.status in ('pending','approved','cancel_requested')
             and not (a.end_date < p_start or a.start_date > p_end)) then
    raise exception '所选日期与已有申请重叠';
  end if;

  if p_resubmit_id is not null then
    update applications set leave_type=p_type, start_date=p_start, end_date=p_end,
      start_half=p_sh, end_half=p_eh, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception '只能重新提交被退回的申请'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,d,p_reason,p_attachment,p_start<current_date)
    returning id into app_id;
  end if;

  insert into application_events (application_id, actor, action)
  values (app_id, me.id, case when p_resubmit_id is null then 'submitted' else 'resubmitted' end);

  if me.approver1 is null then
    update applications set status='approved', updated_at=now() where id=app_id;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (me.id, p_type, -d, '请假扣减', app_id, me.id);
    end if;
    insert into application_events (application_id, actor, action, comment)
    values (app_id, me.id, 'auto_approved', 'No approver required (Managing Director)');
  else
    insert into approval_steps (application_id, step_order, approver_id, status)
    values (app_id, 1, me.approver1, 'pending');
    if me.two_level and me.approver2 is not null then
      insert into approval_steps (application_id, step_order, approver_id, status)
      values (app_id, 2, me.approver2, 'waiting');
    end if;
  end if;
  return app_id;
end $$;

-- ---------- B + C. act_on_step：批准复核余额 + HR 代批兜底 ----------
create or replace function act_on_step(p_app uuid, p_action text, p_comment text default null, p_ack boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); a applications%rowtype; s approval_steps%rowtype;
        t leave_types%rowtype; nxt approval_steps%rowtype; has_overlap boolean;
begin
  if me_id is null then raise exception '未找到员工档案'; end if;
  select * into a from applications where id = p_app for update;
  if a.id is null or a.status <> 'pending' then raise exception '申请不在待审批状态'; end if;
  select * into s from approval_steps
    where application_id = p_app and step_order = a.current_step;
  -- 当前节点指名审批人，或 HR 代批他人（HR 不能借此自批）
  if s.approver_id is distinct from me_id
     and not (is_hr() and a.emp_id is distinct from me_id) then
    raise exception '你不是当前节点的审批人（HR 可代批他人）'; end if;
  if p_action in ('reject','return') and coalesce(trim(p_comment),'') = '' then
    raise exception '拒绝/退回必须填写原因'; end if;

  select * into t from leave_types where code = a.leave_type;

  if p_action = 'approve' then
    select exists (select 1 from overlapping_team_leave(p_app)) into has_overlap;
    if has_overlap and not p_ack then
      raise exception '同团队有人同日请假，必须勾选知晓（acknowledge）后才能批准';
    end if;
    if has_overlap then update applications set overlap_acknowledged = true where id = p_app; end if;
    update approval_steps set status='approved', comment=p_comment, acted_at=now() where id=s.id;
    select * into nxt from approval_steps
      where application_id=p_app and step_order=a.current_step+1;
    if nxt.id is not null then
      update approval_steps set status='pending' where id=nxt.id;
      update applications set current_step=current_step+1, updated_at=now() where id=p_app;
      insert into application_events (application_id,actor,action,comment)
      values (p_app, me_id, case when has_overlap then 'step_approved_overlap_ack' else 'step_approved' end, p_comment);
    else
      update applications set status='approved', updated_at=now() where id=p_app;
      if not t.no_deduct then
        -- 落账前复核：防提交与批准之间余额变化把余额扣成负数
        if coalesce((select balance from leave_balances
                     where emp_id=a.emp_id and leave_type=a.leave_type),0) < a.days then
          raise exception '批准失败：该员工 % 余额不足，无法扣减 % 天', a.leave_type, a.days;
        end if;
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
        values (a.emp_id, a.leave_type, -a.days, '请假扣减', p_app, me_id);
      end if;
      insert into application_events (application_id,actor,action,comment)
      values (p_app, me_id, case when has_overlap then 'approved_overlap_ack' else 'approved' end, p_comment);
    end if;
  elsif p_action = 'reject' then
    update approval_steps set status='rejected', comment=p_comment, acted_at=now() where id=s.id;
    update applications set status='rejected', updated_at=now() where id=p_app;
    insert into application_events (application_id,actor,action,comment)
    values (p_app, me_id, 'rejected', p_comment);
  elsif p_action = 'return' then
    update approval_steps set status='returned', comment=p_comment, acted_at=now() where id=s.id;
    update applications set status='returned', updated_at=now() where id=p_app;
    insert into application_events (application_id,actor,action,comment)
    values (p_app, me_id, 'returned', p_comment);
  else
    raise exception '未知动作 %', p_action;
  end if;
end $$;
