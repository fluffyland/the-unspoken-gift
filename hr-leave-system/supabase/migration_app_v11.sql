-- LeaveDesk SG — migration v11：数据库层全部改用英文（报错信息 + 账目 reason + 系统公告）
-- 幂等，可重复执行。SQL Editor 粘贴 → Run 一次即可。
--
-- 背景：应用界面已全英文，但数据库函数抛出的错误（如「申请不在待审批状态」）和
--       写入账目的 reason（如「请假扣减」）仍是中文，会原样弹到界面上。本迁移把
--       全部改为英文。年度入账的幂等键同时兼容旧中文 reason（' 年度配额'）与新英文
--       reason（' annual allowance'），重复执行不会重复入账。

create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
begin
  select * into me from employees where auth_user_id = auth.uid() and active;
  if me.id is null then raise exception 'Employee profile not found'; end if;
  -- 串行化同一员工的并发提交：消除余额/重叠「查后写」竞态（锁在事务提交时自动释放）
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception 'Not eligible for this leave type'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception 'This leave type requires an attachment (e.g. MC)'; end if;
  -- 范围夹取：进逐日循环前拦掉超大区间，防 CPU DoS
  if p_end < p_start or p_end - p_start > 366 then
    raise exception 'Invalid date range (maximum about one year)'; end if;
  -- 次年日历只读：次年额度要到 1 月 1 日才发放，此前不能申请落在次年的假
  if extract(year from p_start)::int > extract(year from current_date)::int
     or extract(year from p_end)::int > extract(year from current_date)::int then
    raise exception 'Next year''s leave opens for application on 1 Jan (until then the calendar is view-only)';
  end if;
  -- 半天假仅对允许的假期类型生效；其余类型忽略半天明细，一律按整天计
  if not coalesce(t.allow_half_day, false) then hd := '[]'::jsonb; end if;
  d := case when jsonb_array_length(hd) > 0
            then working_days_hd(p_start, p_end, hd)
            else working_days(p_start, p_end, p_sh, p_eh) end;
  if d <= 0 then raise exception 'The selected dates contain no working days'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances
      where emp_id = me.id and leave_type = p_type;
    if coalesce(avail, 0) < d then raise exception 'Not enough balance: % day(s) needed, only % available', d, coalesce(avail,0); end if;
  end if;
  if exists (select 1 from applications a where a.emp_id = me.id
             and a.id is distinct from p_resubmit_id
             and a.status in ('pending','approved','cancel_requested')
             and not (a.end_date < p_start or a.start_date > p_end)) then
    raise exception 'These dates overlap an existing application';
  end if;

  if p_resubmit_id is not null then
    update applications set leave_type=p_type, start_date=p_start, end_date=p_end,
      start_half=p_sh, end_half=p_eh, half_days=hd, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception 'Only a returned application can be resubmitted'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,half_days,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,hd,d,p_reason,p_attachment,p_start<current_date)
    returning id into app_id;
  end if;

  insert into application_events (application_id, actor, action)
  values (app_id, me.id, case when p_resubmit_id is null then 'submitted' else 'resubmitted' end);

  if me.approver1 is null then
    -- 无审批人（Managing Director）：提交即自动批准、记账，事件流通知 HR 备案
    update applications set status='approved', updated_at=now() where id=app_id;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (me.id, p_type, -d, 'Leave taken', app_id, me.id);
    end if;
    insert into application_events (application_id, actor, action, comment)
    values (app_id, me.id, 'auto_approved', 'No approver required (Managing Director)');
  else
    -- 按员工档案生成审批链（一级或两级）；在途申请不受之后档案变更影响
    insert into approval_steps (application_id, step_order, approver_id, status)
    values (app_id, 1, me.approver1, 'pending');
    if me.two_level and me.approver2 is not null then
      insert into approval_steps (application_id, step_order, approver_id, status)
      values (app_id, 2, me.approver2, 'waiting');
    end if;
  end if;
  return app_id;
end $$;

create or replace function leave_available(p_emp uuid, p_code text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare allowed boolean;
begin
  select is_hr() or exists (
    select 1 from applications a join approval_steps s on s.application_id = a.id
    where a.emp_id = p_emp and s.approver_id = current_emp_id()
  ) into allowed;
  if not allowed then raise exception 'You are not allowed to view this employee''s balance'; end if;
  return coalesce((select balance from leave_balances where emp_id = p_emp and leave_type = p_code), 0)
       - coalesce((select sum(days) from applications
                   where emp_id = p_emp and leave_type = p_code and status = 'pending'), 0);
end $$;

create or replace function act_on_step(p_app uuid, p_action text, p_comment text default null, p_ack boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); a applications%rowtype; s approval_steps%rowtype;
        t leave_types%rowtype; nxt approval_steps%rowtype; has_overlap boolean;
begin
  if me_id is null then raise exception 'Employee profile not found'; end if;
  select * into a from applications where id = p_app for update;
  if a.id is null or a.status <> 'pending' then raise exception 'This application is no longer pending — it may already have been decided'; end if;
  select * into s from approval_steps
    where application_id = p_app and step_order = a.current_step;
  -- 当前节点指名审批人，或 HR 代批他人（HR 不能借此自批）。
  -- is distinct from：me_id/approver_id 任一为 NULL 时仍能正确判否（裸 <> 会得 NULL 而跳过）
  if s.approver_id is distinct from me_id
     and not (is_hr() and a.emp_id is distinct from me_id) then
    raise exception 'You are not the current approver for this application'; end if;
  if p_action in ('reject','return') and coalesce(trim(p_comment),'') = '' then
    raise exception 'A note is required when rejecting or returning'; end if;

  select * into t from leave_types where code = a.leave_type;

  if p_action = 'approve' then
    select exists (select 1 from overlapping_team_leave(p_app)) into has_overlap;
    if has_overlap and not p_ack then
      raise exception 'Someone in the same team is away on these dates — tick the acknowledgement box to approve anyway';
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
          raise exception 'Cannot approve: not enough % balance to deduct % day(s)', a.leave_type, a.days;
        end if;
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
        values (a.emp_id, a.leave_type, -a.days, 'Leave taken', p_app, me_id);
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
    raise exception 'Unknown action %', p_action;
  end if;
end $$;

create or replace function withdraw_application(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id();
begin
  update applications set status='withdrawn', updated_at=now()
    where id=p_app and emp_id=me_id and status='pending';
  if not found then raise exception 'Only your own pending applications can be withdrawn'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'withdrawn');
end $$;

create or replace function request_cancel(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id();
begin
  update applications set status='cancel_requested', updated_at=now()
    where id=p_app and emp_id=me_id and status='approved' and start_date > current_date;
  if not found then raise exception 'Only approved leave that hasn''t started yet can be cancelled'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'cancel_requested');
end $$;

create or replace function confirm_cancel(p_app uuid, p_ok boolean, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); a applications%rowtype; t leave_types%rowtype;
begin
  select * into a from applications where id=p_app for update;
  if a.status <> 'cancel_requested' then raise exception 'This application has no pending cancellation request'; end if;
  if not exists (select 1 from approval_steps
                 where application_id=p_app and step_order=1 and approver_id=me_id)
     and not is_hr() then raise exception 'Only the 1st level approver or HR can confirm a cancellation'; end if;
  select * into t from leave_types where code=a.leave_type;
  if p_ok then
    update applications set status='cancelled', updated_at=now() where id=p_app;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (a.emp_id, a.leave_type, a.days, 'Refunded — leave cancelled', p_app, me_id);
    end if;
    insert into application_events (application_id,actor,action,comment) values (p_app, me_id, 'cancelled', p_comment);
  else
    update applications set status='approved', updated_at=now() where id=p_app;
    insert into application_events (application_id,actor,action,comment) values (p_app, me_id, 'cancel_denied', p_comment);
  end if;
end $$;

create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  -- 白名单门禁：只有在职 HR（经 API）或 SQL Editor 超级用户可执行。
  -- （旧版 `if auth.uid() is not null and not is_hr()` 会被 anon(auth.uid()=NULL) 绕过。）
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
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

create or replace function offboard_employee(p_emp uuid, p_last_day date, p_mode text)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); r record; tgt employees%rowtype;
begin
  if not is_hr() then raise exception 'Only HR can offboard employees'; end if;
  if p_mode not in ('encash','clear') then raise exception 'mode must be encash or clear'; end if;
  if p_emp = me_id then raise exception 'You cannot offboard yourself'; end if;
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

create or replace function apply_holiday_sync(
  p_holidays jsonb, p_years int[], p_source text default 'data.gov.sg'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_added jsonb := '[]'::jsonb; v_removed jsonb := '[]'::jsonb; v_renamed jsonb := '[]'::jsonb;
  r record; changed boolean := false; add_txt text; rem_txt text; ann_body text;
begin
  if current_user <> 'service_role' and session_user <> 'postgres' then
    raise exception 'apply_holiday_sync can only be called by the system sync task'; end if;
  if p_years is null or array_length(p_years, 1) is null then
    raise exception 'p_years must not be empty'; end if;
  for r in select (e->>'holiday')::date as d, e->>'name' as nm
           from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
           where extract(year from (e->>'holiday')::date)::int = any(p_years)
  loop
    if not exists (select 1 from public_holidays where holiday = r.d) then
      v_added := v_added || jsonb_build_object('holiday', r.d, 'name', r.nm); changed := true;
    elsif (select name from public_holidays where holiday = r.d) is distinct from r.nm then
      v_renamed := v_renamed || jsonb_build_object('holiday', r.d, 'name', r.nm); changed := true;
    end if;
    insert into public_holidays (holiday, name, source, synced_at)
    values (r.d, r.nm, p_source, now())
    on conflict (holiday) do update set name = excluded.name, source = excluded.source, synced_at = now();
  end loop;
  for r in select ph.holiday as d, ph.name as nm from public_holidays ph
           where extract(year from ph.holiday)::int = any(p_years) and ph.source = p_source
             and not exists (select 1 from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
                             where (e->>'holiday')::date = ph.holiday)
  loop
    v_removed := v_removed || jsonb_build_object('holiday', r.d, 'name', r.nm);
    delete from public_holidays where holiday = r.d; changed := true;
  end loop;
  insert into holiday_sync_log (source, years, added, removed, renamed, total_seen, status)
  values (p_source, p_years, v_added, v_removed, v_renamed,
          jsonb_array_length(coalesce(p_holidays, '[]'::jsonb)), 'ok');
  if changed then
    add_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_added || v_renamed) e);
    rem_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_removed) e);
    ann_body := 'The public-holiday calendar was updated from the official MOM source (data.gov.sg).';
    if add_txt is not null then ann_body := ann_body || E'\n\n➕ Added / updated:\n' || add_txt; end if;
    if rem_txt is not null then ann_body := ann_body || E'\n\n➖ Removed:\n' || rem_txt; end if;
    insert into announcements (kind, title, body, audience)
    values ('holiday', '📅 Public holidays updated', ann_body, 'all');
    insert into announcements (kind, title, body, audience)
    values ('holiday', '🛠️ HR: public holidays changed — please review',
            'The automatic sync updated the public-holiday calendar. Review or adjust it in HR Console → Company settings — you can add, edit or remove any date.'
            || E'\n\n' || ann_body, 'hr');
  end if;
  return jsonb_build_object('changed', changed, 'added', v_added, 'removed', v_removed, 'renamed', v_renamed);
end $$;

create or replace function rollover_annual_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; cap numeric; used numeric; rem numeric; bal numeric; carry numeric; excess numeric; n int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can run the annual carry-over'; end if;
  cap := coalesce((select carry_over_cap from leave_types where code = 'annual'), 0);
  for r in select id from employees where active loop
    perform 1 from annual_carry where emp_id = r.id and year = p_year - 1 and expired_at is null;
    if found then
      select carry_in into carry from annual_carry where emp_id = r.id and year = p_year - 1;
      used := annual_used_in_year(r.id, p_year - 1);
      rem  := greatest(0, carry - used);
      if rem > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -rem, (p_year - 1) || ' carry-over expired (unused)', null);
      end if;
      update annual_carry set expired_days = rem, expired_at = now()
        where emp_id = r.id and year = p_year - 1;
    end if;
    if not exists (select 1 from annual_carry where emp_id = r.id and year = p_year) then
      bal    := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
      -- 若本年度额度已发放，剔除它 → 只按「上一年遗留」算结转，避免 rollover/grant 执行顺序出错
      bal    := bal - coalesce((select sum(delta_days) from leave_ledger
                                where emp_id = r.id and leave_type = 'annual'
                                  and reason in (p_year || ' 年度配额', p_year || ' annual allowance')), 0);
      carry  := least(cap, greatest(0, bal));
      excess := greatest(0, bal - cap);
      if excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -excess, (p_year - 1) || ' annual leave above the carry-over cap (' || cap || ') — forfeited', null);
      end if;
      insert into annual_carry (emp_id, year, carry_in) values (r.id, p_year, carry);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function guard_employee_self_edit() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return new; end if;      -- SQL Editor / 后台任务放行
  if coalesce(current_setting('leavedesk.svc', true), '') = '1' then return new; end if;  -- 服务端函数内部放行
  if is_admin() then return new; end if;       -- Owner 可改任何人任何字段
  if new.role = 'admin' and (tg_op = 'INSERT' or old.role is distinct from 'admin') then
    raise exception 'Only the Owner can assign the Owner / Super Admin role';
  end if;
  if tg_op = 'UPDATE' and new.id = me and (
       new.approver1   is distinct from old.approver1
    or new.approver2   is distinct from old.approver2
    or new.two_level   is distinct from old.two_level
    or new.annual_base is distinct from old.annual_base
    or new.role        is distinct from old.role) then
    raise exception 'You cannot change your own approvers, leave base or account type — ask the Owner to change them';
  end if;
  return new;
end $$;

drop trigger if exists trg_employee_self_edit on employees;
create trigger trg_employee_self_edit before insert or update on employees
  for each row execute function guard_employee_self_edit();
