-- ============================================================================
-- R. A carry-forward has two halves and both must be written.
--
--   annual_carry row  — what the screen shows and the expiry job reads
--   ledger carry_in   — the days you can actually book
--
-- Write one without the other and the screen advertises days the balance does not
-- have. That is the reported "carried forward is 2 days when I credited 5":
-- Available 11 (= 14 entitled − 3 taken, no carry) with "Carry Forward: 2"
-- (= 5 recorded − 3 taken) sitting next to it.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;
create or replace function eid(p text) returns uuid language sql stable as $$
  select id from employees where name = p $$;
create or replace function av(p text) returns numeric language sql stable as $$
  select coalesce((select available from leave_balances
                   where emp_id = eid(p) and leave_type = 'annual'), 0) $$;

-- 14 entitled, 5 carried, 3 taken.
select credit_carry_forward(eid('Fem'), 5);
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('a2000000-0000-0000-0000-0000000000e1', eid('Fem'), 'annual', '2026-02-09','2026-02-11', 3, 'approved','x');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values (eid('Fem'), 'annual', -3, 'Leave taken', 'a2000000-0000-0000-0000-0000000000e1', '2026-02-09');

do $$ begin raise notice ' '; raise notice '=== A. written properly, both halves ==='; end $$;
select ck('R1 credit_carry_forward writes both halves', av('Fem'), 16::numeric);
select ck('R2 so the health check is happy',
          (select count(*)::int from carry_health_check() where "Verdict" <> 'ok'), 0);

do $$ begin raise notice ' '; raise notice '=== B. only the annual_carry half — the reported shape ==='; end $$;
delete from leave_ledger where emp_id = eid('Fem') and leave_type = 'annual' and kind = 'carry_in';
select ck('R3 the balance drops to entitled minus taken', av('Fem'), 11::numeric);
select ck('R4 while the Carry Forward line still records 5',
          (select carry_in from annual_carry where emp_id = eid('Fem')
            and year = extract(year from current_date)::int), 5::numeric);
select ck('R5 the health check names the person and the gap',
          (select "Difference" from carry_health_check() where "Employee" = 'Fem'), 5::numeric);
select ck('R6 and says what to do about it',
          (select "Verdict" like '%repair_carry_ledger%' from carry_health_check()
            where "Employee" = 'Fem'), true);

do $$ begin raise notice ' '; raise notice '=== C. the repair ==='; end $$;
select ck('R7 the preview reports the days without writing them',
          (select "Days added back" from repair_carry_ledger() where "Employee" = 'Fem'), 5::numeric);
select ck('R8 nothing was written', av('Fem'), 11::numeric);
select ck('R9 running it for real gives the days back',
          (select "Done" from repair_carry_ledger(false) where "Employee" = 'Fem'), true);
select ck('R10 and the balance is right again', av('Fem'), 16::numeric);
select ck('R11 the repair is recorded, not silent',
          (select count(*)::int from hr_amendments
            where kind = 'carry_credit' and reason like '%repaired%'), 1);
select ck('R12 running it again does nothing',
          (select count(*)::int from repair_carry_ledger(false)), 0);
select ck('R13 everyone is healthy',
          (select count(*)::int from carry_health_check() where "Verdict" <> 'ok'), 0);

do $$ begin raise notice ' '; raise notice '=== D. it never takes days away ==='; end $$;
-- Ledger holding MORE than annual_carry could be a deliberate manual credit.
-- Removing days needs a person to decide, so the repair leaves it alone.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, leave_year, kind)
values (eid('Fem'), 'annual', 2, 'Carried forward from 2025 (extra, added by hand)',
        extract(year from current_date)::int, 'carry_in');
select ck('R14 the ledger now holds more than the record', av('Fem'), 18::numeric);
select ck('R15 the repair does not claw it back',
          (select count(*)::int from repair_carry_ledger(false) where "Employee" = 'Fem'), 0);
select ck('R16 the days are still there', av('Fem'), 18::numeric);

do $$ begin raise notice ' '; raise notice 'ALL t39 ASSERTIONS PASSED'; end $$;
