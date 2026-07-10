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
