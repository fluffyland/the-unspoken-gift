-- ============================================================================
-- The state the user reported, rebuilt from scratch:
--   · the company's 2026 allowances were granted in JULY 2026 (not at a year start)
--   · a few company-wide annual bumps followed in August
--   · one person joined in August, after that grant
--   · there is NO 2025 data at all — the system was only started in 2026
-- ============================================================================
insert into departments (name) values ('Ops') on conflict do nothing;

insert into auth.users (id, email) values
 ('11111111-0000-0000-0000-000000000001','barry@x.com'),
 ('11111111-0000-0000-0000-000000000002','bel@x.com'),
 ('11111111-0000-0000-0000-000000000003','barbie@x.com'),
 ('11111111-0000-0000-0000-000000000004','newbie@x.com'),
 ('11111111-0000-0000-0000-000000000009','hr@x.com');

insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1) values
 ('a0000000-0000-0000-0000-000000000009','Hilda HR','hr@x.com','Ops','F','hr','2020-01-01',14,5,true,false,'11111111-0000-0000-0000-000000000009',null),
 ('a0000000-0000-0000-0000-000000000001','Barry','barry@x.com','Ops','M','employee','2022-01-01',17.5,5,true,false,'11111111-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000009'),
 ('a0000000-0000-0000-0000-000000000002','Belinda','bel@x.com','Ops','F','employee','2022-01-01',19,5,true,false,'11111111-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000009'),
 ('a0000000-0000-0000-0000-000000000003','Barbie','barbie@x.com','Ops','F','employee','2024-01-01',14,5,true,false,'11111111-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000009'),
 ('a0000000-0000-0000-0000-000000000004','Newbie','newbie@x.com','Ops','F','employee','2026-08-01',14,5,true,false,'11111111-0000-0000-0000-000000000004','a0000000-0000-0000-0000-000000000009');

-- July 2026: every allowance for everyone who was here then. Exactly the rows
-- grant_annual_entitlements writes, with its wording and a July timestamp.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, lt.code,
       case when lt.code = 'annual' then e.annual_base else lt.default_days end,
       '2026 年度配额', '2026-07-09 02:00:00+00'::timestamptz
  from employees e cross join leave_types lt
 where e.join_date < '2026-07-09'
   and lt.code <> 'oil' and (lt.default_days > 0 or lt.code = 'annual')
   and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender);

-- August 2026: the company-wide annual bumps (+3.5 for two people).
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, 'annual', d.days,
       '2026 annual leave +' || fmt_days(d.days) || ' — company-wide',
       '2026-08-28 02:00:00+00'::timestamptz
  from employees e cross join (values (1),(1),(1),(0.5)) as d(days)
 where e.name in ('Barry','Belinda');
update employees set annual_base = annual_base + 3.5 where name in ('Barry','Belinda');
