-- =============================================================
-- LeaveDesk SG — migration v12
--
-- 三件事，一次跑完（幂等，可重复执行）：
--
--   1) 【根因】把「这天算不算工作日」收敛成**唯一一处**权威实现。
--      改之前它同时存在于 3 个地方（schema.sql 两处 + 前端），彼此已经漂移 ——
--      日历把周末画成休假就是漂移的症状。再加「周六上班」会变成第 4 处，
--      所以先合并、再加功能。
--
--   2) 【新功能】周六上班：部门默认 + 员工个人覆盖。
--      这是唯一会**改变余额**的改动（周一到周六的假从 5 天变 6 天）。
--
--   3) 【销假】允许对「已经开始」的假期提交销假申请，并给退还加两道保险。
--
-- 执行：Supabase Dashboard → SQL Editor → New query → 全文粘贴 → Run
-- =============================================================

-- ---------- 1. 周六上班：两级设置 ----------
alter table departments add column if not exists works_saturday boolean not null default false;
alter table employees   add column if not exists works_saturday boolean;   -- null = 跟随部门

comment on column departments.works_saturday is 'Department default: does this department work Saturdays?';
comment on column employees.works_saturday   is 'Per-person override. NULL = inherit the department default.';

-- 解析优先级：员工个人设置 > 部门默认 > false。只此一处，别在别处再 coalesce。
create or replace function emp_works_saturday(p_emp uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(e.works_saturday, d.works_saturday, false)
  from employees e
  left join departments d on d.name = e.dept
  where e.id = p_emp;
$$;

-- ---------- 2. 唯一权威：这天对这个人算不算工作日 ----------
-- 周日永远不算；周六只有该员工「上班」才算；公共假期对任何人都不算。
-- p_emp 传 null = 按公司默认（周一至周五），供不针对个人的场景使用。
create or replace function is_working_day(p_emp uuid, p_date date)
returns boolean language sql stable security definer set search_path = public as $$
  select (
           extract(isodow from p_date) <= 5
           or (extract(isodow from p_date) = 6 and coalesce(emp_works_saturday(p_emp), false))
         )
     and not exists (select 1 from public_holidays where holiday = p_date);
$$;

comment on function is_working_day(uuid, date) is
  'THE single authority on whether a date is a working day for an employee. Every other place — SQL, frontend, calendar — must defer to this. Do not re-derive the weekend/public-holiday rule anywhere else.';

-- ---------- 3. 天数折算改为调用权威函数（新增带 emp 的重载） ----------
create or replace function working_days(p_emp uuid, p_start date, p_end date, p_sh boolean, p_eh boolean)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare d date; n numeric := 0; first_wd date; last_wd date;
begin
  if p_end < p_start then return 0; end if;
  d := p_start;
  while d <= p_end loop
    if is_working_day(p_emp, d) then
      n := n + 1;
      if first_wd is null then first_wd := d; end if;
      last_wd := d;
    end if;
    d := d + 1;
  end loop;
  if p_sh and first_wd = p_start then n := n - 0.5; end if;
  if p_eh and last_wd  = p_end   then n := n - 0.5; end if;
  if n <= 0 and last_wd is not null then n := 0.5; end if;
  return n;
end $$;

create or replace function working_days_hd(p_emp uuid, p_start date, p_end date, p_half jsonb)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare d date; n numeric := 0;
begin
  if p_end < p_start then return 0; end if;
  d := p_start;
  while d <= p_end loop
    if is_working_day(p_emp, d) then
      n := n + 1;
      if exists (select 1 from jsonb_array_elements(coalesce(p_half,'[]'::jsonb)) e
                 where (e->>'d')::date = d and lower(e->>'part') in ('am','pm')) then
        n := n - 0.5;
      end if;
    end if;
    d := d + 1;
  end loop;
  if n <= 0 then n := 0.5; end if;
  return n;
end $$;

-- 旧签名保留为薄包装（按公司默认周一至周五），避免任何遗漏的调用点报错。
create or replace function working_days(p_start date, p_end date, p_sh boolean, p_eh boolean)
returns numeric language sql stable security definer set search_path = public as $$
  select working_days(null::uuid, p_start, p_end, p_sh, p_eh);
$$;
create or replace function working_days_hd(p_start date, p_end date, p_half jsonb)
returns numeric language sql stable security definer set search_path = public as $$
  select working_days_hd(null::uuid, p_start, p_end, p_half);
$$;

grant execute on function emp_works_saturday(uuid) to authenticated;
grant execute on function is_working_day(uuid, date) to authenticated;
grant execute on function working_days(uuid, date, date, boolean, boolean) to authenticated;
grant execute on function working_days_hd(uuid, date, date, jsonb) to authenticated;

-- ---------- 4. submit_application 改为按「申请人」算工作日 ----------
-- 本函数整段取自 schema.sql 现有定义，只改了两行天数折算的调用（多传 me.id）。
-- 不传的话，周六上班的员工仍会被按周一至周五计算，功能等于没生效。
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
            then working_days_hd(me.id, p_start, p_end, hd)
            else working_days(me.id, p_start, p_end, p_sh, p_eh) end;
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

-- ---------- 5. 销假：允许对「已经开始」的假期提交销假 ----------
-- 原限制 `start_date > current_date` 同时存在于前端和这里，所以只改前端没有用。
-- 设计上**不做按比例退还**：整张申请全额退还，员工再为「实际已休」的日期重新申请。
-- 理由：按比例退还等于把新的算术塞进写账本的函数里，算错是「静默」的；
--      全额退还 + 重新申请不引入任何新算术，出错是「看得见」的（人能发现）。
create or replace function request_cancel(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id();
begin
  update applications set status='cancel_requested', updated_at=now()
    where id=p_app and emp_id=me_id and status='approved';
  if not found then raise exception 'Only your own approved leave can be cancelled'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'cancel_requested');
end $$;

-- ---------- 6. 退还的两道保险（第二重确认） ----------
-- 要求：退还前后余额必须对得上 —— 例如原有 14 天、这张申请用掉 4 天（余 10），
--       销假退还 4 天后余额必须**正好**是 14。对不上就整笔回滚，什么都不写。
--
-- 关键性质：本函数是一个事务，raise exception 会把「退还」和「改状态」一起回滚，
--          不存在只做了一半的中间状态。
--
-- 注意：退还金额那一行**没有改动**（仍是 a.days 全额）。这里加的只是断言 ——
--      断言只会「阻止写入」，永远不会算出另一个数字。
create or replace function confirm_cancel(p_app uuid, p_ok boolean, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me_id uuid := current_emp_id();
  a applications%rowtype;
  t leave_types%rowtype;
  v_before numeric;
  v_after  numeric;
begin
  select * into a from applications where id=p_app for update;
  if a.status <> 'cancel_requested' then raise exception 'This application has no pending cancellation request'; end if;
  if not exists (select 1 from approval_steps
                 where application_id=p_app and step_order=1 and approver_id=me_id)
     and not is_hr() then raise exception 'Only the 1st level approver or HR can confirm a cancellation'; end if;

  select * into t from leave_types where code = a.leave_type;

  if p_ok then
    -- 保险 1：幂等 —— 这张申请已经退过就绝不再退（防重复退还，比算术错误更伤）
    if exists (select 1 from leave_ledger where ref_application = p_app and delta_days > 0) then
      raise exception 'This application has already been refunded.';
    end if;

    update applications set status='cancelled', updated_at=now() where id=p_app;

    if not coalesce(t.no_deduct, false) then
      -- 退还前余额（直接读账本，不读 leave_balances 视图：视图是 security_invoker，
      -- 本函数是 security definer，读基表可避开 RLS 带来的不确定性）
      select coalesce(sum(delta_days), 0) into v_before
        from leave_ledger where emp_id = a.emp_id and leave_type = a.leave_type;

      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (a.emp_id, a.leave_type, a.days, 'Refunded — leave cancelled', p_app, me_id);

      -- 退还后余额
      select coalesce(sum(delta_days), 0) into v_after
        from leave_ledger where emp_id = a.emp_id and leave_type = a.leave_type;

      -- 保险 2：对账。差额必须正好等于这张申请的天数，否则整笔回滚。
      if v_after - v_before <> a.days then
        raise exception
          'Refund reconciliation failed: balance moved by % but this application is % day(s) (before %, after %). Nothing was saved.',
          v_after - v_before, a.days, v_before, v_after;
      end if;
    end if;

    insert into application_events (application_id,actor,action,comment) values (p_app, me_id, 'cancelled', p_comment);
  else
    update applications set status='approved', updated_at=now() where id=p_app;
    insert into application_events (application_id,actor,action,comment) values (p_app, me_id, 'cancel_denied', p_comment);
  end if;
end $$;

-- ---------- 7. 日历视图带上「这个人周六上不上班」 ----------
-- 日历要按**假期所属的人**来决定周六画不画休假条，但原视图只有 name/dept/日期/状态。
-- 这里让视图自己算好（走 emp_works_saturday，个人覆盖也算得到），
-- 既拿到了需要的信息，又不用把 emp_id 暴露给全体员工。
create or replace view leave_calendar as
select e.name, e.dept, a.start_date, a.end_date,
       case when a.status = 'pending' then 'pending' else 'approved' end as status,
       emp_works_saturday(e.id) as works_saturday
from applications a join employees e on e.id = a.emp_id
where a.status in ('pending','approved','cancel_requested') and e.active
  and is_staff();
grant select on leave_calendar to authenticated;
revoke select on leave_calendar from anon;

-- ---------- 8. 保险被触发时的记录表 ----------
-- 为什么单独建表：application_events 只有 select 策略，写入一律由 security definer
-- 函数完成 —— 这是刻意的，给它开放 insert 会让任何人都能伪造审计记录。
-- 而对账保险一旦触发就整笔回滚，连事件行也会跟着消失，失败将不留任何痕迹。
-- 所以失败记录写到这张独立的小表，前端在**回滚之后**另发一次请求写入。
create table if not exists ledger_guard_failures (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  emp_id     uuid references employees(id) on delete set null,
  app_id     uuid,
  message    text
);
comment on table ledger_guard_failures is
  'Recorded when a balance guard in confirm_cancel blocks a refund. Written by the frontend after the rollback, because anything written inside the transaction is rolled back too.';

alter table ledger_guard_failures enable row level security;
drop policy if exists lgf_insert on ledger_guard_failures;
drop policy if exists lgf_read   on ledger_guard_failures;
-- 任何在职员工都能写（只写自己遇到的失败），但只有 HR 能看
create policy lgf_insert on ledger_guard_failures for insert to authenticated
  with check (emp_id = current_emp_id());
create policy lgf_read on ledger_guard_failures for select to authenticated
  using (is_hr());
grant insert, select on ledger_guard_failures to authenticated;

-- ---------- 验证 ----------
-- 1) 权威函数存在且行为正确（周日永远 false；周六看设置；公共假期永远 false）
select 'is_working_day exists' as check, is_working_day(null::uuid, date '2026-08-16') as sunday_should_be_false;
-- 2) 部门/员工两级字段已就位
select 'columns' as check,
  (select count(*) from information_schema.columns where table_name='departments' and column_name='works_saturday') as dept_col,
  (select count(*) from information_schema.columns where table_name='employees'   and column_name='works_saturday') as emp_col;
