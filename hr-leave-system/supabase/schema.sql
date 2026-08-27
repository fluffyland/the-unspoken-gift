-- =============================================================
-- LeaveDesk SG — Supabase 数据库底座（正式版）
-- 在 Supabase Dashboard → SQL Editor 里整段执行一次即可。
-- 设计原则：
--   1) 假期是账本：余额 = leave_ledger 交易之和，不存可变余额字段
--   2) 审批是状态机：所有状态转移只能走 security definer 存储过程
--   3) 通知是转移副作用：application_events 插入 → Webhook → Edge Function 发邮件
--   4) 权限来自组织关系：RLS 按 本人 / 审批人 / HR 三层放行
-- =============================================================

create extension if not exists pgcrypto;

-- ---------- 1. 员工 ----------
create table if not exists employees (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  name          text not null,
  email         text unique not null,
  title         text,                             -- 职位 / occupation（可空）
  emp_no        text,                             -- 工号 / employee number（可空）
  alias         text,                             -- 别名 / alias（可空）
  mobile        text,                             -- 手机 / mobile（可空）
  join_date     date not null,
  dept          text,
  gender        text check (gender in ('M','F')),
  role          text not null default 'employee'
                check (role in ('employee','approver','hr','admin')),
  approver1     uuid references employees (id),  -- 空 = 无需审批（如 Managing Director，提交即自动批准）
  approver2     uuid references employees (id),
  two_level     boolean not null default false,   -- HR 按员工勾选是否两级审批
  annual_base   numeric(5,1) not null default 14, -- 年假基数；每多一年服务 +1（年度入账时计算）
  last_working_day date,                          -- 离职日（offboard 时填写）
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  check (approver2 is distinct from id and approver1 is distinct from id),
  check (not two_level or approver2 is not null)
);

-- ---------- 2. 假期类型（配置数据，政策变了改这里） ----------
create table if not exists leave_types (
  code                text primary key,
  name_zh             text not null,
  name_en             text not null,
  requires_attachment boolean not null default false,  -- 如 MC
  gender_eligibility  text check (gender_eligibility in ('M','F')),
  no_deduct           boolean not null default false,  -- 无薪假/NS 不扣配额
  default_days        numeric(5,1) not null default 0, -- 年度默认入账
  carry_over_cap      numeric(5,1),                    -- 年末最多结转（null=不结转）
  allow_half_day      boolean not null default false,  -- 是否允许请半天（默认仅年假/补休；HR 可改）
  sort                int not null default 99,
  note                text
);

-- 天数按 MOM 现行政策(mom.gov.sg,2026-07 核对);注释英文(界面直接展示)
insert into leave_types (code,name_zh,name_en,requires_attachment,gender_eligibility,no_deduct,default_days,carry_over_cap,sort,note) values
 ('annual','年假','Annual Leave',false,null,false,14,5,1,'Statutory minimum: 7 days in year 1, +1 per year up to 14. Company base is configurable per employee. Carry-over cap 5 days (expire end of next year).'),
 ('sick','病假（门诊）','Sick Leave',true,null,false,14,null,2,'Outpatient. Eligible after 3 months of service (MOM).'),
 ('hosp','住院假','Hospitalisation Leave',true,null,false,60,null,3,'MOM: 60 days per year, inclusive of the 14 outpatient sick-leave days.'),
 ('childcare','育儿假','Childcare Leave',false,null,false,6,null,4,'Child under 7 and a SG citizen: 6 days/parent/year. Extended childcare: +2 days if the child is 7-12.'),
 ('oil','补休','Off-in-Lieu',false,null,false,0,null,5,'Credited via Ledger & adjustments when someone works overtime or on a public holiday.'),
 ('maternity','产假','Maternity Leave',false,'F',false,112,null,6,'16 weeks (Government-Paid Maternity Leave).'),
 ('paternity','陪产假','Paternity Leave',false,'M',false,28,null,7,'4 weeks (Government-Paid Paternity Leave), mandatory for children born on/after 1 Apr 2025.'),
 ('shared_parental','共享育儿假','Shared Parental Leave',false,null,false,70,null,8,'10-week shared pool for child born on/after 1 Apr 2026 (6 weeks if born 1 Apr 2025 - 31 Mar 2026)'),
 ('infant','无薪婴儿照顾假','Unpaid Infant Care',false,null,false,6,null,9,'Unpaid. Child under 2: 6 days per parent per year.'),
 ('adoption','领养假','Adoption Leave',true,'F',false,84,null,10,'12 weeks (Government-Paid Adoption Leave).'),
 ('compassionate','恩恤假','Compassionate Leave',true,null,false,3,null,11,'Company benefit - not required by law.'),
 ('marriage','婚假','Marriage Leave',true,null,false,3,null,12,'Company benefit - not required by law.'),
 ('ns','战备军人假','NS / Reservist',false,'M',true,0,null,13,'Statutory for NSmen. Recorded only - no quota deduction.'),
 ('unpaid','无薪假','Unpaid Leave',false,null,true,0,null,14,'Recorded only - no quota deduction.'),
 ('overseas_trip','','Overseas Business Trip Leave',false,null,true,0,null,20,'Recorded only - work travel.'),
 ('training','','Training Leave',false,null,true,0,null,21,'Recorded only - training / courses.'),
 ('others','','Others',false,null,true,0,null,22,'Recorded only - anything not covered above.')
on conflict (code) do nothing;
-- 半天假默认仅年假 / 补休可请；其余整天（HR 可在控制台按类型开关）
update leave_types set allow_half_day = true where code in ('annual','oil');

-- ---------- 3. 公共假期（请假折算工作日时排除） ----------
create table if not exists public_holidays (
  holiday date primary key,
  name    text not null
);
insert into public_holidays values
 ('2026-01-01','New Year''s Day'),('2026-02-17','Chinese New Year'),('2026-02-18','Chinese New Year'),
 ('2026-03-21','Hari Raya Puasa'),('2026-04-03','Good Friday'),('2026-05-01','Labour Day'),
 ('2026-05-27','Hari Raya Haji'),('2026-05-31','Vesak Day'),('2026-06-01','Vesak Day (observed)'),
 ('2026-08-09','National Day'),('2026-08-10','National Day (observed)'),
 ('2026-11-08','Deepavali'),('2026-11-09','Deepavali (observed)'),('2026-12-25','Christmas Day')
on conflict do nothing;

-- ---------- 4. 假期账本（余额 = sum(delta_days)） ----------
create table if not exists leave_ledger (
  id          bigint generated always as identity primary key,
  emp_id      uuid not null references employees (id),
  leave_type  text not null references leave_types (code),
  delta_days  numeric(5,1) not null check (delta_days <> 0),
  reason      text not null,   -- 年度配额 / 请假扣减 / 销假返还 / OIL入账 / 手工调整 / 年末失效
  ref_application uuid,
  created_by  uuid references employees (id),
  created_at  timestamptz not null default now()
);
create index if not exists idx_ledger_emp on leave_ledger (emp_id, leave_type);

-- ---------- 5. 申请单 ----------
create table if not exists applications (
  id          uuid primary key default gen_random_uuid(),
  emp_id      uuid not null references employees (id),
  leave_type  text not null references leave_types (code),
  start_date  date not null,
  end_date    date not null check (end_date >= start_date),
  start_half  boolean not null default false,
  end_half    boolean not null default false,
  half_days   jsonb not null default '[]'::jsonb,  -- 逐日半天明细：[{"d":"2026-07-15","part":"am"}]
  days        numeric(5,1) not null check (days > 0),
  reason      text not null,
  attachment_path text,           -- Supabase Storage 路径
  status      text not null default 'pending'
              check (status in ('pending','approved','rejected','returned',
                                'withdrawn','cancel_requested','cancelled')),
  current_step int not null default 1,
  backdated   boolean not null default false,
  overlap_acknowledged boolean not null default false, -- 同团队同日请假，审批人已知晓
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_app_emp on applications (emp_id, status);
-- 同一员工同类型同起止日期在活跃状态下唯一：堵住并发/双击的重复提交（前端另有防抖）
create unique index if not exists uniq_active_application
  on applications (emp_id, leave_type, start_date, end_date)
  where status in ('pending','approved','cancel_requested');

-- ---------- 6. 审批链步骤（两级审批的载体；一级 = 只有一行） ----------
create table if not exists approval_steps (
  id             bigint generated always as identity primary key,
  application_id uuid not null references applications (id) on delete cascade,
  step_order     int not null,
  approver_id    uuid not null references employees (id),
  status         text not null default 'waiting'
                 check (status in ('waiting','pending','approved','rejected','returned')),
  comment        text,
  acted_at       timestamptz,
  unique (application_id, step_order)
);
create index if not exists idx_steps_approver on approval_steps (approver_id, status);

-- ---------- 7. 事件流（审计 + 邮件触发源） ----------
create table if not exists application_events (
  id             bigint generated always as identity primary key,
  application_id uuid not null references applications (id) on delete cascade,
  actor          uuid not null references employees (id),
  action         text not null,   -- submitted / step_approved / approved / rejected / returned / withdrawn / cancel_requested / cancelled / cancel_denied
  comment        text,
  created_at     timestamptz not null default now()
);

-- ---------- 8. 余额视图 ----------
create or replace view leave_balances as
select l.emp_id, l.leave_type,
       sum(l.delta_days) filter (where l.delta_days > 0)  as granted,
       -sum(l.delta_days) filter (where l.delta_days < 0) as used,
       sum(l.delta_days)                                  as balance,
       coalesce((select sum(a.days) from applications a
                 where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                   and a.status = 'pending'), 0)          as pending,
       sum(l.delta_days) - coalesce((select sum(a.days) from applications a
                 where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                   and a.status = 'pending'), 0)          as available
from leave_ledger l
group by l.emp_id, l.leave_type;
-- 以调用者身份执行:底层账本的 RLS(本人/HR)自动生效;
-- security definer 存储过程内部查询以属主执行,不受影响
alter view leave_balances set (security_invoker = true);
revoke select on leave_balances from anon;

-- ---------- 9. 身份辅助函数 ----------
-- 信任锚点:调用者作为【在职】员工的身份(加 active → 离职即服务器层登出)
create or replace function current_emp_id() returns uuid
language sql stable security definer set search_path = public as
$$ select id from employees where auth_user_id = auth.uid() and active $$;

create or replace function is_hr() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from employees
                  where auth_user_id = auth.uid() and role in ('hr','admin') and active) $$;

-- "是本公司在职员工吗?"——所有全员可读数据的统一门禁
-- ("已登录"不是信任边界:anon key 公开,任何人都可能持有登录态)
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select current_emp_id() is not null $$;

-- ---------- 10. 工作日折算（排除周末 + 公共假期，支持首尾半天） ----------
create or replace function working_days(p_start date, p_end date, p_sh boolean, p_eh boolean)
returns numeric language plpgsql stable as $$
declare d date; n numeric := 0; first_wd date; last_wd date;
begin
  if p_end < p_start then return 0; end if;
  d := p_start;
  while d <= p_end loop
    if extract(isodow from d) < 6 and not exists (select 1 from public_holidays where holiday = d) then
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

-- 逐日半天折算：整工作日数 − 0.5 ×（落在工作日内、标为 am/pm 的日期数）；下限 0.5
create or replace function working_days_hd(p_start date, p_end date, p_half jsonb)
returns numeric language plpgsql stable as $$
declare d date; n numeric := 0;
begin
  if p_end < p_start then return 0; end if;
  d := p_start;
  while d <= p_end loop
    if extract(isodow from d) < 6 and not exists (select 1 from public_holidays where holiday = d) then
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

-- ---------- 11. 状态机存储过程（前端只能调这些，不能直写表） ----------

-- 提交申请（也用于退回后的重新提交：传 p_resubmit_id）
-- p_half_days：逐日半天明细 [{"d":date,"part":"am|pm"}]；p_sh/p_eh 为旧前端兼容的可选尾参
drop function if exists submit_application(text,date,date,boolean,boolean,text,text,uuid);
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

-- 同团队重叠请假检查：申请人的直属团队 = 同部门 ∪ 同一审批人的队友 ∪ 其审批人 ∪ 其直接下属
create or replace function overlapping_team_leave(p_app uuid)
returns table (emp_name text, start_date date, end_date date, status text)
language sql stable security definer set search_path = public as $$
  with app as (select * from applications where id = p_app),
  grp as (
    select x.id from employees x, app a
    join employees e on e.id = a.emp_id
    -- "department" = same dept field, plus the person's own manager (the leader
    -- counts as a member), plus their direct reports. We deliberately do NOT
    -- group by shared approver1: everyone reporting to the Managing Director is
    -- a head of a DIFFERENT department, not one team.
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
    -- 鉴权：只有 HR 或该申请链上的审批人能看到结果；其余调用者得到空集（不泄露）
    and (is_hr() or exists (select 1 from approval_steps s
                            where s.application_id = p_app and s.approver_id = current_emp_id()));
$$;
revoke execute on function overlapping_team_leave(uuid) from anon, public;
grant  execute on function overlapping_team_leave(uuid) to authenticated;

-- 审批人看申请人余额：RLS 不让非 HR 审批人读别人的账本，这个 definer 函数
-- 只返回一个"可用天数"数字，且仅在调用者是 HR 或该员工某申请的链上审批人时放行。
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

-- 审批动作：approve / reject / return（当前节点审批人才能调）
-- p_ack：同团队同日请假时必须传 true（前端勾选 acknowledge），否则拒绝批准
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

-- 员工撤回（仅 pending）
create or replace function withdraw_application(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id();
begin
  update applications set status='withdrawn', updated_at=now()
    where id=p_app and emp_id=me_id and status='pending';
  if not found then raise exception 'Only your own pending applications can be withdrawn'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'withdrawn');
end $$;

-- 销假：员工发起 → 第 1 级审批人确认（返还账本）或驳回
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

-- ---------- 12. RLS（行级权限） ----------
alter table employees          enable row level security;
alter table leave_types        enable row level security;
alter table public_holidays    enable row level security;
alter table leave_ledger       enable row level security;
alter table applications       enable row level security;
alter table approval_steps     enable row level security;
alter table application_events enable row level security;

-- 假期类型/公共假期：仅在职员工可读（"登录"不构成信任边界）
-- 员工表按需知：HR 看全部；每人可读自己的整行（loadMe 需要）；其余全员走下方目录视图。
create policy emp_read   on employees          for select to authenticated
  using (is_hr() or auth_user_id = auth.uid());
create policy lt_read    on leave_types        for select to authenticated using (is_staff());
create policy ph_read    on public_holidays    for select to authenticated using (is_staff());
-- 员工档案与配置：只有 HR 能改
create policy emp_write  on employees for all to authenticated
  using (is_hr()) with check (is_hr());
create policy lt_write   on leave_types for all to authenticated
  using (is_hr()) with check (is_hr());
create policy ph_write   on public_holidays for all to authenticated
  using (is_hr()) with check (is_hr());

-- 员工目录视图：全员可读，但只暴露渲染必需的非敏感列
-- （不含 auth_user_id / annual_base / join_date / last_working_day / gender）。
-- 属主执行 + is_staff() 门；含离职者以便历史审批人姓名可解析。前端非 HR 读这里。
create or replace view employees_directory as
select id, name, email, title, dept, role, approver1, approver2, two_level, active
from employees
where is_staff();
grant  select on employees_directory to authenticated;
revoke select on employees_directory from anon;

-- 账本：本人可读自己的，HR 可读可写（手工调整）；扣减/返还走 security definer 过程
create policy ledger_read on leave_ledger for select to authenticated
  using (emp_id = current_emp_id() or is_hr());
create policy ledger_hr_insert on leave_ledger for insert to authenticated
  with check (is_hr());

-- 申请：本人 / 链上审批人 / HR 可读；一切写操作走存储过程
-- 可见性判断封装进 security definer 函数：函数体内查 applications/approval_steps
-- 时以属主身份运行、绕过 RLS，避免"policy 里查自己表"导致的无限递归。
create or replace function can_view_application(p_app uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from applications a where a.id = p_app
      and (a.emp_id = current_emp_id() or is_hr()
           or exists (select 1 from approval_steps s
                      where s.application_id = a.id and s.approver_id = current_emp_id())));
$$;

create policy app_read    on applications        for select to authenticated using (can_view_application(id));
create policy steps_read  on approval_steps      for select to authenticated using (can_view_application(application_id));
create policy events_read on application_events  for select to authenticated using (can_view_application(application_id));

-- ---------- 13. 年度入账（HR 每年 1 月 1 日执行一次；也可做成 pg_cron 定时） ----------
-- 年假 = 员工 annual_base + 每多一年服务 +1；入职当年按剩余月份 pro-rate（向上取 0.5）
-- 允许在 SQL Editor（postgres，无登录态）或 HR 账号下执行
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select case
    when extract(year from e.join_date) >= p_year
      then least(
             ceil(e.annual_base * (12 - extract(month from e.join_date) + 1) / 12 * 2) / 2,
             coalesce((select prorate_cap from org_settings where id = 1), 1e9))
    else e.annual_base + greatest(0, p_year - extract(year from e.join_date) - 1)
  end
  from employees e where e.id = p_emp;
$$;

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
revoke execute on function grant_annual_entitlements(int) from anon, public;
grant  execute on function grant_annual_entitlements(int) to authenticated;

-- ---------- 14. 全员请假日历（只暴露 姓名/部门/日期/状态，在职员工可读） ----------
create or replace view leave_calendar as
select e.name, e.dept, a.start_date, a.end_date,
       case when a.status = 'pending' then 'pending' else 'approved' end as status
from applications a join employees e on e.id = a.emp_id
where a.status in ('pending','approved','cancel_requested') and e.active
  and is_staff();  -- 属主执行(要展示全员),但只对在职员工放行
grant select on leave_calendar to authenticated;
revoke select on leave_calendar from anon;

-- ---------- 15. 注册自动关联员工档案（按邮箱匹配，无需手工填 UUID） ----------
create or replace function link_employee_on_signup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update employees set auth_user_id = new.id
  where lower(email) = lower(new.email) and auth_user_id is null;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function link_employee_on_signup();

-- ---------- 16. 离职结算（HR）：撤回在途申请 → 余额结清（encash/clear）→ 停用账号 ----------
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

-- 彻底删除员工（record + 所有痕迹；登录账号由 create-login 的 remove 动作删除）。
-- 仅 HR、不能删自己、目标是 Owner 时只有 Owner 能删；待审环节转给执行操作的 HR。
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
  update employees set approver1 = null where approver1 = p_emp;
  update employees set approver2 = null, two_level = false where approver2 = p_emp;
  update leave_ledger set created_by = null where created_by = p_emp;
  delete from applications where emp_id = p_emp;
  delete from leave_ledger where emp_id = p_emp;
  delete from annual_carry where emp_id = p_emp;
  delete from announcement_reads where emp_id = p_emp;
  update approval_steps set approver_id = me_id
    where approver_id = p_emp and status in ('pending', 'waiting');
  delete from approval_steps where approver_id = p_emp;
  delete from application_events where actor = p_emp;
  delete from employees where id = p_emp;
end $$;

-- 清空员工的请假记录（申请 + 账目 + 结转），保留档案与登录账号。
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
  delete from applications where emp_id = p_emp;
  delete from leave_ledger where emp_id = p_emp;
  delete from annual_carry where emp_id = p_emp;
end $$;

grant execute on function purge_employee(uuid) to authenticated;
grant execute on function clear_employee_records(uuid) to authenticated;

-- ---------- 17. 附件存储（MC 照片/PDF）：私有 bucket + 本人上传 / 本人+链上审批人+HR 可读 ----------
insert into storage.buckets (id, name, public) values ('attachments','attachments',false)
on conflict (id) do nothing;

create policy att_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments'
              and (storage.foldername(name))[1] = current_emp_id()::text);
create policy att_read on storage.objects for select to authenticated
  using (bucket_id = 'attachments'
         and ((storage.foldername(name))[1] = current_emp_id()::text
              or is_hr()
              or exists (select 1 from approval_steps s join applications a on a.id = s.application_id
                         where s.approver_id = current_emp_id()
                           and (storage.foldername(name))[1] = a.emp_id::text)));

-- ---------- 18. 部门（团队）：统一的下拉列表，杜绝 "Operation/Operations" 拼写分裂 ----------
-- 员工的 dept 引用这里的 name；改名 on update cascade 自动同步到每个成员。
create table if not exists departments (
  name       text primary key,
  created_at timestamptz not null default now()
);

-- 把已有员工的部门回填进列表，然后加外键（幂等，可重复执行）
insert into departments (name)
select distinct dept from employees where dept is not null
on conflict (name) do nothing;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'employees_dept_fkey') then
    alter table employees
      add constraint employees_dept_fkey foreign key (dept)
      references departments (name) on update cascade;
  end if;
end $$;

alter table departments enable row level security;
drop policy if exists dept_read  on departments;
drop policy if exists dept_write on departments;
create policy dept_read  on departments for select to authenticated using (is_staff());
create policy dept_write on departments for all    to authenticated
  using (is_hr()) with check (is_hr());

-- ---------- 19. 公司设置：系统可被任何小公司复用，公司信息是数据不是代码 ----------
create table if not exists org_settings (
  id           int primary key default 1 check (id = 1),  -- 单行表
  company_name text not null default 'My Company',
  email_domain text,
  country      text not null default 'Singapore',
  default_annual_base numeric(5,1) not null default 14,   -- Add employee 表单的年假基数默认值
  prorate_cap         numeric(5,1)                         -- 首年 pro-rate 封顶（null=不封顶）
);
insert into org_settings (id, company_name, email_domain)
values (1, 'Shanghai Uniforms', 'shanghai-uniforms.com')
on conflict (id) do nothing;

alter table org_settings enable row level security;
drop policy if exists org_read  on org_settings;
drop policy if exists org_write on org_settings;
create policy org_read  on org_settings for select to authenticated using (is_staff());
create policy org_write on org_settings for update to authenticated
  using (is_hr()) with check (is_hr());

-- =============================================================
-- 20. v7 公共假期自动同步 + 站内公告 + 年假结转（详见 migration_app_v7.sql）
-- =============================================================

-- 20.1 公共假期来源标记（区分手工录入 vs data.gov.sg 自动同步）
alter table public_holidays add column if not exists source   text not null default 'manual';
alter table public_holidays add column if not exists synced_at timestamptz;

-- 20.2 同步审计日志（HR 可读，供监控/排错）
create table if not exists holiday_sync_log (
  id         bigint generated always as identity primary key,
  ran_at     timestamptz not null default now(),
  source     text not null,
  years      int[]  not null default '{}',
  added      jsonb  not null default '[]'::jsonb,
  removed    jsonb  not null default '[]'::jsonb,
  renamed    jsonb  not null default '[]'::jsonb,
  total_seen int    not null default 0,
  status     text   not null default 'ok',
  message    text
);
create index if not exists idx_hsl_ran on holiday_sync_log (ran_at desc);
alter table holiday_sync_log enable row level security;
drop policy if exists hsl_read on holiday_sync_log;
create policy hsl_read on holiday_sync_log for select to authenticated using (is_hr());

-- 20.3 站内公告 + 已读记录（假期变更 → 全员登录即见）
create table if not exists announcements (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null default 'system',
  title      text not null,
  body       text not null,
  active     boolean not null default true
);
-- 受众：'all' 全员可见；'hr' 只给 HR/admin（假期变更时额外发一条可操作提醒）
alter table announcements add column if not exists audience text not null default 'all';
alter table announcements enable row level security;
drop policy if exists ann_read  on announcements;
drop policy if exists ann_write on announcements;
create policy ann_read  on announcements for select to authenticated
  using (is_staff() and active and (audience = 'all' or is_hr()));
create policy ann_write on announcements for all    to authenticated using (is_hr()) with check (is_hr());

create table if not exists announcement_reads (
  announcement_id bigint not null references announcements (id) on delete cascade,
  emp_id          uuid   not null references employees (id),
  read_at         timestamptz not null default now(),
  primary key (announcement_id, emp_id)
);
alter table announcement_reads enable row level security;
drop policy if exists ar_rw on announcement_reads;
create policy ar_rw on announcement_reads for all to authenticated
  using (emp_id = current_emp_id()) with check (emp_id = current_emp_id());

create or replace view my_announcements as
select a.id, a.created_at, a.kind, a.title, a.body, a.audience,
       (r.emp_id is not null) as read
from announcements a
left join announcement_reads r
  on r.announcement_id = a.id and r.emp_id = current_emp_id()
where a.active and is_staff() and (a.audience = 'all' or is_hr());
alter view my_announcements set (security_invoker = true);
grant select on my_announcements to authenticated;
revoke select on my_announcements from anon;

create or replace function mark_announcement_read(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return; end if;
  insert into announcement_reads (announcement_id, emp_id) values (p_id, me) on conflict do nothing;
end $$;
revoke execute on function mark_announcement_read(bigint) from anon, public;
grant  execute on function mark_announcement_read(bigint) to authenticated;

-- 20.4 假期对账 RPC（Edge Function 以 service_role 调用；仅系统任务可执行）
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
revoke execute on function apply_holiday_sync(jsonb, int[], text) from anon, public, authenticated;
grant  execute on function apply_holiday_sync(jsonb, int[], text) to service_role;

-- 20.5 年假结转（上限 5 天、先用结转、次年 12/31 未用作废）
update leave_types set carry_over_cap = 5 where code = 'annual';

create table if not exists annual_carry (
  emp_id       uuid    not null references employees (id),
  year         int     not null,
  carry_in     numeric(5,1) not null,
  granted_at   timestamptz not null default now(),
  expired_days numeric(5,1),
  expired_at   timestamptz,
  primary key (emp_id, year)
);
alter table annual_carry enable row level security;
drop policy if exists acarry_read on annual_carry;
create policy acarry_read on annual_carry for select to authenticated
  using (emp_id = current_emp_id() or is_hr());

create or replace function annual_used_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(a.days), 0) from applications a
  where a.emp_id = p_emp and a.leave_type = 'annual' and a.status = 'approved'
    and extract(year from a.start_date)::int = p_year;
$$;

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
revoke execute on function rollover_annual_leave(int) from anon, public;
grant  execute on function rollover_annual_leave(int) to authenticated;

create or replace view my_annual_carry as
select ac.year, ac.carry_in,
       greatest(0, ac.carry_in - annual_used_in_year(ac.emp_id, ac.year)) as remaining,
       (ac.year || '-12-31')::date as expires_on
from annual_carry ac
where ac.expired_at is null and ac.emp_id = current_emp_id()
  and ac.year = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;

-- =============================================================
-- 21. v8 账号类型权限：Owner 判定 + 自改锁（详见 migration_app_v8.sql §7）
-- =============================================================
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from employees
                 where auth_user_id = auth.uid() and role = 'admin' and active) $$;

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

-- ===== v16: 结转上限（每人）／到期／年度重置／年初一键执行 =====
-- 与 supabase/migration_app_v16.sql 同源。放在文件末尾：本节引用 org_settings、
-- employees、leave_types、annual_carry，它们都在上面建好。
-- ---------- 0. 前置迁移可能没跑过 ----------
-- HANDOVER 第一条教训：**绝不要写一个假设前一个迁移跑过的迁移**。v14 加的这两列
-- 本函数要读，而 schema.sql（从零重建时用的那份）里并没有。补一次，代价为零。
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table org_settings add column if not exists accrual_mode text not null default 'annual';

-- ---------- 1. 字段 ----------
alter table employees   add column if not exists carry_cap           numeric(5,1);
alter table org_settings add column if not exists default_carry_cap  numeric(5,1);
alter table org_settings add column if not exists carry_expiry_months int;
alter table annual_carry add column if not exists expires_on         date;
alter table leave_types  add column if not exists resets_yearly      boolean not null default true;

comment on column employees.carry_cap is
  'Max annual-leave days this person may carry into the next year. Per employee on purpose: different staff carry different amounts.';
comment on column org_settings.default_carry_cap is
  'Pre-fills the Add employee form only. Changing it never moves anyone already in the system (same rule as default_annual_base).';
comment on column org_settings.carry_expiry_months is
  'Months from 1 January until carried days expire. NULL = they never expire.';
comment on column leave_types.resets_yearly is
  'True for every type that goes back to its yearly allowance each January. False for annual (it carries) and off-in-lieu (it was earned).';

-- 回填：上线当天任何数字都不许变
update employees set carry_cap =
  coalesce((select carry_over_cap from leave_types where code = 'annual'), 0)
  where carry_cap is null;
update org_settings set default_carry_cap =
  coalesce((select carry_over_cap from leave_types where code = 'annual'), 0)
  where id = 1 and default_carry_cap is null;
-- 旧行为 = 当年 12-31 到期 = 从 1 月 1 日起 12 个月
update org_settings set carry_expiry_months = 12 where id = 1 and carry_expiry_months is null;
update annual_carry set expires_on = (year || '-12-31')::date where expires_on is null;
update leave_types set resets_yearly = false where code in ('annual', 'oil');

-- ---------- 2. 取数辅助 ----------
-- 某人在某个日期区间内**实际休掉**的年假天数。结转天数「先用先扣」就是靠它：
-- 到期时作废的只是「到期日之前没用掉的那部分」，已经休了的永远不会被倒扣。
create or replace function annual_used_between(p_emp uuid, p_from date, p_to date)
returns numeric language sql stable as $$
  select coalesce(sum(a.days), 0) from applications a
  where a.emp_id = p_emp and a.leave_type = 'annual' and a.status = 'approved'
    and a.start_date >= p_from and a.start_date <= p_to;
$$;

-- 「已经过了到期日、但还没写进账本」的结转天数。
-- 视图立刻扣掉它 ⇒ 即使所有定时任务都死了，也没人能用到已经过期的天数。
-- 一旦 expire_due_carry() 把它落成账本条目（expired_at 落地），这里立刻返回 0，
-- 不会重复扣。
create or replace function due_unwritten_carry(p_emp uuid, p_code text)
returns numeric language sql stable as $$
  select case when p_code <> 'annual' then 0 else coalesce((
    select sum(greatest(0, ac.carry_in
                 - annual_used_between(ac.emp_id, make_date(ac.year, 1, 1), ac.expires_on)))
    from annual_carry ac
    where ac.emp_id = p_emp
      and ac.expired_at is null
      and ac.expires_on is not null
      and ac.expires_on < current_date
  ), 0) end;
$$;

-- ---------- 3. 余额视图：扣掉已过期的结转 ----------
create or replace view leave_balances as
select l.emp_id, l.leave_type,
       sum(l.delta_days) filter (where l.delta_days > 0)  as granted,
       -sum(l.delta_days) filter (where l.delta_days < 0) as used,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type) as balance,
       coalesce((select sum(a.days) from applications a
                 where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                   and a.status = 'pending'), 0)          as pending,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type)
         - coalesce((select sum(a.days) from applications a
                     where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                       and a.status = 'pending'), 0)      as available
from leave_ledger l
group by l.emp_id, l.leave_type;

-- ---------- 4. 到期落账 ----------
create or replace function expire_due_carry(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; rem numeric; n int := 0;
begin
  for r in
    select ac.emp_id, ac.year, ac.carry_in, ac.expires_on
    from annual_carry ac
    where ac.expired_at is null
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

-- ---------- 5. 年初记录表 ----------
create table if not exists year_start_log (
  year               int  not null,
  emp_id             uuid not null references employees (id),
  -- 姓名存一份副本：员工被删掉之后这份记录还要能看懂
  emp_name           text not null,
  annual_taken_prev  numeric(6,1) not null default 0,
  annual_left        numeric(6,1) not null default 0,
  cap_applied        numeric(5,1) not null default 0,
  carried            numeric(6,1) not null default 0,
  forfeited          numeric(6,1) not null default 0,
  expired            numeric(6,1) not null default 0,
  expires_on         date,
  resets             jsonb not null default '[]'::jsonb,
  reset_days         numeric(6,1) not null default 0,
  run_at             timestamptz not null default now(),
  run_by             uuid references employees (id),
  primary key (year, emp_id)
);
comment on table year_start_log is
  'One permanent row per employee per year-start run. Never overwritten. This is what HR reads years later.';
alter table year_start_log enable row level security;
drop policy if exists yslog_read on year_start_log;
create policy yslog_read on year_start_log for select to authenticated using (is_hr());

-- ---------- 6. 年初一键执行（p_preview = true 时只算不写） ----------
-- 预览和执行**共用同一段算术**，preview 只是把写入跳过。所以「预览显示的」和
-- 「实际记录的」不可能对不上 —— 那是构造上的保证，不是靠两处代码维持一致。
create or replace function run_year_start(p_year int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; t record;
  v_months int; v_mode text; v_expires date;
  v_bal numeric; v_cap numeric; v_carry numeric; v_excess numeric;
  v_taken numeric; v_exp numeric; v_tb numeric;
  v_resets jsonb; v_reset_days numeric;
  v_rows jsonb := '[]'::jsonb;
  v_people int := 0; v_carry_people int := 0; v_carry_days numeric := 0;
  v_forfeit_people int := 0; v_forfeit_days numeric := 0;
  v_expired_people int := 0; v_expired_days numeric := 0;
  v_reset_people int := 0; v_granted int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

  select carry_expiry_months, accrual_mode into v_months, v_mode from org_settings where id = 1;
  v_expires := case when v_months is null then null
                    else (make_date(p_year, 1, 1) + (v_months || ' months')::interval)::date - 1 end;

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
                  (p_year - 1) || ' ' || t.name_en || ' reset — use it or lose it', current_emp_id());
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
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 7. 旧的 rollover 改成薄壳，避免两处算术 ----------
-- 保留函数名：YEARLY_CHECKLIST 和旧文档里写过它，别让老步骤突然报「函数不存在」。
create or replace function rollover_annual_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  v := run_year_start(p_year, false);
  return (v ->> 'carried_people')::int;
end $$;
revoke execute on function rollover_annual_leave(int) from anon, public;
grant  execute on function rollover_annual_leave(int) to authenticated;

-- ---------- 8. 员工看得到的结转视图：真实到期日 ----------
create or replace view my_annual_carry as
select ac.year, ac.carry_in,
       greatest(0, ac.carry_in - annual_used_in_year(ac.emp_id, ac.year)) as remaining,
       ac.expires_on
from annual_carry ac
where ac.emp_id = current_emp_id() and ac.year = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;
