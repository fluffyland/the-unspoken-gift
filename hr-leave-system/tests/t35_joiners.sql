-- ============================================================================
-- H. The screenshot: sick 13 / 14 / 27 in one company, on one day.
--
-- seed_joiners.sql is loaded into a pre-v35 database and migration_app_v35.sql
-- is run against it. First the damage is confirmed to be there, then the two
-- things that make it go away and stay away.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;
create or replace function ent(p text, c text) returns numeric language sql stable as $$
  select entitled_in_year((select id from employees where name = p), c,
                          extract(year from current_date)::int) $$;

do $$ begin raise notice ' '; raise notice '=== the reported split is really there ==='; end $$;
select ck('H1 Early holds the July figure for sick',            ent('Early','sick'), 13::numeric);
select ck('H2 Late, who joined in August, holds 14',            ent('Late','sick'),  14::numeric);
select ck('H3 Twice, credited on joining AND by the run, holds 27', ent('Twice','sick'), 27::numeric);
select ck('H4 the same three-way split on hospitalisation',     ent('Twice','hosp'), 117::numeric);
select ck('H5 and on shared parental',                          ent('Twice','shared_parental'), 140::numeric);
select ck('H6 Mid got the raised shared-parental figure but the old sick one',
          trim_scale(ent('Mid','shared_parental')) || ' / ' || trim_scale(ent('Mid','sick')), '70 / 13');

do $$ begin raise notice ' '; raise notice '=== a joining credit IS the year''s allowance ==='; end $$;
-- This is the whole cause. Until v35 the wording was not recognised, so the yearly
-- run credited these people a second time and the Leave types tab skipped them.
select ck('H7 a joining credit is filed as an allowance, not a correction',
          ledger_kind_of('Leave allowance on joining', null, 14), 'grant');
select ck('H8 so is the annual-leave one',
          ledger_kind_of('Annual leave allowance on joining', null, 14), 'grant');
select ck('H9 the duplicate was kept as days, but only one of them is an allowance',
          (select count(*)::int from leave_ledger
            where emp_id = (select id from employees where name = 'Twice')
              and leave_type = 'sick' and kind = 'grant'), 1);
select ck('H10 nobody lost a day to the repair — Twice still holds 27',
          ent('Twice','sick'), 27::numeric);

do $$ begin raise notice ' '; raise notice '=== the yearly run no longer credits them twice ==='; end $$;
-- It WILL credit the leave types this fixture never seeded (childcare, maternity and
-- the rest) — that is its job. What it must not do is add a second allowance for the
-- three types everybody already holds. Five people x three types = fifteen, before
-- and after.
select ck('H11 fifteen allowances for the seeded types, before the run',
          (select count(*)::int from leave_ledger
            where leave_type in ('sick','hosp','shared_parental')
              and kind = 'grant' and leave_year = extract(year from current_date)::int), 15);
select grant_annual_entitlements(extract(year from current_date)::int);
select ck('H11b and still fifteen after it — a joining credit is now recognised',
          (select count(*)::int from leave_ledger
            where leave_type in ('sick','hosp','shared_parental')
              and kind = 'grant' and leave_year = extract(year from current_date)::int), 15);
select ck('H12 so the figures did not move',   ent('Late','sick'), 14::numeric);
select ck('H13 nor did the doubled one',       ent('Twice','sick'), 27::numeric);

do $$ begin raise notice ' '; raise notice '=== retyping the figure on Leave types fixes everybody ==='; end $$;
select amend_leave_type_days('sick', 14);
select ck('H14 Early comes up to 14',  ent('Early','sick'), 14::numeric);
select ck('H15 Mid comes up to 14',    ent('Mid','sick'),   14::numeric);
select ck('H16 Late stays at 14',      ent('Late','sick'),  14::numeric);
select ck('H17 Twice comes DOWN to 14 — the doubling is gone', ent('Twice','sick'), 14::numeric);
select ck('H18 and everyone eligible is on exactly 14',
          (select count(*)::int from employees e where e.active and ent(e.name,'sick') <> 14), 0);

select amend_leave_type_days('hosp', 59);
select amend_leave_type_days('shared_parental', 70);
select ck('H19 hospitalisation is level too',
          (select count(distinct ent(e.name,'hosp'))::int from employees e where e.active), 1);
select ck('H20 and shared parental',
          (select count(distinct ent(e.name,'shared_parental'))::int from employees e where e.active), 1);
select ck('H21 saving the same figure again writes nothing',
          (amend_leave_type_days('sick', 14)->>'affected')::int, 0);

do $$ begin raise notice ' '; raise notice '=== and it cannot come back ==='; end $$;
-- A second allowance row for the same person, type and year is now impossible,
-- whatever wording it arrives under.
do $$ begin
  insert into leave_ledger (emp_id, leave_type, delta_days, reason)
  values ((select id from employees where name = 'Late'), 'sick', 14, 'Leave allowance on joining');
  raise exception 'NOT BLOCKED';
exception
  when unique_violation then raise notice 'ok    H22 a second joining credit for the same year is refused';
  when others then if sqlerrm = 'NOT BLOCKED' then raise exception 'FAIL H22 a duplicate allowance was accepted'; else raise; end if;
end $$;

do $$ begin raise notice ' '; raise notice '=== running the migration a second time repairs its own earlier mistakes ==='; end $$;
-- The harness ran v35, then put the OLD (wrong) classification back, then ran v35
-- again. If the second run only filled in blanks, these would still be corrections
-- and the Leave types tab would still skip these people -- which is exactly what
-- was reported.
select ck('H23 a joining credit filed as a correction by an earlier run is repaired',
          (select count(*)::int from leave_ledger
            where reason like '%allowance on joining%' and kind <> 'grant'), 0);

do $$ begin raise notice ' '; raise notice '=== somebody with no allowance at all gets one ==='; end $$;
insert into auth.users (id, email) values ('33333333-0000-0000-0000-000000000005','none@x.com');
insert into employees (id,name,email,dept,gender,role,join_date,annual_base,carry_cap,active,two_level,auth_user_id,approver1)
values ('e0000000-0000-0000-0000-000000000005','Nothing','none@x.com','Ops','F','employee','2026-09-01',14,5,true,false,
        '33333333-0000-0000-0000-000000000005','e0000000-0000-0000-0000-000000000009');
select ck('H24 she starts with no compassionate leave at all', ent('Nothing','compassionate'), 0::numeric);
select amend_leave_type_days('compassionate', 5);
select ck('H25 setting the figure gives her the full 5', ent('Nothing','compassionate'), 5::numeric);
select ck('H26 and everybody else is on 5 too',
          (select count(distinct ent(e.name,'compassionate'))::int from employees e where e.active), 1);
select ck('H27 what she got is an ALLOWANCE, so the yearly run will not credit her again',
          (select kind from leave_ledger
            where emp_id = 'e0000000-0000-0000-0000-000000000005'
              and leave_type = 'compassionate' and delta_days = 5), 'grant');
select ck('H28 proof: running the yearly grant changes nothing for her',
          (select ent('Nothing','compassionate')
             from (select grant_annual_entitlements(extract(year from current_date)::int)) _), 5::numeric);

do $$ begin raise notice ' '; raise notice '=== one command levels every leave type ==='; end $$;
-- Eleven leave types is eleven trips to the Leave types tab. This does the lot.
update leave_ledger set delta_days = delta_days + 3
 where emp_id = 'e0000000-0000-0000-0000-000000000001' and leave_type = 'childcare' and kind = 'grant';
select ck('H29 Early is off the childcare figure', ent('Early','childcare'), 9::numeric);
select ck('H30 the preview reports it without changing anything',
          (select "People corrected" from reconcile_all_leave_types() where "Leave type" = 'Childcare Leave'), 1);
select ck('H31 and really has changed nothing', ent('Early','childcare'), 9::numeric);
select reconcile_all_leave_types(false);
select ck('H32 now he is back on the figure', ent('Early','childcare'), 6::numeric);
select ck('H33 every yearly leave type has exactly one figure across the company',
          (select count(*)::int from leave_types t
             where t.code <> 'annual' and t.code <> 'oil' and not t.no_deduct
               and (select count(distinct entitled_in_year(e.id, t.code, extract(year from current_date)::int))
                      from employees e
                     where e.active and (t.gender_eligibility is null or t.gender_eligibility = e.gender)) > 1), 0);
select ck('H34 running it again writes nothing',
          (select sum("People corrected")::int from reconcile_all_leave_types(false)), 0);

do $$ begin raise notice ' '; raise notice 'ALL t35-H ASSERTIONS PASSED'; end $$;
