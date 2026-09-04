-- =============================================================
-- LeaveDesk migration v27 —— 审计发现的问题
--
-- 拿一家四个人的公司过了完整一年、开了新年、又在一月里继续用，查出三件事。
-- 线上数据没有受损：这三件都必须先跑过 Start a new year，而它从来没跑过。
--
--   1. 【最严重】31 日还挂着没批的假 → 员工凭空少几天。
--      run_year_start 读的是 balance，而 balance **不扣待批**。Ken 请了 6 天已批、
--      6 天待批，年结看到「剩 8」→ 结转 5、作废 3。他真实用掉 12 天，剩 2 天，
--      本来一天都不该作废。审批人年后回来一批，他从 19 变 13 —— 应该是 16。
--      少 3 天，没有任何提示，Past runs 还永远记着「请 6 天、作废 3 天」。
--      **对策：还有待批/待销假就不许开新年**，预览里点名列出来。
--      （不能改成「把待批当已用」：那张单要是后来被**驳回**，天数得退回一个
--        已经关掉的年度 —— 同一个坑，换个方向。）
--
--   2. 离职后一切冻结。Mei 离职结算清零到 0，但结转记录还在，到期那天又扣一次
--      → **-5**，永远挂着。用户原话：「off board staff just skip don't do anything
--      the record stays fix no credit leave or anything just freeze everything」。
--      **五个函数**今天还能碰到离职的人：due_unwritten_carry / expire_due_carry /
--      set_carry_expiry / reconcile_closed_year / credit_oil。
--      补五个函数只能管到有人写第六个之前，所以规则**写在账本这张表上**：
--      leave_ledger 上一个触发器，离职的人一律不许写 —— 用 v10 那套
--      leavedesk.svc 旁路，让离职结算本身照写，别的都写不进去。
--
--   3. 一张申请只能落在一个年度，而一个年度要 HR 开了才能申请。
--      现有规则只拦「日历意义上的未来年份」，所以 1 月 3 日申请
--      2026-12-27 → 2027-01-03 是放行的，而 2027 的额度根本还没发；
--      更常见的是一月头几天申请当年的假，那些天数直接从去年的结转里扣掉。
--
-- 依赖 v16/v18/v19/v24/v26。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 1. 这一年 HR 开过没有 ----------
create or replace function year_started_for(p_emp uuid, p_year int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from year_start_log where emp_id = p_emp and year = p_year);
$$;
revoke execute on function year_started_for(uuid, int) from anon, public;
grant  execute on function year_started_for(uuid, int) to authenticated;

-- ---------- 2. 离职 = 冻结，写在账本表上 ----------
-- 补函数只能管到有人写下一个函数之前。这条规则写在天数真正存放的地方，
-- 所以哪怕我漏了一条路、或者明年新加一条，都会当场报错而不是悄悄改动离职者的账。
create or replace function guard_ledger_active() returns trigger
language plpgsql security definer set search_path = public as $$
declare a boolean;
begin
  -- 离职结算自己要写最后那笔，v10 的旁路开关放行它
  if coalesce(current_setting('leavedesk.svc', true), '') = '1' then return new; end if;
  select active into a from employees where id = new.emp_id;
  if a is false then
    raise exception 'That employee has left. Their leave record is frozen and cannot be changed';
  end if;
  return new;
end $$;
drop trigger if exists trg_ledger_active on leave_ledger;
create trigger trg_ledger_active before insert on leave_ledger
  for each row execute function guard_ledger_active();

-- 到期判定：离职的人一律返回 0（视图里那一下减法就是 -5 的来源）
create or replace function due_unwritten_carry(p_emp uuid, p_code text)
returns numeric language sql stable as $$
  select case when p_code <> 'annual' then 0 else coalesce((
    select sum(greatest(0, ac.carry_in
                 - annual_used_between(ac.emp_id, make_date(ac.year, 1, 1), ac.expires_on)))
    from annual_carry ac join employees e on e.id = ac.emp_id
    where ac.emp_id = p_emp
      and e.active                                  -- v27：离职即冻结
      and ac.expired_at is null
      and ac.expires_on is not null
      and ac.expires_on < current_date
  ), 0) end;
$$;

-- 到期落账：同样跳过离职的人
create or replace function expire_due_carry(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; rem numeric; n int := 0;
begin
  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on
    from annual_carry ac join employees e on e.id = ac.emp_id
    where e.active                                  -- v27：离职即冻结
      and ac.expired_at is null
      and ac.expires_on is not null
      and ac.expires_on < current_date
      and (p_emp is null or ac.emp_id = p_emp)
  loop
    rem := greatest(0, r.carry_in - annual_used_between(r.emp_id, make_date(r.year, 1, 1), r.expires_on));
    if rem > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.emp_id, 'annual', -rem, r.year || ' carry-over expired (unused)', null);
    end if;
    update annual_carry set expired_days = rem, expired_at = now()
      where emp_id = r.emp_id and year = r.year;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_carry(uuid) from anon, public;
grant  execute on function expire_due_carry(uuid) to authenticated;

-- 补休不许发给已经离职的人
create or replace function credit_oil(p_emp uuid, p_days numeric, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit off-in-lieu'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if not e.active then raise exception 'That employee has left. Their leave record is frozen'; end if;
  insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
  values (p_emp, 'oil', p_days, 'Off-in-lieu: ' || btrim(p_reason), current_emp_id());
  perform log_amendment(p_emp, e.name, 'oil', 'oil_credit', null, null, p_days, 1, btrim(p_reason));
  return p_days;
end $$;
revoke execute on function credit_oil(uuid, numeric, text) from anon, public;
grant  execute on function credit_oil(uuid, numeric, text) to authenticated;

-- 修复已有数据 + 离职时把结转记录就地关掉。
-- expired_at 落地、expired_days = 0 = 「这条已结清，没作废任何天数」，
-- due_unwritten_carry 和 expire_due_carry 都据此跳过它。
create or replace function freeze_leaver_carry() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; m int := 0;
begin
  with fixed as (
    update annual_carry ac set expired_at = now(), expired_days = 0
      from employees e
     where e.id = ac.emp_id and not e.active and ac.expired_at is null
    returning 1)
  select count(*) into n from fixed;
  -- 已经错扣过的，退回来（到期落账发生在他离职之后 ⇒ 那笔本来就不该有）
  perform set_config('leavedesk.svc', '1', true);
  with back as (
    insert into leave_ledger (emp_id, leave_type, delta_days, reason)
    select l.emp_id, 'annual', -l.delta_days,
           'Correction — carry-over expiry reversed, employee had already left'
      from leave_ledger l join employees e on e.id = l.emp_id
     where not e.active and l.leave_type = 'annual'
       and l.reason like '%carry-over expired (unused)%'
       and (e.last_working_day is null or l.created_at::date > e.last_working_day)
       and not exists (select 1 from leave_ledger x where x.emp_id = l.emp_id
                        and x.reason = 'Correction — carry-over expiry reversed, employee had already left'
                        and x.delta_days = -l.delta_days)
    returning 1)
  select count(*) into m from back;
  return n + m;
end $$;
revoke execute on function freeze_leaver_carry() from anon, public;
grant  execute on function freeze_leaver_carry() to authenticated;
select freeze_leaver_carry();

-- ---------- 3. 开新年前：还有待批的假就不许开 ----------
create or replace function run_year_start(p_year int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; t record;
  v_mode text; v_expires date;
  v_bal numeric; v_cap numeric; v_carry numeric; v_excess numeric;
  v_taken numeric; v_exp numeric; v_tb numeric;
  v_resets jsonb; v_reset_days numeric;
  v_rows jsonb := '[]'::jsonb;
  v_people int := 0; v_carry_people int := 0; v_carry_days numeric := 0;
  v_forfeit_people int := 0; v_forfeit_days numeric := 0;
  v_expired_people int := 0; v_expired_days numeric := 0;
  v_reset_people int := 0; v_granted int := 0;
  v_block jsonb := '[]'::jsonb;   -- v27
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

  -- v27：上一年还挂着没批的假 ⇒ 那些天数会被当成「没用掉」结转/作废，
  -- 等审批人回来一批，又从新一年的余额里扣一次 —— 员工凭空少几天。
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', e.name, 'start', a.start_date, 'end', a.end_date,
           'days', a.days, 'status', a.status) order by e.name, a.start_date), '[]'::jsonb)
    into v_block
    from applications a join employees e on e.id = a.emp_id
   where e.active
     and a.status in ('pending', 'cancel_requested')
     and extract(year from a.start_date)::int = p_year - 1;
  if jsonb_array_length(v_block) > 0 and not p_preview then
    raise exception '% application(s) dated in % are still waiting: %. Approve, reject or cancel them first — otherwise those days count as unused and the people lose them.',
      jsonb_array_length(v_block), p_year - 1,
      (select string_agg(distinct x->>'name', ', ') from jsonb_array_elements(v_block) x);
  end if;

  select accrual_mode into v_mode from org_settings where id = 1;
  v_expires := carry_expiry_for(p_year);          -- v24：日期直接来自设置，不再由月数推算

  -- 步骤 1：把已经到期的结转落成账本条目（预览不写）
  if not p_preview then perform expire_due_carry(); end if;

  for r in select e.id, e.name, coalesce(e.carry_cap, 0) as cap
           from employees e where e.active order by e.name loop

    -- 已经处理过这一年的人直接跳过 ⇒ 按第二次只会报 0，不会重复扣
    if exists (select 1 from year_start_log y where y.year = p_year and y.emp_id = r.id) then
      continue;
    end if;
    v_people := v_people + 1;
    v_cap := r.cap;

    -- 去年结转的到期情况（预览时按「将会作废多少」算，执行后按已落账的算 —— 同一个数）
    select coalesce(case
             when ac.expires_on is null then 0
             when ac.expired_at is not null then ac.expired_days
             else greatest(0, ac.carry_in - annual_used_between(r.id, make_date(ac.year,1,1), ac.expires_on))
           end, 0)
      into v_exp
      from annual_carry ac where ac.emp_id = r.id and ac.year = p_year - 1;
    v_exp := coalesce(v_exp, 0);
    if v_exp > 0 then v_expired_people := v_expired_people + 1; v_expired_days := v_expired_days + v_exp; end if;

    -- 步骤 2：年假结转。先减掉「本年度配额」——即使有人先跑了发放，结转也只按去年剩余算。
    v_bal := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
    v_bal := v_bal - coalesce((select sum(delta_days) from leave_ledger
                               where emp_id = r.id and leave_type = 'annual'
                                 and reason in (p_year || ' 年度配额', p_year || ' annual allowance')), 0);
    -- 预览时上面那 expire 还没写账，视图已经替我们扣掉了 due_unwritten_carry，所以两条路数字一致
    v_carry  := least(v_cap, greatest(0, v_bal));
    v_excess := greatest(0, v_bal - v_cap);
    v_taken  := annual_used_in_year(r.id, p_year - 1);
    if v_carry  > 0 then v_carry_people := v_carry_people + 1; v_carry_days := v_carry_days + v_carry; end if;
    if v_excess > 0 then v_forfeit_people := v_forfeit_people + 1; v_forfeit_days := v_forfeit_days + v_excess; end if;

    -- 步骤 3：其余假别清零。清多少读余额，发多少读 leave_types.default_days —— 都不硬编码。
    v_resets := '[]'::jsonb; v_reset_days := 0;
    for t in select code, name_en, default_days from leave_types
             where resets_yearly and not no_deduct order by sort loop
      select coalesce(balance, 0) into v_tb from leave_balances
        where emp_id = r.id and leave_type = t.code;
      v_tb := coalesce(v_tb, 0);
      if v_tb <> 0 then
        v_resets := v_resets || jsonb_build_object(
          'code', t.code, 'name', t.name_en, 'cleared', v_tb, 'credits', t.default_days);
        v_reset_days := v_reset_days + v_tb;
        if not p_preview then
          insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
          values (r.id, t.code, -v_tb,
                  (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id());
        end if;
      end if;
    end loop;
    if jsonb_array_length(v_resets) > 0 then v_reset_people := v_reset_people + 1; end if;

    if not p_preview then
      if v_excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -v_excess,
                (p_year - 1) || ' annual leave above the carry-over cap (' || v_cap || ') — forfeited',
                current_emp_id());
      end if;
      insert into annual_carry (emp_id, year, carry_in, expires_on)
      values (r.id, p_year, v_carry, v_expires)
      on conflict (emp_id, year) do nothing;
      insert into year_start_log (year, emp_id, emp_name, annual_taken_prev, annual_left,
                                  cap_applied, carried, forfeited, expired, expires_on,
                                  resets, reset_days, run_by)
      values (p_year, r.id, r.name, v_taken, v_bal, v_cap, v_carry, v_excess, v_exp, v_expires,
              v_resets, v_reset_days, current_emp_id());
    end if;

    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'taken_prev', v_taken, 'left', v_bal, 'cap', v_cap,
      'carried', v_carry, 'forfeited', v_excess, 'expired', v_exp,
      'expires_on', v_expires, 'reset_days', v_reset_days, 'resets', v_resets);
  end loop;

  -- 步骤 4：发放新一年的配额。**必须在清零之后**，否则刚发的立刻被抹掉。
  if v_mode = 'monthly' then
    v_granted := 0;
  elsif p_preview then
    -- 别名不能叫 t：上面声明了 record t，PL/pgSQL 会把它当变量替换进查询，
    -- 报 "record t is not assigned yet"。这类冲突不会在编译期发现，只在跑到时才炸。
    v_granted := (select count(distinct e.id) from employees e cross join leave_types lt
                  where e.active and (lt.default_days > 0 or lt.code = 'annual')
                    and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender)
                    and not exists (select 1 from leave_ledger l
                                    where l.emp_id = e.id and l.leave_type = lt.code
                                      and l.reason in (p_year || ' 年度配额', p_year || ' annual allowance')));
  else
    v_granted := grant_annual_entitlements(p_year);
  end if;

  return jsonb_build_object(
    'year', p_year, 'preview', p_preview, 'people', v_people,
    'blockers', v_block,
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 4. 离职时把结转记录就地关掉 ----------
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

  -- v27：结转记录就地结清，到期作业以后就找不到它了（-5 就是这么来的）
  update annual_carry set expired_at = now(), expired_days = 0
    where emp_id = p_emp and expired_at is null;

  update employees set active=false, last_working_day=p_last_day where id=p_emp;
end $$;

-- ---------- 5. 这两个也跳过离职的人 ----------
create or replace function set_carry_expiry(p_month int, p_day int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_year int := extract(year from current_date)::int;
  v_new date; v_dying numeric;
  v_people int := 0; v_days_lost numeric := 0; v_dying_people int := 0;
  v_already int := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can change the carry-forward expiry date';
  end if;
  -- 两个都空 = 永不过期；否则两个都要有，且必须是真日子。
  if (p_month is null) <> (p_day is null) then
    raise exception 'Pick both a month and a day, or neither';
  end if;
  if p_month is not null then
    if p_month < 1 or p_month > 12 then raise exception 'Month must be 1-12'; end if;
    if p_day   < 1 or p_day   > 31 then raise exception 'Day must be 1-31'; end if;
    if p_day > extract(day from (make_date(2000, p_month, 1)
                                 + interval '1 month' - interval '1 day'))::int then
      raise exception 'That month does not have % days', p_day;
    end if;
    v_new := make_date(v_year, p_month,
               least(p_day, extract(day from (make_date(v_year, p_month, 1)
                                              + interval '1 month' - interval '1 day'))::int));
  end if;

  -- 已经落账作废的那些行不再动 —— 天数已经没了，把日期往后挪也换不回来。
  select count(*) into v_already from annual_carry
   where year = v_year and expired_at is not null;

  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on, e.name
      from annual_carry ac join employees e on e.id = ac.emp_id
     where ac.year = v_year and e.active and ac.expired_at is null   -- v27
       and ac.expires_on is distinct from v_new
     order by e.name
  loop
    v_people := v_people + 1;
    -- 只有新日期已经过去了，天数才会当场没。日期在将来 ⇒ 现在什么都不掉。
    v_dying := case when v_new is not null and v_new < current_date
                 then greatest(0, r.carry_in - annual_used_between(r.emp_id, make_date(r.year, 1, 1), v_new))
                 else 0 end;
    if v_dying > 0 then
      v_dying_people := v_dying_people + 1;
      v_days_lost := v_days_lost + v_dying;
    end if;
    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'from', r.expires_on, 'to', v_new, 'dying', v_dying);
  end loop;

  if not p_preview then
    update org_settings set carry_expiry_month = p_month, carry_expiry_day = p_day where id = 1;
    update annual_carry set expires_on = v_new
     where year = v_year and expired_at is null and expires_on is distinct from v_new;
    -- 「and clear off in system」：新日期已经过去的，现在就落账，不用等明天的定时任务。
    perform expire_due_carry();
  end if;

  return jsonb_build_object(
    'preview', p_preview, 'year', v_year, 'month', p_month, 'day', p_day,
    'new_date', v_new, 'people', v_people,
    'dying_people', v_dying_people, 'days_lost', v_days_lost,
    'already_expired', v_already, 'rows', v_rows);
end $$;
revoke execute on function set_carry_expiry(int, int, boolean) from anon, public;
grant  execute on function set_carry_expiry(int, int, boolean) to authenticated;
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

  if not exists (select 1 from employees where id = p_emp and active) then
    raise exception 'That employee has left. Their leave record is frozen';   -- v27
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

-- ---------- 6. 一张申请一个年度；年度要 HR 开过才能申请 ----------
-- 整个函数逐字保持 v26 的样子,只改了上面那一段规则。
-- **没有加参数** —— 加带默认值的参数 = 新建重载,旧签名不会消失,
-- 应用发的那组 key 会同时匹配两个,PostgREST 无法二选一 → 全公司请假当场失败。
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
  -- v27：一张申请只能落在一个年度。跨年那一张的天数会整笔算进开始的那一年,
  -- 于是一月的假是从十二月的额度里扣的 —— 而且看不出来。
  if v_yr <> extract(year from p_end)::int then
    raise exception 'Leave cannot run across New Year. Please apply for the December days and the January days separately — they come out of different years'' leave';
  end if;
  -- v27：一个年度要 HR 开过才能申请,不是日历翻页就算数。
  -- 旧规则只拦「日历意义上的未来年份」,所以一月头几天申请当年的假是放行的 ——
  -- 而那时新一年的额度还没发,天数直接从去年的结转里扣掉,结转就悄悄变少了。
  -- 从没开过年的公司（第一年）不受影响：上一年没有记录,这条就不生效。
  if extract(year from p_start)::int > extract(year from current_date)::int then
    raise exception 'Next year''s leave opens for application on 1 Jan (until then the calendar is view-only)';
  end if;
  if year_started_for(me.id, v_yr - 1) and not year_started_for(me.id, v_yr) then
    raise exception '% leave has not been issued yet. HR starts the new year in the first days of January — you can apply for % leave once they have.', v_yr, v_yr;
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
