-- ============================================================================
-- A company with REAL history — the fixture the reported case cannot provide.
--
-- Every row in seed_reported_case.sql sits in one year, so "the year named in the
-- wording" and "the year it was typed in" always agree there, and a migration that
-- got the year wrong would look identical to one that got it right. Nothing can be
-- proved on data that cannot tell the two apart.
--
-- This one has a 2025 that really happened:
--   · 2025 allowances, granted in January 2025
--   · two days of December 2025 leave, KEYED IN on 6 January 2026 — the entry whose
--     leave year and typing year disagree
--   · a January 2026 year start: 2025 written off, 5 days carried, 7 forfeited
--   · the carry expiring on 30 June 2026, written off in July 2026 — a write-off
--     that belongs to the CURRENT year, so misreading it as entitlement shows up
--
-- Load this into a pre-v35 database, then run migration_app_v35.sql against it.
-- ============================================================================
insert into departments (name) values ('Ops') on conflict do nothing;

insert into auth.users (id, email) values
 ('22222222-0000-0000-0000-000000000001','cara@x.com'),
 ('22222222-0000-0000-0000-000000000009','hr2@x.com');

insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1) values
 ('c0000000-0000-0000-0000-000000000009','Hana HR','hr2@x.com','Ops','F','hr','2020-01-01',14,5,true,false,'22222222-0000-0000-0000-000000000009',null),
 ('c0000000-0000-0000-0000-000000000001','Cara','cara@x.com','Ops','F','employee','2022-01-01',14,5,true,false,'22222222-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000009');

-- ---- 2025: the year's allowances, granted in January 2025 ----
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, lt.code, lt.default_days, '2025 annual allowance', '2025-01-02 02:00:00+00'::timestamptz
  from employees e cross join leave_types lt
 where lt.code in ('annual','sick','hosp')
   and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender);

-- ---- December 2025 leave, keyed in on 6 January 2026 ----
-- This is the whole point of the fixture. The days come out of 2025's allowance;
-- the entry was typed in 2026. Anything that reads the year off created_at gets
-- this one wrong, and gets it wrong silently.
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('d0000000-0000-0000-0000-00000000000a','c0000000-0000-0000-0000-000000000001','annual',
        '2025-12-22','2025-12-23', 2, 'approved', 'keyed in late');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values ('c0000000-0000-0000-0000-000000000001','annual', -2, 'Leave taken',
        'd0000000-0000-0000-0000-00000000000a', '2026-01-06 02:00:00+00'::timestamptz);

-- ---- January 2026: the year start, as the pre-v35 code wrote it ----
-- Other types cleared to zero, worded with the year that is ENDING (2025) but
-- written on 2 January 2026.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, lt.code, -lt.default_days,
       '2025 ' || lt.name_en || ' expired (unused)', '2026-01-02 03:00:00+00'::timestamptz
  from employees e cross join leave_types lt
 where lt.code in ('sick','hosp');

-- Annual: 14 granted − 2 taken = 12 left, cap 5, so 7 forfeited and 5 carried.
-- Before v35 the carried days were never a ledger entry — they simply stayed in
-- the balance — so only the forfeit is written here. That is deliberate: this
-- fixture must look like the OLD system, not the new one.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
values ('c0000000-0000-0000-0000-000000000001','annual', -7,
        '2025 annual leave above the carry-over cap (5.0) — forfeited',
        '2026-01-02 03:00:00+00'::timestamptz),
       ('c0000000-0000-0000-0000-000000000009','annual', -9,
        '2025 annual leave above the carry-over cap (5.0) — forfeited',
        '2026-01-02 03:00:00+00'::timestamptz);
insert into annual_carry (emp_id, year, carry_in, expires_on, granted_at) values
 ('c0000000-0000-0000-0000-000000000001', 2026, 5, '2026-06-30', '2026-01-02 03:00:00+00'),
 ('c0000000-0000-0000-0000-000000000009', 2026, 5, '2026-06-30', '2026-01-02 03:00:00+00');

-- ---- 2026's allowances ----
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, lt.code, lt.default_days, '2026 annual allowance', '2026-01-02 04:00:00+00'::timestamptz
  from employees e cross join leave_types lt
 where lt.code in ('annual','sick','hosp')
   and (lt.gender_eligibility is null or lt.gender_eligibility = e.gender);

-- ---- 1 July 2026: the carried days hit their expiry date unused ----
-- A write-off worded with, and belonging to, the CURRENT year. Read as entitlement
-- by mistake, it silently takes 5 days off everybody's 2026 figure.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
select e.id, 'annual', -5, '2026 carry-over expired (unused)', '2026-07-01 02:00:00+00'::timestamptz
  from employees e;
update annual_carry set expired_days = 5, expired_at = '2026-07-01 02:00:00+00' where year = 2026;
