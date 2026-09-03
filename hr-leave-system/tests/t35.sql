-- ============================================================================
-- t35.sql — the year-tag suite. Every assertion is written as "this must be
-- true"; anything else aborts with the numbers that were actually found.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want;
  end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;

do $$ begin raise notice ' '; raise notice '=== A. no previous year at all ==='; end $$;

-- Nobody has been granted anything. Starting 2026 must carry NOTHING —
-- not because a rule remembered to fire, but because there is nothing to carry.
select ck('A1 nothing granted yet', year_has_started(2026), false);
select ck('A2 starting 2026 carries 0 days',
          (run_year_start(2026, false)->>'carried_days')::numeric, 0::numeric);
select ck('A3 everyone now holds 2026 leave', year_has_started(2026), true);
select ck('A4 Barry annual = his figure, nothing added',
          entitled_in_year('a0000000-0000-0000-0000-000000000001', 'annual', 2026), 17.5::numeric);
select ck('A5 Barry sick = the leave type default',
          entitled_in_year('a0000000-0000-0000-0000-000000000001', 'sick', 2026), 14::numeric);
select ck('A6 no 2025 row exists at all',
          (select count(*)::int from leave_ledger where leave_year = 2025), 0);
select ck('A7 starting 2026 twice is refused', (run_year_start(2026, true)->>'already_started')::boolean, true);
do $$ begin
  perform run_year_start(2026, false);
  raise exception 'FAIL A8 pressing Start a new year for a year already running was NOT refused';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  raise notice 'ok    A8 and refused for real, not just in the preview';
end $$;
-- A row that names its year in its wording belongs to THAT year, whenever it was
-- keyed in. Falling back to the day it was typed is the old bug, in one line.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
values ('a0000000-0000-0000-0000-000000000002','hosp', 5, '2019 Hospitalisation Leave amended 55 → 60', now());
select ck('A9 the wording decides the year, not the day it was typed',
          (select leave_year from leave_ledger where reason like '2019 %'), 2019);
delete from leave_ledger where reason like '2019 %';

do $$ begin raise notice ' '; raise notice '=== C. the leave-types tab reconciles to the number typed (this year) ==='; end $$;

-- Two allowance rows in one year is what produced "sick 28" and "hosp 118".
-- The unique index makes a second one impossible.
do $$ begin
  insert into leave_ledger (emp_id, leave_type, delta_days, reason, leave_year, kind)
  values ('a0000000-0000-0000-0000-000000000001','sick', 14, '2026 annual allowance', 2026, 'grant');
  raise exception 'NOT BLOCKED';
exception
  when unique_violation then raise notice 'ok    C1 a second allowance row for the same year is refused';
  when others then if sqlerrm = 'NOT BLOCKED' then raise exception 'FAIL C1 a duplicate allowance was accepted'; else raise; end if;
end $$;

-- Someone is off-target for another reason: a correction pushed sick to 28.
insert into leave_ledger (emp_id, leave_type, delta_days, reason, leave_year, kind)
values ('a0000000-0000-0000-0000-000000000001','sick', 14, 'manual correction', 2026, 'adjust');
select ck('C2 Barry is now on 28 sick days',
          entitled_in_year('a0000000-0000-0000-0000-000000000001', 'sick', 2026), 28::numeric);
select amend_leave_type_days('sick', 14);
select ck('C3 typing 14 on the Leave types tab brings him back to 14',
          entitled_in_year('a0000000-0000-0000-0000-000000000001', 'sick', 2026), 14::numeric);
select ck('C4 and everyone else is on 14 too',
          (select count(*)::int from employees e where e.active
             and entitled_in_year(e.id, 'sick', 2026) <> 14), 0);
select ck('C5 saving the same number again writes nothing',
          (amend_leave_type_days('sick', 14)->>'affected')::int, 0);

do $$ begin raise notice ' '; raise notice '=== B. a real second year ==='; end $$;

-- Barry takes 3 days in 2026, and one more application dated December 2026 is
-- keyed in during January 2027 — the case that used to land in the wrong year.
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('b0000000-0000-0000-0000-00000000000a','a0000000-0000-0000-0000-000000000001','annual',
        '2026-03-02','2026-03-04', 3, 'approved', 'March');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values ('a0000000-0000-0000-0000-000000000001','annual', -3, 'Leave taken',
        'b0000000-0000-0000-0000-00000000000a', '2026-03-01 02:00:00+00');

insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('b0000000-0000-0000-0000-00000000000b','a0000000-0000-0000-0000-000000000001','annual',
        '2026-12-21','2026-12-22', 2, 'approved', 'keyed in late');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application, created_at)
values ('a0000000-0000-0000-0000-000000000001','annual', -2, 'Leave taken',
        'b0000000-0000-0000-0000-00000000000b', '2027-01-06 02:00:00+00');

select ck('B1 December leave keyed in January belongs to 2026',
          (select leave_year from leave_ledger where ref_application = 'b0000000-0000-0000-0000-00000000000b'), 2026);
select ck('B2 Barry took 5 days in 2026',
          annual_used_in_year('a0000000-0000-0000-0000-000000000001', 2026), 5::numeric);
select ck('B3 his 2026 entitlement is untouched by the leave',
          entitled_in_year('a0000000-0000-0000-0000-000000000001', 'annual', 2026), 17.5::numeric);

-- Start 2027. Barry has 17.5 − 5 = 12.5 left, cap 5 → carries 5, forfeits 7.5.
select ck('B4 2027 carries the capped days',
          (select (x->>'carried')::numeric from jsonb_array_elements(run_year_start(2027, true)->'rows') x
            where x->>'name' = 'Barry'), 5::numeric);
select ck('B5 and forfeits the rest',
          (select (x->>'forfeited')::numeric from jsonb_array_elements(run_year_start(2027, true)->'rows') x
            where x->>'name' = 'Barry'), 7.5::numeric);
select ck('B6 preview writes nothing', (select count(*)::int from leave_ledger where leave_year = 2027), 0);

-- HR records a day of sick leave dated February 2027 before pressing the button.
-- The reset clears LAST year's days; this one is next year's and must survive.
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('b0000000-0000-0000-0000-00000000000d','a0000000-0000-0000-0000-000000000002','sick',
        '2027-02-10','2027-02-10', 1, 'approved', 'MC');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application)
values ('a0000000-0000-0000-0000-000000000002','sick', -1, 'Leave taken',
        'b0000000-0000-0000-0000-00000000000d');

-- Hilda overspent 2026 by 2 days. A debt is not "nothing to carry": if the year
-- start quietly clamps it to zero, those 2 days are written off in her favour and
-- nobody ever sees it.
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('b0000000-0000-0000-0000-00000000000e','a0000000-0000-0000-0000-000000000009','annual',
        '2026-05-04','2026-05-25', 16, 'approved', 'long trip');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application)
values ('a0000000-0000-0000-0000-000000000009','annual', -16, 'Leave taken',
        'b0000000-0000-0000-0000-00000000000e');

select ck('B7 run it for real', (run_year_start(2027, false)->>'year')::int, 2027);
select ck('B8 2026 is now closed out — nothing left tagged 2026 or earlier',
          (select coalesce(sum(delta_days),0) from leave_ledger
            where emp_id = 'a0000000-0000-0000-0000-000000000001' and leave_type = 'annual'
              and leave_year < 2027), 0::numeric);
select ck('B9 the carried days are a real ledger entry, tagged 2027',
          (select coalesce(sum(delta_days),0) from leave_ledger
            where emp_id = 'a0000000-0000-0000-0000-000000000001'
              and leave_type = 'annual' and leave_year = 2027 and kind = 'carry_in'), 5::numeric);
select ck('B10 carried days are NOT counted as this year''s entitlement',
          entitled_in_year('a0000000-0000-0000-0000-000000000001', 'annual', 2027), 17.5::numeric);
select ck('B11 balance = carried + granted',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000001' and leave_type = 'annual'), 22.5::numeric);
select ck('B12 sick was cleared and granted again, exactly once',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000001' and leave_type = 'sick'), 14::numeric);
select ck('B13 one allowance row per type per year',
          (select count(*)::int from (select emp_id, leave_type, leave_year from leave_ledger
             where kind = 'grant' group by 1,2,3 having count(*) > 1) d), 0);
select ck('B14 granting 2027 again does nothing', grant_annual_entitlements(2027), 0);
select ck('B16 an overspent year carries its debt forward, it is not forgiven',
          (select coalesce(sum(delta_days),0) from leave_ledger
            where emp_id = 'a0000000-0000-0000-0000-000000000009'
              and leave_type = 'annual' and leave_year = 2027 and kind = 'carry_in'), -2::numeric);
select ck('B17 so her 2027 balance is the allowance minus the debt',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000009' and leave_type = 'annual'), 12::numeric);
select ck('B15 leave already recorded for 2027 was not wiped by the reset',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000002' and leave_type = 'sick'), 13::numeric);

do $$ begin raise notice ' '; raise notice '=== D. a rejected application never touches the ledger ==='; end $$;
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('b0000000-0000-0000-0000-00000000000c','a0000000-0000-0000-0000-000000000003','annual',
        '2027-04-05','2027-04-06', 2, 'rejected', 'no');
select ck('D1 nothing was deducted for it',
          (select count(*)::int from leave_ledger where ref_application = 'b0000000-0000-0000-0000-00000000000c'), 0);
-- 14 granted for 2027 + 5 carried from 2026 = 19 available against a 14-day
-- entitlement. That gap is normal and is what "19 / 14" on the Balances tab means.
select ck('D2 so Barbie still has every day she is owed',
          (select balance from leave_balances
            where emp_id = 'a0000000-0000-0000-0000-000000000003' and leave_type = 'annual'), 19::numeric);
select ck('D3 her entitlement for the year is still just the allowance',
          entitled_in_year('a0000000-0000-0000-0000-000000000003', 'annual', 2027), 14::numeric);

do $$ begin raise notice ' '; raise notice '=== E. undo puts a year start back exactly ==='; end $$;
create temp table _snap as select emp_id, leave_type, balance from leave_balances;
select ck('E1 2028 starts', (run_year_start(2028, false)->>'year')::int, 2028);
select ck('E2 undo previews without writing',
          (undo_year_start(2028, true)->>'preview')::boolean, true);
select ck('E3 undo runs', (undo_year_start(2028, false)->>'found')::boolean, true);
select ck('E4 every balance is back where it was',
          (select count(*)::int from _snap s join leave_balances b
             on b.emp_id = s.emp_id and b.leave_type = s.leave_type
            where b.balance is distinct from s.balance), 0);
select ck('E5 undoing again is a no-op', (undo_year_start(2028, false)->>'found')::boolean, false);

do $$ begin raise notice ' '; raise notice 'ALL t35 ASSERTIONS PASSED'; end $$;
