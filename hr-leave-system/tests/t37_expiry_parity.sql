-- ============================================================================
-- P. The two expiry dates are one mechanism, and every forfeit is on the record.
--
-- Asked for as: "this two expiry function should be identical ... same logic and
-- same method, and same will be recorded for all amendement", after an expiry set
-- to today did nothing on the live site.
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
create or replace function bal(p text, c text) returns numeric language sql stable as $$
  select coalesce((select balance from leave_balances where emp_id = eid(p) and leave_type = c), 0) $$;

do $$ begin raise notice ' '; raise notice '=== A. the root cause: lying about volatility ==='; end $$;
-- A function that reads current_date and claims to be IMMUTABLE lets the planner
-- freeze today's date into a cached plan. Fresh psql sessions never notice; a pooled
-- PostgREST connection does, and the expiry silently stops happening.
select ck('P1 the off-in-lieu cut-off helper is STABLE, not IMMUTABLE',
          (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'oil_cutoff_of'), 's'::"char");
select ck('P2 so is the carry-forward one',
          (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'carry_cutoff_of'), 's'::"char");
select ck('P3 and they are the same algorithm, not two copies',
          carry_cutoff_of(9, 3), oil_cutoff_of(9, 3));

do $$ begin raise notice ' '; raise notice '=== B. an expiry set to TODAY forfeits today ==='; end $$;
-- The exact report: "i set Sep 3 so every OIL should be forfeited right?"
select ck('P4 Fem is holding off-in-lieu', bal('Fem','oil'), 3::numeric);
select set_oil_expiry(extract(month from current_date)::int, extract(day from current_date)::int, false);
select ck('P5 today counts as passed — the whole balance goes', bal('Fem','oil'), 0::numeric);
select ck('P6 and Male too', bal('Male','oil'), 0::numeric);

do $$ begin raise notice ' '; raise notice '=== C. every forfeit is on the record ==='; end $$;
select ck('C1 the off-in-lieu forfeit is in Amendment records',
          (select count(*)::int from hr_amendments where kind = 'expiry' and leave_type = 'oil'), 2);
select ck('C2 with the person named',
          (select count(*)::int from hr_amendments
            where kind = 'expiry' and leave_type = 'oil' and coalesce(emp_name,'') = ''), 0);
select ck('C3 the days taken away are the days recorded',
          (select -sum(delta_days) from hr_amendments where kind = 'expiry' and leave_type = 'oil'), 5::numeric);
select ck('C4 and it says when, in words',
          (select count(*)::int from hr_amendments
            where kind = 'expiry' and reason like '%expired on%forfeited%'), 2);
select ck('C5 it is in the ledger as well, so the balance can be explained',
          (select count(*)::int from leave_ledger where leave_type = 'oil' and kind = 'writeoff'), 2);

do $$ begin raise notice ' '; raise notice '=== D. carry-forward, credited by hand and then expired ==='; end $$;
-- "please credit 5 carryfoward AL to Lee Jian Wei, Amanda and ABB. i will need to
-- test the function too."
select ck('D1 crediting 5 carry-forward days reports back',
          (credit_carry_forward(eid('Fem'), 5)->>'carry_now')::numeric, 5::numeric);
select ck('D2 the days are really usable — both halves were written',
          (select coalesce(sum(delta_days),0) from leave_ledger
            where emp_id = eid('Fem') and leave_type = 'annual' and kind = 'carry_in'), 5::numeric);
select ck('D3 and the expiry job can see them',
          (select carry_in from annual_carry where emp_id = eid('Fem')
            and year = extract(year from current_date)::int), 5::numeric);
select ck('D4 crediting it is itself recorded',
          (select count(*)::int from hr_amendments where kind = 'carry_credit'), 1);

-- Now expire them: yesterday's date, so it is already past.
select set_carry_expiry(extract(month from current_date - 1)::int,
                        extract(day   from current_date - 1)::int, false);
select ck('D5 the carried days are gone',
          (select coalesce(sum(delta_days),0) from leave_ledger
            where emp_id = eid('Fem') and leave_type = 'annual' and kind = 'writeoff'), -5::numeric);
select ck('D6 and THAT forfeit is recorded the same way as the off-in-lieu one',
          (select count(*)::int from hr_amendments where kind = 'expiry' and leave_type = 'annual'), 1);
select ck('D7 word for word the same shape',
          (select count(*)::int from hr_amendments
            where kind = 'expiry' and reason like '%expired on%forfeited%'), 3);

do $$ begin raise notice ' '; raise notice '=== E. neither runs twice ==='; end $$;
select ck('E1 off-in-lieu', expire_due_oil(), 0);
select ck('E2 carry-forward', expire_due_carry(), 0);
select ck('E3 no extra amendment rows',
          (select count(*)::int from hr_amendments where kind = 'expiry'), 3);

do $$ begin raise notice ' '; raise notice 'ALL t37 ASSERTIONS PASSED'; end $$;
