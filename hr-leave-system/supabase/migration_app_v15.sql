-- =============================================================
-- LeaveDesk SG — migration v15：没有审批人的人，销假会永远卡住
--
-- 【问题】（2026-08-19 用户实测发现）
--   submit_application 对「没有审批人」的人（approver1 为空，例如 Managing
--   Director）是**提交即自动批准**，而且**不会写任何 approval_steps 行**
--   （见 v12 第 171-179 行）。
--   但 request_cancel 无论如何都只把状态改成 'cancel_requested' 就结束，
--   等一个根本不存在的审批人来确认：
--     · confirm_cancel 要求「一级审批人本人」或 is_hr()；这张申请没有一级审批人；
--     · 前端审批箱按 a.steps[0].approverId 过滤，没有 steps 的申请**谁都看不见**。
--   结果：状态永远停在「Cancellation requested」，假期照扣，无人能处理。
--   界面还写着「It's with your approver」——而上面一行明明写着
--   「Approved automatically — no approver needed」。自相矛盾。
--
-- 【修法】销假必须和提交对称：提交能自动批准的人，销假就自动确认。
--   不是「多写一份退还逻辑」，而是把退还那段**抽成一个内部函数**，
--   自动路径和审批人路径共用同一段代码 —— 账本算术全系统只有这一处。
--   （沿用 v12 的原则：账本路径不加新算术，只加断言。）
--
-- 【顺带】修复已经卡住的历史数据（见文末第 4 节，会报告处理了几笔）。
--
-- 依赖 v12。幂等，可重复执行。
-- =============================================================

-- ---------- 1. 唯一的退还实现 ----------
-- 从 v12 的 confirm_cancel 原样搬过来：幂等保险 + 全额退还 + 前后对账。
-- 三段都没有改动，只是换了个位置，好让两条路径共用。
-- 谁来执行、写什么事件，由调用方用参数传进来。
create or replace function apply_cancellation(
  p_app uuid, p_actor uuid, p_action text, p_comment text default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  a applications%rowtype;
  t leave_types%rowtype;
  v_before numeric;
  v_after  numeric;
begin
  select * into a from applications where id = p_app for update;
  if a.id is null then raise exception 'Application not found'; end if;
  if a.status <> 'cancel_requested' then
    raise exception 'This application has no pending cancellation request';
  end if;

  -- 保险 1：幂等 —— 已经退过就绝不再退（重复退还比算错更伤）
  if exists (select 1 from leave_ledger where ref_application = p_app and delta_days > 0) then
    raise exception 'This application has already been refunded.';
  end if;

  select * into t from leave_types where code = a.leave_type;
  update applications set status='cancelled', updated_at=now() where id=p_app;

  if not coalesce(t.no_deduct, false) then
    -- 退还前余额（直接读账本，不读 leave_balances 视图：视图是 security_invoker，
    -- 本函数是 security definer，读基表可避开 RLS 带来的不确定性）
    select coalesce(sum(delta_days), 0) into v_before
      from leave_ledger where emp_id = a.emp_id and leave_type = a.leave_type;

    insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
    values (a.emp_id, a.leave_type, a.days, 'Refunded — leave cancelled', p_app, p_actor);

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

  insert into application_events (application_id, actor, action, comment)
  values (p_app, p_actor, p_action, p_comment);
end $$;

comment on function apply_cancellation(uuid, uuid, text, text) is
  'INTERNAL. The single implementation of a cancellation refund, shared by request_cancel (no-approver path) and confirm_cancel (approver path). Performs no permission check of its own — callers must do that. Not granted to anon/authenticated.';

-- ⚠️ 这个函数**不做任何权限检查**（权限由调用方负责），所以绝不能直接暴露给前端 ——
--    否则任何人都能拿别人的申请号直接触发退还。只留给上面两个函数在服务端调用。
revoke all on function apply_cancellation(uuid, uuid, text, text) from public;
revoke all on function apply_cancellation(uuid, uuid, text, text) from anon, authenticated;

-- ---------- 2. 申请销假：没有审批人就当场确认 ----------
create or replace function request_cancel(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me_id uuid := current_emp_id();
  v_has_approver boolean;
begin
  update applications set status='cancel_requested', updated_at=now()
    where id=p_app and emp_id=me_id and status='approved';
  if not found then raise exception 'Only your own approved leave can be cancelled'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'cancel_requested');

  -- 和 submit_application 对称：那边「没有审批人 → 自动批准」，
  -- 这边就必须「没有审批人 → 自动确认」，否则请求无人可接。
  -- 判据用 approval_steps 有没有行，而不是重新去读 employees.approver1：
  -- 审批链是**提交那一刻**定下来的，之后改档案不影响在途申请，
  -- 所以「这张申请当时有没有审批人」只有 approval_steps 说了算。
  select exists (select 1 from approval_steps where application_id = p_app) into v_has_approver;
  if not v_has_approver then
    perform apply_cancellation(p_app, me_id, 'auto_cancelled',
                               'No approver required — cancellation confirmed automatically');
  end if;
end $$;

-- ---------- 3. 审批人确认：权限检查照旧，退还改为调用共用实现 ----------
create or replace function confirm_cancel(p_app uuid, p_ok boolean, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me_id uuid := current_emp_id();
  a applications%rowtype;
begin
  select * into a from applications where id=p_app for update;
  if a.status <> 'cancel_requested' then raise exception 'This application has no pending cancellation request'; end if;
  if not exists (select 1 from approval_steps
                 where application_id=p_app and step_order=1 and approver_id=me_id)
     and not is_hr() then raise exception 'Only the 1st level approver or HR can confirm a cancellation'; end if;

  if p_ok then
    perform apply_cancellation(p_app, me_id, 'cancelled', p_comment);
  else
    update applications set status='approved', updated_at=now() where id=p_app;
    insert into application_events (application_id,actor,action,comment) values (p_app, me_id, 'cancel_denied', p_comment);
  end if;
end $$;

-- ---------- 4. 修复已经卡住的历史数据 ----------
-- 只处理这个 bug 造成的那一类：状态是 cancel_requested，却一个审批人都没有。
-- 这些申请在旧代码下**永远**无人能处理，所以按本来就该发生的结果补上：确认 + 退还。
-- 走的是同一个 apply_cancellation，幂等保险同样生效，重复执行不会退两次。
do $$
declare r record; n int := 0;
begin
  for r in
    select a.id, a.emp_id, a.days, a.leave_type
      from applications a
     where a.status = 'cancel_requested'
       and not exists (select 1 from approval_steps s where s.application_id = a.id)
  loop
    perform apply_cancellation(r.id, r.emp_id, 'auto_cancelled',
      'No approver required — confirmed by migration v15 (this request could not be actioned by anyone)');
    n := n + 1;
    raise notice 'v15 healed: application % — refunded % day(s) of % to %', r.id, r.days, r.leave_type, r.emp_id;
  end loop;
  raise notice 'v15: % stuck cancellation request(s) confirmed and refunded', n;
end $$;

-- ---------- 验证 ----------
-- 1) 三个函数都在
select 'functions' as check,
  (select count(*) from pg_proc where proname='apply_cancellation') as apply_cancellation,
  (select count(*) from pg_proc where proname='request_cancel')     as request_cancel,
  (select count(*) from pg_proc where proname='confirm_cancel')     as confirm_cancel;

-- 2) 内部函数没有暴露给前端（两列都应为 false）
select 'apply_cancellation not exposed' as check,
  has_function_privilege('anon',          'apply_cancellation(uuid,uuid,text,text)', 'execute') as anon_can_call,
  has_function_privilege('authenticated', 'apply_cancellation(uuid,uuid,text,text)', 'execute') as auth_can_call;

-- 3) 没有任何「无人可处理」的销假请求残留（应为 0）
select 'stuck cancellations remaining' as check, count(*) as should_be_zero
  from applications a
 where a.status = 'cancel_requested'
   and not exists (select 1 from approval_steps s where s.application_id = a.id);

-- 4) 刚刚被修复的那些申请：状态、退还流水、余额一起看
select 'healed' as check, e.name, a.leave_type, a.days as booked,
       (select sum(l.delta_days) from leave_ledger l where l.ref_application = a.id and l.delta_days > 0) as refunded,
       a.status
  from applications a join employees e on e.id = a.emp_id
 where a.status = 'cancelled'
   and exists (select 1 from application_events ev
               where ev.application_id = a.id and ev.action = 'auto_cancelled')
 order by a.updated_at desc;
