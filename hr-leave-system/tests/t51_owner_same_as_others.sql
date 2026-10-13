-- ============================================================================
-- v48. An account the Supabase trigger creates must be an ordinary employee.
--
-- "for the account that created via supabase i found there is some bug, the annual
--  leave unable to credited in ... please make it follow the format exactly as
--  employee created via leave desk system. dont make it difference."
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;
create or replace function eid(p text) returns uuid language sql stable as $$
  select id from employees where lower(email) = lower(p) $$;
create or replace function av(p text, c text) returns numeric language sql stable as $$
  select coalesce((select available from leave_balances where emp_id = eid(p) and leave_type = c), 0) $$;

do $$ begin raise notice ' '; raise notice '=== A. the trigger creates a fully-formed employee ==='; end $$;
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@x.com');
select ck('N1 the Owner exists', (select role from employees where email = 'owner@x.com'), 'admin');
select ck('N2 with annual leave, not zero',       av('owner@x.com', 'annual'), 14::numeric);
select ck('N3 sick leave',                        av('owner@x.com', 'sick'),   14::numeric);
select ck('N4 hospitalisation',                   av('owner@x.com', 'hosp'),   60::numeric);
select ck('N5 childcare',                         av('owner@x.com', 'childcare'), 6::numeric);
select ck('N6 off-in-lieu stays 0 — it is earned, not granted', av('owner@x.com', 'oil'), 0::numeric);
select ck('N7 and the rows say they are the year''s allowance',
          (select count(*)::int from leave_ledger where emp_id = eid('owner@x.com') and kind = 'grant' and delta_days > 0) > 5, true);

do $$ begin raise notice ' '; raise notice '=== B. identical to somebody added through the app ==='; end $$;
-- The app inserts the employee then writes one grant row per eligible type. Compare
-- the two shapes directly rather than trusting that they match.
insert into employees (name, email, join_date, role, active, dept, gender, annual_base)
values ('App Person', 'app@x.com', current_date, 'employee', true,
        (select name from departments order by name limit 1), null, 14);
select credit_joining_allowances(eid('app@x.com'));
select ck('N8 same set of leave types credited',
          (select string_agg(distinct leave_type, ',' order by leave_type) from leave_ledger
            where emp_id = eid('app@x.com') and kind = 'grant'),
          (select string_agg(distinct leave_type, ',' order by leave_type) from leave_ledger
            where emp_id = eid('owner@x.com') and kind = 'grant'));
select ck('N9 and the same day counts',
          (select string_agg(leave_type || '=' || delta_days, ',' order by leave_type) from leave_ledger
            where emp_id = eid('app@x.com') and kind = 'grant'),
          (select string_agg(leave_type || '=' || delta_days, ',' order by leave_type) from leave_ledger
            where emp_id = eid('owner@x.com') and kind = 'grant'));

do $$ begin raise notice ' '; raise notice '=== C. typing an entitlement credits it — the reported bug ==='; end $$;
-- Somebody holding nothing at all: the state the Owner was in before this migration.
insert into employees (name, email, join_date, role, active, dept, annual_base)
values ('Empty', 'empty@x.com', current_date, 'employee', true,
        (select name from departments order by name limit 1), 14);
select ck('N10 holds no annual leave', av('empty@x.com', 'annual'), 0::numeric);
select ck('N11 HR types 14 — it returns 14, not 0', set_annual_entitlement(eid('empty@x.com'), 14), 14::numeric);
select ck('N12 and the balance is really 14', av('empty@x.com', 'annual'), 14::numeric);
select ck('N13 recorded in Amendment records too',
          (select delta_days from hr_amendments where emp_id = eid('empty@x.com') and kind = 'entitlement'), 14::numeric);

do $$ begin raise notice ' '; raise notice '=== D. it cannot be credited twice ==='; end $$;
select ck('N14 the year-start grant skips somebody already granted',
          (select count(*)::int from leave_ledger where emp_id = eid('empty@x.com')
            and leave_type = 'annual' and kind = 'grant'), 1);
select grant_annual_entitlements(extract(year from current_date)::int);
select ck('N15 still one allowance row',
          (select count(*)::int from leave_ledger where emp_id = eid('empty@x.com')
            and leave_type = 'annual' and kind = 'grant'), 1);
select ck('N16 and still 14 days, not 28', av('empty@x.com', 'annual'), 14::numeric);
select ck('N17 crediting the joining allowances again writes nothing',
          credit_joining_allowances(eid('owner@x.com')), 0);

do $$ begin raise notice ' '; raise notice '=== E. changing the figure afterwards still works ==='; end $$;
select ck('N18 set to 16: adjusts by +2', set_annual_entitlement(eid('empty@x.com'), 16), 2::numeric);
select ck('N19 balance follows', av('empty@x.com', 'annual'), 16::numeric);
select ck('N20 set to 12: adjusts by -4', set_annual_entitlement(eid('empty@x.com'), 12), -4::numeric);
select ck('N21 balance follows down', av('empty@x.com', 'annual'), 12::numeric);

do $$ begin raise notice ' '; raise notice '=== F. a leaver is not credited ==='; end $$;
insert into employees (name, email, join_date, role, active, dept, annual_base)
values ('Left', 'left@x.com', current_date, 'employee', false,
        (select name from departments order by name limit 1), 14);
select ck('N22 nothing written for an inactive employee', credit_joining_allowances(eid('left@x.com')), 0);

do $$ begin raise notice ' '; raise notice 'ALL t51 ASSERTIONS PASSED'; end $$;
