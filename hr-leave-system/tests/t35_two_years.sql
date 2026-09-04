-- ============================================================================
-- G. An upgrade on a company that has a real previous year.
--
-- seed_two_years.sql is loaded into a pre-v35 database and migration_app_v35.sql
-- is run against it. These assertions say the backfill read the history correctly
-- — and, unlike the reported case, this data can actually tell a right answer from
-- a wrong one, because the year an entry belongs to and the year it was typed in
-- disagree in three places.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;

-- The migration must not have moved a single day. _pre was captured before it ran.
select ck('G1 the upgrade moved nobody''s balance',
          (select count(*)::int from _pre s join leave_balances b
             on b.emp_id = s.emp_id and b.leave_type = s.leave_type
            where b.balance is distinct from s.balance), 0);

-- The December leave keyed in January. This is the entry the old code filed wrong.
select ck('G2 December 2025 leave keyed in January 2026 belongs to 2025',
          (select leave_year from leave_ledger
            where ref_application = 'd0000000-0000-0000-0000-00000000000a'), 2025);
select ck('G3 and it counts as 2025 leave taken, not 2026',
          annual_used_in_year('c0000000-0000-0000-0000-000000000001', 2025), 2::numeric);
select ck('G4 Cara took nothing in 2026',
          annual_used_in_year('c0000000-0000-0000-0000-000000000001', 2026), 0::numeric);

-- Year-end housekeeping written on 2 January but belonging to the year that ended.
select ck('G5 the 2025 clear-outs are filed under 2025, not the day they were typed',
          (select count(*)::int from leave_ledger
            where reason like '2025 %expired (unused)%' and leave_year <> 2025), 0);
select ck('G6 the 2025 forfeit is filed under 2025 too',
          (select count(*)::int from leave_ledger
            where reason like '2025 annual leave above the carry-over cap%' and leave_year <> 2025), 0);
select ck('G7 all of it is housekeeping, not entitlement',
          (select count(*)::int from leave_ledger
            where (reason like '%expired (unused)%' or reason like '%above the carry-over cap%')
              and kind <> 'writeoff'), 0);

-- The carry-over expiry belongs to THIS year. Counting it as entitlement would
-- quietly take 5 days off everyone's 2026 figure.
select ck('G8 this year''s carry-over expiry is a write-off, not a correction',
          (select kind from leave_ledger where reason = '2026 carry-over expired (unused)' limit 1), 'writeoff');
select ck('G9 so Cara''s 2026 entitlement is the allowance, untouched',
          entitled_in_year('c0000000-0000-0000-0000-000000000001', 'annual', 2026), 14::numeric);
select ck('G10 and her 2025 entitlement is still readable, years later',
          entitled_in_year('c0000000-0000-0000-0000-000000000001', 'annual', 2025), 14::numeric);

-- Balance arithmetic, end to end: 14 granted 2025, 2 taken, 7 forfeited,
-- 14 granted 2026, 5 carried days expired unused = 14.
select ck('G11 her annual balance is still exactly what it was',
          (select balance from leave_balances
            where emp_id = 'c0000000-0000-0000-0000-000000000001' and leave_type = 'annual'), 14::numeric);
select ck('G12 sick was cleared for 2025 and granted for 2026',
          (select balance from leave_balances
            where emp_id = 'c0000000-0000-0000-0000-000000000001' and leave_type = 'sick'), 14::numeric);

-- 2026 is already running, so the button must refuse it.
select ck('G13 starting 2026 again is refused', (run_year_start(2026, true)->>'already_started')::boolean, true);
-- 2027 is not, and it carries from 2026's records — not from 2025's.
select ck('G14 starting 2027 carries what is left of 2026',
          (select (x->>'carried')::numeric from jsonb_array_elements(run_year_start(2027, true)->'rows') x
            where x->>'name' = 'Cara'), 5::numeric);

do $$ begin raise notice ' '; raise notice 'ALL t35-G ASSERTIONS PASSED'; end $$;
