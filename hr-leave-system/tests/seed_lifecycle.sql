-- ============================================================================
-- A company with every awkward kind of employee in it, so that "check every
-- leave and every employee" means something:
--   Fem      — female, here all year
--   Male     — male, here all year
--   Nogender — gender never recorded. Gendered leave types compare
--              gender_eligibility = e.gender, and 'F' = NULL is NULL, not false,
--              so this person is silently outside every gendered rule.
--   Joiner   — added mid-year through Add employee, credited "on joining"
--   Gone     — left the company; frozen, and must stay out of every total
--   Boss     — HR, and everybody's approver
-- ============================================================================
insert into departments (name) values ('Ops') on conflict do nothing;

insert into auth.users (id, email) values
 ('44444444-0000-0000-0000-000000000009','boss@x.com'),
 ('44444444-0000-0000-0000-000000000001','fem@x.com'),
 ('44444444-0000-0000-0000-000000000002','male@x.com'),
 ('44444444-0000-0000-0000-000000000003','nogender@x.com'),
 ('44444444-0000-0000-0000-000000000004','joiner@x.com'),
 ('44444444-0000-0000-0000-000000000005','gone@x.com');

insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1) values
 ('f0000000-0000-0000-0000-000000000009','Boss','boss@x.com','Ops','F','hr','2020-01-01',14,5,true,false,'44444444-0000-0000-0000-000000000009',null),
 ('f0000000-0000-0000-0000-000000000001','Fem','fem@x.com','Ops','F','employee','2022-01-01',14,5,true,false,'44444444-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000009'),
 ('f0000000-0000-0000-0000-000000000002','Male','male@x.com','Ops','M','employee','2022-01-01',14,5,true,false,'44444444-0000-0000-0000-000000000002','f0000000-0000-0000-0000-000000000009'),
 ('f0000000-0000-0000-0000-000000000003','Nogender','nogender@x.com','Ops',null,'employee','2022-01-01',14,5,true,false,'44444444-0000-0000-0000-000000000003','f0000000-0000-0000-0000-000000000009'),
 ('f0000000-0000-0000-0000-000000000005','Gone','gone@x.com','Ops','M','employee','2022-01-01',14,5,true,false,'44444444-0000-0000-0000-000000000005','f0000000-0000-0000-0000-000000000009');
-- Gone is created ACTIVE so the January run below can credit them the way it
-- really did, then switched off afterwards. A leaver's ledger is frozen by a
-- trigger, so seeding them as inactive fails -- and it fails by aborting the
-- statement that credits EVERYBODY, which is a fine way to test nothing at all.

-- The yearly run, in January, for everybody who was here then.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, lt.code,
       case when lt.code = 'annual' then e.annual_base else lt.default_days end,
       '2026 annual allowance', '2026-01-02 02:00:00+00'::timestamptz
  from employees e cross join leave_types lt
 where lt.code <> 'oil' and (lt.default_days > 0 or lt.code = 'annual')
   and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender);

-- Joiner arrives in July and is credited by Add employee, at the figures in
-- force that day. Inserted after the run above so nothing grants them twice.
insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1)
values ('f0000000-0000-0000-0000-000000000004','Joiner','joiner@x.com','Ops','F','employee','2026-07-01',14,5,true,false,'44444444-0000-0000-0000-000000000004','f0000000-0000-0000-0000-000000000009');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select 'f0000000-0000-0000-0000-000000000004', lt.code,
       case when lt.code = 'annual' then 14 else lt.default_days end,
       case when lt.code = 'annual' then 'Annual leave allowance on joining' else 'Leave allowance on joining' end,
       '2026-07-01 02:00:00+00'::timestamptz
  from leave_types lt
 where lt.code <> 'oil' and not lt.no_deduct and (lt.default_days > 0 or lt.code = 'annual')
   and (lt.gender_eligibility is null or lt.gender_eligibility = 'F');

-- ...and now they leave.
update employees set active = false where name = 'Gone';

-- ---- Off-in-lieu, earned at different times of the year (for t36) ----
-- Fem: 2 days earned before 31 January, 2 more after it, 1 taken in April.
-- April on purpose: the lifecycle test walks Fem through every leave type in
-- consecutive weeks from 5 January, and one application per person may not overlap
-- another. A date inside that run makes the OTHER suite fail, for a reason that has
-- nothing to do with what either is testing.
-- Male: 2 days, both earned before 31 January and none after.
-- The dates matter: they are what tells "forfeit the lot" apart from
-- "forfeit only last year's".
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at) values
 ('f0000000-0000-0000-0000-000000000001','oil', 2, 'Off-in-lieu earned', '2026-01-10 02:00:00+00'),
 ('f0000000-0000-0000-0000-000000000001','oil', 2, 'Off-in-lieu earned', '2026-02-10 02:00:00+00'),
 ('f0000000-0000-0000-0000-000000000002','oil', 2, 'Off-in-lieu earned', '2026-01-10 02:00:00+00');
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('c0000000-0000-0000-0000-0000000000b1','f0000000-0000-0000-0000-000000000001','oil',
        '2026-04-20','2026-04-20', 1, 'approved', 'oil day');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values ('f0000000-0000-0000-0000-000000000001','oil', -1, 'Leave taken',
        'c0000000-0000-0000-0000-0000000000b1', '2026-04-20 02:00:00+00');
