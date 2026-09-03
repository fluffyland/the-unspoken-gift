-- ============================================================================
-- O. Off-in-Lieu expiry.
--
-- Asked for as "same as the carry forward AL function ... once the date reaches it
-- will be forfeited". The rule chosen, which is NOT the same as annual leave:
--   annual : last year's leftover dies on this year's date; this year's is safe
--   OIL    : whatever is in the balance on the date is forfeited, whenever earned
--
-- Off by default. Installing the migration must not cost anybody a day.
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
create or replace function oilbal(p text) returns numeric language sql stable as $$
  select coalesce((select balance from leave_balances
                   where emp_id = eid(p) and leave_type = 'oil'), 0) $$;

do $$ begin raise notice ' '; raise notice '=== A. installing it changes nothing ==='; end $$;
select ck('O1 off-in-lieu never expires until a month is chosen',
          oil_expiry_for(extract(year from current_date)::int), null::date);
select ck('O2 so nothing is due to be written off', oil_last_cutoff(), null::date);
select ck('O3 and the daily run has nothing to do', expire_due_oil(), 0);
select ck('O4 Fem still has the 3 off-in-lieu days she earned', oilbal('Fem'), 3::numeric);
select ck('O5 Male still has his 2', oilbal('Male'), 2::numeric);

do $$ begin raise notice ' '; raise notice '=== B. a date in the future takes nothing away ==='; end $$;
-- 31 December: this year's has not arrived, so the last one that HAS passed is
-- 31 December LAST year — before any of these days were earned.
select ck('B1 the preview says nobody loses anything',
          (set_oil_expiry(12, 31, true)->>'days_lost')::numeric, 0::numeric);
select set_oil_expiry(12, 31, false);
select ck('B2 saving it really costs nobody a day', oilbal('Fem'), 3::numeric);
select ck('B3 nor him', oilbal('Male'), 2::numeric);
select ck('B4 the setting is stored',
          to_char(oil_expiry_for(extract(year from current_date)::int), 'DD Mon'), '31 Dec');

do $$ begin raise notice ' '; raise notice '=== C. a date already past forfeits the WHOLE balance ==='; end $$;
-- 31 January. It has already gone by this year, and both of them earned days
-- before it AND after it. Under the annual-leave rule only the older days would
-- die; under the rule chosen here, everything held on that date goes.
select ck('C1 the preview warns, before anything is written',
          (set_oil_expiry(1, 31, true)->>'dying_people')::int, 2);
select ck('C2 and nothing has been written yet', oilbal('Fem'), 3::numeric);
select set_oil_expiry(1, 31, false);
select ck('C3 Fem keeps only what she earned AFTER the date', oilbal('Fem'), 1::numeric);
select ck('C4 Male earned nothing after it, so he is at zero', oilbal('Male'), 0::numeric);
select ck('C5 it is written down as a forfeit, not a silent change',
          (select count(*)::int from leave_ledger
            where leave_type = 'oil' and kind = 'writeoff'), 2);
select ck('C6 and the day she took is untouched',
          (select coalesce(-sum(delta_days), 0) from leave_ledger
            where emp_id = eid('Fem') and leave_type = 'oil' and kind = 'taken'), 1::numeric);

do $$ begin raise notice ' '; raise notice '=== D. it only happens once ==='; end $$;
select ck('D1 running the expiry again writes nothing', expire_due_oil(), 0);
select ck('D2 balances unmoved', trim_scale(oilbal('Fem')) || '/' || trim_scale(oilbal('Male')), '1/0');
select ck('D3 the daily heartbeat is safe to call repeatedly',
          (select count(distinct keepalive_ping())::int from generate_series(1, 3)), 3);
select ck('D4 and still wrote nothing more', oilbal('Fem'), 1::numeric);
do $$ begin raise notice ' '; raise notice '=== E. turning it back off ==='; end $$;
select set_oil_expiry(null, null, false);
select ck('E1 off-in-lieu stops expiring', oil_last_cutoff(), null::date);
select ck('E2 but the days already forfeited do not come back', oilbal('Fem'), 1::numeric);
select ck('E3 which the preview says out loud',
          (set_oil_expiry(1, 31, true)->>'already_expired')::int > 0, true);

do $$ begin raise notice ' '; raise notice '=== F. the safety net, with every scheduled job dead ==='; end $$;
-- The heartbeat is the only thing that WRITES the forfeit down. If it stops, the days
-- must still be unusable — the same guarantee the carry-forward expiry has.
--
-- Nogender is used here because she has no off-in-lieu history and no expiry record:
-- the safety net only applies to a cut-off that has not been processed, so testing it
-- on somebody already processed in section C would prove nothing.
select set_oil_expiry(null, null, false);
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
values (eid('Nogender'), 'oil', 4, 'Off-in-lieu earned', '2026-03-01 02:00:00+00');
select ck('F1 she is credited 4 days', oilbal('Nogender'), 4::numeric);
-- Set the date straight in the table, so NOTHING is written off: this is what the
-- world looks like if the daily job has quietly been dead for months.
update org_settings set oil_expiry_month = 6, oil_expiry_day = 30 where id = 1;
select ck('F2 30 June has passed', oil_last_cutoff(), '2026-06-30'::date);
select ck('F3 nothing at all has been written for it',
          (select count(*)::int from oil_expiry_log where expires_on = '2026-06-30'), 0);
select ck('F4 and yet the balance already refuses the days', oilbal('Nogender'), 0::numeric);
select ck('F5 so she cannot book them', due_unwritten_oil(eid('Nogender'), 'oil'), 4::numeric);
select ck('F6 when the job finally runs it records the same thing',
          expire_due_oil(eid('Nogender')), 1);
select ck('F7 same answer either way', oilbal('Nogender'), 0::numeric);
select ck('F8 and now it is written down where a person can see it',
          (select coalesce(-sum(delta_days), 0) from leave_ledger
            where emp_id = eid('Nogender') and leave_type = 'oil' and kind = 'writeoff'), 4::numeric);

do $$ begin raise notice ' '; raise notice '=== G. leavers, and other leave types ==='; end $$;
select ck('G1 a leaver is left alone',
          (select count(*)::int from oil_expiry_log where emp_id = eid('Gone')), 0);
select ck('G2 annual leave is not affected by the off-in-lieu date',
          due_unwritten_oil(eid('Fem'), 'annual'), 0::numeric);
select ck('G3 nor sick leave', due_unwritten_oil(eid('Fem'), 'sick'), 0::numeric);

do $$ begin raise notice ' '; raise notice '=== H. the daily heartbeat does the work by itself ==='; end $$;
-- The heartbeat is the ONLY thing that runs this by itself. Asserting it can be called
-- is not the same as asserting it does the work — and it did not: install.sql loads
-- keepalive_ping_v3.sql AFTER the migrations, and that file drops and recreates
-- keepalive_ping, throwing away v36's version on every fresh install.
select set_oil_expiry(null, null, false);
insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_at)
values (eid('Boss'), 'oil', 3, 'Off-in-lieu earned', '2026-01-05 02:00:00+00');
-- 30 April, not 31 January: section C already processed everyone for January, and a
-- date that has been processed is exactly the case this is NOT testing.
update org_settings set oil_expiry_month = 4, oil_expiry_day = 30 where id = 1;
select ck('H1 Boss is holding 3 days past an expiry nobody has processed', oilbal('Boss'), 0::numeric);
select ck('H2 and nothing is written down yet',
          (select count(*)::int from leave_ledger
            where emp_id = eid('Boss') and leave_type = 'oil' and kind = 'writeoff'), 0);
select keepalive_ping();
select ck('H3 THE DAILY HEARTBEAT writes it off — not a person, not a separate job',
          (select coalesce(-sum(delta_days), 0) from leave_ledger
            where emp_id = eid('Boss') and leave_type = 'oil' and kind = 'writeoff'), 3::numeric);
select set_oil_expiry(null, null, false);
-- Name the date rather than reading the current setting: the heartbeat check below
-- turns the setting off again, and a test that quietly measures a different date than
-- it means to is worse than no test.
select ck('D5 one expiry record per person for the date section C processed',
          (select count(*)::int from oil_expiry_log where expires_on = oil_cutoff_of(1, 31)),
          (select count(*)::int from employees where active));


do $$ begin raise notice ' '; raise notice 'ALL t36 ASSERTIONS PASSED'; end $$;
