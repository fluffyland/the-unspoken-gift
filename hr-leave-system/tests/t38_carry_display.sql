-- ============================================================================
-- Q. The carry-forward figure on screen must be the one you can actually book.
--
-- Reported, and reproduced exactly:
--   "Available Balance: 11 days (Annual Leave: 9 · Carry Forward: 2 ·
--    Entitled this year: 14 · Taken: 3)"  after being credited 5 carried days,
--   and "why after i apply the Annual leave will change from Annual Leave: 9 ·
--    Carry Forward: 2 to Annual Leave: 10 · Carry Forward: 1?"
--
-- Cause: the expiry date had been set to a date already past (to test it), so the
-- balance correctly withheld all 5 carried days — but my_annual_carry reported
-- carry_in minus days taken, never asking whether they had expired. Two rules for
-- the same days. And "Annual Leave" is the REMAINDER of Available minus that
-- figure, so the phantom number shrinking made Annual Leave grow.
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
create or replace function be(p text) returns void language plpgsql as $$
begin delete from auth._whoami;
      insert into auth._whoami select auth_user_id from employees where name = p; end $$;
create or replace function av() returns numeric language sql stable as $$
  select coalesce((select available from leave_balances
                   where emp_id = eid('Fem') and leave_type = 'annual'), 0) $$;
create or replace function shown() returns numeric language sql stable as $$
  select coalesce((select remaining from my_annual_carry), 0) $$;
-- What the screen prints: Annual Leave is the remainder of Available minus the carry.
create or replace function own() returns numeric language sql stable as $$
  select av() - least(greatest(shown(), 0), greatest(av(), 0)) $$;

select be('Fem');
select credit_carry_forward(eid('Fem'), 5);
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('a1000000-0000-0000-0000-0000000000f1', eid('Fem'), 'annual', '2026-02-09','2026-02-11', 3, 'approved','x');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values (eid('Fem'), 'annual', -3, 'Leave taken', 'a1000000-0000-0000-0000-0000000000f1', '2026-02-09');

do $$ begin raise notice ' '; raise notice '=== A. the normal case: 14 entitled + 5 carried, 3 taken ==='; end $$;
select ck('Q1 total available is 14 + 5 - 3', av(), 16::numeric);
select ck('Q2 carry shown is what is left of the carry', shown(), 2::numeric);
select ck('Q3 and "Annual Leave" is this year''s, untouched — carry is used first', own(), 14::numeric);

-- One more day. Carry is used first, so THIS YEAR'S figure must not move.
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('a1000000-0000-0000-0000-0000000000f2', eid('Fem'), 'annual', '2026-03-09','2026-03-09', 1, 'approved','x');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values (eid('Fem'), 'annual', -1, 'Leave taken', 'a1000000-0000-0000-0000-0000000000f2', '2026-03-09');
select ck('Q4 taking one more day reduces the total', av(), 15::numeric);
select ck('Q5 it comes out of the carry', shown(), 1::numeric);
select ck('Q6 and "Annual Leave" STAYS at 14 — it must never go up when leave is taken',
          own(), 14::numeric);

do $$ begin raise notice ' '; raise notice '=== B. the expiry date set to a date already past ==='; end $$;
update annual_carry set expires_on = '2026-01-31' where emp_id = eid('Fem')
   and year = extract(year from current_date)::int;
select ck('Q7 the balance withholds every carried day — they are gone', av(), 10::numeric);
select ck('Q8 and the screen says 0, not a number you cannot book', shown(), 0::numeric);
select ck('Q9 it says WHY', (select expired from my_annual_carry), true);
select ck('Q10 so "Annual Leave" is the whole of what is left', own(), 10::numeric);

do $$ begin raise notice ' '; raise notice '=== C. the two figures always add up to Available ==='; end $$;
select ck('Q11 with the expiry past', own() + least(greatest(shown(),0), greatest(av(),0)), av());
update annual_carry set expires_on = '2026-12-31' where emp_id = eid('Fem')
   and year = extract(year from current_date)::int;
select ck('Q12 and with it in the future', own() + least(greatest(shown(),0), greatest(av(),0)), av());
select ck('Q13 back to a real 15 available', av(), 15::numeric);

do $$ begin raise notice ' '; raise notice 'ALL t38 ASSERTIONS PASSED'; end $$;
