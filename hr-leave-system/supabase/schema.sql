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
  title         text,                             -- 职位 / job title（可空）
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
  sort                int not null default 99,
  note                text
);

-- 天数按 MOM 现行政策(mom.gov.sg,2026-07 核对);注释英文(界面直接展示)
insert into leave_types (code,name_zh,name_en,requires_attachment,gender_eligibility,no_deduct,default_days,carry_over_cap,sort,note) values
 ('annual','年假','Annual Leave',false,null,false,14,7,1,'Statutory minimum: 7 days in year 1, +1 per year up to 14. Company base is configurable per employee.'),
 ('sick','病假（门诊）','Sick Leave',true,null,false,14,null,2,'Outpatient. Eligible after 3 months of service (MOM).'),
 ('hosp','住院假','Hospitalisation Leave',true,null,false,60,null,3,'MOM: 60 days per year, inclusive of the 14 outpatient sick-leave days.'),
 ('childcare','育儿假','Childcare Leave',false,null,false,6,null,4,'Child under 7 and a SG citizen: 6 days/parent/year. Extended childcare: +2 days if the child is 7-12.'),
 ('oil','补休','Off-in-Lieu',false,null,false,0,null,5,'Credited via Ledger & adjustments when someone works overtime or on a public holiday.'),
 ('maternity','产假','Maternity Leave',false,'F',false,112,null,6,'16 weeks (Government-Paid Maternity Leave).'),
 ('paternity','陪产假','Paternity Leave',false,'M',false,28,null,7,'4 weeks (Government-Paid Paternity Leave), mandatory for children born on/after 1 Apr 2025.'),
 ('shared_parental','共享育儿假','Shared Parental Leave',false,null,false,70,null,8,'10-week shared pool for child born on/after 1 Apr 2026 (6 weeks if born 1 Apr 2025 - 31 Mar 2026)'),
 ('infant','无薪婴儿照顾假','Unpaid Infant Care',false,null,false,6,null,9,'Unpaid. Child under 2: 6 days per parent per year.'),
 ('adoption','领养假','Adoption Leave',false,'F',false,84,null,10,'12 weeks (Government-Paid Adoption Leave).'),
 ('compassionate','恩恤假','Compassionate Leave',false,null,false,3,null,11,'Company benefit - not required by law.'),
 ('marriage','婚假','Marriage Leave',false,null,false,3,null,12,'Company benefit - not required by law.'),
 ('ns','战备军人假','NS / Reservist',false,'M',true,0,null,13,'Statutory for NSmen. Recorded only - no quota deduction.'),
 ('unpaid','无薪假','Unpaid Leave',false,null,true,0,null,14,'Recorded only - no quota deduction.')
on conflict (code) do nothing;

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

-- ---------- 9. 身份辅助函数 ----------
create or replace function current_emp_id() returns uuid
language sql stable security definer set search_path = public as
$$ select id from employees where auth_user_id = auth.uid() $$;

create or replace function is_hr() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from employees
                  where auth_user_id = auth.uid() and role in ('hr','admin')) $$;

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

-- ---------- 11. 状态机存储过程（前端只能调这些，不能直写表） ----------

-- 提交申请（也用于退回后的重新提交：传 p_resubmit_id）
create or replace function submit_application(
  p_type text, p_start date, p_end date, p_sh boolean, p_eh boolean,
  p_reason text, p_attachment text default null, p_resubmit_id uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare me employees%rowtype; t leave_types%rowtype; d numeric; app_id uuid; avail numeric;
begin
  select * into me from employees where auth_user_id = auth.uid() and active;
  if me.id is null then raise exception '未找到员工档案'; end if;
  select * into t from leave_types where code = p_type;
  if t.code is null then raise exception '假期类型不存在'; end if;
  if t.gender_eligibility is not null and t.gender_eligibility <> me.gender then
    raise exception '不符合该假期的资格条件'; end if;
  if t.requires_attachment and p_attachment is null then
    raise exception '该假期类型必须上传证明（MC）'; end if;
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
    -- 无审批人（Managing Director）：提交即自动批准、记账，事件流通知 HR 备案
    update applications set status='approved', updated_at=now() where id=app_id;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (me.id, p_type, -d, '请假扣减', app_id, me.id);
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
    and not (o.end_date < a.start_date or o.start_date > a.end_date);
$$;

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
  if not allowed then raise exception '无权查看该员工余额'; end if;
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
  select * into a from applications where id = p_app for update;
  if a.id is null or a.status <> 'pending' then raise exception '申请不在待审批状态'; end if;
  select * into s from approval_steps
    where application_id = p_app and step_order = a.current_step;
  if s.approver_id <> me_id then raise exception '你不是当前节点的审批人'; end if;
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

-- 员工撤回（仅 pending）
create or replace function withdraw_application(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id();
begin
  update applications set status='withdrawn', updated_at=now()
    where id=p_app and emp_id=me_id and status='pending';
  if not found then raise exception '只能撤回待审批的本人申请'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'withdrawn');
end $$;

-- 销假：员工发起 → 第 1 级审批人确认（返还账本）或驳回
create or replace function request_cancel(p_app uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id();
begin
  update applications set status='cancel_requested', updated_at=now()
    where id=p_app and emp_id=me_id and status='approved' and start_date > current_date;
  if not found then raise exception '只能对未开始的已批准请假申请销假'; end if;
  insert into application_events (application_id,actor,action) values (p_app, me_id, 'cancel_requested');
end $$;

create or replace function confirm_cancel(p_app uuid, p_ok boolean, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me_id uuid := current_emp_id(); a applications%rowtype; t leave_types%rowtype;
begin
  select * into a from applications where id=p_app for update;
  if a.status <> 'cancel_requested' then raise exception '申请不在销假确认状态'; end if;
  if not exists (select 1 from approval_steps
                 where application_id=p_app and step_order=1 and approver_id=me_id)
     and not is_hr() then raise exception '只有第 1 级审批人或 HR 能确认销假'; end if;
  select * into t from leave_types where code=a.leave_type;
  if p_ok then
    update applications set status='cancelled', updated_at=now() where id=p_app;
    if not t.no_deduct then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_by)
      values (a.emp_id, a.leave_type, a.days, '销假返还', p_app, me_id);
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

-- 员工名录/假期类型/公共假期：登录即可读（显示姓名、下拉选项需要）
create policy emp_read   on employees          for select to authenticated using (true);
create policy lt_read    on leave_types        for select to authenticated using (true);
create policy ph_read    on public_holidays    for select to authenticated using (true);
-- 员工档案与配置：只有 HR 能改
create policy emp_write  on employees for all to authenticated
  using (is_hr()) with check (is_hr());
create policy lt_write   on leave_types for all to authenticated
  using (is_hr()) with check (is_hr());
create policy ph_write   on public_holidays for all to authenticated
  using (is_hr()) with check (is_hr());

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
      then ceil(e.annual_base * (12 - extract(month from e.join_date) + 1) / 12 * 2) / 2
    else e.annual_base + greatest(0, p_year - extract(year from e.join_date) - 1)
  end
  from employees e where e.id = p_emp;
$$;

create or replace function grant_annual_entitlements(p_year int)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; amt numeric;
begin
  if auth.uid() is not null and not is_hr() then raise exception '只有 HR 能执行年度入账'; end if;
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

-- ---------- 14. 全员请假日历（只暴露 姓名/部门/日期/状态，全公司可读） ----------
create or replace view leave_calendar as
select e.name, e.dept, a.start_date, a.end_date,
       case when a.status = 'pending' then 'pending' else 'approved' end as status
from applications a join employees e on e.id = a.emp_id
where a.status in ('pending','approved','cancel_requested') and e.active;
grant select on leave_calendar to authenticated;

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
declare me_id uuid := current_emp_id(); r record; remaining numeric;
begin
  if not is_hr() then raise exception '只有 HR 能执行离职结算'; end if;
  if p_mode not in ('encash','clear') then raise exception 'mode 必须是 encash 或 clear'; end if;
  if p_emp = me_id then raise exception '不能对自己执行离职结算'; end if;

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

  update employees set active=false, last_working_day=p_last_day where id=p_emp;
end $$;

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
create policy dept_read  on departments for select to authenticated using (true);
create policy dept_write on departments for all    to authenticated
  using (is_hr()) with check (is_hr());

-- ---------- 19. 公司设置：系统可被任何小公司复用，公司信息是数据不是代码 ----------
create table if not exists org_settings (
  id           int primary key default 1 check (id = 1),  -- 单行表
  company_name text not null default 'My Company',
  email_domain text,
  country      text not null default 'Singapore',
  default_annual_base numeric(5,1) not null default 14    -- Add employee 表单的年假基数默认值
);
insert into org_settings (id, company_name, email_domain)
values (1, 'Shanghai Uniforms', 'shanghai-uniforms.com')
on conflict (id) do nothing;

alter table org_settings enable row level security;
drop policy if exists org_read  on org_settings;
drop policy if exists org_write on org_settings;
create policy org_read  on org_settings for select to authenticated using (true);
create policy org_write on org_settings for update to authenticated
  using (is_hr()) with check (is_hr());
