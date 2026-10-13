-- ============================================================================
-- The screenshot: sick 13 / 14 / 27, hospitalisation 57 / 59 / 117, shared
-- parental 42 / 70 / 140 — all in the same company, on the same day.
--
-- One cause. Somebody added through **Add employee** is credited
-- "Leave allowance on joining" at whatever the leave type said ON THE DAY THEY
-- JOINED. Nothing recognises that wording as the year's allowance, so:
--   · the yearly grant credits them a SECOND time  -> the doubled figures
--   · every change to a leave type since leaves a new stratum behind
--
-- Three intakes, with the leave types edited between them, is enough to
-- reproduce every column in that screenshot.
-- ============================================================================
insert into departments (name) values ('Ops') on conflict do nothing;

insert into auth.users (id, email) values
 ('33333333-0000-0000-0000-000000000009','hr3@x.com'),
 ('33333333-0000-0000-0000-000000000001','early@x.com'),
 ('33333333-0000-0000-0000-000000000002','mid@x.com'),
 ('33333333-0000-0000-0000-000000000003','late@x.com'),
 ('33333333-0000-0000-0000-000000000004','twice@x.com');

insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1) values
 ('e0000000-0000-0000-0000-000000000009','Hilda HR','hr3@x.com','Ops','F','hr','2020-01-01',14,5,true,false,'33333333-0000-0000-0000-000000000009',null),
 -- Granted by the yearly run in July, at the figures in force then.
 ('e0000000-0000-0000-0000-000000000001','Early','early@x.com','Ops','F','employee','2022-01-01',14,5,true,false,'33333333-0000-0000-0000-000000000001','e0000000-0000-0000-0000-000000000009'),
 -- Joined after the shared-parental figure was raised, before sick and hosp were.
 ('e0000000-0000-0000-0000-000000000002','Mid','mid@x.com','Ops','F','employee','2026-07-20',14,5,true,false,'33333333-0000-0000-0000-000000000002','e0000000-0000-0000-0000-000000000009'),
 -- Joined after all three were raised.
 ('e0000000-0000-0000-0000-000000000003','Late','late@x.com','Ops','F','employee','2026-08-15',14,5,true,false,'33333333-0000-0000-0000-000000000003','e0000000-0000-0000-0000-000000000009'),
 -- Joined AND was caught by a later yearly grant run: credited twice.
 ('e0000000-0000-0000-0000-000000000004','Twice','twice@x.com','Ops','F','employee','2026-07-20',14,5,true,false,'33333333-0000-0000-0000-000000000004','e0000000-0000-0000-0000-000000000009');

-- ---- July: the yearly run, at sick 13 / hosp 57 / shared parental 42 ----
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at) values
 ('e0000000-0000-0000-0000-000000000009','sick',            13, '2026 annual allowance', '2026-07-09 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000009','hosp',            57, '2026 annual allowance', '2026-07-09 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000009','shared_parental', 42, '2026 annual allowance', '2026-07-09 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000001','sick',            13, '2026 annual allowance', '2026-07-09 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000001','hosp',            57, '2026 annual allowance', '2026-07-09 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000001','shared_parental', 42, '2026 annual allowance', '2026-07-09 02:00:00+00');

-- ---- 20 July: shared parental raised to 70. Mid and Twice join that day. ----
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at) values
 ('e0000000-0000-0000-0000-000000000002','sick',            13, 'Leave allowance on joining', '2026-07-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000002','hosp',            57, 'Leave allowance on joining', '2026-07-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000002','shared_parental', 70, 'Leave allowance on joining', '2026-07-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000004','sick',            13, 'Leave allowance on joining', '2026-07-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000004','hosp',            57, 'Leave allowance on joining', '2026-07-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000004','shared_parental', 70, 'Leave allowance on joining', '2026-07-20 02:00:00+00');

-- ---- 15 Aug: sick raised to 14, hosp to 59. Late joins that day. ----
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at) values
 ('e0000000-0000-0000-0000-000000000003','sick',            14, 'Leave allowance on joining', '2026-08-15 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000003','hosp',            59, 'Leave allowance on joining', '2026-08-15 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000003','shared_parental', 70, 'Leave allowance on joining', '2026-08-15 02:00:00+00');

-- ---- The doubling: a later grant run does not recognise a joining credit ----
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at) values
 ('e0000000-0000-0000-0000-000000000004','sick',            14, '2026 annual allowance', '2026-08-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000004','hosp',            60, '2026 annual allowance', '2026-08-20 02:00:00+00'),
 ('e0000000-0000-0000-0000-000000000004','shared_parental', 70, '2026 annual allowance', '2026-08-20 02:00:00+00');

-- Where the leave types stand today.
update leave_types set default_days = 14 where code = 'sick';
update leave_types set default_days = 59 where code = 'hosp';
update leave_types set default_days = 70 where code = 'shared_parental';
