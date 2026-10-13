-- ============================================================================
-- F. The exact situation the user reported, on the exact data shape they had:
--    the 2026 allowances were granted in July 2026, some people then got
--    company-wide top-ups, and there is no 2025 data anywhere.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;

-- _pre was captured BEFORE the migration ran (see t35f.sh). A snapshot taken
-- afterwards could never fail, which is not a test.
create temp table _snap as select emp_id, leave_type, balance from _pre;

select ck('F1 the backfill moved nobody''s balance',
          (select count(*)::int from _snap s join leave_balances b
             on b.emp_id = s.emp_id and b.leave_type = s.leave_type
            where b.balance is distinct from s.balance), 0);
select ck('F2 every row knows its year',
          (select count(*)::int from leave_ledger where leave_year is null or kind is null), 0);
select ck('F3 the July allowances are tagged 2026, not guessed',
          (select count(*)::int from leave_ledger where kind = 'grant' and leave_year <> 2026), 0);
select ck('F4 the August top-ups are corrections, not allowances',
          (select count(*)::int from leave_ledger where reason like '%company-wide%' and kind <> 'adjust'), 0);
select ck('F5 there is no 2025 data at all',
          (select count(*)::int from leave_ledger where leave_year < 2026), 0);

-- The disaster: pressing Start a new year for 2026 when 2026 is already running.
select ck('F6 starting 2026 is refused', (run_year_start(2026, true)->>'already_started')::boolean, true);
do $$ begin
  perform run_year_start(2026, false);
  raise exception 'FAIL F7 the year start was NOT refused';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  raise notice 'ok    F7 and refused for real: %', left(sqlerrm, 60);
end $$;
select ck('F8 nothing moved',
          (select count(*)::int from _snap s join leave_balances b
             on b.emp_id = s.emp_id and b.leave_type = s.leave_type
            where b.balance is distinct from s.balance), 0);
select ck('F9 Barry still has his 21 annual days',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000001' and leave_type = 'annual'), 21::numeric);
select ck('F10 and his sick leave was not cleared',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000001' and leave_type = 'sick'), 14::numeric);

-- And when January really comes, the top-ups are 2026 days, so they carry
-- correctly instead of appearing as phantom 2025 days.
select ck('F11 in January, Barry carries the capped 5 of his 21 days',
          (select (x->>'carried')::numeric from jsonb_array_elements(run_year_start(2027, true)->'rows') x
            where x->>'name' = 'Barry'), 5::numeric);
select ck('F12 Newbie, who joined in August and was never granted, carries 0',
          (select (x->>'carried')::numeric from jsonb_array_elements(run_year_start(2027, true)->'rows') x
            where x->>'name' = 'Newbie'), 0::numeric);

do $$ begin raise notice ' '; raise notice 'ALL t35-F ASSERTIONS PASSED'; end $$;
