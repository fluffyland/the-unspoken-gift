-- =============================================================
-- LeaveDesk migration v26 —— 已结算年度的补录假期
--
-- 用户的问题：Start a new year 跑完之后，如果有人又去申请上一年的年假会怎样？
-- 他的直觉是对的：结转天数是按「那一年年底还剩多少」算出来的，
-- 那一年的假期事后变了，结转就必须跟着变。现在不会。
--
-- 现状：submit_application 会拒绝**未来**年份的日期（次年额度 1 月 1 日才发），
-- 但**没有任何一处**拦住过去的年份。日期落在已结算年度的申请照收，
-- 天数直接从今天的余额里扣。
--
-- 会错成什么样：Siti 2026 年底剩 8 天、上限 5 → 结转 5、作废 3，2027 年初 19 天。
-- 2 月她交来一张 2026 年 12 月的纸质单，2 天。系统从 2027 余额里扣掉 2 → 17。
-- 但她 2026 真实用掉的是 8 天，剩 6 天，本来只该作废 1 天而不是 3 天 ——
-- 那 2 天原本就要被丢掉的。她凭空少了 2 天，而且屏幕上没有任何提示。
--
-- 还有两处连带：
--   · 补录较多时结转本身该变小（用 11 天 → 剩 3 → 该结转 3 而不是 5）。
--     停在 5，到期作业以后会作废她根本没有过的天数。
--   · year_start_log（Past runs）还写着「上年请了 6 天、作废 3 天」，
--     而假期记录已经变成 8 天 —— 两个事实来源静默打架。
--
-- 这个迁移：
--   1. year_closed_for(emp, year)：那一年对这个人结算过没有。
--      run_year_start(Y) 结算的是 Y-1，所以查的是 year = Y+1 的 year_start_log。
--   2. reconcile_closed_year(emp, year, extra, preview)：
--      **一个函数同时负责预览和执行**（v16 run_year_start 立的规矩）。
--      不是打补丁公式，而是**拿更正后的数字，把那一个人的年结算重算一遍**：
--        本该剩下 = 当时剩下 − 事后补录的天数
--        本该结转 = least(上限, 本该剩下)      —— 存库时再夹到 >= 0
--        本该作废 = greatest(0, 本该剩下 − 上限)
--        该退回   = 当时作废 − 本该作废 − 已经退过的
--      「已经退过的」从账本里加总 ⇒ 补录第二张单不会重复退，重跑一次是空操作。
--   3. submit_application 加 p_closed_ok：员工一律拒绝，HR 明确确认后才放行，
--      放行时在同一个事务里把上面那一套重算做掉。
--      **刻意不另写一个函数** —— 工作日计算、余额校验、重叠检查、附件必填
--      全系统只有这一处，另写一份就是两套规则。
--
-- 边界（越界一律拒绝，宁可让 HR 手工调额度，也不给一个算不准的答案）：
--   · 只能补录**上一年**。再往前要拆解连着的多年结转链。
--   · 那一年的结转**尚未到期**。已经作废落账的天数换不回来。
--
-- year_start_log 只增不改：一月那一行永远保持一月写下的样子，
-- 更正写成**新的**账本条目 + 一条 HR 修改记录。
-- 「余额永远等于它所有条目之和」—— 这套系统的根本规则。
--
-- 依赖 v16/v18/v19/v24。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 1. 这一年对这个人结算过没有 ----------
create or replace function year_closed_for(p_emp uuid, p_year int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from year_start_log
                  where emp_id = p_emp and year = p_year + 1);
$$;
revoke execute on function year_closed_for(uuid, int) from anon, public;
grant  execute on function year_closed_for(uuid, int) to authenticated;

-- ---------- 2. 重算那一个人的年结算 ----------
-- 更正条目的措辞**必须**含 "above the carry-over cap"：
-- SQL 的 annual_entitled_in_year 和前端的 HOUSEKEEPING 正则都靠这句话把它
-- 归类为「年结家务事」，既不算新增额度也不算请假。
-- 少了这句，Balances 会把退回的天数显示成今年多发的额度。
create or replace function reconcile_closed_year(
  p_emp uuid, p_year int, p_extra numeric default 0, p_preview boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ysl year_start_log%rowtype;
  ac  annual_carry%rowtype;
  v_taken_now numeric; v_left_now numeric;
  v_new_carry numeric; v_new_forfeit numeric;
  v_returned numeric; v_due numeric;
  v_name text;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can reconcile a closed year';
  end if;
  if p_year <> extract(year from current_date)::int - 1 then
    raise exception 'Only last year can still be reconciled. For anything older, adjust the employee''s Annual Leave Entitled / Yr instead';
  end if;

  select * into ysl from year_start_log where emp_id = p_emp and year = p_year + 1;
  if ysl.emp_id is null then
    raise exception 'That year was never closed for this employee, so there is nothing to reconcile';
  end if;
  select * into ac from annual_carry where emp_id = p_emp and year = p_year + 1;
  if ac.expired_at is not null then
    raise exception 'That carry-over has already expired and been written off — those days cannot be returned. Adjust the employee''s Annual Leave Entitled / Yr instead';
  end if;

  -- 当时剩多少是历史（year_start_log 冻结的），事后补录多少是现在算的。
  v_taken_now := annual_used_in_year(p_emp, p_year) + coalesce(p_extra, 0);
  v_left_now  := ysl.annual_left - (v_taken_now - ysl.annual_taken_prev);
  -- 结转夹到 0：不可能结转负数天。而**作废必须按未夹的 v_left_now 算** ——
  -- v_left_now 为负表示那一年超支了，这时本该作废 0 天，该退的就是当时作废的全部；
  -- 超支的天数自然留在余额里从今年扣回来。先夹 0 再算作废会把这个信息抹掉。
  v_new_carry   := greatest(0, least(ysl.cap_applied, v_left_now));
  v_new_forfeit := greatest(0, v_left_now - ysl.cap_applied);

  select coalesce(sum(delta_days), 0) into v_returned from leave_ledger
   where emp_id = p_emp and leave_type = 'annual'
     and reason like p_year || ' annual leave above the carry-over cap%forfeit corrected%';
  v_due := (ysl.forfeited - v_new_forfeit) - v_returned;
  select name into v_name from employees where id = p_emp;

  if not p_preview then
    if v_due <> 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (p_emp, 'annual', v_due,
              p_year || ' annual leave above the carry-over cap — forfeit corrected, '
                || trim(to_char(v_due, 'FM9999999.9')) || ' day(s) returned',
              current_emp_id());
      insert into hr_amendments (by_emp, by_name, emp_id, emp_name, leave_type, kind,
                                 before_days, after_days, delta_days, reason)
      values (current_emp_id(),
              coalesce((select name from employees where id = current_emp_id()), ''),
              p_emp, v_name, 'annual', 'correction',
              ysl.forfeited, v_new_forfeit, v_due,
              p_year || ' reconciled after leave was recorded late');
    end if;
    -- 结转本身也要跟着改：到期作业读的就是这个数。
    update annual_carry set carry_in = v_new_carry
     where emp_id = p_emp and year = p_year + 1
       and carry_in is distinct from v_new_carry;
  end if;

  return jsonb_build_object(
    'preview', p_preview, 'year', p_year, 'name', v_name,
    'taken_then', ysl.annual_taken_prev, 'left_then', ysl.annual_left,
    'carried_then', ysl.carried, 'forfeited_then', ysl.forfeited, 'cap', ysl.cap_applied,
    'taken_now', v_taken_now, 'left_now', v_left_now,
    'new_carry', v_new_carry, 'new_forfeit', v_new_forfeit,
    'returning', v_due, 'already_returned', v_returned);
end $$;
revoke execute on function reconcile_closed_year(uuid, int, numeric, boolean) from anon, public;
grant  execute on function reconcile_closed_year(uuid, int, numeric, boolean) to authenticated;

-- ---------- 3. submit_application：过去的年份也要有一条规则 ----------
-- **先把旧签名删掉。** 给一个带默认值的参数就是新建了一个重载,旧的不会消失。
-- 库里本来就躺着两个（v8 的 9 参、v18 的 10 参）,应用之所以还能用,
-- 只是因为它发的 key 里有 p_for_emp,只有 10 参那个认得。
-- 一旦再加第 11 个带默认值的参数,应用发的那组 key 10 参和 11 参**都能接**,
-- PostgREST 无法二选一 → 全公司的请假申请当场全部失败。
-- 这不是理论:测试第一次跑就炸在 "function ... is not unique"。
-- 规则:**给已发布的函数加参数,必须同时删掉旧签名。**
drop function if exists submit_application(text,date,date,text,text,uuid,jsonb,boolean,boolean);
drop function if exists submit_application(text,date,date,text,text,uuid,jsonb,boolean,boolean,uuid);

-- 整个函数逐字保持原样,只加了 p_closed_ok 和上面说的那两段。
-- **刻意不另写一个 HR 专用函数**：工作日计算、余额校验、重叠检查、次年只读、
-- 附件必填,全系统只有这一处。另写一份 = 两套规则,早晚不一致。
create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false,
  p_for_emp uuid default null, p_closed_ok boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
        actor uuid; on_behalf boolean := p_for_emp is not null;
        v_yr int := extract(year from p_start)::int;   -- v26
begin
  -- v18：HR 可以代员工申请。**刻意复用这同一个函数**，而不是另写一份：
  -- 工作日计算、余额校验、重叠检查、次年只读、附件必填……全系统只有这一处。
  -- 另写一份 = 两套规则，早晚不一致。
  if on_behalf then
    if not is_hr() then raise exception 'Only HR can apply for another employee'; end if;
    select * into me from employees where id = p_for_emp and active;
    if me.id is null then raise exception 'That employee is not on the active list'; end if;
    actor := current_emp_id();
  else
    select * into me from employees where auth_user_id = auth.uid() and active;
    if me.id is null then raise exception 'Employee profile not found'; end if;
    actor := me.id;
  end if;
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
  -- v26 已结算年度：镜像上面那条规则，只是指向过去。
  -- 那一年的结转是按「年底还剩多少」算出来的,事后往那一年补假必须把结转重算,
  -- 否则天数会从今年的余额里扣掉,而它们本来就要被作废 —— 员工凭空少几天,无人报错。
  if year_closed_for(me.id, v_yr) then
    if not (on_behalf and p_closed_ok) then
      raise exception '% has been closed off. Leave dated in % can no longer be applied for here — that year was finalised when the new year was started. Hand your form to HR and they can record it for you.', v_yr, v_yr;
    end if;
    -- HR 明确确认了。边界在 reconcile_closed_year 里,先干跑一次:
    -- 越界就在这里失败,而不是等假期已经写进去之后才发现算不了。
    perform reconcile_closed_year(me.id, v_yr, 0, true);
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

  insert into application_events (application_id, actor, action, comment)
  values (app_id, actor, case when p_resubmit_id is null then 'submitted' else 'resubmitted' end,
          case when on_behalf then 'Applied by HR on behalf' else null end);

  -- HR 代申请一律即时批准（这就是「代申请」的意思：HR 已经决定了）。
  if me.approver1 is null or on_behalf then
    -- 无审批人（Managing Director）：提交即自动批准、记账，事件流通知 HR 备案
    update applications set status='approved', updated_at=now() where id=app_id;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (me.id, p_type, -d, 'Leave taken', app_id, actor);
    end if;
    insert into application_events (application_id, actor, action, comment)
    values (app_id, actor, 'auto_approved',
            case when on_behalf then 'Applied by HR on behalf' else 'No approver required' end);
  else
    -- 按员工档案生成审批链（一级或两级）；在途申请不受之后档案变更影响
    insert into approval_steps (application_id, step_order, approver_id, status)
    values (app_id, 1, me.approver1, 'pending');
    if me.two_level and me.approver2 is not null then
      insert into approval_steps (application_id, step_order, approver_id, status)
      values (app_id, 2, me.approver2, 'waiting');
    end if;
  end if;
  -- v26：假期已经落账,现在把那一年重算一遍 —— 同一个事务,要么都成,要么都不成。
  if p_closed_ok and on_behalf and year_closed_for(me.id, v_yr) then
    perform reconcile_closed_year(me.id, v_yr, 0, false);
  end if;
  return app_id;
end $$;
revoke execute on function submit_application(text,date,date,text,text,uuid,jsonb,boolean,boolean,uuid,boolean) from anon, public;
grant  execute on function submit_application(text,date,date,text,text,uuid,jsonb,boolean,boolean,uuid,boolean) to authenticated;
