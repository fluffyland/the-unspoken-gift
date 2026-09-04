-- =============================================================
-- LeaveDesk — v4 复审修复（2026-07-11 专业代码复审后）
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 修复（按严重度）：
--   1.【高危】grant_annual_entitlements 未登录(anon)即可调用 → 篡改全员账本
--        → 门禁改「白名单」(只有 HR 或 SQL Editor 超级用户) + 从 anon/public 收回执行权
--   2. 并发/双击重复提交 → applications 部分唯一索引兜底（前端另加防抖）
--   3. overlapping_team_leave 是 definer 但无鉴权 → 查询体加「HR 或链上审批人」过滤 + 收回 anon 执行权
--   4. employees 全列暴露给任何在职员工（含 auth_user_id/annual_base/离职档案）
--        → 新建 employees_directory 目录视图（仅非敏感列，全员可读）；原表收紧为 本人/HR
--   7. act_on_step 用裸 `<> me_id`，me_id 为 NULL 时静默跳过鉴权 → 显式判空
-- 注：注册按邮箱自动认领(link_employee_on_signup)本轮不改代码——真正的边界是
--     Dashboard「关闭自助注册」(已关)；代码层加 invited 列若默认放开则无保护、
--     若默认收紧则改变 HR 入职流程，风险高于收益，故维持现状 + 依赖 Dashboard 开关。
-- =============================================================

-- ---------- 1.【高危】grant_annual_entitlements：anon 不得调用 ----------
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  -- 白名单门禁：只有在职 HR（经 API）或 SQL Editor 超级用户可执行。
  -- 旧版 `if auth.uid() is not null and not is_hr()` 会被 anon(auth.uid()=NULL) 绕过。
  if not is_hr() and session_user <> 'postgres' then
    raise exception '只有 HR 能执行年度入账';
  end if;
  for r in
    select e.id as emp_id, t.code, t.default_days
    from employees e cross join leave_types t
    where e.active and (t.default_days > 0 or t.code = 'annual')
      and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
      and not exists (select 1 from leave_ledger l
                      where l.emp_id = e.id and l.leave_type = t.code
                        and l.reason = p_year || ' 年度配额')
  loop
    amt := case when r.code = 'annual' then annual_entitlement_for(r.emp_id, p_year) else r.default_days end;
    if amt > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.emp_id, r.code, amt, p_year || ' 年度配额', current_emp_id());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function grant_annual_entitlements(int) from anon, public;
grant  execute on function grant_annual_entitlements(int) to authenticated;

-- ---------- 2. 提交并发去重（DB 兜底，前端另加按钮防抖） ----------
-- 完全相同的 (员工,假期,起,止) 在活跃状态下只允许一条，堵住并发/双击重复提交。
create unique index if not exists uniq_active_application
  on applications (emp_id, leave_type, start_date, end_date)
  where status in ('pending','approved','cancel_requested');

-- ---------- 3. overlapping_team_leave：加鉴权过滤 + 收回 anon 执行权 ----------
-- 保持 language sql；未授权调用者得到空集（不泄露），不再对任何持 anon key 者开放。
create or replace function overlapping_team_leave(p_app uuid)
returns table (emp_name text, start_date date, end_date date, status text)
language sql stable security definer set search_path = public as $$
  with app as (select * from applications where id = p_app),
  grp as (
    select x.id from employees x, app a
    join employees e on e.id = a.emp_id
    where x.id <> e.id and x.active
      and (x.dept = e.dept
           or x.id = e.approver1
           or x.approver1 = e.id)
  )
  select e.name, o.start_date, o.end_date, o.status
  from applications o
  join employees e on e.id = o.emp_id, app a
  where o.id <> a.id and o.emp_id in (select id from grp)
    and o.status in ('pending','approved','cancel_requested')
    and not (o.end_date < a.start_date or o.start_date > a.end_date)
    -- 只有 HR 或该申请链上的审批人能看到结果；其余调用者得到空集
    and (is_hr() or exists (select 1 from approval_steps s
                            where s.application_id = p_app and s.approver_id = current_emp_id()));
$$;
revoke execute on function overlapping_team_leave(uuid) from anon, public;
grant  execute on function overlapping_team_leave(uuid) to authenticated;

-- ---------- 4. 员工档案按需知：目录视图给全员，敏感列仅 本人/HR ----------
-- 目录视图：只暴露渲染必需的非敏感列（无 auth_user_id/annual_base/join_date/last_working_day/gender）。
-- 属主执行 + is_staff() 门；含离职者以便历史审批人姓名可解析。
create or replace view employees_directory as
select id, name, email, title, dept, role, approver1, approver2, two_level, active
from employees
where is_staff();
grant  select on employees_directory to authenticated;
revoke select on employees_directory from anon;

-- 原表收紧：HR 看全部；每人可读自己的整行（loadMe 需要）；其余走目录视图。
drop policy if exists emp_read on employees;
create policy emp_read on employees for select to authenticated
  using (is_hr() or auth_user_id = auth.uid());

-- ---------- 7. act_on_step：me_id 为 NULL 时显式拒绝（不再靠 NOT NULL 约束兜底） ----------
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
  if s.approver_id is distinct from me_id then raise exception '你不是当前节点的审批人'; end if;
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
