-- ============================================================================
-- LeaveDesk — install.sql   ⚙️  GENERATED FILE, do not edit by hand
--
-- ONE paste sets up a brand-new database. Supabase Dashboard → SQL Editor →
-- New query → paste all of this → Run. It takes a few seconds.
--
-- Then run ONE more file: bootstrap_owner.sql — kept separate because you have to
-- type your own email and password into it.
--
-- This replaces the old procedure of pasting 31 files one at a time in the
-- right order. Missing one left the system subtly wrong in a single place, which is
-- very hard to work out later.
--
-- ⚠️ For a NEW, EMPTY project only. If your database already exists, do NOT run this —
--    use the individual migration_app_vNN.sql files, which upgrade it in place.
--
-- Contains, in order:
--    1. schema.sql
--    2. migration_app_v1.sql
--    3. migration_app_v2.sql
--    4. migration_app_v3.sql
--    5. migration_app_v4.sql
--    6. migration_app_v5.sql
--    7. migration_app_v6.sql
--    8. migration_app_v7.sql
--    9. migration_app_v8.sql
--   10. migration_app_v9.sql
--   11. migration_app_v10.sql
--   12. migration_app_v11.sql
--   13. migration_app_v12.sql
--   14. migration_app_v13.sql
--   15. migration_app_v14.sql
--   16. migration_app_v15.sql
--   17. migration_app_v16.sql
--   18. migration_app_v18.sql
--   19. migration_app_v19.sql
--   20. migration_app_v24.sql
--   21. migration_app_v25.sql
--   22. migration_app_v26.sql
--   23. migration_app_v27.sql
--   24. migration_app_v28.sql
--   25. migration_app_v31.sql
--   26. migration_app_v32.sql
--   27. migration_app_v35.sql
--   28. migration_app_v36.sql
--   29. migration_app_v37.sql
--   30. keepalive_ping_v3.sql
--   31. undo_year_start.sql
--
-- Regenerate with:  node build-install.mjs
-- ============================================================================

-- ============================================================================
--  ✏️  FILL THIS IN — the only part of this file you edit
-- ============================================================================
--  Change the values between the quotes, then run the whole file. Six values.
--
--  You are NOT asked for the project address or the API key. Those already go
--  into app.html (the two lines near the top of the website file), and typing
--  the same thing twice is how two places end up disagreeing. The app reports
--  its own address to the database the first time an HR/Owner signs in.
-- ----------------------------------------------------------------------------
drop table if exists _leavedesk_setup;
create table _leavedesk_setup (
  company_name         text,     -- appears on screen and in every email
  email_domain         text,     -- staff email addresses, e.g. shanghai-uniforms.com
  default_annual_leave numeric,  -- days a new employee starts on
  default_carry_cap    numeric,  -- most days anyone may carry into next year
  owner_name           text,     -- YOU — the first HR/Owner account
  owner_email          text      -- must match the login you created in Authentication
);
-- Nobody but this SQL Editor session ever needs to read this, and the last thing
-- this file does is drop it. Row Level Security with no policy = no anon or
-- signed-in client can see it. Without this line the Supabase dashboard stops and
-- asks you to approve an exception -- and being asked to approve something you
-- cannot judge, in the middle of setting up a new company, is not a setup step.
alter table _leavedesk_setup enable row level security;
insert into _leavedesk_setup values (
  'My Company',
  'company.com',
  14,
  5,
  'Owner Name',
  'owner@company.com'
);
-- ============================================================================
--  Nothing below here needs editing.
-- ============================================================================



-- ===========================================================================
-- schema.sql
-- ===========================================================================

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

-- ---------- 8b. 公司设置：系统可被任何小公司复用，公司信息是数据不是代码 ----------
-- 位置很重要：第 13 节的 annual_entitlement_for 是 `language sql`，函数体在**创建时**
-- 就会解析，所以它引用的 org_settings 必须已经存在。这张表原本定义在文件末尾（第 19 节），
-- 于是在一个全新的库上跑 schema.sql 会报
--   ERROR: relation "org_settings" does not exist
-- ——测试脚本一直跑两遍 schema.sql，第二遍才成功，正好把这个问题盖住了。
-- 一次粘贴的 install.sql 没有第二遍，所以这里必须真的修好。
create table if not exists org_settings (
  id           int primary key default 1 check (id = 1),  -- 单行表
  company_name text not null default 'My Company',
  email_domain text,
  country      text not null default 'Singapore',
  default_annual_base numeric(5,1) not null default 14,   -- Add employee 表单的年假基数默认值
  annual_cap          numeric(5,1)                         -- 全公司年假上限（null=不封顶）
);
insert into org_settings (id, company_name, email_domain)
values (1, 'Shanghai Uniforms', 'shanghai-uniforms.com')
on conflict (id) do nothing;

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
-- 年假 = 员工 annual_base，就这一个数。不按年资加，也不按入职月份折算。
--
-- 这里曾经是「annual_base + 每多一年服务 +1，入职当年 pro-rate」。v18 在正式库里去掉了，
-- 但这个建库脚本没跟着改 —— 于是新装一套系统就会把两条自动规则原样带回来。这就是
-- Barry 的账本里 7 月发了 17 天、而 employees.annual_base 只有 14 的原因：那 3 天是
-- 年资加出来的，进了账本却没进那一列，之后在 Edit employee 里按 Save 就把它抹掉了。
--
-- 用户原话：「remove all automation of crediting one annualleave every year」
--           「first year HR will calculate by themself and will credit them via edit employee」
-- 新人第一年该给几天，HR 自己算，填进 Edit employee → Annual Leave Entitled / Yr。
-- 系统不从入职日期推算任何东西。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select least(e.annual_base,
               coalesce((select annual_cap from org_settings where id = 1), 1e9))
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

-- v12：周六是否为工作日。部门给默认值，员工可以覆盖（NULL = 跟部门）。
-- 这两列一直只存在于 migration_app_v12 里，schema.sql 的建表语句没有 ——
-- 于是「从零建库」建出来的库连 emp_works_saturday 都建不起来。
alter table departments add column if not exists works_saturday boolean not null default false;
alter table employees   add column if not exists works_saturday boolean;   -- null = 跟随部门
comment on column departments.works_saturday is 'Department default: does this department work Saturdays?';
comment on column employees.works_saturday   is 'Per-person override. NULL = inherit the department default.';

-- v12 的「每人一份的周六」一族：emp_works_saturday / is_working_day / working_days。
-- schema.sql 少了这三个，而折进来的 v18 submit_application 依赖它们 —— 从零建库
-- 建出来的系统一提交申请就报 function does not exist。
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

-- 每人一份的工作日计算（v12 起：周六是否上班按员工/团队定）。
-- schema.sql 里一直只有下面那个三参数版本，可是折进来的 submit_application 调用的是
-- **四参数**版本 —— 只有跑迁移链才装得上。于是「从零建库」建出来的 submit_application
-- 一遇到半天申请就报 function does not exist，而这正是 schema.sql 存在的场景。
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
revoke execute on function working_days_hd(uuid, date, date, jsonb) from anon;
grant  execute on function working_days_hd(uuid, date, date, jsonb) to authenticated;



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
-- （表体已上移到第 8b 节：第 13 节的 annual_entitlement_for 要用它。）

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

-- ===== v18: 年假总额直接填写／假别天数按差额补发／HR 代申请／人工改动记录 =====
-- 与 supabase/migration_app_v18.sql 同源。
-- ---------- 0. 前置迁移可能没跑过（HANDOVER 第一条教训） ----------
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table org_settings add column if not exists accrual_mode text not null default 'annual';
alter table employees    add column if not exists carry_cap    numeric(5,1);

-- ---------- 1. 年假额度 = 填进去的数字 ----------
-- 工龄递增（annual_base + 工龄）和新人首年折算都去掉了。公司上限仍然生效：
-- 它现在约束的是「你填的那个数字」，而不是一段看不见的算式。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select least(e.annual_base,
               coalesce((select annual_cap from org_settings where id = 1), 1e9))
  from employees e where e.id = p_emp;
$$;

-- ---------- 1b. 给人看的天数写法 ----------
-- numeric(5,1) 直接拼进字符串会写出 "14.0 → 16.0"、"+2.0 days"。人不这么写数字。
create or replace function fmt_days(v numeric) returns text language sql immutable as $$
  select case when v is null then '' else trim_scale(v)::text end;
$$;

-- ---------- 2. 人工改动记录 ----------
-- 和请假记录**分开**的第二本账：所有 HR 手动改过的东西都在这里。
-- emp_id 为 NULL = 全公司范围的改动（例如把住院假从 60 改成 62），
-- 按用户要求只写一条，不逐个员工列名字。
create table if not exists hr_amendments (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  by_emp      uuid references employees (id),
  by_name     text not null default '',     -- 姓名存副本：人被删掉后记录仍看得懂
  emp_id      uuid references employees (id),
  emp_name    text,                          -- NULL = 全公司
  leave_type  text references leave_types (code),
  kind        text not null,                 -- entitlement | oil_credit | type_days | correction
  before_days numeric(6,1),
  after_days  numeric(6,1),
  delta_days  numeric(6,1),
  affected    int,                           -- 全公司改动影响到几个人
  reason      text not null default ''
);
comment on table hr_amendments is
  'Second record book: every manual change HR makes to a balance. Leave applications live in `applications`; this is everything else.';
alter table hr_amendments enable row level security;
drop policy if exists hramd_read on hr_amendments;
create policy hramd_read on hr_amendments for select to authenticated using (is_hr());

create or replace function log_amendment(
  p_emp uuid, p_emp_name text, p_type text, p_kind text,
  p_before numeric, p_after numeric, p_delta numeric, p_affected int, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare who uuid := current_emp_id();
begin
  insert into hr_amendments (by_emp, by_name, emp_id, emp_name, leave_type, kind,
                             before_days, after_days, delta_days, affected, reason)
  values (who, coalesce((select name from employees where id = who), 'System'),
          p_emp, p_emp_name, p_type, p_kind, p_before, p_after, p_delta, p_affected,
          coalesce(p_reason, ''));
end $$;

-- ---------- 3. 年假额度：填进去的数字就是当年的总额度（v19） ----------
-- ---------- 1. 当年「算作额度」的天数 ----------
-- 什么算额度：年度发放、入职发放、历次额度调整、按月累积。
-- 什么不算：
--   · 请假扣减、销假返还 —— 这两种都写了 ref_application，一并排除，
--     这比按文字匹配可靠（返还是**正数**，不排除就会被当成额度）。
--   · 年末清零、结转到期、超出结转上限作废、离职结算 —— 是账务，不是额度。
create or replace function annual_entitled_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(delta_days), 0)
    from leave_ledger
   where emp_id = p_emp
     and leave_type = 'annual'
     and extract(year from created_at)::int = p_year
     and ref_application is null
     and reason not like '%expired (unused)%'
     and reason not like '%above the carry-over cap%'
     and reason not like '%reset — use it or lose it%'
     and reason not like '%excess forfeited%'
     and reason not like '%expired carry-over%'
     and reason not like 'Offboarding%'
     and reason not like '%结转%'
     and reason not like '%作废%';
$$;
comment on function annual_entitled_in_year(uuid, int) is
  'Days credited as ENTITLEMENT this year — grants, joining credits and entitlement changes. Leave taken and refunds carry ref_application and are excluded; year-end write-offs are excluded by wording.';
revoke execute on function annual_entitled_in_year(uuid, int) from anon;
grant  execute on function annual_entitled_in_year(uuid, int) to authenticated;

-- ---------- 2. 设定年假额度：对账到这个数字 ----------
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; ent numeric; adj numeric;
        y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if p_days is null or p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', fmt_days(cap);
  end if;

  before_days := e.annual_base;
  update employees set annual_base = p_days where id = p_emp;

  -- 今年还一天额度都没发过的人：不补。等年初发放时自然就是新数字。
  -- （v18 是拿 reason 字符串去认那一行，认不出来就整个跳过 —— 这就是「系统里加进来的人
  --   改了额度却什么都没发生」的原因。现在按**总额**判断，与措辞无关。）
  if not exists (select 1 from leave_ledger
                  where emp_id = p_emp and leave_type = 'annual'
                    and extract(year from created_at)::int = y
                    and ref_application is null) then
    perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, 0, 1, '');
    return 0;
  end if;

  ent := annual_entitled_in_year(p_emp, y);
  adj := p_days - ent;                      -- 对账：把当年额度**补成**填进去的数字
  if adj <> 0 then
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
    values (p_emp, 'annual', adj,
            y || ' annual entitlement set to ' || fmt_days(p_days), current_emp_id());
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, adj, 1, '');
  return adj;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 3. 一键给全公司加年假 ----------
-- 用户原话：「one click then it will credit whole company with one day of annual leave」，
-- 并选了「永久」：每人的 Annual Leave Entitled / Yr 加 N（明年自动就是新数字），
-- 当年余额同时补 N。会超过公司上限的人**跳过并列名**，不静默截断 ——
-- 「max AL is link, it cannot goes over the max AL i set」。
create or replace function bump_annual_all(p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cap numeric; r record; n int := 0; credited int := 0;
        skipped text[] := '{}'; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit annual leave'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  cap := (select annual_cap from org_settings where id = 1);

  for r in select id, name, annual_base from employees where active order by name loop
    if cap is not null and r.annual_base + p_days > cap then
      skipped := skipped || r.name;
      continue;
    end if;
    if r.annual_base + p_days < 0 then
      skipped := skipped || r.name;
      continue;
    end if;
    n := n + 1;
    -- 只给今年已经发过额度的人补当年余额；没发过的，改额度就够了。
    if exists (select 1 from leave_ledger
                where emp_id = r.id and leave_type = 'annual'
                  and extract(year from created_at)::int = y
                  and ref_application is null) then
      credited := credited + 1;
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', p_days,
                y || ' annual leave ' || case when p_days > 0 then '+' else '' end ||
                fmt_days(p_days) || ' — company-wide', current_emp_id());
      end if;
    end if;
    if not p_preview then
      update employees set annual_base = annual_base + p_days where id = r.id;
    end if;
  end loop;

  -- n = 0 表示一个人都没加成（例如全部卡在公司上限）。这种情况**不写记录**：
  -- 否则修订记录里会留下一条「+1 day to every employee」，而实际上谁都没拿到。
  if not p_preview and n > 0 then
    -- 全公司一条记录，不逐个列名字（用户明确要求）。
    perform log_amendment(null, null, 'annual', 'annual_bump', null, null, p_days, n,
      'Company annual leave amendment — ' || case when p_days > 0 then '+' else '' end ||
      fmt_days(p_days) || ' day' || case when abs(p_days) = 1 then '' else 's' end ||
      ' to every employee');
  end if;
  return jsonb_build_object('days', p_days, 'affected', n, 'credited', credited,
                            'skipped', to_jsonb(skipped));
end $$;
revoke execute on function bump_annual_all(numeric, boolean) from anon, public;
grant  execute on function bump_annual_all(numeric, boolean) to authenticated;

-- ---------- 4. 改假别天数 → 按差额补发给所有人 ----------
-- 用户原话：「if previously i set as 60days for Hospitalization leave, then i change to
-- 62 and click save changes it should credit 2 days to all employee ... who already taken
-- the leave will not be affected do not reset the whole thing to 62」。
-- 所以是**差额**，不是重设。已休掉的天数完全不受影响。
create or replace function amend_leave_type_days(p_code text, p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t leave_types%rowtype; diff numeric; n int := 0; r record; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change a leave type'; end if;
  select * into t from leave_types where code = p_code;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if p_days < 0 then raise exception 'Days per year cannot be negative'; end if;
  diff := p_days - t.default_days;

  -- 年假：额度是**每人一个数字**（Edit employee 里填），全公司统一补发会和它打架。
  -- 补休：是加班换来的，没有「每年多少天」这回事。两者都不参与差额补发。
  -- no_deduct 的类型（无薪假、NS 等）根本没有余额，补发也没有意义。
  -- 年假：每人一个数字（Edit employee 里填）。补休：加班换来的，没有「每年多少天」。
  -- 这两个连 default_days 都不该存 —— 之前只是不补发、却照样把数字写下去，
  -- 结果年度发放看到 oil.default_days = 3 就发给了所有人（测试里 OIL 从 1.5 变 4.5）。
  -- 所以直接拒绝，而不是默默存一个没有意义、还会被别处读到的数字。
  if p_code = 'annual' then
    raise exception 'Annual leave is set per employee, in Edit employee — not here';
  end if;
  if p_code = 'oil' then
    raise exception 'Off-in-lieu is earned, not granted — credit it per employee in Edit employee';
  end if;
  if t.no_deduct or diff = 0 then
    if not p_preview then
      update leave_types set default_days = p_days where code = p_code;
    end if;
    return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
      'after', p_days, 'delta', diff, 'affected', 0, 'credited', false);
  end if;

  for r in select e.id from employees e
           where e.active
             and (t.gender_eligibility is null or t.gender_eligibility = e.gender) loop
    n := n + 1;
    if not p_preview then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.id, p_code, diff,
              y || ' ' || t.name_en || ' amended ' || fmt_days(t.default_days) || ' → ' || fmt_days(p_days),
              current_emp_id());
    end if;
  end loop;

  if not p_preview then
    update leave_types set default_days = p_days where code = p_code;
    -- 全公司一条记录，不逐个列名字（用户明确要求）。
    perform log_amendment(null, null, p_code, 'type_days', t.default_days, p_days, diff, n,
      'Company leave amendment — ' || t.name_en || ' ' ||
      case when diff > 0 then '+' else '' end || fmt_days(diff) || ' days');
  end if;
  return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
    'after', p_days, 'delta', diff, 'affected', n, 'credited', true);
end $$;
revoke execute on function amend_leave_type_days(text, numeric, boolean) from anon, public;
grant  execute on function amend_leave_type_days(text, numeric, boolean) to authenticated;

-- ---------- 5. OIL 补发（Edit employee 里的按钮） ----------
create or replace function credit_oil(p_emp uuid, p_days numeric, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit off-in-lieu'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
  values (p_emp, 'oil', p_days, 'Off-in-lieu: ' || btrim(p_reason), current_emp_id());
  perform log_amendment(p_emp, e.name, 'oil', 'oil_credit', null, null, p_days, 1, btrim(p_reason));
  return p_days;
end $$;
revoke execute on function credit_oil(uuid, numeric, text) from anon, public;
grant  execute on function credit_oil(uuid, numeric, text) to authenticated;

-- ---------- 6. HR 代员工请假：同一个函数，多一个参数 ----------
create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false,
  p_for_emp uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
        actor uuid; on_behalf boolean := p_for_emp is not null;
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
  return app_id;
end $$;

-- ---------- 7. 年初清零的措辞：expired ----------
-- 用户的原话：「just remove how much leave remained label as expired and add back the
-- default date set by user」。机制不变（v16 已经对了），只是把措辞改成他要的字。
create or replace function reset_statutory_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; t record; b numeric; n int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can reset the yearly leave balances'; end if;
  for r in select id from employees where active loop
    for t in select code, name_en from leave_types where resets_yearly and not no_deduct order by sort loop
      select coalesce(balance, 0) into b from leave_balances where emp_id = r.id and leave_type = t.code;
      if coalesce(b, 0) <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, t.code, -b, (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id());
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke execute on function reset_statutory_leave(int) from anon, public;
grant  execute on function reset_statutory_leave(int) to authenticated;

-- run_year_start 里的清零措辞也要跟着改 —— 它自己内联了那段循环，不是调用上面的函数。
-- 两处写同一句话本来就是隐患，这里至少让它们一次改齐。
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
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 8. 年度发放永远不碰补休 ----------
-- 上面已经拦住了「把 oil 的 default_days 改成非 0」这条路，但这个函数是账目的最后一关：
-- 就算数据库里靠别的途径塞进去一个数字，补休也不该被年度发放批量补给所有人。
-- 两道防线，因为这一条错了是**给所有人凭空多发假**，不会有任何人报错。
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
  for r in
    select e.id as emp_id, t.code, t.default_days
    from employees e cross join leave_types t
    where e.active and t.code <> 'oil' and (t.default_days > 0 or t.code = 'annual')
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

-- =============================================================
-- v24：结转到期「日期」取代「月数」
-- annual_carry.expires_on 本来就是 date，改的只是「谁算出这个日期」。
-- carry_expiry_months 保留不动 —— 前端的 db.orgV16 靠它探测。
-- =============================================================
-- ---------- 1. 字段 ----------
alter table org_settings add column if not exists carry_expiry_month int;
alter table org_settings add column if not exists carry_expiry_day   int;

comment on column org_settings.carry_expiry_month is
  'Month (1-12) that carried annual leave expires on, repeating every year. NULL (with carry_expiry_day) = never expires.';
comment on column org_settings.carry_expiry_day is
  'Day of carry_expiry_month. 29 February is clamped to 28 February in a non-leap year.';

-- ---------- 2. 回填：上线当天任何日期都不许变 ----------
-- 旧算法是 make_date(Y,1,1) + N 个月 - 1 天。用闰年 2000 反推日月，
-- N=2（2 月底）会得到 02-29，再由下面的收敛规则在平年收到 02-28 ——
-- 和旧算法逐年的结果完全一致。
update org_settings
   set carry_expiry_month = extract(month from d)::int,
       carry_expiry_day   = extract(day   from d)::int
  from (select ((make_date(2000, 1, 1) + (carry_expiry_months || ' months')::interval)::date - 1) as d
          from org_settings where id = 1 and carry_expiry_months is not null) s(d)
 where org_settings.id = 1
   and org_settings.carry_expiry_month is null
   and org_settings.carry_expiry_day is null;

-- ---------- 3. 唯一一处算日期的地方 ----------
create or replace function carry_expiry_for(p_year int)
returns date language sql stable set search_path = public as $$
  select case
           when o.carry_expiry_month is null or o.carry_expiry_day is null then null
           else make_date(p_year, o.carry_expiry_month,
                  least(o.carry_expiry_day,
                        extract(day from (make_date(p_year, o.carry_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
grant execute on function carry_expiry_for(int) to authenticated;

-- ---------- 4. 改日期：预览 + 执行是同一个函数 ----------
-- 往前挪日期会**立刻作废别人手上正拿着的天数**，所以这里必须先能算出
-- 「几个人、几天会当场没」，让界面在写任何东西之前把话说清楚。
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
     where ac.year = v_year and ac.expired_at is null
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

-- ---------- 5. run_year_start 改读日期 ----------
-- 整个函数只有 v_expires 这一处变了，其余逐字保持 v18 的样子。
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
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

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
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- =============================================================
-- v25：carry_expiry_for 改为 security definer
-- 作为 invoker 时，凡是读不到 org_settings 的调用方都会拿到 NULL，
-- 而 NULL 在这里的含义是「永不过期」—— 静默地把过期规则关掉。
-- =============================================================
create or replace function carry_expiry_for(p_year int)
returns date language sql stable security definer set search_path = public as $$
  select case
           when o.carry_expiry_month is null or o.carry_expiry_day is null then null
           else make_date(p_year, o.carry_expiry_month,
                  least(o.carry_expiry_day,
                        extract(day from (make_date(p_year, o.carry_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
comment on function carry_expiry_for(int) is
  'The date carried annual leave expires in a given year. SECURITY DEFINER on purpose: as an invoker it returned NULL wherever org_settings was unreadable, and NULL here means "never expires" — a silent failure rather than an error.';
revoke execute on function carry_expiry_for(int) from anon, public;
grant  execute on function carry_expiry_for(int) to authenticated;

-- =============================================================
-- v26：已结算年度的补录假期
-- 结转是按「那一年年底还剩多少」算出来的，那一年的假期事后变了，结转必须跟着变。
-- 员工一律拒绝；HR 明确确认后放行，并在同一个事务里把那一年重算一遍。
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

-- =============================================================
-- v27：审计修复 —— 年结前的待批假、离职冻结、一张申请一个年度
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

-- =============================================================
-- v28：邮件通知 —— 测试期间只发给指定的那一个人
-- =============================================================
alter table org_settings add column if not exists notify_only_emp uuid references employees (id);

comment on column org_settings.notify_only_emp is
  'Test mode for notification emails: while this names an employee, only mail addressed to THEM is sent and nobody else in the company receives anything. NULL = notify everyone normally. Also the destination for the Send test email button.';


-- ===========================================================================
-- migration_app_v1.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — 正式版接线补丁（在已跑过 schema.sql + seed.sql 之后执行一次）
-- 作用：给正式版 app.html 补两样东西
--   1) employees.title（职位/job title 列）
--   2) leave_available()（让审批人能看到申请人余额数字，受权限保护）
-- 在 Supabase → SQL Editor 里整段粘贴 → Run 即可（可重复执行，安全）。
-- =============================================================

-- 1) 职位列（HR 新增/编辑员工时填写）
alter table employees add column if not exists title text;

-- 2) 审批人查看申请人可用天数（RLS 不让非 HR 读别人账本，用受控 definer 函数）
create or replace function leave_available(p_emp uuid, p_code text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare allowed boolean;
begin
  select is_hr() or exists (
    select 1 from applications a join approval_steps s on s.application_id = a.id
    where a.emp_id = p_emp and s.approver_id = current_emp_id()
  ) into allowed;
  if not allowed then raise exception '无权查看该员工余额'; end if;
  return coalesce((select balance from leave_balances where emp_id = p_emp and leave_type = p_code), 0)
       - coalesce((select sum(days) from applications
                   where emp_id = p_emp and leave_type = p_code and status = 'pending'), 0);
end $$;

-- 3) 修复：申请/审批步骤/事件的读取策略原来在 policy 里查自己的表，
--    导致 Postgres 报 "infinite recursion detected in policy"。改为封装进
--    security definer 函数（函数内绕过 RLS），三张表的读取策略都指向它。
create or replace function can_view_application(p_app uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from applications a where a.id = p_app
      and (a.emp_id = current_emp_id() or is_hr()
           or exists (select 1 from approval_steps s
                      where s.application_id = a.id and s.approver_id = current_emp_id())));
$$;

drop policy if exists app_read    on applications;
drop policy if exists steps_read  on approval_steps;
drop policy if exists events_read on application_events;
create policy app_read    on applications        for select to authenticated using (can_view_application(id));
create policy steps_read  on approval_steps      for select to authenticated using (can_view_application(application_id));
create policy events_read on application_events  for select to authenticated using (can_view_application(application_id));

-- 4) 清理集成测试期间插入的临时部门（如不存在则无操作）
delete from departments where name = 'ZZ Temp Test';


-- ===========================================================================
-- migration_app_v2.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — v2 补丁(第 7 轮反馈)。SQL Editor 整段执行一次,可重复执行。
-- 内容:
--   1) org_settings 加 default_annual_base(Add employee 表单默认年假基数)
--   2) leave_types 注释全部改英文 + 按 MOM 现行政策修正天数
--      (Shared Parental Leave: 2026-04-01 起 10 周 = 70 天)
-- =============================================================

-- 1) 公司默认值
alter table org_settings add column if not exists default_annual_base numeric(5,1) not null default 14;

-- 2) 假期类型:英文注释 + MOM 核对(mom.gov.sg,2026-07)
update leave_types set default_days = 70,
  note = '10-week shared pool for child born on/after 1 Apr 2026 (6 weeks if born 1 Apr 2025 - 31 Mar 2026)'
  where code = 'shared_parental';

update leave_types set note = 'Statutory minimum: 7 days in year 1, +1 per year up to 14. Company base is configurable per employee.' where code = 'annual';
update leave_types set note = 'Outpatient. Eligible after 3 months of service (MOM).' where code = 'sick';
update leave_types set note = 'MOM: 60 days per year, inclusive of the 14 outpatient sick-leave days.' where code = 'hosp';
update leave_types set note = 'Child under 7 and a SG citizen: 6 days/parent/year. Extended childcare: +2 days if the child is 7-12.' where code = 'childcare';
update leave_types set note = 'Credited via Ledger & adjustments when someone works overtime or on a public holiday.' where code = 'oil';
update leave_types set note = '16 weeks (Government-Paid Maternity Leave).' where code = 'maternity';
update leave_types set note = '4 weeks (Government-Paid Paternity Leave), mandatory for children born on/after 1 Apr 2025.' where code = 'paternity';
update leave_types set note = 'Unpaid. Child under 2: 6 days per parent per year.' where code = 'infant';
update leave_types set note = '12 weeks (Government-Paid Adoption Leave).' where code = 'adoption';
update leave_types set note = 'Company benefit - not required by law.' where code = 'compassionate';
update leave_types set note = 'Company benefit - not required by law.' where code = 'marriage';
update leave_types set note = 'Statutory for NSmen. Recorded only - no quota deduction.' where code = 'ns';
update leave_types set note = 'Recorded only - no quota deduction.' where code = 'unpaid';


-- ===========================================================================
-- migration_app_v3.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — v3 安全加固(第一性原理:信任锚点 = 登录账号↔在职员工档案)
-- SQL Editor 整段执行一次;可重复执行。
-- 修复(均经 live 实测坐实):
--   A. leave_balances 视图绕过 RLS:未登录都能读全公司余额 → security_invoker
--   B. "已登录"被当成信任边界:任何自助注册的陌生账号可读员工名录/日历
--      → 一切只读策略改为"在职员工才可读"(is_staff)
--   C. 离职员工仍能登录读数据 → 身份地基函数加 active,服务器层等于登出
-- =============================================================

-- ---------- 1. 身份地基:调用者作为【在职】员工的身份 ----------
-- 整个权限体系唯一的信任锚点;加 active 后,离职者在数据库层全部策略自动失效。
create or replace function current_emp_id() returns uuid
language sql stable security definer set search_path = public as
$$ select id from employees where auth_user_id = auth.uid() and active $$;

create or replace function is_hr() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from employees
                  where auth_user_id = auth.uid() and role in ('hr','admin') and active) $$;

-- "是本公司在职员工吗?"——所有全员可读数据的统一门禁
create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select current_emp_id() is not null $$;

-- ---------- 2. 全员可读的数据:从"登录即可读"收紧为"在职员工才可读" ----------
drop policy if exists emp_read  on employees;
drop policy if exists lt_read   on leave_types;
drop policy if exists ph_read   on public_holidays;
drop policy if exists dept_read on departments;
drop policy if exists org_read  on org_settings;
create policy emp_read  on employees       for select to authenticated using (is_staff());
create policy lt_read   on leave_types     for select to authenticated using (is_staff());
create policy ph_read   on public_holidays for select to authenticated using (is_staff());
create policy dept_read on departments     for select to authenticated using (is_staff());
create policy org_read  on org_settings    for select to authenticated using (is_staff());

-- ---------- 3. 视图漏洞 ----------
-- leave_balances:改为以调用者身份执行 → 底层账本的 RLS(本人/HR)自动生效。
-- 存储过程(submit/leave_available/offboard)以属主身份查询,不受影响。
alter view leave_balances set (security_invoker = true);

-- leave_calendar:本来就要给全员看(姓名/日期/状态),保持属主执行,
-- 但在查询体内加 is_staff() 门 —— 非在职员工得到空集。
create or replace view leave_calendar as
select e.name, e.dept, a.start_date, a.end_date,
       case when a.status = 'pending' then 'pending' else 'approved' end as status
from applications a join employees e on e.id = a.emp_id
where a.status in ('pending','approved','cancel_requested') and e.active
  and is_staff();

-- 未登录(anon)通道彻底斩断
revoke select on leave_balances from anon;
revoke select on leave_calendar from anon;


-- ===========================================================================
-- migration_app_v4.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v5.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v6.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — v6 半天假重做 + 公司名
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
--   · 半天假改为逐日可选（全天/上午/下午）：新增 half_days 列 + working_days_hd()，
--     重建 submit_application（p_sh/p_eh 保留为可选尾参 → 前后端部署顺序无关）
--   · 公司名更新为 Shanghai School Uniforms Pte Ltd
-- =============================================================

-- ---------- 1. 半天假明细列 ----------
alter table applications add column if not exists half_days jsonb not null default '[]'::jsonb;

-- ---------- 2. 逐日半天的工作日折算 ----------
-- 整工作日数 − 0.5 ×（落在工作日内、被标为 am/pm 的日期数）；下限 0.5。
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

-- ---------- 3. 重建 submit_application（新增 p_half_days；p_sh/p_eh 变可选尾参） ----------
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
  if me.id is null then raise exception '未找到员工档案'; end if;
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception '假期类型不存在'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception '不符合该假期的资格条件'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception '该假期类型必须上传证明（MC）'; end if;
  if p_end < p_start or p_end - p_start > 366 then
    raise exception '请假区间无效或过长（最多约一年）'; end if;
  d := case when jsonb_array_length(hd) > 0
            then working_days_hd(p_start, p_end, hd)
            else working_days(p_start, p_end, p_sh, p_eh) end;
  if d <= 0 then raise exception '所选日期不含工作日'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances where emp_id = me.id and leave_type = p_type;
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
      start_half=p_sh, end_half=p_eh, half_days=hd, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception '只能重新提交被退回的申请'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,half_days,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,hd,d,p_reason,p_attachment,p_start<current_date)
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

-- ---------- 4. 公司名 ----------
update org_settings set company_name = 'Shanghai School Uniforms Pte Ltd' where id = 1;


-- ===========================================================================
-- migration_app_v7.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — v7 公共假期自动同步 + 站内公告 + 次年日历只读 + 年假结转(上限5天,逾期作废)
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 需要一起部署：sync-holidays Edge Function（拉取 data.gov.sg）+ 前端 index.html。
--
-- 本迁移新增/变更：
--   1. public_holidays 增加来源/同步时间列（区分手工录入 vs 自动同步）
--   2. holiday_sync_log     每次同步的审计日志（HR 可见，供监控/排错）
--   3. announcements / announcement_reads  站内公告（假期变更时通知全员，登录即见）
--   4. apply_holiday_sync() 供 Edge Function（service_role）调用：对账 + 记日志 + 发公告
--   5. submit_application  加「次年日历只读」：跨年/次年日期在 1 月 1 日前不可申请
--   6. 年假结转：annual_carry 表 + rollover_annual_leave()（上限 5 天，先用结转、年底作废）
--      并把 annual 的 carry_over_cap 设为 5
-- =============================================================


-- =============================================================
-- 1. 公共假期来源标记
-- =============================================================
alter table public_holidays add column if not exists source    text not null default 'manual';
alter table public_holidays add column if not exists synced_at  timestamptz;
comment on column public_holidays.source is 'manual = HR 手工录入; data.gov.sg = 自动同步（对账时只会动自动来源的行，不覆盖手工录入）';


-- =============================================================
-- 2. 同步审计日志
-- =============================================================
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


-- =============================================================
-- 3. 站内公告（假期变更 → 全员登录即见的通知）
-- =============================================================
create table if not exists announcements (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null default 'system',      -- 'holiday' | 'system'
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

-- 当前用户「未读」公告视图（前端登录后读这里，逐条弹/挂横幅）
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

-- 标记已读（幂等）
create or replace function mark_announcement_read(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return; end if;
  insert into announcement_reads (announcement_id, emp_id) values (p_id, me)
  on conflict do nothing;
end $$;
revoke execute on function mark_announcement_read(bigint) from anon, public;
grant  execute on function mark_announcement_read(bigint) to authenticated;


-- =============================================================
-- 4. 假期对账 RPC（Edge Function 以 service_role 调用）
--    入参 p_holidays: [{"holiday":"2027-01-01","name":"New Year's Day"}, ...]
--         p_years:    该批数据「权威覆盖」的年份，如 {2026,2027}；只在这些年份内对账，
--                     绝不动其它年份，也绝不删除 source='manual' 的手工录入
-- =============================================================
create or replace function apply_holiday_sync(
  p_holidays jsonb, p_years int[], p_source text default 'data.gov.sg'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_added   jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_renamed jsonb := '[]'::jsonb;
  r record; changed boolean := false;
  add_txt text; rem_txt text; ann_body text;
begin
  -- 仅系统任务可调用：PostgREST 用 service_role key → current_user='service_role'；
  -- 或在 SQL Editor（postgres）里手动测试。普通登录用户/anon 一律拒绝。
  if current_user <> 'service_role' and session_user <> 'postgres' then
    raise exception 'apply_holiday_sync 仅限系统同步任务调用';
  end if;
  if p_years is null or array_length(p_years, 1) is null then
    raise exception 'p_years 不能为空'; end if;

  -- (a) 新增 / 改名：逐条 upsert，落在覆盖年份内的才对账
  for r in
    select (e->>'holiday')::date as d, e->>'name' as nm
    from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
    where extract(year from (e->>'holiday')::date)::int = any(p_years)
  loop
    if not exists (select 1 from public_holidays where holiday = r.d) then
      v_added := v_added || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    elsif (select name from public_holidays where holiday = r.d) is distinct from r.nm then
      v_renamed := v_renamed || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    end if;
    insert into public_holidays (holiday, name, source, synced_at)
    values (r.d, r.nm, p_source, now())
    on conflict (holiday) do update
      set name = excluded.name, source = excluded.source, synced_at = now();
  end loop;

  -- (b) 删除：覆盖年份内、由本来源自动同步过、但这批数据里已不存在的日期
  --     （只删 source=p_source 的行；手工录入的临时假日不会被误删）
  for r in
    select ph.holiday as d, ph.name as nm from public_holidays ph
    where extract(year from ph.holiday)::int = any(p_years)
      and ph.source = p_source
      and not exists (select 1 from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
                      where (e->>'holiday')::date = ph.holiday)
  loop
    v_removed := v_removed || jsonb_build_object('holiday', r.d, 'name', r.nm);
    delete from public_holidays where holiday = r.d;
    changed := true;
  end loop;

  insert into holiday_sync_log (source, years, added, removed, renamed, total_seen, status)
  values (p_source, p_years, v_added, v_removed, v_renamed,
          jsonb_array_length(coalesce(p_holidays, '[]'::jsonb)), 'ok');

  -- (c) 有变更 → 发全员站内公告
  if changed then
    add_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_added || v_renamed) e);
    rem_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_removed) e);
    ann_body := 'The public-holiday calendar was updated from the official MOM source (data.gov.sg). 系统已按 MOM 官方数据更新公共假期。';
    if add_txt is not null then ann_body := ann_body || E'\n\n➕ Added / updated 新增或更新:\n' || add_txt; end if;
    if rem_txt is not null then ann_body := ann_body || E'\n\n➖ Removed 移除:\n' || rem_txt; end if;
    -- 全员通知（informational）
    insert into announcements (kind, title, body, audience)
    values ('holiday', '📅 Public holidays updated 公共假期已更新', ann_body, 'all');
    -- 额外给 HR / admin 一条可操作提醒：可在 HR 控制台复核 / 增删改
    insert into announcements (kind, title, body, audience)
    values ('holiday', '🛠️ HR: public holidays changed — please review 公共假期已变更（请复核）',
            'The automatic sync updated the public-holiday calendar. Review or adjust it in HR Console → Company settings — you can add, edit or remove any date.'
            || E'\n\n' || ann_body, 'hr');
  end if;

  return jsonb_build_object('changed', changed, 'added', v_added, 'removed', v_removed, 'renamed', v_renamed);
end $$;
revoke execute on function apply_holiday_sync(jsonb, int[], text) from anon, public, authenticated;
grant  execute on function apply_holiday_sync(jsonb, int[], text) to service_role;


-- =============================================================
-- 5. 次年日历「只读」 + 半天假仅对适用假期开放
--    （重建 submit_application；签名与 v6 完全一致，仅新增两处校验，前端无需改调用）
-- =============================================================
-- 5.0 半天假开关：默认仅年假 / 补休可请半天；其余（病假/住院假等）整天。HR 可在控制台改。
alter table leave_types add column if not exists allow_half_day boolean not null default false;
update leave_types set allow_half_day = (code in ('annual','oil'));

create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
begin
  select * into me from employees where auth_user_id = auth.uid() and active;
  if me.id is null then raise exception '未找到员工档案'; end if;
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception '假期类型不存在'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception '不符合该假期的资格条件'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception '该假期类型必须上传证明（MC）'; end if;
  if p_end < p_start or p_end - p_start > 366 then
    raise exception '请假区间无效或过长（最多约一年）'; end if;
  -- 次年日历只读：次年额度要到 1 月 1 日才发放，此前不能申请落在次年的假
  if extract(year from p_start)::int > extract(year from current_date)::int
     or extract(year from p_end)::int > extract(year from current_date)::int then
    raise exception '次年假期要到 1 月 1 日才开放申请（次年日历现在仅供查看） / Next year''s leave opens on 1 Jan';
  end if;
  -- 半天假仅对允许的假期类型生效；其余类型忽略半天明细，一律按整天计
  if not coalesce(t.allow_half_day, false) then hd := '[]'::jsonb; end if;
  d := case when jsonb_array_length(hd) > 0
            then working_days_hd(p_start, p_end, hd)
            else working_days(p_start, p_end, p_sh, p_eh) end;
  if d <= 0 then raise exception '所选日期不含工作日'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances where emp_id = me.id and leave_type = p_type;
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
      start_half=p_sh, end_half=p_eh, half_days=hd, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception '只能重新提交被退回的申请'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,half_days,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,hd,d,p_reason,p_attachment,p_start<current_date)
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


-- =============================================================
-- 6. 年假结转（上限 5 天，先用结转、次年 12/31 未用作废）
-- =============================================================
-- 6.0 年假结转上限设为 5（原为 7）
update leave_types set carry_over_cap = 5 where code = 'annual';

-- 6.1 结转记账表：记录「某员工在某年可用的结转天数」，供次年到期核销 + 前端展示
create table if not exists annual_carry (
  emp_id       uuid    not null references employees (id),
  year         int     not null,          -- 该结转在「这一年」内可用（次年 1/1 从上一年结转而来）
  carry_in     numeric(5,1) not null,     -- 结转进来的天数（已 ≤ 上限）
  granted_at   timestamptz not null default now(),
  expired_days numeric(5,1),              -- 年末未用、被作废的天数（核销后回填）
  expired_at   timestamptz,
  primary key (emp_id, year)
);
alter table annual_carry enable row level security;
drop policy if exists acarry_read on annual_carry;
create policy acarry_read on annual_carry for select to authenticated
  using (emp_id = current_emp_id() or is_hr());

-- 6.2 某员工某年「实际休掉的年假」（用于判断结转是否用完）。
--     因次年日历只读 → 每张年假申请都落在单一自然年，用 start_date 归年即准确。
create or replace function annual_used_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(a.days), 0) from applications a
  where a.emp_id = p_emp and a.leave_type = 'annual' and a.status = 'approved'
    and extract(year from a.start_date)::int = p_year;
$$;

-- 6.3 年度切换：处理「转入 p_year」这一刻的结转与作废。建议每年 1/1 由 pg_cron 或 HR 执行；
--     必须在 grant_annual_entitlements(p_year) 发放新年度额度之前调用。幂等。
--     规则：① 先核销上一年（p_year-1）结转里没用完的部分（先用结转 → 未用即过期）；
--          ② 再看上一年剩余年假余额：≤5 全部结转、>5 的部分作废；把结转额记入 annual_carry。
create or replace function rollover_annual_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; cap numeric; used numeric; rem numeric; bal numeric; carry numeric; excess numeric; n int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception '只有 HR 能执行年度结转'; end if;
  cap := coalesce((select carry_over_cap from leave_types where code = 'annual'), 0);

  for r in select id from employees where active loop
    -- ① 上一年结转未用部分作废（先用结转的口径：作废 = max(0, 结转进来 − 上一年实际休掉)）
    perform 1 from annual_carry where emp_id = r.id and year = p_year - 1 and expired_at is null;
    if found then
      select carry_in into carry from annual_carry where emp_id = r.id and year = p_year - 1;
      used := annual_used_in_year(r.id, p_year - 1);
      rem  := greatest(0, carry - used);
      if rem > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -rem, (p_year - 1) || ' 结转年假到期作废 (expired carry-over)', null);
      end if;
      update annual_carry set expired_days = rem, expired_at = now()
        where emp_id = r.id and year = p_year - 1;
    end if;

    -- ② 建立转入 p_year 的结转额度（上限 cap；超额部分作废）
    if not exists (select 1 from annual_carry where emp_id = r.id and year = p_year) then
      bal    := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
      -- 若本年度额度已发放，剔除它 → 只按「上一年遗留」算结转，避免 rollover/grant 执行顺序出错
      bal    := bal - coalesce((select sum(delta_days) from leave_ledger
                                where emp_id = r.id and leave_type = 'annual'
                                  and reason = p_year || ' 年度配额'), 0);
      carry  := least(cap, greatest(0, bal));
      excess := greatest(0, bal - cap);
      if excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -excess, (p_year - 1) || ' 年假超出结转上限(' || cap || ')作废 (excess forfeited)', null);
      end if;
      -- 结转天数本就在余额里（去年遗留），无需再入账；仅登记以便展示与次年核销
      insert into annual_carry (emp_id, year, carry_in) values (r.id, p_year, carry);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function rollover_annual_leave(int) from anon, public;
grant  execute on function rollover_annual_leave(int) to authenticated;

-- 6.4 当前用户「本年结转」视图（前端在仪表盘展示：还剩几天结转、几时到期）
create or replace view my_annual_carry as
select ac.year,
       ac.carry_in,
       greatest(0, ac.carry_in - annual_used_in_year(ac.emp_id, ac.year)) as remaining,
       (ac.year || '-12-31')::date as expires_on
from annual_carry ac
where ac.expired_at is null
  and ac.emp_id = current_emp_id()
  and ac.year  = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;

-- =============================================================
-- 完。部署顺序见 SETUP.md「v7 部署」：① 跑本 SQL ② 部署 sync-holidays Edge Function
--   ③ 建 cron（每月同步 + 每年 1/1 结转&发放）④ 上传新 index.html
-- =============================================================


-- ===========================================================================
-- migration_app_v8.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — v8（自带 v7）：一次粘贴即可把数据库从 v6 升到 v8
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 已经跑过 v7 也没关系（全部 create or replace / add column if not exists / on conflict）。
--
-- 本文件 = v7 全部内容（公共假期同步 / 站内公告 / 次年只读 / 年假结转 / 半天假开关）
--          + v8 新增：员工自助字段、新假期类型、附件默认、账号类型权限（自改锁）。
-- =============================================================


-- =============================================================
-- 1. 公共假期来源标记
-- =============================================================
alter table public_holidays add column if not exists source    text not null default 'manual';
alter table public_holidays add column if not exists synced_at  timestamptz;

-- =============================================================
-- 2. 同步审计日志
-- =============================================================
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

-- =============================================================
-- 3. 站内公告
-- =============================================================
create table if not exists announcements (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind       text not null default 'system',
  title      text not null,
  body       text not null,
  active     boolean not null default true
);
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
  insert into announcement_reads (announcement_id, emp_id) values (p_id, me)
  on conflict do nothing;
end $$;
revoke execute on function mark_announcement_read(bigint) from anon, public;
grant  execute on function mark_announcement_read(bigint) to authenticated;

-- =============================================================
-- 4. 假期对账 RPC（Edge Function 以 service_role 调用）
-- =============================================================
create or replace function apply_holiday_sync(
  p_holidays jsonb, p_years int[], p_source text default 'data.gov.sg'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_added   jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_renamed jsonb := '[]'::jsonb;
  r record; changed boolean := false;
  add_txt text; rem_txt text; ann_body text;
begin
  if current_user <> 'service_role' and session_user <> 'postgres' then
    raise exception 'apply_holiday_sync 仅限系统同步任务调用';
  end if;
  if p_years is null or array_length(p_years, 1) is null then
    raise exception 'p_years 不能为空'; end if;

  for r in
    select (e->>'holiday')::date as d, e->>'name' as nm
    from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
    where extract(year from (e->>'holiday')::date)::int = any(p_years)
  loop
    if not exists (select 1 from public_holidays where holiday = r.d) then
      v_added := v_added || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    elsif (select name from public_holidays where holiday = r.d) is distinct from r.nm then
      v_renamed := v_renamed || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    end if;
    insert into public_holidays (holiday, name, source, synced_at)
    values (r.d, r.nm, p_source, now())
    on conflict (holiday) do update
      set name = excluded.name, source = excluded.source, synced_at = now();
  end loop;

  for r in
    select ph.holiday as d, ph.name as nm from public_holidays ph
    where extract(year from ph.holiday)::int = any(p_years)
      and ph.source = p_source
      and not exists (select 1 from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
                      where (e->>'holiday')::date = ph.holiday)
  loop
    v_removed := v_removed || jsonb_build_object('holiday', r.d, 'name', r.nm);
    delete from public_holidays where holiday = r.d;
    changed := true;
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
    if add_txt is not null then ann_body := ann_body || E'\n\nAdded / updated:\n' || add_txt; end if;
    if rem_txt is not null then ann_body := ann_body || E'\n\nRemoved:\n' || rem_txt; end if;
    insert into announcements (kind, title, body, audience)
    values ('holiday', 'Public holidays updated', ann_body, 'all');
    insert into announcements (kind, title, body, audience)
    values ('holiday', 'HR: public holidays changed — please review',
            'The automatic sync updated the public-holiday calendar. Review or adjust it in HR Console -> Company settings — you can add, edit or remove any date.'
            || E'\n\n' || ann_body, 'hr');
  end if;

  return jsonb_build_object('changed', changed, 'added', v_added, 'removed', v_removed, 'renamed', v_renamed);
end $$;
revoke execute on function apply_holiday_sync(jsonb, int[], text) from anon, public, authenticated;
grant  execute on function apply_holiday_sync(jsonb, int[], text) to service_role;

-- =============================================================
-- 5. 次年日历「只读」 + 半天假仅对适用假期开放（重建 submit_application）
-- =============================================================
alter table leave_types add column if not exists allow_half_day boolean not null default false;
-- 只把年假/补休打开为可请半天；不去动其它类型（避免重复执行时覆盖 HR 的自定义勾选）
update leave_types set allow_half_day = true where code in ('annual','oil');

create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
begin
  select * into me from employees where auth_user_id = auth.uid() and active;
  if me.id is null then raise exception '未找到员工档案'; end if;
  perform pg_advisory_xact_lock(hashtext(me.id::text));
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception '假期类型不存在'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception '不符合该假期的资格条件'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception '该假期类型必须上传证明（附件）'; end if;
  if p_end < p_start or p_end - p_start > 366 then
    raise exception '请假区间无效或过长（最多约一年）'; end if;
  if extract(year from p_start)::int > extract(year from current_date)::int
     or extract(year from p_end)::int > extract(year from current_date)::int then
    raise exception '次年假期要到 1 月 1 日才开放申请（次年日历现在仅供查看） / Next year''s leave opens on 1 Jan';
  end if;
  if not coalesce(t.allow_half_day, false) then hd := '[]'::jsonb; end if;
  d := case when jsonb_array_length(hd) > 0
            then working_days_hd(p_start, p_end, hd)
            else working_days(p_start, p_end, p_sh, p_eh) end;
  if d <= 0 then raise exception '所选日期不含工作日'; end if;
  if not t.no_deduct then
    select available into avail from leave_balances where emp_id = me.id and leave_type = p_type;
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
      start_half=p_sh, end_half=p_eh, half_days=hd, days=d, reason=p_reason,
      attachment_path=coalesce(p_attachment, attachment_path),
      status='pending', current_step=1, backdated=(p_start<current_date), updated_at=now()
      where id=p_resubmit_id and emp_id=me.id and status='returned'
      returning id into app_id;
    if app_id is null then raise exception '只能重新提交被退回的申请'; end if;
    delete from approval_steps where application_id = app_id;
  else
    insert into applications (emp_id,leave_type,start_date,end_date,start_half,end_half,half_days,days,reason,attachment_path,backdated)
    values (me.id,p_type,p_start,p_end,p_sh,p_eh,hd,d,p_reason,p_attachment,p_start<current_date)
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
    values (app_id, me.id, 'auto_approved', 'No approver required');
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

-- =============================================================
-- 6. 年假结转（上限 5 天，先用结转、次年 12/31 未用作废）
-- =============================================================
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
  if not is_hr() and session_user <> 'postgres' then raise exception '只有 HR 能执行年度结转'; end if;
  cap := coalesce((select carry_over_cap from leave_types where code = 'annual'), 0);

  for r in select id from employees where active loop
    perform 1 from annual_carry where emp_id = r.id and year = p_year - 1 and expired_at is null;
    if found then
      select carry_in into carry from annual_carry where emp_id = r.id and year = p_year - 1;
      used := annual_used_in_year(r.id, p_year - 1);
      rem  := greatest(0, carry - used);
      if rem > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -rem, (p_year - 1) || ' expired carry-over', null);
      end if;
      update annual_carry set expired_days = rem, expired_at = now()
        where emp_id = r.id and year = p_year - 1;
    end if;

    if not exists (select 1 from annual_carry where emp_id = r.id and year = p_year) then
      bal    := coalesce((select balance from leave_balances where emp_id = r.id and leave_type = 'annual'), 0);
      bal    := bal - coalesce((select sum(delta_days) from leave_ledger
                                where emp_id = r.id and leave_type = 'annual'
                                  and reason = p_year || ' 年度配额'), 0);
      carry  := least(cap, greatest(0, bal));
      excess := greatest(0, bal - cap);
      if excess > 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', -excess, (p_year - 1) || ' excess forfeited (carry cap ' || cap || ')', null);
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
  and ac.year  = extract(year from current_date)::int;
alter view my_annual_carry set (security_invoker = true);
grant select on my_annual_carry to authenticated;
revoke select on my_annual_carry from anon;


-- =============================================================
-- 7. v8 —— 员工自助字段 + 新假期类型 + 附件默认 + 账号类型权限（自改锁）
-- =============================================================

-- 7.1 员工自助档案字段（个人「My details」页展示）
alter table employees add column if not exists emp_no text;
alter table employees add column if not exists alias  text;
alter table employees add column if not exists mobile text;

-- 7.2 新增假期类型（默认仅记录、不扣配额；HR 可在控制台改为可扣减/改天数/加附件）
insert into leave_types (code,name_zh,name_en,requires_attachment,gender_eligibility,no_deduct,default_days,carry_over_cap,allow_half_day,sort,note) values
 ('overseas_trip','','Overseas Business Trip Leave',false,null,true,0,null,false,20,'Recorded only — work travel.'),
 ('training','','Training Leave',false,null,true,0,null,false,21,'Recorded only — training / courses.'),
 ('others','','Others',false,null,true,0,null,false,22,'Recorded only — anything not covered above.')
on conflict (code) do nothing;

-- 7.3 附件默认：这些类型默认需要附件（HR 可在控制台逐类勾选调整）
update leave_types set requires_attachment = true
  where code in ('sick','hosp','marriage','compassionate','adoption');

-- 7.4 Owner / Super Admin 判定（role = 'admin'）
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from employees
                 where auth_user_id = auth.uid() and role = 'admin' and active) $$;

-- 7.5 自改锁：非 Owner 不能改「自己」的审批人 / 年假基数 / 账号类型；
--     任何非 Owner 都不能把谁设成 Owner（防提权）。SQL Editor(postgres) 不受限。
create or replace function guard_employee_self_edit() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return new; end if;      -- 无登录态（SQL Editor / 后台任务）放行
  if is_admin() then return new; end if;       -- Owner 可改任何人任何字段
  -- 非 Owner 不得把任何人设为 Owner
  if new.role = 'admin' and (tg_op = 'INSERT' or old.role is distinct from 'admin') then
    raise exception '只有 Owner 能设置 Owner / Super Admin 账号';
  end if;
  -- 非 Owner 不得修改「自己」的敏感字段
  if tg_op = 'UPDATE' and new.id = me and (
       new.approver1   is distinct from old.approver1
    or new.approver2   is distinct from old.approver2
    or new.two_level   is distinct from old.two_level
    or new.annual_base is distinct from old.annual_base
    or new.role        is distinct from old.role) then
    raise exception '不能修改自己的审批人 / 年假基数 / 账号类型，请由 Owner 代改';
  end if;
  return new;
end $$;
drop trigger if exists trg_employee_self_edit on employees;
create trigger trg_employee_self_edit before insert or update on employees
  for each row execute function guard_employee_self_edit();

-- =============================================================
-- 完。跑完本 SQL 后：半天/附件勾选、新字段、新假期类型、自改锁 全部生效。
-- =============================================================


-- ===========================================================================
-- migration_app_v9.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk — v9：新员工首年年假「按月折算」封顶（可选）
-- 在 Supabase Dashboard → SQL Editor 整段执行一次；幂等，可重复执行。
-- 只加一列 + 更新一个函数。跑完后「Company settings」会出现
-- 「Cap pro-rated annual leave at」一栏；留空 = 不封顶。
-- =============================================================
alter table org_settings add column if not exists prorate_cap numeric(5,1);

-- 首年 pro-rate 的结果不超过 org_settings.prorate_cap（为空则不封顶）。
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


-- ===========================================================================
-- migration_app_v10.sql
-- ===========================================================================

-- LeaveDesk SG — migration v10：员工「彻底删除」「清空记录」+ 离职/删除的安全加固
-- 幂等，可重复执行。SQL Editor 粘贴 → Run 一次即可。
--
-- 包含：
--   1. purge_employee(uuid)          彻底删除员工（供应用「Delete permanently」按钮调用）
--   2. clear_employee_records(uuid)  清空员工的请假记录但保留账号（「Clear leave records」按钮）
--   3. offboard_employee 加固        HR 不能离职结算 Owner；离职者不再挂着别人的审批链
--   4. guard_employee_self_edit 加固 允许上述服务端函数内部整理审批人引用（GUC 旁路）
--
-- 安全设计：
--   · 三个函数都是 security definer，但内部先校验调用者是 HR；
--   · 目标是 Owner / Super Admin 时，只有另一位 Owner 才能操作（防 HR 越权接管/清除 Owner）；
--   · 不能对自己执行删除/离职；
--   · 待审批环节不会被删成「悬空」：目标员工名下待审的环节自动转给执行操作的 HR。

-- ---------- 0. 自我编辑守卫：加服务端旁路 ----------
-- purge/offboard 需要把「别人以目标为审批人」的引用置空；若其中恰好包括执行者自己的行，
-- 原触发器会拦下（不能改自己的审批人）。函数内先设 leavedesk.svc=1（事务内有效）即可放行。
create or replace function guard_employee_self_edit() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := current_emp_id();
begin
  if me is null then return new; end if;      -- SQL Editor / 后台任务放行
  if coalesce(current_setting('leavedesk.svc', true), '') = '1' then return new; end if;  -- 服务端函数内部放行
  if is_admin() then return new; end if;       -- Owner 可改任何人任何字段
  if new.role = 'admin' and (tg_op = 'INSERT' or old.role is distinct from 'admin') then
    raise exception '只有 Owner 能设置 Owner / Super Admin 账号';
  end if;
  if tg_op = 'UPDATE' and new.id = me and (
       new.approver1   is distinct from old.approver1
    or new.approver2   is distinct from old.approver2
    or new.two_level   is distinct from old.two_level
    or new.annual_base is distinct from old.annual_base
    or new.role        is distinct from old.role) then
    raise exception '不能修改自己的审批人 / 年假基数 / 账号类型，请由 Owner 代改';
  end if;
  return new;
end $$;
drop trigger if exists trg_employee_self_edit on employees;
create trigger trg_employee_self_edit before insert or update on employees
  for each row execute function guard_employee_self_edit();

-- ---------- 1. 彻底删除一个员工 ----------
-- 清掉：其申请（级联审批步骤/事件）、账目、公告已读、年假结转、审批人引用、
--       他给别人记账的 created_by、他在别人申请上的已决审批步骤与事件；
-- 转移：他名下「待审 / 等待中」的别人申请环节 → 执行操作的 HR（避免申请卡死）；
-- 最后删除员工档案本身。登录账号由应用侧 create-login 函数的 remove 动作先行删除。
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

  -- 1) 别人把他当审批人的引用先解开（这些员工此后改为自动批准/单级，可再指派）
  update employees set approver1 = null where approver1 = p_emp;
  update employees set approver2 = null, two_level = false where approver2 = p_emp;

  -- 2) 他给别人记账时的 created_by 置空（保留别人的账目）
  update leave_ledger set created_by = null where created_by = p_emp;

  -- 3) 他自己的申请（approval_steps / application_events 会级联删除）与账目、结转、公告已读
  delete from applications where emp_id = p_emp;
  delete from leave_ledger where emp_id = p_emp;
  delete from annual_carry where emp_id = p_emp;
  delete from announcement_reads where emp_id = p_emp;

  -- 4) 他在别人申请上的审批环节：待审/等待中的转给执行操作的 HR（申请不卡死），已决的删除
  update approval_steps set approver_id = me_id
    where approver_id = p_emp and status in ('pending', 'waiting');
  delete from approval_steps where approver_id = p_emp;
  delete from application_events where actor = p_emp;

  -- 5) 员工档案
  delete from employees where id = p_emp;
end $$;

-- ---------- 2. 清空一个员工的请假记录（保留档案与登录账号） ----------
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
  delete from applications where emp_id = p_emp;   -- 级联 approval_steps + application_events
  delete from leave_ledger where emp_id = p_emp;   -- 清空账目 → 余额归零
  delete from annual_carry where emp_id = p_emp;   -- 结转记录属于请假记录，一并清
end $$;

-- ---------- 3. 离职结算加固 ----------
-- 新增：目标是 Owner 时只有 Owner 能操作；离职者名下待审环节转给执行操作的 HR；
--       别人把他当审批人的引用解开（否则申请会送到一个再也无法登录的人手里）。
create or replace function offboard_employee(p_emp uuid, p_last_day date, p_mode text)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); r record; tgt employees%rowtype;
begin
  if not is_hr() then raise exception '只有 HR 能执行离职结算'; end if;
  if p_mode not in ('encash','clear') then raise exception 'mode 必须是 encash 或 clear'; end if;
  if p_emp = me_id then raise exception '不能对自己执行离职结算'; end if;
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

grant execute on function purge_employee(uuid) to authenticated;
grant execute on function clear_employee_records(uuid) to authenticated;


-- ===========================================================================
-- migration_app_v11.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v12.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v13.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk SG — migration v13：公共假期的「来源 + 时间」与手工录入保护
--
-- 可以在 v12 之前或之后执行，两者互不依赖。幂等，可重复执行。
--
-- 解决三件事：
--   1) 手工录入的假期，系统里**没有任何时间戳** —— 界面想显示「什么时候加的」
--      根本无从取数（manual 编辑时还会把 synced_at 置空）。
--   2) 同步会**悄悄接管**手工录入的行：source 被改成 data.gov.sg，
--      于是名称被 MOM 覆盖，而且这行从此可以被下一次同步删掉 —— 保护凭空消失。
--      若名称恰好相同，连公告都不会发，完全无声。
--   3) 冲突（你手工加的日期，MOM 后来也发布了）没有任何记录。
-- =============================================================

-- ---------- 1. 一个「最后改动时间」列，同步和手工都写 ----------
alter table public_holidays add column if not exists updated_at timestamptz not null default now();
comment on column public_holidays.updated_at is
  'Last change to this row from ANY source. synced_at answers a different question: when MOM last confirmed the date. Manual rows have synced_at null but a real updated_at.';

-- 已有行回填：优先用同步时间，没有就用当前时间
update public_holidays set updated_at = coalesce(synced_at, now()) where updated_at is null;

-- ---------- 2. 同步日志记下「冲突」 ----------
alter table holiday_sync_log add column if not exists conflicts jsonb not null default '[]'::jsonb;
comment on column holiday_sync_log.conflicts is
  'Dates that existed as manual entries and also appeared in the official feed. Kept as manual; recorded so the takeover is never silent.';

-- ---------- 3. 重建对账函数（保护手工录入 + 记录冲突 + 写 updated_at） ----------
create or replace function apply_holiday_sync(
  p_holidays jsonb, p_years int[], p_source text default 'data.gov.sg'
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_added   jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_renamed jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;   -- MOM 也发布了、但本来是手工录入的日期
  r record; changed boolean := false;
  add_txt text; rem_txt text; ann_body text;
begin
  -- 仅系统任务可调用：PostgREST 用 service_role key → current_user='service_role'；
  -- 或在 SQL Editor（postgres）里手动测试。普通登录用户/anon 一律拒绝。
  if current_user <> 'service_role' and session_user <> 'postgres' then
    raise exception 'apply_holiday_sync 仅限系统同步任务调用';
  end if;
  if p_years is null or array_length(p_years, 1) is null then
    raise exception 'p_years 不能为空'; end if;

  -- (a) 新增 / 改名：逐条 upsert，落在覆盖年份内的才对账
  for r in
    select (e->>'holiday')::date as d, e->>'name' as nm
    from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
    where extract(year from (e->>'holiday')::date)::int = any(p_years)
  loop
    if not exists (select 1 from public_holidays where holiday = r.d) then
      v_added := v_added || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    else
      -- 手工录入的日期被 MOM 也收录了：记下来并告知 HR，不再是「静默接管」
      if (select source from public_holidays where holiday = r.d) = 'manual' then
        v_conflicts := v_conflicts || jsonb_build_object('holiday', r.d, 'name', r.nm);
        changed := true;
      end if;
    end if;
    if exists (select 1 from public_holidays where holiday = r.d)
       and (select name from public_holidays where holiday = r.d) is distinct from r.nm then
      v_renamed := v_renamed || jsonb_build_object('holiday', r.d, 'name', r.nm);
      changed := true;
    end if;
    -- 冲突处理：**绝不接管手工录入的行**。
    -- 原写法 set source = excluded.source 会把 HR 手工加的日期悄悄改成自动来源，
    -- 于是 (a) 名称被 MOM 覆盖，(b) 该行从此可被下一次同步删除 —— 保护凭空消失，
    -- 而且名称若刚好相同，连公告都不会发。
    insert into public_holidays (holiday, name, source, synced_at, updated_at)
    values (r.d, r.nm, p_source, now(), now())
    on conflict (holiday) do update
      set name      = excluded.name,
          synced_at = now(),
          updated_at = now(),
          source    = case when public_holidays.source = 'manual' then 'manual'
                           else excluded.source end;
  end loop;

  -- (b) 删除：覆盖年份内、由本来源自动同步过、但这批数据里已不存在的日期
  --     （只删 source=p_source 的行；手工录入的临时假日不会被误删）
  for r in
    select ph.holiday as d, ph.name as nm from public_holidays ph
    where extract(year from ph.holiday)::int = any(p_years)
      and ph.source = p_source
      and not exists (select 1 from jsonb_array_elements(coalesce(p_holidays, '[]'::jsonb)) e
                      where (e->>'holiday')::date = ph.holiday)
  loop
    v_removed := v_removed || jsonb_build_object('holiday', r.d, 'name', r.nm);
    delete from public_holidays where holiday = r.d;
    changed := true;
  end loop;

  insert into holiday_sync_log (source, years, added, removed, renamed, conflicts, total_seen, status)
  values (p_source, p_years, v_added, v_removed, v_renamed, v_conflicts,
          jsonb_array_length(coalesce(p_holidays, '[]'::jsonb)), 'ok');

  -- (c) 有变更 → 发全员站内公告
  if changed then
    add_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_added || v_renamed) e);
    rem_txt := (select string_agg(to_char((e->>'holiday')::date, 'YYYY-MM-DD (Dy)') || '  ' || (e->>'name'), E'\n')
                from jsonb_array_elements(v_removed) e);
    ann_body := 'The public-holiday calendar was updated from the official MOM source (data.gov.sg). 系统已按 MOM 官方数据更新公共假期。';
    if add_txt is not null then ann_body := ann_body || E'\n\n➕ Added / updated 新增或更新:\n' || add_txt; end if;
    if rem_txt is not null then ann_body := ann_body || E'\n\n➖ Removed 移除:\n' || rem_txt; end if;
    -- 全员通知（informational）
    insert into announcements (kind, title, body, audience)
    values ('holiday', '📅 Public holidays updated 公共假期已更新', ann_body, 'all');
    -- 额外给 HR / admin 一条可操作提醒：可在 HR 控制台复核 / 增删改
    insert into announcements (kind, title, body, audience)
    values ('holiday', '🛠️ HR: public holidays changed — please review 公共假期已变更（请复核）',
            'The automatic sync updated the public-holiday calendar. Review or adjust it in HR Console → Company settings — you can add, edit or remove any date.'
            || case when jsonb_array_length(v_conflicts) > 0 then
                 E'\n\n📌 ' || jsonb_array_length(v_conflicts) ||
                 ' date(s) you added by hand also appear in MOM''s list. They have been KEPT AS YOURS — the sync will never rename or delete them.'
               else '' end
            || E'\n\n' || ann_body, 'hr');
  end if;

  return jsonb_build_object('changed', changed, 'added', v_added, 'removed', v_removed, 'renamed', v_renamed, 'conflicts', v_conflicts);
end $$;
revoke execute on function apply_holiday_sync(jsonb, int[], text) from anon, public, authenticated;
grant  execute on function apply_holiday_sync(jsonb, int[], text) to service_role;

-- ---------- 验证 ----------
select 'columns' as check,
  (select count(*) from information_schema.columns
    where table_name='public_holidays' and column_name='updated_at')  as ph_updated_at,
  (select count(*) from information_schema.columns
    where table_name='holiday_sync_log' and column_name='conflicts')  as log_conflicts;
select 'no null updated_at' as check, count(*) as should_be_zero
  from public_holidays where updated_at is null;


-- ===========================================================================
-- migration_app_v14.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk SG — migration v14：年假上限 + 「按月累计 / 一次发放」
--
-- 与 v12 / v13 互不依赖，先后顺序随意。幂等，可重复执行。
--
-- 1) 年假上限（每家公司自己设）
--    现状：`annual_base + (年份 - 入职年 - 1)` **没有任何封顶**，
--    工龄 20 年、基数 14 的人会拿到 33 天，而且是一年一天悄悄涨上去的。
--    （org_settings.prorate_cap 只管新人**第一年**的折算，管不到这里。）
--    默认 NULL = 不封顶 —— 迁移当天不会有任何人的额度被改动。
--
-- 2) 年假发放方式：一次发放（annual）或按月累计（monthly）
--    按月累计做成**12 笔小额账本流水**，而不是「实时算出来的数字」。
--    本系统的根本不变量是「余额 = 所有流水之和」；如果改成实时计算，
--    所有读取路径都得跟着改，且这条不变量就没了。
-- =============================================================

-- ---------- 0. 前置：确保 prorate_cap 存在 ----------
-- 下面重写的 annual_entitlement_for 会引用 org_settings.prorate_cap（首年折算封顶）。
-- 这一列是 v9 加的；如果那次迁移没跑过，这里会报
--   ERROR: 42703: column "prorate_cap" does not exist
-- 所以在这里补加一次。NULL = 不封顶 = 与原来完全一致，不会改动任何人的额度。
alter table org_settings add column if not exists prorate_cap numeric(5,1);
comment on column org_settings.prorate_cap is
  'Cap on a NEW JOINER''s first-year pro-rated annual leave. NULL = no cap. Different from annual_cap, which caps long-service increments.';

alter table org_settings add column if not exists annual_cap numeric(5,1);
comment on column org_settings.annual_cap is
  'Maximum annual leave after long-service increments. NULL = no maximum (previous behaviour). Does not affect a new joiner first-year pro-rate, which uses prorate_cap.';

alter table org_settings add column if not exists accrual_mode text not null default 'annual';
do $$ begin
  alter table org_settings add constraint org_settings_accrual_mode_ck
    check (accrual_mode in ('annual','monthly'));
exception when duplicate_object then null; end $$;
comment on column org_settings.accrual_mode is
  'annual = whole entitlement credited once (1 Jan). monthly = credited in 12 instalments as it is earned; employees can then go negative if they take more than accrued so far.';

-- ---------- 1. 上限只加在「工龄递增」那一支 ----------
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select case
    when extract(year from e.join_date) >= p_year
      then least(
             ceil(e.annual_base * (12 - extract(month from e.join_date) + 1) / 12 * 2) / 2,
             coalesce((select prorate_cap from org_settings where id = 1), 1e9))
    else least(
           e.annual_base + greatest(0, p_year - extract(year from e.join_date) - 1),
           coalesce((select annual_cap from org_settings where id = 1), 1e9))
  end
  from employees e where e.id = p_emp;
$$;

-- ---------- 2. 按月累计 ----------
-- 每月发放 = 「到本月为止应得的累计额」减「今年已经发过的」。
-- 用累计差额而不是每月 annual/12，四舍五入就不会越滚越偏，12 月正好落在全年额度上。
create or replace function accrue_monthly_leave(p_year int, p_month int)
returns int language plpgsql security definer set search_path = public as $$
declare
  n int := 0; r record;
  v_full numeric; v_target numeric; v_already numeric; v_add numeric;
  v_start_month int;
begin
  if not is_hr() and session_user <> 'postgres' and current_user <> 'service_role' then
    raise exception 'Only HR or the scheduled job can accrue monthly leave'; end if;
  if coalesce((select accrual_mode from org_settings where id = 1), 'annual') <> 'monthly' then
    return 0;   -- 一次发放模式下什么都不做，避免两种方式同时记账
  end if;
  if p_month < 1 or p_month > 12 then raise exception 'Month must be 1-12'; end if;

  for r in select e.id as emp_id, e.join_date from employees e where e.active loop
    v_full := annual_entitlement_for(r.emp_id, p_year);
    if v_full is null or v_full <= 0 then continue; end if;

    -- 年中入职的人从入职当月开始累计
    v_start_month := case when extract(year from r.join_date)::int = p_year
                          then extract(month from r.join_date)::int else 1 end;
    if p_month < v_start_month then continue; end if;

    v_target := round(v_full * (p_month - v_start_month + 1)
                      / (12 - v_start_month + 1), 2);

    select coalesce(sum(delta_days), 0) into v_already
      from leave_ledger
      where emp_id = r.emp_id and leave_type = 'annual'
        and reason like p_year || ' monthly accrual%';

    v_add := v_target - v_already;
    if v_add > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.emp_id, 'annual', v_add,
              p_year || ' monthly accrual — month ' || p_month, current_emp_id());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function accrue_monthly_leave(int, int) from anon, public;
grant  execute on function accrue_monthly_leave(int, int) to authenticated, service_role;

-- ---------- 3. 一次发放的函数在 monthly 模式下必须让路 ----------
-- 否则切换模式的当年会被记两次账。
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
  if coalesce((select accrual_mode from org_settings where id = 1), 'annual') = 'monthly' then
    raise exception 'This company credits annual leave monthly. Use accrue_monthly_leave(), or switch the mode in Company settings first.';
  end if;
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

-- ---------- 验证 ----------
select 'columns' as check,
  (select count(*) from information_schema.columns where table_name='org_settings' and column_name='annual_cap')   as cap,
  (select count(*) from information_schema.columns where table_name='org_settings' and column_name='accrual_mode') as mode;
select 'current settings' as check, annual_cap, accrual_mode from org_settings where id = 1;


-- ===========================================================================
-- migration_app_v15.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v16.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk SG — migration v16
--   年假结转（每人上限 + 可设到期）／其余假别每年重置／年初一键执行 + 永久记录
--
-- 【为什么要有这个】（2026-08-27 用户发现）
--   余额 = 该员工账本 **全部** 条目之和，没有任何年度边界（leave_balances）。
--   grant_annual_entitlements 每年再发一次配额，**但从来没有东西把上一年的清掉**。
--   于是 2027 年一个 2026 只请了 2 天病假的人会显示 26 天，而不是 14 天。
--   这不是谁设计的功能，而是「缺了一步」——缺的那一步就是本迁移的第 4 节。
--
--   用户要的是：病假之类每年重置回 HR 设定的天数；只有年假结转、补休不动。
--
-- 【本迁移做了什么】
--   1. 每人各自的结转上限 employees.carry_cap（旧的全公司 leave_types.carry_over_cap
--      会被回填进来，上线当天数字不变）+ org_settings.default_carry_cap（只用于
--      「新员工默认值」，和 default_annual_base 语义一致，不影响已有员工）。
--   2. 结转到期日 annual_carry.expires_on（真实日期，取代写死的 12-31），
--      公司级 org_settings.carry_expiry_months（NULL = 永不过期）。
--   3. 到期自动生效：leave_balances **立刻**扣掉「已过期但还没写账」的结转天数，
--      所以 submit_application 的余额校验天然正确，不必改那个函数；
--      expire_due_carry() 再把它落成账本条目（keepalive 每天调一次）。
--      两者不会重复扣：写账时 expired_at 落地，视图那一半立刻归零。
--   4. leave_types.resets_yearly（年假、补休为 false，其余全 true）+
--      年初把这些假别清零，再由 grant_annual_entitlements 按 HR 设定的
--      default_days 重新发放 —— 天数一律读设置，不硬编码。
--   5. run_year_start(year, preview) 一个函数同时负责「预览」和「执行」：
--      同一段算术，preview 只是不写。预览和实际结果不可能对不上。
--   6. year_start_log：每人每年一行的永久记录（去年请了多少、剩多少、上限多少、
--      结转多少、超额作废多少、过期多少、各假别清了多少、谁在什么时候按的）。
--
-- 依赖 v11 及以前全部迁移。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

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


-- ===========================================================================
-- migration_app_v18.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk SG — migration v18
--   年假=直接填写的总额／假别天数改动=按差额补发／HR 代申请／人工改动记录
--
-- 【为什么】（2026-08-27 用户实测）
--   1. 「Leave types」页改了 Days per year，**对已在职的人毫无作用** —— 只影响下一次
--      年度发放。那个页面看起来是控制项，实际是一张便条。用户原话：
--      「what is the purpose of this page. how can i change the number of days for
--        each leave and update them?」——这是本次最核心的缺陷。
--   2. 年假额度 = annual_base + 工龄年数，界面上写着 14、实际拿 20，没有任何一处解释。
--   3. 「Balance adjustments」应该是「HR 代员工请假」，不是加减数字。
--
-- 【本迁移】
--   1. annual_entitlement_for → 就是 annual_base（受公司上限约束）。
--      **取消工龄递增，取消新人首年按月折算** —— 新人多少天由 HR 自己算了填进去。
--   2. set_annual_entitlement()：改额度立刻按差额调整**当年**余额，并写一条人工记录。
--   3. amend_leave_type_days()：把 60→62 的**差额 +2 补发给每一位适用员工**，
--      已经休掉的天数不受影响，**不是**把所有人重设成 62。全公司只写一条记录。
--   4. submit_application 增加 p_for_emp：HR 代申请，即时批准，事件里写明是 HR 代的。
--      **复用同一个函数**，工作日/余额/重叠规则全系统仍只有一处。
--   5. hr_amendments：所有人工改动的记录（额度调整、OIL 补发、全公司假别改动）。
--   6. 年初清零的措辞改成 expired（用户要的字）。
--
-- 依赖 v16。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 0. 前置迁移可能没跑过（HANDOVER 第一条教训） ----------
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table org_settings add column if not exists accrual_mode text not null default 'annual';
alter table employees    add column if not exists carry_cap    numeric(5,1);

-- ---------- 1. 年假额度 = 填进去的数字 ----------
-- 工龄递增（annual_base + 工龄）和新人首年折算都去掉了。公司上限仍然生效：
-- 它现在约束的是「你填的那个数字」，而不是一段看不见的算式。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select least(e.annual_base,
               coalesce((select annual_cap from org_settings where id = 1), 1e9))
  from employees e where e.id = p_emp;
$$;

-- ---------- 1b. 给人看的天数写法 ----------
-- numeric(5,1) 直接拼进字符串会写出 "14.0 → 16.0"、"+2.0 days"。人不这么写数字。
create or replace function fmt_days(v numeric) returns text language sql immutable as $$
  select case when v is null then '' else trim_scale(v)::text end;
$$;

-- ---------- 2. 人工改动记录 ----------
-- 和请假记录**分开**的第二本账：所有 HR 手动改过的东西都在这里。
-- emp_id 为 NULL = 全公司范围的改动（例如把住院假从 60 改成 62），
-- 按用户要求只写一条，不逐个员工列名字。
create table if not exists hr_amendments (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  by_emp      uuid references employees (id),
  by_name     text not null default '',     -- 姓名存副本：人被删掉后记录仍看得懂
  emp_id      uuid references employees (id),
  emp_name    text,                          -- NULL = 全公司
  leave_type  text references leave_types (code),
  kind        text not null,                 -- entitlement | oil_credit | type_days | correction
  before_days numeric(6,1),
  after_days  numeric(6,1),
  delta_days  numeric(6,1),
  affected    int,                           -- 全公司改动影响到几个人
  reason      text not null default ''
);
comment on table hr_amendments is
  'Second record book: every manual change HR makes to a balance. Leave applications live in `applications`; this is everything else.';
alter table hr_amendments enable row level security;
drop policy if exists hramd_read on hr_amendments;
create policy hramd_read on hr_amendments for select to authenticated using (is_hr());

create or replace function log_amendment(
  p_emp uuid, p_emp_name text, p_type text, p_kind text,
  p_before numeric, p_after numeric, p_delta numeric, p_affected int, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare who uuid := current_emp_id();
begin
  insert into hr_amendments (by_emp, by_name, emp_id, emp_name, leave_type, kind,
                             before_days, after_days, delta_days, affected, reason)
  values (who, coalesce((select name from employees where id = who), 'System'),
          p_emp, p_emp_name, p_type, p_kind, p_before, p_after, p_delta, p_affected,
          coalesce(p_reason, ''));
end $$;

-- ---------- 3. 改额度 → 立刻调整当年余额 ----------
-- 以前改了只影响「下一次发放」，当年余额纹丝不动 —— 界面上还写着一行字叫你去用
-- Balance adjustments。现在改了就是改了，差额当场入账，全站同步。
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; diff numeric; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', cap;
  end if;
  if p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  before_days := e.annual_base;
  if p_days = before_days then return 0; end if;

  update employees set annual_base = p_days where id = p_emp;

  -- 只有本年度已经发过额度的人才需要补差额；没发过的，下次发放自然就是新数字。
  if exists (select 1 from leave_ledger where emp_id = p_emp and leave_type = 'annual'
             and reason in (y || ' 年度配额', y || ' annual allowance')) then
    diff := p_days - before_days;
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
    values (p_emp, 'annual', diff,
            y || ' entitlement changed ' || fmt_days(before_days) || ' → ' || fmt_days(p_days), current_emp_id());
  else
    diff := 0;
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, diff, 1, '');
  return diff;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 4. 改假别天数 → 按差额补发给所有人 ----------
-- 用户原话：「if previously i set as 60days for Hospitalization leave, then i change to
-- 62 and click save changes it should credit 2 days to all employee ... who already taken
-- the leave will not be affected do not reset the whole thing to 62」。
-- 所以是**差额**，不是重设。已休掉的天数完全不受影响。
create or replace function amend_leave_type_days(p_code text, p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t leave_types%rowtype; diff numeric; n int := 0; r record; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change a leave type'; end if;
  select * into t from leave_types where code = p_code;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if p_days < 0 then raise exception 'Days per year cannot be negative'; end if;
  diff := p_days - t.default_days;

  -- 年假：额度是**每人一个数字**（Edit employee 里填），全公司统一补发会和它打架。
  -- 补休：是加班换来的，没有「每年多少天」这回事。两者都不参与差额补发。
  -- no_deduct 的类型（无薪假、NS 等）根本没有余额，补发也没有意义。
  -- 年假：每人一个数字（Edit employee 里填）。补休：加班换来的，没有「每年多少天」。
  -- 这两个连 default_days 都不该存 —— 之前只是不补发、却照样把数字写下去，
  -- 结果年度发放看到 oil.default_days = 3 就发给了所有人（测试里 OIL 从 1.5 变 4.5）。
  -- 所以直接拒绝，而不是默默存一个没有意义、还会被别处读到的数字。
  if p_code = 'annual' then
    raise exception 'Annual leave is set per employee, in Edit employee — not here';
  end if;
  if p_code = 'oil' then
    raise exception 'Off-in-lieu is earned, not granted — credit it per employee in Edit employee';
  end if;
  if t.no_deduct or diff = 0 then
    if not p_preview then
      update leave_types set default_days = p_days where code = p_code;
    end if;
    return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
      'after', p_days, 'delta', diff, 'affected', 0, 'credited', false);
  end if;

  for r in select e.id from employees e
           where e.active
             and (t.gender_eligibility is null or t.gender_eligibility = e.gender) loop
    n := n + 1;
    if not p_preview then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
      values (r.id, p_code, diff,
              y || ' ' || t.name_en || ' amended ' || fmt_days(t.default_days) || ' → ' || fmt_days(p_days),
              current_emp_id());
    end if;
  end loop;

  if not p_preview then
    update leave_types set default_days = p_days where code = p_code;
    -- 全公司一条记录，不逐个列名字（用户明确要求）。
    perform log_amendment(null, null, p_code, 'type_days', t.default_days, p_days, diff, n,
      'Company leave amendment — ' || t.name_en || ' ' ||
      case when diff > 0 then '+' else '' end || fmt_days(diff) || ' days');
  end if;
  return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
    'after', p_days, 'delta', diff, 'affected', n, 'credited', true);
end $$;
revoke execute on function amend_leave_type_days(text, numeric, boolean) from anon, public;
grant  execute on function amend_leave_type_days(text, numeric, boolean) to authenticated;

-- ---------- 5. OIL 补发（Edit employee 里的按钮） ----------
create or replace function credit_oil(p_emp uuid, p_days numeric, p_reason text)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit off-in-lieu'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
  values (p_emp, 'oil', p_days, 'Off-in-lieu: ' || btrim(p_reason), current_emp_id());
  perform log_amendment(p_emp, e.name, 'oil', 'oil_credit', null, null, p_days, 1, btrim(p_reason));
  return p_days;
end $$;
revoke execute on function credit_oil(uuid, numeric, text) from anon, public;
grant  execute on function credit_oil(uuid, numeric, text) to authenticated;

-- ---------- 6. HR 代员工请假：同一个函数，多一个参数 ----------
create or replace function submit_application(
  p_type text, p_start date, p_end date, p_reason text,
  p_attachment text default null, p_resubmit_id uuid default null,
  p_half_days jsonb default '[]'::jsonb, p_sh boolean default false, p_eh boolean default false,
  p_for_emp uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
        hd jsonb := coalesce(p_half_days, '[]'::jsonb);
        actor uuid; on_behalf boolean := p_for_emp is not null;
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
  return app_id;
end $$;

-- ---------- 7. 年初清零的措辞：expired ----------
-- 用户的原话：「just remove how much leave remained label as expired and add back the
-- default date set by user」。机制不变（v16 已经对了），只是把措辞改成他要的字。
create or replace function reset_statutory_leave(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare r record; t record; b numeric; n int := 0;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can reset the yearly leave balances'; end if;
  for r in select id from employees where active loop
    for t in select code, name_en from leave_types where resets_yearly and not no_deduct order by sort loop
      select coalesce(balance, 0) into b from leave_balances where emp_id = r.id and leave_type = t.code;
      if coalesce(b, 0) <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, t.code, -b, (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id());
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke execute on function reset_statutory_leave(int) from anon, public;
grant  execute on function reset_statutory_leave(int) to authenticated;

-- run_year_start 里的清零措辞也要跟着改 —— 它自己内联了那段循环，不是调用上面的函数。
-- 两处写同一句话本来就是隐患，这里至少让它们一次改齐。
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
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 8. 年度发放永远不碰补休 ----------
-- 上面已经拦住了「把 oil 的 default_days 改成非 0」这条路，但这个函数是账目的最后一关：
-- 就算数据库里靠别的途径塞进去一个数字，补休也不该被年度发放批量补给所有人。
-- 两道防线，因为这一条错了是**给所有人凭空多发假**，不会有任何人报错。
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
  for r in
    select e.id as emp_id, t.code, t.default_days
    from employees e cross join leave_types t
    where e.active and t.code <> 'oil' and (t.default_days > 0 or t.code = 'annual')
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


-- ===========================================================================
-- migration_app_v19.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk migration v19 —— 年假额度：填进去的数字**就是**当年的总额度
--
-- 这一版修的是 v18 留下的一个真问题：
--   set_annual_entitlement 只在找到 reason 恰好等于 '2026 annual allowance'
--   的那一行时才补差额。可是**从系统里「Add employee」加进来的人**，那一行的
--   reason 是 'Pro-rated leave allowance (joined ...)' —— 对不上，于是什么都不写。
--   屏幕上却写着「This year's balance moves from 19 to 20, and it is recorded」。
--   承诺了一件数据库根本没做的事，这是最坏的一类错。
--
-- 用户的决定（原话：「the system should total should change to 15 days」）：
--   **填 15，当年的年假额度就正好是 15**，而不是「在现有基础上加 1」。
--   剩余 = 15 + 上年结转 − 已休。于是：
--     · 不再靠 reason 字符串猜，谁都适用；
--     · 之前重复发放撑出来的 972 / 19 这类数字，保存一次额度就自动纠正回来。
--
-- 本版内容：
--   1. annual_entitled_in_year()：当年「算作额度」的天数。请假扣减和销假返还
--      都带 ref_application，直接排除；年末失效/超上限作废按文字排除。
--   2. set_annual_entitlement()：对账到填进去的数字（不是加差额）。
--   3. bump_annual_all()：一键给全公司每人加 N 天年假 —— 额度**永久**加 N，
--      当年余额同时补 N。超过公司上限的人跳过并列出名字。
--
-- 依赖 v18。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 0. 前置迁移可能没跑过（HANDOVER 第一条教训） ----------
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table employees    add column if not exists carry_cap    numeric(5,1);

-- ---------- 1. 当年「算作额度」的天数 ----------
-- 什么算额度：年度发放、入职发放、历次额度调整、按月累积。
-- 什么不算：
--   · 请假扣减、销假返还 —— 这两种都写了 ref_application，一并排除，
--     这比按文字匹配可靠（返还是**正数**，不排除就会被当成额度）。
--   · 年末清零、结转到期、超出结转上限作废、离职结算 —— 是账务，不是额度。
create or replace function annual_entitled_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(delta_days), 0)
    from leave_ledger
   where emp_id = p_emp
     and leave_type = 'annual'
     and extract(year from created_at)::int = p_year
     and ref_application is null
     and reason not like '%expired (unused)%'
     and reason not like '%above the carry-over cap%'
     and reason not like '%reset — use it or lose it%'
     and reason not like '%excess forfeited%'
     and reason not like '%expired carry-over%'
     and reason not like 'Offboarding%'
     and reason not like '%结转%'
     and reason not like '%作废%';
$$;
comment on function annual_entitled_in_year(uuid, int) is
  'Days credited as ENTITLEMENT this year — grants, joining credits and entitlement changes. Leave taken and refunds carry ref_application and are excluded; year-end write-offs are excluded by wording.';
revoke execute on function annual_entitled_in_year(uuid, int) from anon;
grant  execute on function annual_entitled_in_year(uuid, int) to authenticated;

-- ---------- 2. 设定年假额度：对账到这个数字 ----------
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; ent numeric; adj numeric;
        y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if p_days is null or p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', fmt_days(cap);
  end if;

  before_days := e.annual_base;
  update employees set annual_base = p_days where id = p_emp;

  -- 今年还一天额度都没发过的人：不补。等年初发放时自然就是新数字。
  -- （v18 是拿 reason 字符串去认那一行，认不出来就整个跳过 —— 这就是「系统里加进来的人
  --   改了额度却什么都没发生」的原因。现在按**总额**判断，与措辞无关。）
  if not exists (select 1 from leave_ledger
                  where emp_id = p_emp and leave_type = 'annual'
                    and extract(year from created_at)::int = y
                    and ref_application is null) then
    perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, 0, 1, '');
    return 0;
  end if;

  ent := annual_entitled_in_year(p_emp, y);
  adj := p_days - ent;                      -- 对账：把当年额度**补成**填进去的数字
  if adj <> 0 then
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
    values (p_emp, 'annual', adj,
            y || ' annual entitlement set to ' || fmt_days(p_days), current_emp_id());
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, adj, 1, '');
  return adj;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 3. 一键给全公司加年假 ----------
-- 用户原话：「one click then it will credit whole company with one day of annual leave」，
-- 并选了「永久」：每人的 Annual Leave Entitled / Yr 加 N（明年自动就是新数字），
-- 当年余额同时补 N。会超过公司上限的人**跳过并列名**，不静默截断 ——
-- 「max AL is link, it cannot goes over the max AL i set」。
create or replace function bump_annual_all(p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cap numeric; r record; n int := 0; credited int := 0;
        skipped text[] := '{}'; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit annual leave'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  cap := (select annual_cap from org_settings where id = 1);

  for r in select id, name, annual_base from employees where active order by name loop
    if cap is not null and r.annual_base + p_days > cap then
      skipped := skipped || r.name;
      continue;
    end if;
    if r.annual_base + p_days < 0 then
      skipped := skipped || r.name;
      continue;
    end if;
    n := n + 1;
    -- 只给今年已经发过额度的人补当年余额；没发过的，改额度就够了。
    if exists (select 1 from leave_ledger
                where emp_id = r.id and leave_type = 'annual'
                  and extract(year from created_at)::int = y
                  and ref_application is null) then
      credited := credited + 1;
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by)
        values (r.id, 'annual', p_days,
                y || ' annual leave ' || case when p_days > 0 then '+' else '' end ||
                fmt_days(p_days) || ' — company-wide', current_emp_id());
      end if;
    end if;
    if not p_preview then
      update employees set annual_base = annual_base + p_days where id = r.id;
    end if;
  end loop;

  -- n = 0 表示一个人都没加成（例如全部卡在公司上限）。这种情况**不写记录**：
  -- 否则修订记录里会留下一条「+1 day to every employee」，而实际上谁都没拿到。
  if not p_preview and n > 0 then
    -- 全公司一条记录，不逐个列名字（用户明确要求）。
    perform log_amendment(null, null, 'annual', 'annual_bump', null, null, p_days, n,
      'Company annual leave amendment — ' || case when p_days > 0 then '+' else '' end ||
      fmt_days(p_days) || ' day' || case when abs(p_days) = 1 then '' else 's' end ||
      ' to every employee');
  end if;
  return jsonb_build_object('days', p_days, 'affected', n, 'credited', credited,
                            'skipped', to_jsonb(skipped));
end $$;
revoke execute on function bump_annual_all(numeric, boolean) from anon, public;
grant  execute on function bump_annual_all(numeric, boolean) to authenticated;

-- ---------- 4. 自检 ----------
do $$
begin
  raise notice 'v19 installed: % / % / %',
    (select count(*) from pg_proc where proname = 'annual_entitled_in_year'),
    (select count(*) from pg_proc where proname = 'set_annual_entitlement'),
    (select count(*) from pg_proc where proname = 'bump_annual_all');
end $$;


-- ===========================================================================
-- migration_app_v24.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk migration v24 —— 结转到期「日期」取代「月数」
--
-- 起因：Company settings 里那一栏是 "Carry Forward AL expire after (months)"，
-- 填 6，系统自己算出 6 月 30 日。用户要的是**直接选日期**：设 12 月 31 日，
-- 到那天还没用掉的结转年假就作废清账。
--
-- 关键事实（决定了这个改动很小）：annual_carry.expires_on **本来就是 date**。
-- 下游全部读它 —— 余额视图扣掉 due_unwritten_carry、expire_due_carry 落账、
-- 员工看到的 "use them by"。月数只在 run_year_start 里用过**一次**，
-- 就是为了算出这个日期。所以这里换掉的是那次计算的输入，不是任何下游逻辑。
--
--   1. org_settings.carry_expiry_month / carry_expiry_day：**每年重复**的日月。
--      设一次 12-31，2027 结转的到 2027-12-31 过期，2028 的到 2028-12-31，永远。
--      两列同时为 NULL = 永不过期（等于旧的「留空」）。
--   2. 回填自 carry_expiry_months，**上线当天任何日期都不变**：12 → 12-31，
--      6 → 06-30，NULL → NULL。carry_expiry_months **保留不动** ——
--      前端的 db.orgV16 是靠它探测的，删掉会让没迁移的库瞎掉。
--   3. carry_expiry_for(year)：唯一一处算日期的地方，run_year_start 和
--      set_carry_expiry 都调它，两边不可能算出不同的日子。
--      2 月 29 日在平年自动收到 2 月 28 日 —— 设置永远不会产生非法日期。
--   4. set_carry_expiry(month, day, preview)：**一个函数同时负责预览和执行**，
--      v16 的 run_year_start 立的规矩。同一段算术，preview 只是不写，
--      所以确认框上的人数和真正被改的行数不可能对不上。
--      执行时：改设置 → 重盖当年 annual_carry.expires_on → 调 expire_due_carry()
--      把已经过期的立刻清账（用户原话「and clear off in system」）。
--
-- 依赖 v16（annual_carry.expires_on、expire_due_carry、annual_used_between）。
-- 幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

-- ---------- 1. 字段 ----------
alter table org_settings add column if not exists carry_expiry_month int;
alter table org_settings add column if not exists carry_expiry_day   int;

comment on column org_settings.carry_expiry_month is
  'Month (1-12) that carried annual leave expires on, repeating every year. NULL (with carry_expiry_day) = never expires.';
comment on column org_settings.carry_expiry_day is
  'Day of carry_expiry_month. 29 February is clamped to 28 February in a non-leap year.';

-- ---------- 2. 回填：上线当天任何日期都不许变 ----------
-- 旧算法是 make_date(Y,1,1) + N 个月 - 1 天。用闰年 2000 反推日月，
-- N=2（2 月底）会得到 02-29，再由下面的收敛规则在平年收到 02-28 ——
-- 和旧算法逐年的结果完全一致。
update org_settings
   set carry_expiry_month = extract(month from d)::int,
       carry_expiry_day   = extract(day   from d)::int
  from (select ((make_date(2000, 1, 1) + (carry_expiry_months || ' months')::interval)::date - 1) as d
          from org_settings where id = 1 and carry_expiry_months is not null) s(d)
 where org_settings.id = 1
   and org_settings.carry_expiry_month is null
   and org_settings.carry_expiry_day is null;

-- ---------- 3. 唯一一处算日期的地方 ----------
create or replace function carry_expiry_for(p_year int)
returns date language sql stable set search_path = public as $$
  select case
           when o.carry_expiry_month is null or o.carry_expiry_day is null then null
           else make_date(p_year, o.carry_expiry_month,
                  least(o.carry_expiry_day,
                        extract(day from (make_date(p_year, o.carry_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
grant execute on function carry_expiry_for(int) to authenticated;

-- ---------- 4. 改日期：预览 + 执行是同一个函数 ----------
-- 往前挪日期会**立刻作废别人手上正拿着的天数**，所以这里必须先能算出
-- 「几个人、几天会当场没」，让界面在写任何东西之前把话说清楚。
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
     where ac.year = v_year and ac.expired_at is null
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

-- ---------- 5. run_year_start 改读日期 ----------
-- 整个函数只有 v_expires 这一处变了，其余逐字保持 v18 的样子。
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
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

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
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;


-- ===========================================================================
-- migration_app_v25.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk migration v25 —— carry_expiry_for 改为 security definer
--
-- 起因：v24 上线后从外部探测 carry_expiry_for(2027)，返回的是 null 而不是日期。
-- 查下来那是探测本身的局限 —— org_settings 上有 RLS
-- （org_read … to authenticated using (is_staff())），匿名调用读不到任何行。
-- 真正的两个调用方 run_year_start / set_carry_expiry 都是 security definer，
-- 函数内部 current_user 是属主，属主绕过 RLS，所以线上一切正常，没有坏掉。
--
-- **但这里藏着一个不会报错的陷阱。**
-- carry_expiry_for 是 language sql stable —— security **invoker**。
-- 它读不到 org_settings 时不会失败，而是返回 null；
-- 而 null 在这套系统里的含义是「结转年假永不过期」。
-- 一个「失败时会静默地把过期规则关掉」的函数，正是这个项目反复栽过的那一类：
-- 按符号分类的 bal()、被吃掉的负号、拿存储值去比的 entitlement ——
-- 都是没有任何人报错，屏幕却说得理直气壮。
-- 今天没有这样的调用路径。问题在于没有任何东西拦着以后加一条。
--
-- 改动只有一处：加 security definer + 收回 anon。
-- 它读的是 org_settings 的一行，而这张表本来就对所有在职员工可读，
-- 所以这没有多授予任何权限 —— 只是让这个函数不再依赖「碰巧是谁在调用它」
-- 才能给出正确答案。
--
-- 不动任何列、任何数据、任何日期。幂等，可重复执行。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

create or replace function carry_expiry_for(p_year int)
returns date language sql stable security definer set search_path = public as $$
  select case
           when o.carry_expiry_month is null or o.carry_expiry_day is null then null
           else make_date(p_year, o.carry_expiry_month,
                  least(o.carry_expiry_day,
                        extract(day from (make_date(p_year, o.carry_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
comment on function carry_expiry_for(int) is
  'The date carried annual leave expires in a given year. SECURITY DEFINER on purpose: as an invoker it returned NULL wherever org_settings was unreadable, and NULL here means "never expires" — a silent failure rather than an error.';
revoke execute on function carry_expiry_for(int) from anon, public;
grant  execute on function carry_expiry_for(int) to authenticated;


-- ===========================================================================
-- migration_app_v26.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v27.sql
-- ===========================================================================

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


-- ===========================================================================
-- migration_app_v28.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk migration v28 —— 邮件通知的开关
--
-- 邮件本身在 Edge Function 里（supabase/functions/send-notification）。
-- 数据库这边只需要一样东西：**测试期间只发给谁**。
--
-- 用户原话：「the email sending please only send to user Amanda for testing」。
-- 做成一个设置而不是把名字写死在代码里 —— 他可以随时指向别人，也可以自己关掉，
-- 不用等我改代码。
--
-- 语义：填了人 = 只有**发给这个人**的邮件会真的发出去，公司里其他人一封都收不到。
--       留空 = 正常发给所有相关的人（试完之后就留空）。
--
-- 这一列还兼着「测试邮件寄到哪里」：Edge Function 的测试发送**不接受**外部传入的
-- 收件地址，只会寄给这里指定的员工。所以就算有人拿到公开的 anon key，
-- 也没办法借它往任意邮箱发信。
--
-- 幂等，可重复执行。不影响任何现有功能：邮件从头到尾都不是任何流程的前置条件，
-- 没配置 / 函数没部署 / Resend 挂了，请假和审批照常。
-- 执行：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
-- =============================================================

alter table org_settings add column if not exists notify_only_emp uuid references employees (id);

comment on column org_settings.notify_only_emp is
  'Test mode for notification emails: while this names an employee, only mail addressed to THEM is sent and nobody else in the company receives anything. NULL = notify everyone normally. Also the destination for the Send test email button.';


-- ===========================================================================
-- migration_app_v31.sql
-- ===========================================================================

-- ============================================================================
-- migration_app_v31.sql — 年假不再有任何自动增长；并把 annual_base 对回真实账本
--
-- 用户原话：
--   「remove all automation of crediting one annualleave every year」
--   「first year HR will calculate by themself and will credit them via edit employee」
--   「the balance sheet tab MUST show the REAL value ... then under edit employee the box
--     it should follow the Real values」
--
-- 背景（Barry 的例子，真实数据）：
--   2026-07-09  +17     「2026 年度配额」   ← 旧规则：annual_base(14) + 3 年年资
--   2026-08-28  +3.5     全公司统一加
--   账本合计 20.5，而 employees.annual_base 只有 17.5 —— 差的正是那 3 天年资。
--   Edit employee 显示的是 annual_base，一按 Save 就把真实的 20.5 拉到 14，凭空少 6.5 天。
--
-- 这个脚本做三件事，都不动任何人的天数：
--   1. annual_entitlement_for → 只取 annual_base（年资、首年折算全部去掉）
--   2. 删掉 org_settings.prorate_cap（首年折算的封顶，已无人使用）
--   3. 把 annual_base 修正成本年度**实际发放**的天数，让两个数字从此一致
--
-- 幂等：重复执行没有副作用。第 3 步只改 employees 这一列，**不写任何 leave_ledger**。
-- ============================================================================

-- ---------- 1. 唯一的年假规则：就是那个数字 ----------
-- v18 已经在正式库里这么改了，这里重申一次，好让任何一套旧库执行后也对齐。
-- schema.sql 里那份（年资 + 首年折算）同步删掉了 —— 否则新装一套系统会把规则带回来。
create or replace function annual_entitlement_for(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select least(e.annual_base,
               coalesce((select annual_cap from org_settings where id = 1), 1e9))
  from employees e where e.id = p_emp;
$$;

comment on function annual_entitlement_for(uuid, int) is
  'This year''s annual leave = the employee''s annual_base, capped by org_settings.annual_cap. Nothing is added for length of service and no first-year pro-rate: HR types the figure they want, in Edit employee or on the Leave types tab.';

-- ---------- 2. 首年折算封顶：连列一起删 ----------
-- 留着它，下一个读代码的人会以为首年折算还在。
alter table org_settings drop column if exists prorate_cap;

-- ---------- 3. 把 annual_base 对回真实账本 ----------
-- 只改「今年确实发过年假」的在职员工。没发过的人账本没有意见，保持原样。
-- 不写账本 = 没有人多一天或少一天，只是那一列不再说谎。
do $$
declare y int := extract(year from current_date)::int;
        n int := 0; over_cap text[] := '{}'; r record; cap numeric;
begin
  cap := (select annual_cap from org_settings where id = 1);

  for r in
    select e.id, e.name, e.annual_base as was, annual_entitled_in_year(e.id, y) as truth
      from employees e
     where e.active
       and exists (select 1 from leave_ledger l
                    where l.emp_id = e.id and l.leave_type = 'annual'
                      and extract(year from l.created_at)::int = y
                      and l.ref_application is null)
       and annual_entitled_in_year(e.id, y) <> e.annual_base
  loop
    update employees set annual_base = r.truth where id = r.id;
    n := n + 1;
    raise notice '  % : % → %  (Edit employee now agrees with Balances)',
      r.name, trim_scale(r.was), trim_scale(r.truth);
    if cap is not null and r.truth > cap then
      over_cap := over_cap || (r.name || ' (' || trim_scale(r.truth) || ')');
    end if;
  end loop;

  raise notice 'v31: % employee(s) corrected. No ledger rows were written — nobody gained or lost a day.', n;

  -- 真实发放数高于公司上限的人：不静默截断（那才是真的扣人天数），只报出来。
  if array_length(over_cap, 1) > 0 then
    raise warning 'Above the company maximum of % days: %. Their days are untouched, but Edit employee will refuse to save them at that figure until you raise the maximum.',
      trim_scale(cap), array_to_string(over_cap, ', ');
  end if;
end $$;

-- ---------- 4. 自检 ----------
do $$
declare bad int;
begin
  -- 规则里不该再出现 join_date
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'annual_entitlement_for'
                and pg_get_functiondef(p.oid) like '%join_date%') then
    raise exception 'v31 FAILED: annual_entitlement_for still refers to join_date';
  end if;
  if exists (select 1 from information_schema.columns
              where table_name = 'org_settings' and column_name = 'prorate_cap') then
    raise exception 'v31 FAILED: org_settings.prorate_cap is still there';
  end if;
  select count(*) into bad
    from employees e
   where e.active
     and exists (select 1 from leave_ledger l
                  where l.emp_id = e.id and l.leave_type = 'annual'
                    and extract(year from l.created_at)::int = extract(year from current_date)::int
                    and l.ref_application is null)
     and annual_entitled_in_year(e.id, extract(year from current_date)::int) <> e.annual_base;
  if bad > 0 then raise exception 'v31 FAILED: % employee(s) still disagree with their ledger', bad; end if;
  raise notice 'v31 installed: no automatic yearly day, no first-year pro-rate, every stored figure matches its ledger.';
end $$;


-- ===========================================================================
-- migration_app_v32.sql
-- ===========================================================================

-- ============================================================================
-- migration_app_v32.sql — 邮件通知的地址由**应用自己填**，不再让人手抄一遍
--
-- 用户原话：
--   「if for a new company i should be editing the project thing inside the website
--     instead of supabase, why you still ask me to paste the project refernce???」
--
-- 他说得对。项目地址和 anon key 本来就必须写进 app.html（网站那两行），
-- 再让人往 SQL 里抄一遍，就是同一份东西输两次 —— 而输两次，迟早会不一致。
--
-- 改法：数据库里留两个空格子；HR/Owner 一登录，应用就把自己正在用的地址和 key
-- 写进去（不一样才写）。人一个字都不用抄。
--
-- 触发器在此之前就存在，只是**静默**：地址是空的就直接放行，什么都不做。
-- 请假永远不会因为邮件而失败。
-- ============================================================================

alter table org_settings add column if not exists notify_url text;
alter table org_settings add column if not exists notify_key text;

comment on column org_settings.notify_url is
  'Where leave-notification events are POSTed. Written by the app itself when an HR/Owner signs in — never typed by hand. Empty = notifications off, and nothing fails.';
comment on column org_settings.notify_key is
  'The project anon key, so the Edge Function gateway accepts the call. Public by design.';

-- ---------- 触发器：读格子，不写死 ----------
-- v33 之前是用 execute format() 把地址烤进函数体，所以换项目就得重建函数。
-- 现在函数体是固定的，地址是数据 —— 换项目只要改那一行数据。
create or replace function leavedesk_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text; k text;
begin
  select notify_url, notify_key into u, k from org_settings where id = 1;
  if coalesce(u, '') = '' then
    return new;                      -- 还没接上邮件：静悄悄放行
  end if;
  -- 邮件**绝不能**挡住请假。这里出任何事都吞掉：假条已经记下了，邮件只是礼貌。
  begin
    perform net.http_post(
      url     := u,
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'Authorization', 'Bearer ' || coalesce(k, '')),
      body    := jsonb_build_object('type', 'INSERT', 'table', 'application_events',
                                    'schema', 'public', 'record', to_jsonb(new)),
      timeout_milliseconds := 15000);   -- 面板默认 1000ms，比函数实际耗时还短
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists trg_leavedesk_notify on application_events;
create trigger trg_leavedesk_notify after insert on application_events
  for each row execute function leavedesk_notify();

-- ---------- 应用用来自报地址的入口 ----------
-- 只有 HR/Owner 能调；值相同就什么都不做（避免每次登录都写一次）。
create or replace function set_notify_endpoint(p_url text, p_key text)
returns boolean language plpgsql security definer set search_path = public as $$
declare changed boolean := false;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can change the notification endpoint';
  end if;
  update org_settings
     set notify_url = p_url, notify_key = p_key
   where id = 1
     and (coalesce(notify_url, '') is distinct from coalesce(p_url, '')
       or coalesce(notify_key, '') is distinct from coalesce(p_key, ''));
  changed := found;
  return changed;
end $$;
revoke execute on function set_notify_endpoint(text, text) from anon, public;
grant  execute on function set_notify_endpoint(text, text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_leavedesk_notify') then
    raise exception 'v32 FAILED: the notification trigger was not created';
  end if;
  raise notice 'v32 installed: the app now reports its own address — nothing to copy by hand.';
end $$;


-- ===========================================================================
-- migration_app_v35.sql
-- ===========================================================================

-- ============================================================================
-- migration_app_v35.sql — 每一条账本记录都写明「属于哪一年」
--
-- 用户原话：
--   「let the leave have a tag, for example this leave is 2025 leave, so that the system
--     recognise it and when click new year 2026, it will calculate 2025 remaining leave and
--     carry forward to 2026, then the other leave like SL or HL tagged as 2025 will be reset
--     then credit 2026 leave」
--
-- 为什么以前会出错 —— 系统从来没有记下过「这一行属于哪一年」，它每次都在**猜**：
--   · 按 created_at 的年份猜（一月补录十二月的假 → 算进一月那一年）
--   · 按 reason 的文字猜（'2026 annual allowance' 认得，别的措辞一律认不出）
--
-- 那次 2026 年初操作之所以出事，就是这个猜法：
--   「去年剩多少」= 年假余额 − 措辞正好是 '2026 annual allowance' 的那一行。
--   八月全公司加的那 3.5 天措辞不一样，减不掉，于是被当成「2025 年剩下的」结转到 2026 ——
--   而这套系统里根本没有 2025 年的数据。有人 3.5、有人 0、有人 4，就是这么来的。
--   同一次运行又把其它假别按余额清零，再调 grant_annual_entitlements 补发；
--   而补发那一步看到七月已经有 '2026 年度配额' 就跳过了 —— 清了不发，全部归零。
--
-- 这个迁移把「哪一年」从猜测变成事实：
--   leave_year —— 这一笔属于哪个假期年度
--   kind       —— 这一笔是什么：grant 发放 / carry_in 结转 / taken 请假 /
--                 refund 销假退回 / adjust 调整 / writeoff 年结冲销
-- 于是所有算法都变成一句话，全系统再没有一处按文字判断年份或性质。
--
-- 幂等：重复执行没有副作用。回填**不改任何 delta_days**，没有人多一天或少一天，
-- 迁移末尾会逐人逐假别核对这一点，对不上就整笔回滚。
-- ============================================================================

-- ---------- 0. 前置：这个迁移读到的列，老库里可能没有 ----------
-- HANDOVER 第一条教训：绝不写一个假设前一个迁移跑过的迁移。
alter table employees    add column if not exists carry_cap    numeric(5,1);
alter table org_settings add column if not exists annual_cap   numeric(5,1);
alter table leave_types  add column if not exists resets_yearly boolean not null default true;

-- ---------- 1. 两个字段 ----------
alter table leave_ledger add column if not exists leave_year int;
alter table leave_ledger add column if not exists kind       text;

comment on column leave_ledger.leave_year is
  'The leave year this entry belongs to. For leave taken or refunded it is the year of the LEAVE DATES, not the day it was keyed in — so December leave entered in January still comes out of December''s allowance.';
comment on column leave_ledger.kind is
  'What this entry is: grant (the year''s allowance) · carry_in (days carried from last year) · taken · refund · adjust (a correction) · writeoff (year-end clearing, forfeiture, offboarding). Before v35 this was guessed from the wording, in 23 different places.';

-- ---------- 2. 从一行记录推出它的年份和性质 ----------
-- 这两个函数是**唯一**的推断处，而且只在没有明写的时候才用得上。
-- 新代码一律直接写 leave_year / kind，不经过它们。

create or replace function ledger_kind_of(p_reason text, p_ref uuid, p_delta numeric)
returns text language sql immutable as $$
  select case
    -- 跟某一张申请挂钩的，就是请假或销假退回。这比看文字可靠：退回是**正数**。
    when p_ref is not null and p_delta < 0 then 'taken'
    when p_ref is not null                 then 'refund'
    -- 同样的两句措辞，但没有挂申请：手工补录、旧数据、测试脚本都会这样写。
    -- 认不出来它就会被当成「额度」，于是「把 SL 设成 62」变成给这个人发 67 天。
    when coalesce(p_reason,'') like 'Leave taken%'  then 'taken'
    when coalesce(p_reason,'') like 'Refunded%'     then 'refund'
    -- 结转：措辞由 v35 的 run_year_start 自己写，独一无二，先认它
    when coalesce(p_reason,'') like 'Carried forward from %' then 'carry_in'
    -- 年结家务事。必须排在 grant 前面：'2025 年假…作废' 也是 4 位数字开头的。
    when coalesce(p_reason,'') ~* '(expired \(unused\)|above the carry-over cap|reset — use it or lose it|expired carry-over|excess forfeited|forfeited)' then 'writeoff'
    when coalesce(p_reason,'') like 'Offboarding%' then 'writeoff'
    when coalesce(p_reason,'') like '%结转%' or coalesce(p_reason,'') like '%作废%' then 'writeoff'
    -- 年度发放：措辞是系统写的，中英两种
    when coalesce(p_reason,'') ~ '^[0-9]{4} (annual allowance|年度配额)$' then 'grant'
    -- 入职发放：Add employee 写的是「Leave allowance on joining」。
    -- **这一条就是那一堆错数字的根源。** 它是这个人当年的额度，可是措辞对不上上面那一句，
    -- 于是全系统都不认得它：
    --   · 年初发放看不见它 ⇒ 给这个人**再发一次** ⇒ 病假 27、住院假 117、SPL 140
    --   · 归类成 adjust ⇒ Leave types 里重打一个数字**跳过**这些人，修不到他们
    -- 认成 grant，这三件事同时解决：唯一索引让第二次发放根本发不出来，
    -- 年初发放会跳过他们，Leave types 也终于能把他们对账回去。
    when coalesce(p_reason,'') like '%allowance on joining%' then 'grant'
    else 'adjust'
  end;
$$;
comment on function ledger_kind_of(text, uuid, numeric) is
  'Last-resort classifier for rows written before v35, and for any code path that still inserts without saying what it is. New code sets kind directly.';

create or replace function ledger_year_of(p_reason text, p_ref uuid, p_created timestamptz)
returns int language plpgsql stable security definer set search_path = public as $$
declare y int;
begin
  -- 1) 请假／销假：以**假期日期**的年份为准
  if p_ref is not null then
    select extract(year from a.start_date)::int into y from applications a where a.id = p_ref;
    if y is not null then return y; end if;
  end if;
  -- 2) 措辞以 4 位年份开头 —— 全系统的发放、清零、调整都是这个格式
  y := nullif(substring(coalesce(p_reason, '') from '^([0-9]{4})'), '')::int;
  if y between 2000 and 2100 then return y; end if;
  -- 3) 都不是：按写进来的那一天算
  return extract(year from coalesce(p_created, now()))::int;
end $$;

-- ---------- 3. 触发器：任何一条新记录都带着标签落地 ----------
-- 全系统有几十处 insert into leave_ledger。**不逐一改**：漏掉一处就又多一条
-- 没有年份的记录，而且要到明年一月才会发作。写在数据真正落地的地方，一条都跑不掉。
create or replace function tag_leave_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind is null then
    new.kind := ledger_kind_of(new.reason, new.ref_application, new.delta_days);
  end if;
  if new.leave_year is null then
    new.leave_year := ledger_year_of(new.reason, new.ref_application, coalesce(new.created_at, now()));
  end if;
  return new;
end $$;
drop trigger if exists trg_ledger_tag on leave_ledger;
create trigger trg_ledger_tag before insert or update on leave_ledger
  for each row execute function tag_leave_ledger();

-- ---------- 4. 回填 ----------
-- 只写 leave_year 和 kind 这两列。**delta_days 一个字都不碰** —— 整个文件里
-- 没有任何一条语句写它，所以没有人会因为这次升级多一天或少一天。
--
-- 这里本来先建了一张 _v35_before 表，把「升级前的数字」拍个快照，升级后拿来对账。
-- 那张表有两个毛病：
--   1. 它建在 public 里，没有 RLS —— Supabase 会弹窗要你批准一个「让登录用户
--      可能读到全公司余额」的例外。让人去批一个他判断不了的例外，本身就是错的。
--   2. 那个余额对账**永远不可能失败** —— 它拿 sum(delta_days) 跟 sum(delta_days)
--      比，而没有任何语句写这一列。一条不可能失败的检查比没有检查更糟。
-- 旧那套判定只读 reason / created_at / ref_application / delta_days，这四列回填
-- 都不动，所以**旧规则在升级前后给出的答案一模一样** —— 快照根本不需要，末尾
-- 直接把新旧两套规则并排算一次就行，而且这样还骗不过一份过期的快照。
update leave_ledger set
  kind       = coalesce(kind,       ledger_kind_of(reason, ref_application, delta_days)),
  leave_year = coalesce(leave_year, ledger_year_of(reason, ref_application, created_at))
where kind is null or leave_year is null;

-- ---------- 5. 归类：每次跑都**重算一遍** ----------
-- 上面那句回填只补 null。这在第一次跑的时候没问题，第二次就要命：
-- v35 的第一版把入职发放归成了 adjust，等这个文件改好再跑一次，那些行的 kind
-- 已经不是 null 了，**回填根本不碰它们** —— 改对了的规则永远到不了已有的数据。
-- 用户原话：「why Barbie Girl and Doraemon San leave remains unchange after i click
-- save changes」。就是这个原因：他们的入职发放还挂着上一版留下的 adjust。
--
-- 所以 kind 每次都从措辞重算。以后规则再改，重跑一次就生效。
-- leave_year **不重算** —— run_year_start 写结转时是明确指定年份的，
-- 而措辞里推不出来（十二月跑明年的年初，按写入日期算就错了）。
drop index if exists ux_ledger_one_grant;
update leave_ledger set kind = ledger_kind_of(reason, ref_application, delta_days)
 where kind is distinct from ledger_kind_of(reason, ref_application, delta_days);

-- ---------- 5b. 一年一个人一种假别，只能有一条「发放」 ----------
-- 同一年发了两次，就是「sick 27」「hosp 117」的来源。
-- 多出来的那几条**不删**（删了就是凭空扣人天数），改标成 adjust：
-- 天数一天不动，但从此 grant 是唯一的，再也不可能发第二次。
-- 想把它们抹平：Leave types 里把天数填成想要的数字按保存，v35 的 amend_leave_type_days
-- 会把每个人的当年额度**对账到**那个数字。
do $$
declare n int;
begin
  with ranked as (
    select id, row_number() over (partition by emp_id, leave_type, leave_year
                                  order by created_at, id) as rn
      from leave_ledger where kind = 'grant')
  update leave_ledger l set kind = 'adjust'
    from ranked r where r.id = l.id and r.rn > 1;
  get diagnostics n = row_count;
  if n > 0 then
    raise warning 'v35: % duplicate allowance row(s) found — a leave type was granted more than once in the same year. The days were left exactly as they are and the extra rows are now marked as corrections. To bring everyone back to the figure on the Leave types tab, open that tab, retype the number and save.', n;
  end if;
end $$;

create unique index ux_ledger_one_grant
  on leave_ledger (emp_id, leave_type, leave_year) where kind = 'grant';

-- ---------- 6. 约束和索引 ----------
alter table leave_ledger alter column leave_year set not null;
alter table leave_ledger alter column kind       set not null;
alter table leave_ledger drop constraint if exists leave_ledger_kind_chk;
alter table leave_ledger add  constraint leave_ledger_kind_chk
  check (kind in ('grant','carry_in','taken','refund','adjust','writeoff'));
alter table leave_ledger drop constraint if exists leave_ledger_year_chk;
alter table leave_ledger add  constraint leave_ledger_year_chk
  check (leave_year between 2000 and 2100);
create index if not exists ix_ledger_year on leave_ledger (emp_id, leave_type, leave_year);

-- ---------- 7. 取数：一句话，没有一处按文字判断 ----------
create or replace function entitled_in_year(p_emp uuid, p_code text, p_year int)
returns numeric language sql stable as $$
  select coalesce(sum(delta_days), 0) from leave_ledger
   where emp_id = p_emp and leave_type = p_code and leave_year = p_year
     and kind in ('grant', 'adjust');
$$;
comment on function entitled_in_year(uuid, text, int) is
  'This year''s ENTITLEMENT for one leave type: the allowance plus every correction. Carried-forward days are not entitlement (they are last year''s days) and leave taken is not entitlement — both are excluded by kind, not by wording.';
revoke execute on function entitled_in_year(uuid, text, int) from anon;
grant  execute on function entitled_in_year(uuid, text, int) to authenticated;

create or replace function annual_entitled_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$ select entitled_in_year(p_emp, 'annual', p_year); $$;
comment on function annual_entitled_in_year(uuid, int) is
  'Annual leave entitled for the year — entitled_in_year for the annual type. Kept as its own name because the app and several migrations call it.';

create or replace function annual_used_in_year(p_emp uuid, p_year int)
returns numeric language sql stable as $$
  select coalesce(-sum(delta_days), 0) from leave_ledger
   where emp_id = p_emp and leave_type = 'annual' and leave_year = p_year
     and kind in ('taken', 'refund');
$$;
comment on function annual_used_in_year(uuid, int) is
  'Annual leave actually taken in a leave year, net of cancellations. Reads the ledger (one source of truth) and uses the leave dates, so December leave keyed in January still counts against December''s year.';

-- 这一年公司开过没有 —— 不再靠某一句措辞
create or replace function year_has_started(p_year int)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from leave_ledger l join employees e on e.id = l.emp_id
                  where e.active and l.leave_year = p_year and l.kind in ('grant', 'carry_in'));
$$;
revoke execute on function year_has_started(int) from anon, public;
grant  execute on function year_has_started(int) to authenticated;

-- ---------- 8. 发放：靠标签认「发过没有」 ----------
create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can grant the annual leave allowances'; end if;
  for r in
    select e.id as emp_id, t.code, t.default_days
    from employees e cross join leave_types t
    where e.active and t.code <> 'oil' and (t.default_days > 0 or t.code = 'annual')
      and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
      and not exists (select 1 from leave_ledger l
                      where l.emp_id = e.id and l.leave_type = t.code
                        and l.leave_year = p_year and l.kind = 'grant')
  loop
    amt := case when r.code = 'annual' then annual_entitlement_for(r.emp_id, p_year) else r.default_days end;
    if amt > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
      values (r.emp_id, r.code, amt, p_year || ' annual allowance', current_emp_id(), p_year, 'grant');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function grant_annual_entitlements(int) from anon, public;
grant  execute on function grant_annual_entitlements(int) to authenticated;

-- ---------- 9. 年假额度：按标签认「今年发过没有」 ----------
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; ent numeric; adj numeric;
        y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if p_days is null or p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', fmt_days(cap);
  end if;

  before_days := e.annual_base;
  update employees set annual_base = p_days where id = p_emp;

  -- 今年一天额度都还没发过的人：不补。年初发放时自然就是新数字。
  if not exists (select 1 from leave_ledger
                  where emp_id = p_emp and leave_type = 'annual'
                    and leave_year = y and kind in ('grant', 'adjust')) then
    perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, 0, 1, '');
    return 0;
  end if;

  ent := annual_entitled_in_year(p_emp, y);
  adj := p_days - ent;                      -- 对账：把当年额度**补成**填进去的数字
  if adj <> 0 then
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
    values (p_emp, 'annual', adj,
            y || ' annual entitlement set to ' || fmt_days(p_days), current_emp_id(), y, 'adjust');
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, adj, 1, '');
  return adj;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 10. 全公司加年假：同样按标签 ----------
create or replace function bump_annual_all(p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cap numeric; r record; n int := 0; credited int := 0;
        skipped text[] := '{}'; y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can credit annual leave'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter a number of days'; end if;
  cap := (select annual_cap from org_settings where id = 1);

  for r in select id, name, annual_base from employees where active order by name loop
    if (cap is not null and r.annual_base + p_days > cap) or r.annual_base + p_days < 0 then
      skipped := skipped || r.name;
      continue;
    end if;
    n := n + 1;
    if exists (select 1 from leave_ledger
                where emp_id = r.id and leave_type = 'annual'
                  and leave_year = y and kind in ('grant', 'adjust')) then
      credited := credited + 1;
      if not p_preview then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, 'annual', p_days,
                y || ' annual leave ' || case when p_days > 0 then '+' else '' end ||
                fmt_days(p_days) || ' — company-wide', current_emp_id(), y, 'adjust');
      end if;
    end if;
    if not p_preview then
      update employees set annual_base = annual_base + p_days where id = r.id;
    end if;
  end loop;

  if not p_preview and n > 0 then
    perform log_amendment(null, null, 'annual', 'annual_bump', null, null, p_days, n,
      'Company annual leave amendment — ' || case when p_days > 0 then '+' else '' end ||
      fmt_days(p_days) || ' day' || case when abs(p_days) = 1 then '' else 's' end ||
      ' to every employee');
  end if;
  return jsonb_build_object('days', p_days, 'affected', n, 'credited', credited,
                            'skipped', to_jsonb(skipped));
end $$;
revoke execute on function bump_annual_all(numeric, boolean) from anon, public;
grant  execute on function bump_annual_all(numeric, boolean) to authenticated;

-- ---------- 11. 改假别天数：对账到那个数字 ----------
-- 用户两句话，以前只做到了第一句：
--   「60 改成 62 就给所有人加 2 天，已经休掉的不受影响」
--   「if I set 14 everything follow 14」
-- 「补差额」只做到第一句：谁的额度因为别的原因偏了，就一直偏下去
--   —— 同一年发了两次的人，SL 是 28，你把 14 存一遍，它还是 28。
-- 「对账到目标」两句都做到：**额度**变成那个数字，**已休掉的天数一天不动**。
create or replace function amend_leave_type_days(p_code text, p_days numeric, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t leave_types%rowtype; diff numeric; n int := 0; granted_n int := 0; adj numeric; r record;
        y int := extract(year from current_date)::int;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change a leave type'; end if;
  select * into t from leave_types where code = p_code;
  if t.code is null then raise exception 'Unknown leave type'; end if;
  if p_days is null or p_days < 0 then raise exception 'Days per year cannot be negative'; end if;
  diff := p_days - t.default_days;

  if p_code = 'annual' then
    raise exception 'Annual leave is set per employee, in Edit employee — not here';
  end if;
  if p_code = 'oil' then
    raise exception 'Off-in-lieu is earned, not granted — credit it per employee in Edit employee';
  end if;
  if t.no_deduct then
    if not p_preview then update leave_types set default_days = p_days where code = p_code; end if;
    return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
      'after', p_days, 'delta', diff, 'affected', 0, 'credited', false);
  end if;

  -- **每一个在职、符合条件的人**，一个不漏。
  -- 用户原话：「if i change 14-15 why it wont update all employee to 15??????」
  -- 上一版只动「今年已经发过这种假」的人 —— 那是照搬 bump_annual_all 的老规矩，
  -- 而那条规矩是为了防「给没发过额度的人补一笔浮空的差额」，也就是 27 天的老病根。
  -- 现在有了标签和唯一索引，那个担心不成立了：没发过的人**直接补一条本年度发放**，
  -- 唯一索引保证年初再跑一次也不会重复发。于是「填 15 就是全公司 15」真的成立。
  for r in
    select e.id, e.name,
           entitled_in_year(e.id, p_code, y) as have,
           exists (select 1 from leave_ledger l
                    where l.emp_id = e.id and l.leave_type = p_code
                      and l.leave_year = y and l.kind = 'grant') as granted
      from employees e
     where e.active
       and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
     order by e.name
  loop
    adj := p_days - r.have;
    if adj = 0 and r.granted then continue; end if;   -- 已经就是这个数字，什么都不用写
    n := n + 1;
    if p_preview then continue; end if;

    if r.granted then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
      values (r.id, p_code, adj,
              y || ' ' || t.name_en || ' set to ' || fmt_days(p_days), current_emp_id(), y, 'adjust');
    else
      -- 今年还没有过这种假的额度。写成**发放**，不是调整 ——
      -- 写成调整的话，年初发放看不见它，会再发一次；那正是 sick 27 的来源。
      granted_n := granted_n + 1;
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
      values (r.id, p_code, p_days, y || ' annual allowance', current_emp_id(), y, 'grant');
      -- 之前如果有零散的调整，把它们抵掉，好让额度正好等于填进去的数字。
      if r.have <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, p_code, -r.have,
                y || ' ' || t.name_en || ' set to ' || fmt_days(p_days), current_emp_id(), y, 'adjust');
      end if;
    end if;
  end loop;

  if not p_preview then
    update leave_types set default_days = p_days where code = p_code;
    if n > 0 or diff <> 0 then
      -- 措辞照用户当初定的那一句，一个字不改：
      -- 「Company leave amendment — Hospitalisation Leave +2 days」。
      -- 它说的是**这个假别**改了多少，那一点没有变。
      perform log_amendment(null, null, p_code, 'type_days', t.default_days, p_days, diff, n,
        'Company leave amendment — ' || t.name_en || ' ' ||
        case when diff > 0 then '+' else '' end || fmt_days(diff) || ' days');
    end if;
  end if;
  return jsonb_build_object('code', p_code, 'name', t.name_en, 'before', t.default_days,
    'after', p_days, 'delta', diff, 'affected', n, 'newly_granted', granted_n, 'credited', n > 0);
end $$;
revoke execute on function amend_leave_type_days(text, numeric, boolean) from anon, public;
grant  execute on function amend_leave_type_days(text, numeric, boolean) to authenticated;

-- ---------- 11b. 一次把**所有**假别对齐 ----------
-- 用户原话：「not only one leave is chekc all the leave also SL HL CCL OIL ML PL SPL
-- UIC ADL CL MRL」。一个一个假别去 Leave types 里重打十一遍，不是个答案。
--   select * from reconcile_all_leave_types();        -- 只看，不改
--   select * from reconcile_all_leave_types(false);   -- 真的做
-- 年假不在里面：它是每人一个数字（Edit employee）。补休也不在：那是加班换来的。
create or replace function reconcile_all_leave_types(p_preview boolean default true)
returns table ("Leave type" text, "Set to" numeric, "People corrected" int, "Newly credited" int)
language plpgsql security definer set search_path = public as $$
declare t record; v jsonb; y int := extract(year from current_date)::int; miss int;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can level the leave types';
  end if;

  -- ---- 年假先补 ----
  -- 年假不在下面那个循环里：它是**每人一个数字**，没有全公司统一的天数。
  -- 但「没有统一天数」不等于「不用管」：一个人今年的年假额度**整条都不见了**，
  -- 下面的循环一辈子也修不到他 —— 那就是 Balances 上那个「-1 / 0」：
  -- 休掉了一天，额度是零，两个数字**彼此自洽**，所以余额对账根本看不出问题。
  -- （ABB 就是这样：他那条 2026 年假是年初那次错误运行写的，撤销时一并删掉了，
  --   而他本来就没有别的年假发放。）
  -- grant_annual_entitlements 正好做这件事：谁今年缺哪一种假的发放就补哪一种，
  -- 年假按他自己的 Annual Leave Entitled / Yr 发。有的人一天都不动。
  select count(*) into miss
    from employees e cross join leave_types lt
   where e.active and lt.code <> 'oil' and (lt.default_days > 0 or lt.code = 'annual')
     and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender)
     and not exists (select 1 from leave_ledger l
                      where l.emp_id = e.id and l.leave_type = lt.code
                        and l.leave_year = y and l.kind = 'grant');
  if not p_preview and miss > 0 then perform grant_annual_entitlements(y); end if;
  if miss > 0 then
    "Leave type"       := 'Annual Leave (and any missing allowance)';
    "Set to"           := null;
    "People corrected" := 0;
    "Newly credited"   := miss;
    return next;
  end if;

  for t in select code, name_en, default_days from leave_types
            where code <> 'annual' and code <> 'oil' and not no_deduct
            order by sort loop
    v := amend_leave_type_days(t.code, t.default_days, p_preview);
    "Leave type"       := t.name_en;
    "Set to"           := t.default_days;
    "People corrected" := coalesce((v->>'affected')::int, 0);
    "Newly credited"   := coalesce((v->>'newly_granted')::int, 0);
    return next;
  end loop;
end $$;
revoke execute on function reconcile_all_leave_types(boolean) from anon, public;
grant  execute on function reconcile_all_leave_types(boolean) to authenticated;
comment on function reconcile_all_leave_types(boolean) is
  'Brings every employee''s entitlement for every yearly leave type to the figure on the Leave types tab. Previews by default. Days already taken are never touched; annual leave and off-in-lieu are excluded because neither has a company-wide figure.';

-- ---------- 12. 年初：三步，全部按标签 ----------
--   结转 = 上一年剩下的（夹到上限）
--   清零 = 把上一年及更早的余额写掉
--   发放 = 写上今年的额度
-- 上一年一条记录都没有 ⇒ 剩下的就是 0 ⇒ 结转 0。不是靠某条规则记得拦住，
-- 而是**根本没有东西可以结转**。
create or replace function run_year_start(p_year int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; t record;
  v_mode text; v_expires date;
  v_left numeric; v_cap numeric; v_carry numeric; v_excess numeric;
  v_taken numeric; v_exp numeric; v_tb numeric;
  v_resets jsonb; v_reset_days numeric;
  v_rows jsonb := '[]'::jsonb;
  v_people int := 0; v_carry_people int := 0; v_carry_days numeric := 0;
  v_forfeit_people int := 0; v_forfeit_days numeric := 0;
  v_expired_people int := 0; v_expired_days numeric := 0;
  v_reset_people int := 0; v_granted int := 0;
  v_block jsonb := '[]'::jsonb;
  v_started boolean; v_started_n int := 0; v_why text := null;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can start a new year';
  end if;
  if p_year < 2000 or p_year > 2500 then raise exception 'Year out of range'; end if;

  -- v35：这一年已经发过额度了 ⇒ 这不是「开新的一年」。
  -- 硬开会把已经发下去的天数当成「去年剩的」结转，再把其它假别清光却不补发。
  -- 那正是 2026 年那一次出的事。
  v_started := year_has_started(p_year);
  if v_started then
    select count(distinct l.emp_id) into v_started_n
      from leave_ledger l join employees e on e.id = l.emp_id
     where e.active and l.leave_year = p_year and l.kind in ('grant', 'carry_in');
    v_why := p_year || ' has already been credited — ' || v_started_n || ' employee(s) already hold '
          || p_year || ' leave. Start a new year sets up the year AHEAD. To change figures for a '
          || 'year already running, use Edit employee (one person) or the Leave types tab (everyone).';
    if not p_preview then raise exception '%', v_why; end if;
  end if;

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
  v_expires := carry_expiry_for(p_year);

  -- 步骤 1：把已经到期的结转落成账本条目（预览不写 —— 下面用 due_unwritten_carry 补上）
  if not p_preview then perform expire_due_carry(); end if;

  for r in select e.id, e.name, coalesce(e.carry_cap, 0) as cap
           from employees e where e.active order by e.name loop

    if exists (select 1 from year_start_log y where y.year = p_year and y.emp_id = r.id) then
      continue;
    end if;
    v_people := v_people + 1;
    v_cap := r.cap;

    -- 上一年（含更早还没结清的年份）留下的年假。**只看标签**，措辞完全不参与。
    -- 减 due_unwritten_carry：预览时上面那一步没写账，这样两条路数字一致；
    -- 执行时它已经落了账，这个函数返回 0，不会重复扣。
    v_left := coalesce((select sum(l.delta_days) from leave_ledger l
                         where l.emp_id = r.id and l.leave_type = 'annual'
                           and l.leave_year < p_year), 0)
            - due_unwritten_carry(r.id, 'annual');

    select coalesce(case
             when ac.expires_on is null then 0
             when ac.expired_at is not null then ac.expired_days
             else greatest(0, ac.carry_in - annual_used_between(r.id, make_date(ac.year,1,1), ac.expires_on))
           end, 0)
      into v_exp
      from annual_carry ac where ac.emp_id = r.id and ac.year = p_year - 1;
    v_exp := coalesce(v_exp, 0);
    if v_exp > 0 then v_expired_people := v_expired_people + 1; v_expired_days := v_expired_days + v_exp; end if;

    -- 结转夹到上限。**不夹 0**：欠着的天数（余额是负的）必须跟着进新一年，
    -- 否则一开年那笔债就凭空消失了。
    v_carry  := least(v_cap, v_left);
    v_excess := greatest(0, v_left - v_cap);
    v_taken  := annual_used_in_year(r.id, p_year - 1);
    if v_carry  > 0 then v_carry_people := v_carry_people + 1; v_carry_days := v_carry_days + v_carry; end if;
    if v_excess > 0 then v_forfeit_people := v_forfeit_people + 1; v_forfeit_days := v_forfeit_days + v_excess; end if;

    -- 步骤 2：其余假别清零。清多少 = 上一年（及更早）这种假的余额。
    v_resets := '[]'::jsonb; v_reset_days := 0;
    for t in select code, name_en, default_days from leave_types
             where resets_yearly and not no_deduct order by sort loop
      select coalesce(sum(l.delta_days), 0) into v_tb from leave_ledger l
        where l.emp_id = r.id and l.leave_type = t.code and l.leave_year < p_year;
      if v_tb <> 0 then
        v_resets := v_resets || jsonb_build_object(
          'code', t.code, 'name', t.name_en, 'cleared', v_tb, 'credits', t.default_days);
        v_reset_days := v_reset_days + v_tb;
        if not p_preview then
          insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
          values (r.id, t.code, -v_tb,
                  (p_year - 1) || ' ' || t.name_en || ' expired (unused)', current_emp_id(),
                  p_year - 1, 'writeoff');
        end if;
      end if;
    end loop;
    if jsonb_array_length(v_resets) > 0 then v_reset_people := v_reset_people + 1; end if;

    if not p_preview then
      -- 关掉上一年的年假：写掉全部余额，于是 leave_year < p_year 的年假合计正好是 0。
      if v_left <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, 'annual', -v_left,
                (p_year - 1) || ' annual leave closed — ' || fmt_days(greatest(0, v_carry))
                  || ' carried forward'
                  || case when v_excess > 0
                          then ', ' || fmt_days(v_excess) || ' above the carry-over cap ('
                               || fmt_days(v_cap) || ') — forfeited'
                          else '' end,
                current_emp_id(), p_year - 1, 'writeoff');
      end if;
      -- 结转变成一条真正的账本条目，属于新的一年。
      if v_carry <> 0 then
        insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
        values (r.id, 'annual', v_carry,
                'Carried forward from ' || (p_year - 1)
                  || case when v_expires is not null
                          then ' (expires ' || to_char(v_expires, 'DD Mon YYYY') || ')' else '' end,
                current_emp_id(), p_year, 'carry_in');
      end if;
      insert into annual_carry (emp_id, year, carry_in, expires_on)
      values (r.id, p_year, greatest(0, v_carry), v_expires)
      on conflict (emp_id, year) do nothing;
      insert into year_start_log (year, emp_id, emp_name, annual_taken_prev, annual_left,
                                  cap_applied, carried, forfeited, expired, expires_on,
                                  resets, reset_days, run_by)
      values (p_year, r.id, r.name, v_taken, v_left, v_cap, greatest(0, v_carry), v_excess, v_exp,
              v_expires, v_resets, v_reset_days, current_emp_id());
    end if;

    v_rows := v_rows || jsonb_build_object(
      'name', r.name, 'taken_prev', v_taken, 'left', v_left, 'cap', v_cap,
      'carried', v_carry, 'forfeited', v_excess, 'expired', v_exp,
      'expires_on', v_expires, 'reset_days', v_reset_days, 'resets', v_resets);
  end loop;

  -- 步骤 3：发放新一年的额度。**必须在清零之后**，否则刚发的立刻被抹掉。
  if v_mode = 'monthly' then
    v_granted := 0;
  elsif p_preview then
    v_granted := (select count(distinct e.id) from employees e cross join leave_types lt
                  where e.active and lt.code <> 'oil' and (lt.default_days > 0 or lt.code = 'annual')
                    and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender)
                    and not exists (select 1 from leave_ledger l
                                    where l.emp_id = e.id and l.leave_type = lt.code
                                      and l.leave_year = p_year and l.kind = 'grant'));
  else
    v_granted := grant_annual_entitlements(p_year);
  end if;

  return jsonb_build_object(
    'year', p_year, 'preview', p_preview, 'people', v_people,
    'blockers', v_block,
    'already_started', v_started, 'blocked_reason', v_why,
    'accrual_mode', v_mode, 'expires_on', v_expires,
    'carried_people', v_carry_people, 'carried_days', v_carry_days,
    'forfeited_people', v_forfeit_people, 'forfeited_days', v_forfeit_days,
    'expired_people', v_expired_people, 'expired_days', v_expired_days,
    'reset_people', v_reset_people, 'granted', v_granted,
    'rows', v_rows);
end $$;
revoke execute on function run_year_start(int, boolean) from anon, public;
grant  execute on function run_year_start(int, boolean) to authenticated;

-- ---------- 13. 自检：回填之后，没有人多一天或少一天 ----------
do $$
declare bad int; r record;
begin
  select count(*) into bad from leave_ledger where leave_year is null or kind is null;
  if bad > 0 then raise exception 'v35 FAILED: % ledger row(s) still have no year or no kind', bad; end if;

  -- 请假／销假：必须挂在**假期日期**那一年，不是录入那一天
  select count(*) into bad
    from leave_ledger l join applications a on a.id = l.ref_application
   where l.leave_year <> extract(year from a.start_date)::int;
  if bad > 0 then
    raise exception 'v35 FAILED: % leave entr(ies) are filed under a different year from the leave itself', bad;
  end if;

  -- 措辞里写明了年份的（发放、清零、调整都是这个格式）：标签必须跟措辞一致
  select count(*) into bad
    from leave_ledger l
   where l.ref_application is null
     and substring(coalesce(l.reason, '') from '^([0-9]{4})') is not null
     and substring(l.reason from '^([0-9]{4})')::int between 2000 and 2100
     and l.leave_year <> substring(l.reason from '^([0-9]{4})')::int;
  if bad > 0 then
    raise exception 'v35 FAILED: % entr(ies) are filed under a year their own wording contradicts', bad;
  end if;

  -- **这是真正重要的一条。** 今年每个人每种假别的额度，新旧两套判定必须给出同一个数字。
  -- 两边都在同一次扫描里现算 —— 不存快照，所以骗不过一份过期的数据；而旧那套只读
  -- 回填不碰的那几列，所以它现在的答案就是升级前的答案。
  bad := 0;
  for r in
    with cy as (select extract(year from current_date)::int as y),
    cmp as (
      select l.emp_id, l.leave_type,
             coalesce(sum(l.delta_days) filter (
               where l.ref_application is null
                 and extract(year from l.created_at)::int = (select y from cy)
                 and l.reason not like '%expired (unused)%'
                 and l.reason not like '%above the carry-over cap%'
                 and l.reason not like '%reset — use it or lose it%'
                 and l.reason not like '%excess forfeited%'
                 and l.reason not like '%expired carry-over%'
                 and l.reason not like 'Offboarding%'
                 and l.reason not like '%结转%'
                 and l.reason not like '%作废%'), 0) as was,
             coalesce(sum(l.delta_days) filter (
               where l.leave_year = (select y from cy)
                 and l.kind in ('grant', 'adjust')), 0) as now
        from leave_ledger l group by l.emp_id, l.leave_type)
    select e.name, cmp.leave_type, cmp.was, cmp.now
      from cmp join employees e on e.id = cmp.emp_id
     where cmp.was is distinct from cmp.now
     order by e.name, cmp.leave_type
  loop
    bad := bad + 1;
    raise warning '  % / % : % → %', r.name, r.leave_type, r.was, r.now;
  end loop;
  if bad > 0 then
    raise exception 'v35 FAILED: % entitlement figure(s) moved during the backfill — nothing has been changed', bad;
  end if;

  -- 规则里不该再出现按年份猜的写法
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public'
                and p.proname in ('annual_entitled_in_year', 'annual_used_in_year',
                                  'grant_annual_entitlements', 'entitled_in_year')
                and pg_get_functiondef(p.oid) like '%extract(year from%created_at%') then
    raise exception 'v35 FAILED: a year function still reads the year off created_at';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'run_year_start'
                and pg_get_functiondef(p.oid) like '%annual allowance%') then
    raise exception 'v35 FAILED: run_year_start still matches an allowance by its wording';
  end if;

  raise notice 'v35 installed: every ledger entry now records the leave year it belongs to.';
end $$;

-- ---------- 14. 把结果**显示出来** ----------
-- Supabase 的 SQL Editor **不显示 raise notice**。上面那句「v35 installed」在
-- psql 里看得见，在网页上只会显示「Success. No rows returned.」—— 等于没有回执，
-- 跑完了也不知道到底成没成。最后一句必须是 select：看得见的才算数。
--
-- 顺便就把该看的东西一次列出来：每种假别，Leave types 里写的是多少，员工手上
-- 实际是多少。**有几个不同的数字，就是几年下来欠的账**：入职发放用的是入职那天
-- 的天数，后来改过的每一次都留下新的一层。要抹平：照它说的做，去 Leave types
-- 把那个数字重打一遍保存 —— v35 之后，那一下会把每个人对账到那个数字。
-- 「有几个不同的数字」看的是拿到过额度的人。**没拿到过的人在那一列里是看不见的**：
-- 他的余额和额度彼此自洽（休了一天、额度为零，就是 -1 / 0），任何余额对账都查不出来。
-- 所以「一个人都没发过」单独一列。ABB 的年假就是这样丢的。
select t.name_en                                              as "Leave type",
       trim_scale(t.default_days)                             as "Leave types tab says",
       count(distinct x.ent) filter (where x.granted)         as "Different figures in use",
       string_agg(distinct trim_scale(x.ent)::text, '  /  ')
         filter (where x.granted)                             as "Figures people actually hold",
       count(*) filter (where not x.granted)                  as "Holding NO allowance",
       case when count(*) filter (where not x.granted) > 0
            then '⚠ ' || count(*) filter (where not x.granted)
                 || ' person(s) hold none — run reconcile_all_leave_types(false)'
            when count(distinct x.ent) filter (where x.granted) > 1
            then '⚠ retype ' || trim_scale(t.default_days) || ' on the Leave types tab and save'
            else 'consistent' end                             as "What to do"
  from leave_types t
  join lateral (
    select entitled_in_year(e.id, t.code, extract(year from current_date)::int) as ent,
           exists (select 1 from leave_ledger l
                    where l.emp_id = e.id and l.leave_type = t.code
                      and l.leave_year = extract(year from current_date)::int
                      and l.kind = 'grant') as granted
      from employees e
     where e.active
       and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
  ) x on true
 where t.code <> 'oil' and not t.no_deduct
   and (t.default_days > 0 or t.code = 'annual')
 group by t.code, t.name_en, t.default_days, t.sort
 order by t.sort;


-- ===========================================================================
-- migration_app_v36.sql
-- ===========================================================================

-- ============================================================================
-- migration_app_v36.sql — 补休（Off-in-Lieu）到期日
--
-- 用户原话：
--   「I need another function for Off in lieu expired date. same as the carry foward
--     AL function just create one for off in lieu, and put it together with the
--     Carry Forward AL expiry date under company setting. the funciton is related to
--     Off in lieu expired, so once the date reaches it will be forfeited. same as AL.」
--
-- 规则（用户当场选定，与年假结转**不同**，这一点要记牢）：
--   到了那个日子，**整个补休余额**清零 —— 不分是哪一年攒的。
--   年假结转是「去年剩下的，今年这个日子作废，今年新发的不受影响」；
--   补休是「这个日子一到，手上还剩多少就作废多少」。
--   例：到期日设 3 月 31 日。2026 年 11 月攒了 2 天，2027 年 2 月又攒了 1 天，
--       2027-03-31 那天，**3 天全部作废**。
--
-- 默认**不到期**（两列都是 NULL）。装上这个迁移不会有任何人少一天；
-- 一直到 HR 自己去 Company settings 选一个月份，才开始生效。
--
-- 幂等：重复执行没有副作用。
-- ============================================================================

-- ---------- 0. 前置 ----------
alter table org_settings add column if not exists oil_expiry_month int;
alter table org_settings add column if not exists oil_expiry_day   int;

comment on column org_settings.oil_expiry_month is
  'Month (1-12) that off-in-lieu expires on, every year. NULL (with oil_expiry_day) = off-in-lieu never expires, which is the default and what every existing company keeps until HR chooses otherwise.';
comment on column org_settings.oil_expiry_day is
  'Day of oil_expiry_month that off-in-lieu expires on. Clamped to the length of the month, so 31 in a 30-day month means the 30th rather than an error.';

-- ---------- 1. 那个日子是哪一天 ----------
-- 和 carry_expiry_for 一个模子，包括「31 号遇到只有 30 天的月份就取 30」那一下。
create or replace function oil_expiry_for(p_year int)
returns date language sql stable security definer set search_path = public as $$
  select case
           when o.oil_expiry_month is null or o.oil_expiry_day is null then null
           else make_date(p_year, o.oil_expiry_month,
                  least(o.oil_expiry_day,
                        extract(day from (make_date(p_year, o.oil_expiry_month, 1)
                                          + interval '1 month' - interval '1 day'))::int))
         end
  from org_settings o where o.id = 1;
$$;
comment on function oil_expiry_for(int) is
  'The date off-in-lieu expires in a given year. SECURITY DEFINER for the same reason as carry_expiry_for: as an invoker it returns NULL wherever org_settings is unreadable, and NULL here means "never expires" — a silent failure instead of an error.';
revoke execute on function oil_expiry_for(int) from anon, public;
grant  execute on function oil_expiry_for(int) to authenticated;

-- 任意「几月几号」最近一次**已经过去**的那一天。设置界面要在保存前就能算，
-- 所以月份和日子是参数，不是从设置里读。
create or replace function oil_cutoff_of(p_month int, p_day int)
returns date language sql immutable as $$
  select case when p_month is null or p_day is null then null
         when make_date(y, p_month, least(p_day, extract(day from (make_date(y, p_month, 1)
                + interval '1 month' - interval '1 day'))::int)) <= current_date
           then make_date(y, p_month, least(p_day, extract(day from (make_date(y, p_month, 1)
                + interval '1 month' - interval '1 day'))::int))
         else make_date(y - 1, p_month, least(p_day, extract(day from (make_date(y - 1, p_month, 1)
                + interval '1 month' - interval '1 day'))::int))
         end
  from (select extract(year from current_date)::int as y) _;
$$;

create or replace function oil_last_cutoff()
returns date language sql stable security definer set search_path = public as $$
  select oil_cutoff_of(o.oil_expiry_month, o.oil_expiry_day) from org_settings o where o.id = 1;
$$;
revoke execute on function oil_last_cutoff() from anon, public;
grant  execute on function oil_last_cutoff() to authenticated;

-- ---------- 2. 那一天为止，手上还有多少补休 ----------
-- **这里用 created_at 是对的**，别「顺手改成 leave_year」。
-- v35 禁止的是「拿写入日期当假期年度」；这里问的是另一回事：
-- 「到那一天为止，这一天到底攒到手没有」—— 那正是 created_at 回答的问题。
-- 但请假／销假两种要看**假期日期**：十二月休的补休一月才补录，
-- 若按补录日期算，就会把一个人已经用掉的天数再作废一次。
create or replace function oil_balance_asof(p_emp uuid, p_on date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(l.delta_days), 0)
    from leave_ledger l
   where l.emp_id = p_emp and l.leave_type = 'oil'
     and (case when l.kind in ('taken', 'refund')
               then coalesce((select a.start_date from applications a where a.id = l.ref_application),
                             l.created_at::date)
               else l.created_at::date end) <= p_on;
$$;
revoke execute on function oil_balance_asof(uuid, date) from anon, public;
grant  execute on function oil_balance_asof(uuid, date) to authenticated;

-- ---------- 3. 作废记录 ----------
-- 和 annual_carry.expired_at 一个作用：证明这一次到期已经落过账，不会作废两次。
create table if not exists oil_expiry_log (
  emp_id       uuid not null references employees (id),
  expires_on   date not null,
  expired_days numeric(6,1) not null,
  expired_at   timestamptz not null default now(),
  primary key (emp_id, expires_on)
);
comment on table oil_expiry_log is
  'One row per employee per off-in-lieu expiry date, written when that date is processed. A row with expired_days = 0 still counts as processed — it is what stops the same date being looked at again every day.';
alter table oil_expiry_log enable row level security;
drop policy if exists oilexp_read on oil_expiry_log;
create policy oilexp_read on oil_expiry_log for select to authenticated
  using (emp_id = current_emp_id() or is_hr());

-- ---------- 4. 安全网：过期了但还没落账 ----------
-- 和 due_unwritten_carry 一样，余额视图里直接扣掉。
-- 这样就算每一个定时任务都死了，也没有人能用到已经作废的补休。
create or replace function due_unwritten_oil(p_emp uuid, p_code text)
returns numeric language sql stable security definer set search_path = public as $$
  select case when p_code <> 'oil' then 0 else coalesce((
    select greatest(0, oil_balance_asof(p_emp, c.d))
      from (select oil_last_cutoff() as d) c
     where c.d is not null
       and exists (select 1 from employees e where e.id = p_emp and e.active)  -- v27：离职即冻结
       and not exists (select 1 from oil_expiry_log g
                        where g.emp_id = p_emp and g.expires_on = c.d)
  ), 0) end;
$$;
revoke execute on function due_unwritten_oil(uuid, text) from anon;
grant  execute on function due_unwritten_oil(uuid, text) to authenticated;

-- ---------- 5. 余额视图：把它扣掉 ----------
create or replace view leave_balances as
select l.emp_id, l.leave_type,
       sum(l.delta_days) filter (where l.delta_days > 0)  as granted,
       -sum(l.delta_days) filter (where l.delta_days < 0) as used,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type)
                         - due_unwritten_oil(l.emp_id, l.leave_type)   as balance,
       coalesce((select sum(a.days) from applications a
                 where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                   and a.status = 'pending'), 0)          as pending,
       sum(l.delta_days) - due_unwritten_carry(l.emp_id, l.leave_type)
                         - due_unwritten_oil(l.emp_id, l.leave_type)
         - coalesce((select sum(a.days) from applications a
                     where a.emp_id = l.emp_id and a.leave_type = l.leave_type
                       and a.status = 'pending'), 0)      as available
from leave_ledger l
group by l.emp_id, l.leave_type;

-- ---------- 6. 到期落账 ----------
create or replace function expire_due_oil(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; d date := oil_last_cutoff(); rem numeric; n int := 0;
begin
  if d is null then return 0; end if;            -- 没设到期日 = 永不过期
  for r in
    select e.id from employees e
     where e.active                               -- 离职的人账已经冻结，不动
       and (p_emp is null or e.id = p_emp)
       and not exists (select 1 from oil_expiry_log g
                        where g.emp_id = e.id and g.expires_on = d)
    order by e.id
  loop
    rem := greatest(0, oil_balance_asof(r.id, d));
    if rem > 0 then
      -- **created_at is the cut-off date, not now.** oil_balance_asof asks "what was in
      -- hand on that day", so a write-off stamped with today's date is invisible to it —
      -- and the next cut-off then forfeits the very same days a second time, driving the
      -- balance negative. Dating it on the day it happened is both truthful and the thing
      -- that makes the arithmetic close.
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                leave_year, kind, created_at)
      values (r.id, 'oil', -rem,
              to_char(d, 'YYYY') || ' off-in-lieu expired (unused)', current_emp_id(),
              extract(year from d)::int, 'writeoff', d);
    end if;
    -- 即使是 0 天也要记一笔：这条记录才是「这一次到期处理过了」的凭据。
    insert into oil_expiry_log (emp_id, expires_on, expired_days) values (r.id, d, rem);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_oil(uuid) from anon, public;
grant  execute on function expire_due_oil(uuid) to authenticated;

-- ---------- 7. HR 设定这个日子 ----------
-- 和 set_carry_expiry 一样：**先预览**。把日子往前挪会当场烧掉别人手上的天数，
-- 那句话必须是真的，不能是这边猜的。
create or replace function set_oil_expiry(p_month int, p_day int, p_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cut date; v_people int := 0; v_days numeric := 0; v_dying_people int := 0;
  v_already int; v_holding int; r record;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can change the off-in-lieu expiry date';
  end if;
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
  end if;

  v_cut := oil_cutoff_of(p_month, p_day);
  select count(*) into v_already from oil_expiry_log;
  select count(*) into v_holding from employees e
   where e.active and coalesce((select balance from leave_balances
                                where emp_id = e.id and leave_type = 'oil'), 0) > 0;

  -- 这个日子最近一次已经过去了 ⇒ 一保存，那些天数立刻没。先数清楚。
  if v_cut is not null then
    for r in
      select e.id, greatest(0, oil_balance_asof(e.id, v_cut)) as dying
        from employees e
       where e.active
         and not exists (select 1 from oil_expiry_log g
                          where g.emp_id = e.id and g.expires_on = v_cut)
    loop
      v_people := v_people + 1;
      if r.dying > 0 then
        v_dying_people := v_dying_people + 1;
        v_days := v_days + r.dying;
      end if;
    end loop;
  end if;

  if not p_preview then
    update org_settings set oil_expiry_month = p_month, oil_expiry_day = p_day where id = 1;
    -- 立刻落账，这样屏幕上看到的和预览说的是同一件事。
    if p_month is not null then perform expire_due_oil(); end if;
  end if;

  return jsonb_build_object(
    'preview', p_preview, 'new_date', v_cut,
    'month', p_month, 'day', p_day,
    'holding', v_holding, 'people', v_people,
    'days_lost', v_days, 'dying_people', v_dying_people,
    'already_expired', v_already);
end $$;
revoke execute on function set_oil_expiry(int, int, boolean) from anon, public;
grant  execute on function set_oil_expiry(int, int, boolean) to authenticated;

-- ---------- 8. 每天的心跳也带上它 ----------
-- **不要重写这个函数的签名。** keepalive_ping 返回 bigint，而且维护着一个持久计数器
-- （keepalive_heartbeat.ping_count）—— 那个计数器就是「心跳真的写进磁盘了」的唯一证据。
-- 把它改成返回 text，或者忘了那段 update，等于把保活功能悄悄弄坏，
-- 而这种坏法要等 Supabase 把项目睡掉才会有人发现。
-- 所以这里连原来的函数体一起照抄，只多加一段补休到期。
create or replace function public.keepalive_ping()
returns bigint
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  update public.keepalive_heartbeat
     set last_ping_at = now(),
         ping_count   = ping_count + 1
   where id = 1
  returning ping_count into v_count;

  -- v3：把「已经过了到期日」的结转年假落成账本条目。
  begin
    perform public.expire_due_carry();
  exception when undefined_function then null;
  end;

  -- v36：补休到期，同样落账。单独包一层 —— 一个坏掉不该把另一个也带下去，
  -- 更不该把保活本身带下去。
  begin
    perform public.expire_due_oil();
  exception when undefined_function then null;
  end;

  -- 万一那一行被人删了，自愈补回来
  if v_count is null then
    insert into public.keepalive_heartbeat (id, last_ping_at, ping_count)
    values (1, now(), 1)
    on conflict (id) do update
      set last_ping_at = now(),
          ping_count   = public.keepalive_heartbeat.ping_count + 1
    returning ping_count into v_count;
  end if;

  return v_count;
end;
$$;
revoke execute on function public.keepalive_ping() from anon, public;
grant  execute on function public.keepalive_ping() to authenticated;

-- ---------- 9. 自检 ----------
do $$
declare d date;
begin
  if not exists (select 1 from information_schema.columns
                  where table_name = 'org_settings' and column_name = 'oil_expiry_month') then
    raise exception 'v36 FAILED: org_settings.oil_expiry_month is missing';
  end if;
  -- 装上之后必须是「永不过期」：不能有任何人因为升级少一天。
  select oil_expiry_for(extract(year from current_date)::int) into d;
  if d is not null and not exists (select 1 from oil_expiry_log) then
    raise warning 'v36: an off-in-lieu expiry date is already set (%). Nothing has expired yet — it will on the next daily run.', d;
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'keepalive_ping'
                and pg_get_functiondef(p.oid) not like '%expire_due_oil%') then
    raise exception 'v36 FAILED: the daily heartbeat does not expire off-in-lieu';
  end if;
  raise notice 'v36 installed: off-in-lieu can be given an expiry date, next to the carry-forward one.';
end $$;

select 'v36 installed — Off-in-Lieu expiry' as status,
       coalesce(to_char(oil_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'),
                'never expires (nothing changes until you pick a month)') as "Off-in-lieu expires",
       coalesce(to_char(carry_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'),
                'never expires') as "Carried annual leave expires";


-- ===========================================================================
-- migration_app_v37.sql
-- ===========================================================================

-- ============================================================================
-- migration_app_v37.sql — 两个到期功能变成同一套；每一笔作废都进修订记录
--
-- 用户原话：
--   「i set Sep 3 so every OIL should be forfeited right? why i still saw employee
--     have OIL?」
--   「is the forfeited recorded ? i need every forfeited leave also be recorded
--     under all records.」
--   「this two expiry function should be identical ... same logic and same method,
--     and same will be recorded for all amendement.」
--
-- ---------------------------------------------------------------------------
-- 1) 为什么设了 9 月 3 日却没作废 —— 根因
-- ---------------------------------------------------------------------------
-- v36 里 oil_cutoff_of 被标成了 IMMUTABLE，可它里面读 current_date，而
-- current_date 是 STABLE。**这是在对规划器撒谎。**
-- Postgres 不会拦你，但一旦标成 immutable，规划器就有权把它在**做计划的时候**
-- 算一次，然后把那个日期钉死在缓存的计划里。
--
-- 用 psql 手工跑每次都是新连接、新计划，所以永远是对的 —— 我的测试就是这么过的。
-- 而线上是 PostgREST：连接是池化的、长命的，计划缓存能活很久。于是那个「今天」
-- 可能是几天前的今天。设 9 月 3 日、当天却什么都没发生，就是这么来的。
--
-- 教训写在这里：**函数里只要出现 current_date / now()，就不能标 immutable。**
-- 下面加了一条自检，直接读 pg_proc 的 provolatile，标错了装不上去。
--
-- ---------------------------------------------------------------------------
-- 2) 两个到期功能同一套做法
-- ---------------------------------------------------------------------------
--   · 同一个「最近一次已过去的日子」算法        cutoff_of(month, day)
--   · 同一个安全网                              余额视图里先扣掉
--   · 同一种落账                                leave_ledger 一条 writeoff
--   · **同一份修订记录**                        hr_amendments，kind = 'expiry'
--
-- 作废掉的是哪些天，两者不同 —— 这是假期本身的性质决定的，不是做法不同：
--   年假：到期的是**结转过来的那一部分**（annual_carry 记着是多少）
--   补休：到期的是**整个补休余额**（补休没有「结转」这回事）
-- 两边都是「那个池子里到那天还剩多少，就作废多少」。
--
-- 幂等：重复执行没有副作用。
-- ============================================================================

-- ---------- 1. 根因修复：不能对规划器撒谎 ----------
create or replace function oil_cutoff_of(p_month int, p_day int)
returns date language sql stable as $$
  select case when p_month is null or p_day is null then null
         when make_date(y, p_month, least(p_day, extract(day from (make_date(y, p_month, 1)
                + interval '1 month' - interval '1 day'))::int)) <= current_date
           then make_date(y, p_month, least(p_day, extract(day from (make_date(y, p_month, 1)
                + interval '1 month' - interval '1 day'))::int))
         else make_date(y - 1, p_month, least(p_day, extract(day from (make_date(y - 1, p_month, 1)
                + interval '1 month' - interval '1 day'))::int))
         end
  from (select extract(year from current_date)::int as y) _;
$$;
comment on function oil_cutoff_of(int, int) is
  'The most recent occurrence of a given day/month that is on or before today. STABLE, never IMMUTABLE: it reads current_date, and marking it immutable lets the planner freeze that date into a cached plan — which is why an expiry set to today did nothing on the live site while working perfectly in a fresh psql session.';

-- 年假那边用同一个算法，同一个名字形状 —— 两个功能从这里开始就是一套东西。
create or replace function carry_cutoff_of(p_month int, p_day int)
returns date language sql stable as $$ select oil_cutoff_of(p_month, p_day); $$;
comment on function carry_cutoff_of(int, int) is
  'Same helper as oil_cutoff_of, under the name the carry-forward side reads. One algorithm, two callers: if the two expiry dates ever behave differently, it will not be because they compute "the last time that date went by" differently.';
revoke execute on function carry_cutoff_of(int, int) from anon, public;
grant  execute on function carry_cutoff_of(int, int) to authenticated;

-- ---------- 2. 一笔作废怎么记 ----------
-- 两边都调这一个。措辞、kind、影响人数全都一致 —— 「same will be recorded」。
create or replace function log_expiry_amendment(
  p_emp uuid, p_type text, p_days numeric, p_on date)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text; v_label text;
begin
  if coalesce(p_days, 0) <= 0 then return; end if;
  select name into v_name from employees where id = p_emp;
  select name_en into v_label from leave_types where code = p_type;
  perform log_amendment(p_emp, coalesce(v_name, ''), p_type, 'expiry',
                        p_days, 0, -p_days, 1,
                        coalesce(v_label, p_type) || ' expired on '
                          || to_char(p_on, 'DD Mon YYYY') || ' — '
                          || trim_scale(p_days) || ' day(s) forfeited');
end $$;
revoke execute on function log_expiry_amendment(uuid, text, numeric, date) from anon, public;

-- ---------- 3. 补休到期：加上修订记录 ----------
create or replace function expire_due_oil(p_emp uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare r record; d date := oil_last_cutoff(); rem numeric; n int := 0;
begin
  if d is null then return 0; end if;
  for r in
    select e.id from employees e
     where e.active
       and (p_emp is null or e.id = p_emp)
       and not exists (select 1 from oil_expiry_log g
                        where g.emp_id = e.id and g.expires_on = d)
    order by e.id
  loop
    rem := greatest(0, oil_balance_asof(r.id, d));
    if rem > 0 then
      -- created_at 是**到期那一天**，不是现在。oil_balance_asof 问的是「那天手上有多少」，
      -- 用今天的日期写这条，它就看不见，下一次到期会把同样的天数再作废一遍。
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                leave_year, kind, created_at)
      values (r.id, 'oil', -rem,
              to_char(d, 'YYYY') || ' off-in-lieu expired (unused)', current_emp_id(),
              extract(year from d)::int, 'writeoff', d);
      perform log_expiry_amendment(r.id, 'oil', rem, d);
    end if;
    insert into oil_expiry_log (emp_id, expires_on, expired_days) values (r.id, d, rem);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_oil(uuid) from anon, public;
grant  execute on function expire_due_oil(uuid) to authenticated;

-- ---------- 4. 年假结转到期：同样加上修订记录 ----------
-- 除了「作废的是结转那一部分」之外，和上面一模一样。
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
    rem := greatest(0, r.carry_in - annual_used_between(r.emp_id, make_date(r.year,1,1), r.expires_on));
    if rem > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by,
                                leave_year, kind, created_at)
      values (r.emp_id, 'annual', -rem, r.year || ' carry-over expired (unused)', current_emp_id(),
              r.year, 'writeoff', r.expires_on);
      -- v37：和补休走同一个函数，所以修订记录里两者长得一模一样。
      perform log_expiry_amendment(r.emp_id, 'annual', rem, r.expires_on);
    end if;
    update annual_carry set expired_days = rem, expired_at = now()
      where emp_id = r.emp_id and year = r.year;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function expire_due_carry(uuid) from anon, public;
grant  execute on function expire_due_carry(uuid) to authenticated;

-- ---------- 5. HR 手动给某人加结转年假（测试用，也是补录用） ----------
-- 用户原话：「please credit 5 carryfoward AL to Lee Jian Wei, Amanda and ABB」。
-- 结转不是凭空一个数字，它有两半，缺一不可：
--   · 账本里一条 carry_in（这才是真正能用的天数）
--   · annual_carry 一行（到期作业读的就是这一行）
-- 手写 SQL 很容易只写一半，然后余额和到期对不上。这个函数两半一起写。
create or replace function credit_carry_forward(p_emp uuid, p_days numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare y int := extract(year from current_date)::int;
        v_exp date; v_name text; v_had numeric;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can credit carry-forward leave';
  end if;
  if p_days is null or p_days <= 0 then raise exception 'Enter a number of days above zero'; end if;
  select name into v_name from employees where id = p_emp and active;
  if v_name is null then raise exception 'That employee is not on the active list'; end if;

  v_exp := carry_expiry_for(y);
  select coalesce(carry_in, 0) into v_had from annual_carry where emp_id = p_emp and year = y;

  insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
  values (p_emp, 'annual', p_days,
          'Carried forward from ' || (y - 1)
            || case when v_exp is not null
                    then ' (expires ' || to_char(v_exp, 'DD Mon YYYY') || ')' else '' end,
          current_emp_id(), y, 'carry_in');

  insert into annual_carry (emp_id, year, carry_in, expires_on)
  values (p_emp, y, p_days, v_exp)
  on conflict (emp_id, year) do update
    set carry_in = annual_carry.carry_in + excluded.carry_in,
        expires_on = excluded.expires_on,
        expired_days = null, expired_at = null;

  perform log_amendment(p_emp, v_name, 'annual', 'carry_credit',
                        coalesce(v_had, 0), coalesce(v_had, 0) + p_days, p_days, 1,
                        trim_scale(p_days) || ' day(s) of carry-forward credited'
                          || case when v_exp is not null
                                  then ', expiring ' || to_char(v_exp, 'DD Mon YYYY')
                                  else ' (no expiry set)' end);

  return jsonb_build_object('name', v_name, 'days', p_days, 'year', y,
                            'carry_now', coalesce(v_had, 0) + p_days, 'expires_on', v_exp);
end $$;
revoke execute on function credit_carry_forward(uuid, numeric) from anon, public;
grant  execute on function credit_carry_forward(uuid, numeric) to authenticated;
comment on function credit_carry_forward(uuid, numeric) is
  'Give somebody carried-forward annual leave by hand. Writes BOTH halves — the ledger entry that makes the days real, and the annual_carry row the expiry job reads — so the balance and the expiry can never disagree. Recorded in Amendment records.';

-- ---------- 6. 自检 ----------
do $$
declare v char;
begin
  select provolatile into v from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'oil_cutoff_of';
  if v = 'i' then
    raise exception 'v37 FAILED: oil_cutoff_of is IMMUTABLE but reads current_date — the planner may freeze today''s date into a cached plan, and the expiry then silently does nothing on a pooled connection';
  end if;
  select provolatile into v from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'carry_cutoff_of';
  if v = 'i' then raise exception 'v37 FAILED: carry_cutoff_of is IMMUTABLE but reads current_date'; end if;

  -- 两个到期都必须写修订记录，否则「same will be recorded」就是句空话
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'expire_due_oil'
                and pg_get_functiondef(p.oid) not like '%log_expiry_amendment%') then
    raise exception 'v37 FAILED: off-in-lieu expiry does not write an amendment record';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
              where ns.nspname = 'public' and p.proname = 'expire_due_carry'
                and pg_get_functiondef(p.oid) not like '%log_expiry_amendment%') then
    raise exception 'v37 FAILED: carry-forward expiry does not write an amendment record';
  end if;
  raise notice 'v37 installed: both expiry dates work the same way, and every forfeit is recorded.';
end $$;

select 'v37 installed' as status,
       coalesce(to_char(oil_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'), 'never') as "Off-in-lieu expires",
       coalesce(to_char(carry_expiry_for(extract(year from current_date)::int), 'DD Mon YYYY'), 'never') as "Carried AL expires",
       (select count(*) from hr_amendments where kind = 'expiry') as "Forfeits recorded so far";


-- ===========================================================================
-- keepalive_ping_v3.sql
-- ===========================================================================

-- =============================================================
-- LeaveDesk SG — keep-alive ping v3 (WRITE-based, + carry-over expiry)
--
-- 背景（2026-08 事故）：
--   v1 的 keepalive_ping() 是 `stable` 函数，只跑 `select now()` —— 纯读。
--   定时任务每 2 天成功 ping 一次（7/13、15、17、19、21 全部 HTTP 200），
--   但项目仍然在 7/21–7/23 之间被自动暂停，HR 系统停摆约两周（7/23 → 8/5）。
--   Supabase 官方回信只说「7 天无活动即暂停」。
--   结论：**纯读请求不会重置 Supabase 的闲置计时器。**
--
-- v2 的做法：每次 ping 真正 **写入** 一行数据（UPDATE 一张单行心跳表）。
--   写操作会产生 WAL、改变数据库状态，是比读强得多的「活动」信号。
--
-- ⚠️ 诚实提醒：Supabase 没有公开「什么才算活动」的准确定义。
--   写入是目前最合理的推断，但**不是官方保证**。唯一有保证的方案是升级 Pro（US$25/月）。
--   如果两周内又被暂停，就说明免费版没有可靠的自救办法，只能升级。
--
-- 执行方式：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run（跑一次即可）
-- 幂等：可以重复执行，不会重复建表或丢数据。
--
-- 谁来定时调用它：**cron-job.org**（外部免费定时服务），每天一次：
--
--   POST https://<项目ref>.supabase.co/rest/v1/rpc/keepalive_ping?apikey=<anon key>
--   不需要任何 header，body 留空即可。
--
--   ⚠️ 把 apikey 放进 URL，不要放 header：很多定时服务的自定义 header 填不进去，
--      会报 {"message":"No API key found in request"}。PostgREST 同时接受
--      url param，实测无 header 也返回 200。
--      （anon key 本来就是公开的 —— 网站源码里就有 —— 放 URL 不增加任何暴露。）
--   ⚠️ 必须 POST：本函数是 volatile（会写），GET 会返回
--      405 "cannot execute UPDATE in a read-only transaction"。
--   ⚠️ 不要改用 GitHub Actions：仓库 60 天无提交就会被自动停用定时任务，
--      而「没在跑」不产生任何失败通知 —— 沉默和成功长得一模一样。
-- =============================================================

-- 1) 心跳表：永远只有一行（id = 1）。不含任何业务数据。
create table if not exists public.keepalive_heartbeat (
  id           smallint    primary key default 1,
  last_ping_at timestamptz not null default now(),
  ping_count   bigint      not null default 0,
  constraint keepalive_heartbeat_single_row check (id = 1)
);

comment on table public.keepalive_heartbeat is
  'Single-row heartbeat for the free-tier keep-alive workflow. Written once a day by keepalive_ping(). Contains no business data.';

-- 播种那唯一一行（已存在则不动）
insert into public.keepalive_heartbeat (id) values (1)
on conflict (id) do nothing;

-- 2) 锁死直接访问：开 RLS 且不建任何 policy ⇒ anon / authenticated 都碰不到这张表。
--    只有下面的 security definer 函数能写它。
alter table public.keepalive_heartbeat enable row level security;
revoke all on table public.keepalive_heartbeat from anon, authenticated;

-- 3) 把 keepalive_ping() 从「只读」换成「真写」。
--
--    返回值从 timestamptz 改成 bigint（累计 ping 次数）。这是刻意的：
--    v1 返回 now()，而两次独立的 HTTP 请求 = 两个事务 = 两个不同的时间戳，
--    所以「时间戳变了」根本证明不了写入发生过。
--    改成返回**持久化的计数器**后，连调两次必然是 N、N+1 —— 只有真的写进磁盘
--    才会递增。想确认心跳真的通了，就看这个数字有没有在涨：
--      select last_ping_at, ping_count from public.keepalive_heartbeat;
--
--    改返回类型必须先 drop（create or replace 不允许改返回类型）。
drop function if exists public.keepalive_ping();

create function public.keepalive_ping()
returns bigint
language plpgsql
volatile              -- 关键：v1 是 stable(只读)，v2 必须是 volatile(会写)
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  update public.keepalive_heartbeat
     set last_ping_at = now(),
         ping_count   = ping_count + 1
   where id = 1
  returning ping_count into v_count;

  -- v3：顺手把「已经过了到期日」的结转年假落成账本条目。
  -- 为什么挂在这里：这是全系统唯一一个**已经在每天跑**的东西。再加一个定时服务，
  -- 就是再加一个会安静停掉的东西（2026-07 的教训）。
  -- 就算这个 ping 停了也不会算错：leave_balances 本身就已经扣掉了到期未落账的天数，
  -- 所以余额校验永远是对的；这里只负责把它写进历史，让人看得见发生过什么。
  begin
    perform public.expire_due_carry();
  exception when undefined_function then
    -- v16 还没执行 —— 保活是保活，不该因为这个失败。
    null;
  end;

  -- v36：补休到期，同样落账。
  -- **这一段必须写在这里，不能只写在 migration_app_v36.sql 里。**
  -- install.sql 的顺序是「所有 migration，然后这个文件」，而这个文件开头是
  -- drop function + create function —— 它会把 v36 改好的 keepalive_ping 整个盖掉。
  -- 新装的库因此永远不会到期补休，而且一点声音都没有。
  -- （v36 里那一份还是要留着：已经跑过 v3 的旧库靠它升级。）
  begin
    perform public.expire_due_oil();
  exception when undefined_function then
    null;
  end;

  -- 万一那一行被人删了，自愈补回来
  if v_count is null then
    insert into public.keepalive_heartbeat (id, last_ping_at, ping_count)
    values (1, now(), 1)
    on conflict (id) do update
      set last_ping_at = now(),
          ping_count   = public.keepalive_heartbeat.ping_count + 1
    returning ping_count into v_count;
  end if;

  return v_count;
end;
$$;

comment on function public.keepalive_ping() is
  'Keep-alive heartbeat. Performs a real WRITE (updates keepalive_heartbeat) and returns the persisted ping counter. Exposes no business data.';

-- 允许未登录（anon）调用：它只写心跳表、只回一个计数，不碰任何业务数据。
grant execute on function public.keepalive_ping() to anon, authenticated;

-- =============================================================
-- 验证
--
-- ⚠️ Supabase SQL Editor 一次跑多条语句时，**只显示最后一条的结果**。
--    所以下面前两行的返回值你是看不到的 —— 这是正常的，不是出错。
--
-- ✅ 通过标准：最后一行显示 ping_count = 2（首次安装时）。
--    计数器能到 2，就说明两次调用各自都真的写进了磁盘并保留了下来 ——
--    只读的 v1 永远只会是 0，因为它根本没有表可写。
--
-- 想单独看返回值，就只选中这一行单独 Run（每跑一次数字 +1）：
--    select public.keepalive_ping();
-- =============================================================
select public.keepalive_ping() as ping_1;   -- 结果不会显示（见上）
select public.keepalive_ping() as ping_2;   -- 结果不会显示（见上）
select last_ping_at, ping_count from public.keepalive_heartbeat where id = 1;


-- ===========================================================================
-- undo_year_start.sql
-- ===========================================================================

-- ============================================================================
-- undo_year_start.sql — 把某一次「Start a new year」原样退回去
--
-- 为什么可以退：账本是**只追加**的。那一次运行只是写了新行，没有改写、没有删除
-- 任何旧行。year_start_log 又记下了它处理过哪些人、什么时候跑的（run_at）。
-- 所以那一批行是**可以精确圈出来**的：时间在 run_at 之后 + 人在名单里 +
-- 措辞是那次运行会写的那几种。三个条件同时满足才删。
--
-- ⚠️ 时间这一条不能省。用户 7 月发过 2026 年度配额，措辞正好也是
--    '2026 年度配额' —— 只按措辞删，会把 7 月那笔正常的发放一起删掉。
--    加上 created_at >= run_at，7 月那笔就永远碰不到。
--
-- 用法（先看，再做）：
--   select undo_year_start(2026);              -- 预览：只算不写
--   select undo_year_start(2026, false);       -- 确认无误后才真的退
--
-- 幂等：退过一次之后再跑，year_start_log 里已经没有那一年了，直接返回「无事可做」。
--
-- 措辞清单里既有 v35 之前的写法，也有 v35 之后的写法 —— 这个文件必须在两种库上都能用：
-- 要退的那一次运行是**升级之前**跑的，而升级本身要等退完了才做。
-- ============================================================================

create or replace function undo_year_start(p_year int, p_preview boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_run_at timestamptz;
  v_people int;
  v_rows   jsonb := '[]'::jsonb;
  v_ledger int := 0;
  v_carry  int := 0;
  v_days   numeric := 0;
  v_ids    bigint[];
  r record;
begin
  if not is_hr() and session_user <> 'postgres' then
    raise exception 'Only HR can undo a year start';
  end if;

  select min(run_at), count(*) into v_run_at, v_people
    from year_start_log where year = p_year;

  if v_run_at is null then
    return jsonb_build_object('year', p_year, 'found', false,
      'message', 'Nothing to undo — no year-start run is recorded for ' || p_year || '.');
  end if;

  -- 圈出那一次写的账本行。三个条件缺一不可。
  -- 用数组不用临时表：临时表在同一条语句里被调用两次会打出
  -- "relation _undo_rows already exists" 的 NOTICE —— 对不写代码的人来说，
  -- 那看着就像出错了。诊断信息必须只在真的出事时出现。
  select coalesce(array_agg(l.id), '{}')
    into v_ids
    from leave_ledger l
   where l.emp_id in (select emp_id from year_start_log where year = p_year)
     and l.created_at >= v_run_at - interval '5 seconds'   -- ← 保住 7 月那笔
     and (
          l.reason like (p_year - 1) || '%expired (unused)%'                       -- 其它假别清零
       or l.reason like (p_year - 1) || ' annual leave above the carry-over cap%'  -- 超上限作废
       or l.reason like '%carry-over expired (unused)%'                            -- 结转到期核销
       or l.reason like (p_year - 1) || ' annual leave closed%'                     -- v35：年假结清
       or l.reason like 'Carried forward from ' || (p_year - 1) || '%'              -- v35：结转入账
       or l.reason in (p_year || ' annual allowance', p_year || ' 年度配额')        -- 新年度发放
     );

  select count(*), coalesce(sum(delta_days), 0) into v_ledger, v_days
    from leave_ledger where id = any(v_ids);
  select count(*) into v_carry
    from annual_carry ac
   where ac.year = p_year
     and ac.granted_at >= v_run_at - interval '5 seconds'
     and ac.emp_id in (select emp_id from year_start_log where year = p_year);

  -- 每个人：删哪些行、余额从多少回到多少
  for r in
    select l.emp_id, e.name as emp_name,
           jsonb_agg(jsonb_build_object('type', l.leave_type, 'days', l.delta_days,
                                        'reason', l.reason) order by l.id) as rows,
           sum(l.delta_days) as net
      from leave_ledger l join employees e on e.id = l.emp_id
     where l.id = any(v_ids)
     group by l.emp_id, e.name order by e.name
  loop
    v_rows := v_rows || jsonb_build_object(
      'name', r.emp_name, 'removes', r.rows, 'net_change', -r.net);
  end loop;

  if p_preview then
    return jsonb_build_object(
      'year', p_year, 'found', true, 'preview', true,
      'run_at', v_run_at, 'people', v_people,
      'ledger_rows', v_ledger, 'carry_rows', v_carry, 'net_days_removed', v_days,
      'detail', v_rows,
      'message', 'PREVIEW ONLY — nothing has changed. Check the numbers, then run '
                 || 'select undo_year_start(' || p_year || ', false);');
  end if;

  delete from leave_ledger where id = any(v_ids);
  delete from annual_carry ac
   where ac.year = p_year
     and ac.granted_at >= v_run_at - interval '5 seconds'
     and ac.emp_id in (select emp_id from year_start_log where year = p_year);
  -- 日志最后删：万一上面出错，这一年还能再预览一次
  delete from year_start_log where year = p_year;

  return jsonb_build_object(
    'year', p_year, 'found', true, 'preview', false,
    'people', v_people, 'ledger_rows', v_ledger, 'carry_rows', v_carry,
    'net_days_removed', v_days, 'detail', v_rows,
    'message', 'Undone. ' || v_ledger || ' ledger row(s) and ' || v_carry
               || ' carry-forward record(s) removed; ' || p_year || ' is no longer started.');
end $$;

revoke execute on function undo_year_start(int, boolean) from anon, public;
grant  execute on function undo_year_start(int, boolean) to authenticated;

comment on function undo_year_start(int, boolean) is
  'Reverses one Start-a-new-year run. Previews by default. Only removes rows written at or after that run''s run_at, by the employees it logged, with the wordings it produces — so an ordinary allowance granted earlier in the same year is never touched.';

do $$
begin
  raise notice ' ';
  raise notice 'undo_year_start installed. To see what a run did, without changing anything:';
  raise notice '    select jsonb_pretty(undo_year_start(2026));';
  raise notice ' ';
end $$;


-- ============================================================================
--  Apply your settings, link your Owner account, and switch email on.
--  Reads the values you typed at the top of this file.
-- ============================================================================
do $$
declare c _leavedesk_setup%rowtype; n int; fn_url text;
begin
  select * into c from _leavedesk_setup;

  -- ---- 1. company settings -------------------------------------------------
  update org_settings set
    company_name        = coalesce(nullif(trim(c.company_name), ''), company_name),
    email_domain        = nullif(trim(c.email_domain), ''),
    default_annual_base = coalesce(c.default_annual_leave, default_annual_base),
    default_carry_cap   = coalesce(c.default_carry_cap, default_carry_cap)
  where id = 1;
  raise notice 'Company set to: %', c.company_name;

  -- ---- 2. link the Owner to the login you made in Authentication -----------
  -- The login itself is created in the dashboard (Authentication -> Add user).
  -- SQL cannot make one: it belongs to Supabase's own auth system.
  insert into employees (name, email, join_date, role, active, auth_user_id, dept, gender)
  select c.owner_name, lower(trim(c.owner_email)), current_date, 'admin', true, u.id,
         (select name from departments order by name limit 1), 'F'
    from auth.users u
   where lower(u.email) = lower(trim(c.owner_email))
     and not exists (select 1 from employees e where lower(e.email) = lower(trim(c.owner_email)));
  get diagnostics n = row_count;
  if n > 0 then
    raise notice 'Owner created and linked: %', c.owner_email;
  elsif exists (select 1 from employees where lower(email) = lower(trim(c.owner_email))) then
    raise notice 'Owner already existed: %', c.owner_email;
  else
    raise warning 'NO LOGIN FOUND for %. Create it first: Authentication -> Add user (tick Auto Confirm User), then run just this last section again.', c.owner_email;
  end if;

  -- ---- 3. email notifications ---------------------------------------------
  -- Nothing to do here on purpose. The trigger already exists (v32) and stays
  -- quiet until it has an address. The app writes that address itself the first
  -- time an HR/Owner signs in, from the values already in app.html -- so there
  -- is nothing for anybody to copy across.
  raise notice 'Email notifications will switch on by themselves when you first sign in as HR.';
end $$;

drop table if exists _leavedesk_setup;

-- ============================================================================
--  Done.
-- ============================================================================
do $$
begin
  raise notice ' ';
  raise notice 'LeaveDesk installed. Next: deploy the two Edge Functions, then point';
  raise notice 'app.html at this project (two lines near the top).';
  raise notice ' ';
end $$;
