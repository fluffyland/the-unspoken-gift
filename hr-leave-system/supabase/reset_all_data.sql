-- LeaveDesk SG — 全量清空业务数据（保留表结构 / 权限 / 假期类型 / 公共假期）
-- 用途：把「当前这个 Supabase 项目」交给新公司复用，而不是新开项目。
-- ⚠ 不可逆：删除所有员工、登录账号、申请、账目、公告、结转。执行前请确认。
--   （若想更干净、零残留，建议直接删掉整个 Supabase 项目再新建，见 NEW_COMPANY_SETUP.md 方案 A。）
--
-- 保留：leave_types（SG 法定假期类型）、public_holidays（公共假期）、org_settings（公司设置，见文末可选重置）。
-- 清空：所有人事与请假数据 + 所有登录账号。

begin;

-- 1) 请假业务数据（子表在前，避免外键报错）
truncate table application_events,
               approval_steps,
               applications,
               leave_ledger,
               annual_carry,
               announcement_reads,
               announcements
  restart identity cascade;

-- 2) 员工与部门（员工含自引用审批人，一次性整表删除即可）
delete from employees;
delete from departments;

-- 3) 所有登录账号（Supabase Auth）
delete from auth.users;

commit;

-- 可选：把公司设置改成新公司（也可以清空后直接在应用 HR Console → Company settings 里改）。
update org_settings set
  company_name        = 'New Company Pte Ltd',
  email_domain        = 'newco.com',
  default_annual_base = 14,
  prorate_cap         = null
where id = 1;

-- 校验：以下都应为 0
select
  (select count(*) from employees)   as employees,
  (select count(*) from applications) as applications,
  (select count(*) from leave_ledger) as ledger,
  (select count(*) from auth.users)   as logins;
