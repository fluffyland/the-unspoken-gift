-- Four faults, one of each shape the report is meant to name. Loaded on top of
-- seed_lifecycle.sql. Nothing here is subtle: the point is that a report which
-- cannot tell these four apart from a healthy company is not worth running.
--
--   1. a row belonging to a PREVIOUS year that nobody ever wrote off
--      -> the balance on screen is bigger than this year's arithmetic
--   2. a leave type retyped to 65 while people still hold 70
--      -> "i set 65 why still 70 come out"
--   3. a carry-forward written as a carry ROW with no ledger half
--      -> the screen promises days that cannot be booked
--   4. an eligible person holding no allowance at all for a type
--      -> figures that agree with each other and are still wrong

-- 1 ------------------------------------------------------------------
insert into leave_ledger (emp_id, leave_type, delta_days, reason, leave_year, kind, created_at)
select id, 'annual', 5, '2025 annual allowance', 2025, 'grant', '2025-01-02'
  from employees where name = 'Boss';

-- 2 ------------------------------------------------------------------
-- Everybody was granted 70 by the seed. Retype the leave type to 65 WITHOUT
-- levelling anyone, which is the state the report has to be able to see.
update leave_types set default_days = 65 where code = 'shared_parental';
insert into leave_ledger (emp_id, leave_type, delta_days, reason, leave_year, kind)
select id, 'shared_parental', -5, '2026 Shared Parental Leave set to 65', 2026, 'adjust'
  from employees where name = 'Male';

-- 3 ------------------------------------------------------------------
insert into annual_carry (emp_id, year, carry_in, expires_on)
select id, extract(year from current_date)::int, 5,
       (extract(year from current_date)::int || '-12-31')::date
  from employees where name = 'Nogender'
    on conflict (emp_id, year) do update set carry_in = 5;

-- 4 ------------------------------------------------------------------
delete from leave_ledger l
 using employees e
 where l.emp_id = e.id and e.name = 'Fem' and l.leave_type = 'compassionate';
