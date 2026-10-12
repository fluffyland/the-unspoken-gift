-- ============================================================================
-- v43. Paste install.sql ONCE, add the login in the dashboard, sign in. No second
-- paste, no block to copy out of the middle of a 10,000-line file.
--
-- "i dont want a paste and stitch job" — and the stitch step was broken anyway:
-- install.sql's final block reads _leavedesk_setup and the next line drops it, so
-- the documented recovery ("run just this last section again") could only ever
-- fail. Checked here too.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;

do $$ begin raise notice ' '; raise notice '=== A. after install.sql, nobody can sign in yet ==='; end $$;
select ck('W1 the install left no employees at all', (select count(*)::int from employees), 0);
select ck('W2 but it remembered who the Owner is to be',
          (select pending_owner_email from org_settings where id = 1), 'hr@shanghai-uniforms.com');
select ck('W3 and it put a trigger on auth.users to watch for that login',
          (select count(*)::int from pg_trigger where tgname = 'trg_leavedesk_owner'), 1);
select ck('W4 the scratch table really is gone — so "re-run the last block" cannot work',
          (select count(*)::int from information_schema.tables where table_name = '_leavedesk_setup'), 0);

do $$ begin raise notice ' '; raise notice '=== B. the dashboard adds the login — and that is the whole of step 2 ==='; end $$;
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'hr@shanghai-uniforms.com');
select ck('W5 the Owner employee row appeared by itself', (select count(*)::int from employees), 1);
select ck('W6 as an Owner, not an ordinary employee',
          (select role from employees limit 1), 'admin');
select ck('W7 linked to that exact login',
          (select auth_user_id from employees limit 1), '11111111-1111-1111-1111-111111111111'::uuid);
select ck('W8 active, so current_emp_id() will trust them',
          (select active from employees limit 1), true);
select ck('W9 named as typed at install', (select name from employees limit 1), 'Lee Jian Wei');
select ck('W10 and the invitation is spent', (select pending_owner_email from org_settings where id = 1), null::text);

do $$ begin raise notice ' '; raise notice '=== C0. a DIFFERENT login, while the invitation is still open ==='; end $$;
-- The case that matters most, and the one this suite first missed. Somebody creates
-- a staff login before the Owner's. If the claim does not check the address, that
-- person becomes an Owner of the whole company — and the mutation run proved the
-- other guards do not cover it: with the invitation still open, only the email
-- comparison stands between a new login and admin.
delete from employees;
update org_settings set pending_owner_email = 'hr@shanghai-uniforms.com',
                        pending_owner_name = 'Lee Jian Wei' where id = 1;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999999', 'warehouse.staff@shanghai-uniforms.com');
select ck('W4a a login on another address creates NOBODY', (select count(*)::int from employees), 0);
select ck('W4b and certainly no Owner', (select count(*)::int from employees where role = 'admin'), 0);
select ck('W4c the invitation is still open for the real Owner',
          (select pending_owner_email from org_settings where id = 1), 'hr@shanghai-uniforms.com');
select ck('W4d the claim says so plainly, rather than failing quietly',
          claim_pending_owner('99999999-9999-9999-9999-999999999999', 'warehouse.staff@shanghai-uniforms.com'),
          'not the pending owner');
-- Put the world back the way section B left it, so what follows measures what it
-- means to. A section that silently changes the starting state of the next one is
-- how a suite ends up asserting against a situation nobody intended.
insert into auth.users (id, email) values ('1111111a-1111-1111-1111-111111111111', 'hr@shanghai-uniforms.com');
select ck('W4e the real Owner still claims it afterwards',
          (select count(*)::int from employees where role = 'admin'), 1);

do $$ begin raise notice ' '; raise notice '=== C. it cannot mint a second Owner ==='; end $$;
insert into auth.users (id, email) values ('22222222-2222-2222-2222-222222222222', 'someone.else@shanghai-uniforms.com');
select ck('W11 a second login does NOT become an Owner', (select count(*)::int from employees), 1);
select ck('W12 nor does a second login on the same address',
          (select count(*)::int from employees where role = 'admin'), 1);

do $$ begin raise notice ' '; raise notice '=== D. order does not matter: login first, SQL second ==='; end $$;
-- Somebody adds the user before pasting the SQL. The catch-up pass must find them.
delete from employees;
insert into auth.users (id, email) values ('33333333-3333-3333-3333-333333333333', 'later@shanghai-uniforms.com');
update org_settings set pending_owner_email = 'later@shanghai-uniforms.com',
                        pending_owner_name = 'Later Owner' where id = 1;
select ck('W13 the login exists and nothing links it yet', (select count(*)::int from employees), 0);
do $$ declare r record; begin
  for r in select u.id, u.email from auth.users u join org_settings o
            on lower(o.pending_owner_email) = lower(u.email) where o.id = 1
  loop perform claim_pending_owner(r.id, r.email); end loop;
end $$;
select ck('W14 the catch-up pass links it', (select role from employees limit 1), 'admin');
select ck('W15 to the right login',
          (select auth_user_id from employees limit 1), '33333333-3333-3333-3333-333333333333'::uuid);

do $$ begin raise notice ' '; raise notice '=== E. the login deleted and remade ==='; end $$;
-- auth_user_id is `on delete set null`, so the employee row survives with no login.
delete from auth.users where id = '33333333-3333-3333-3333-333333333333';
select ck('W16 the employee is still there, now with no login',
          (select count(*)::int from employees where auth_user_id is null), 1);
insert into auth.users (id, email) values ('44444444-4444-4444-4444-444444444444', 'later@shanghai-uniforms.com');
select ck('W17 a new login on the same address reattaches to the same person',
          (select count(*)::int from employees), 1);
select ck('W18 and it is the new login',
          (select auth_user_id from employees limit 1), '44444444-4444-4444-4444-444444444444'::uuid);

do $$ begin raise notice ' '; raise notice '=== F. a failure here must never block a signup ==='; end $$;
-- If the claim raises, the dashboard's own insert must still commit: the cost of a
-- fault is a missing Owner row, never "Add user doesn't work" with no explanation.
create or replace function claim_pending_owner(p_auth_user uuid, p_email text)
returns text language plpgsql security definer set search_path = public as $$
begin raise exception 'deliberate fault'; end $$;
insert into auth.users (id, email) values ('55555555-5555-5555-5555-555555555555', 'boom@shanghai-uniforms.com');
select ck('W19 the login was still created', 
          (select count(*)::int from auth.users where email = 'boom@shanghai-uniforms.com'), 1);

do $$ begin raise notice ' '; raise notice 'ALL t44 ASSERTIONS PASSED'; end $$;
