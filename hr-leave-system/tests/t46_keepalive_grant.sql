-- ============================================================================
-- v45. The daily ping must actually be allowed to run.
--
-- Reported by the user, who was right and I had assumed otherwise:
--
--   Cronjob failed: .../rest/v1/rpc/keepalive_ping?...
--   Last status: Failed (401 Unauthorized)      -- 4 Sep 2026
--
-- The key was never the problem: the same key reads leave_types with a 200. The
-- body of the 401 was `42501 permission denied for function keepalive_ping`.
--
-- Cause: migration_app_v36.sql revokes execute from anon, and keepalive_ping_v3.sql
-- grants it back. A fresh install loads v3 last, so it ends up granted. Apply v36
-- to a database that already had v3 -- which is what happens when you upgrade in
-- place -- and the revoke is the last word. The ping then fails every single day,
-- silently as far as the database is concerned, and the project drifts toward the
-- 7-day idle pause.
--
-- So: no file in this project may leave anon unable to call the heartbeat, and
-- that is asserted here rather than reasoned about. The grant is the whole
-- keepalive story -- without it, every other part of the setup is theatre.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;

do $$ begin raise notice ' '; raise notice '=== A. anon may call the heartbeat ==='; end $$;
select ck('K1 anon has EXECUTE on keepalive_ping — this is what 401''d in production',
          has_function_privilege('anon', 'public.keepalive_ping()', 'EXECUTE'), true);
select ck('K2 so does authenticated',
          has_function_privilege('authenticated', 'public.keepalive_ping()', 'EXECUTE'), true);

do $$ begin raise notice ' '; raise notice '=== B. and it really writes when called ==='; end $$;
-- A grant alone is not enough: the function has to move the counter, or a 200 from
-- the cron service proves nothing. This is the check the July post-mortem lacked.
select ck('K3 the counter advances', (select keepalive_ping() > 0), true);
select ck('K4 and keeps advancing — three calls, three different values',
          (select count(distinct keepalive_ping())::int from generate_series(1, 3)), 3);
select ck('K5 the heartbeat row is stamped with now, not a fixed date',
          (select last_ping_at::date from keepalive_heartbeat where id = 1), current_date);

do $$ begin raise notice ' '; raise notice '=== C. anon still cannot touch the table behind it ==='; end $$;
-- Granting the function must not grant the data. anon can ring the bell; it cannot
-- edit the log of who rang it.
select ck('K6 anon cannot read the heartbeat table',
          has_table_privilege('anon', 'public.keepalive_heartbeat', 'SELECT'), false);
select ck('K7 nor write it',
          has_table_privilege('anon', 'public.keepalive_heartbeat', 'UPDATE'), false);

do $$ begin raise notice ' '; raise notice 'ALL t46 ASSERTIONS PASSED'; end $$;
