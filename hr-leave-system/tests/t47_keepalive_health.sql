-- ============================================================================
-- v46. The alarm must be a STATE, not an event: it has to keep failing for as
-- long as the ping is dead, so a monitor re-alerts on its own schedule.
--
-- "why it only email once after it fail and it stopped cannot it keep sending
--  everyday?" — cron-job.org cannot. This is the piece that can.
-- ============================================================================
\set ON_ERROR_STOP on
create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;
-- Did calling it raise? Returns the SQLSTATE class, or 'no error'.
create or replace function tries() returns text language plpgsql as $$
begin perform keepalive_health(); return 'no error';
exception when others then return 'raised'; end $$;
-- The message a person reads at 2am. sqlerrm only exists inside a handler, so it
-- has to be captured here rather than asked for afterwards.
create or replace function errmsg() returns text language plpgsql as $$
begin perform keepalive_health(); return '(no error)';
exception when others then return sqlerrm; end $$;

do $$ begin raise notice ' '; raise notice '=== A. a healthy, freshly pinged project ==='; end $$;
select keepalive_ping();
select ck('H1 a monitor gets a clean answer', tries(), 'no error');
select ck('H2 and it says when the last ping was', keepalive_health() like 'OK last_ping=%', true);
select ck('H3 with the counter, so a frozen counter is visible too',
          keepalive_health() like '%count=%', true);

do $$ begin raise notice ' '; raise notice '=== B. the ping stops ==='; end $$;
update keepalive_heartbeat set last_ping_at = now() - interval '40 hours' where id = 1;
select ck('H4 the health check fails', tries(), 'raised');
-- The point of the whole exercise: it must fail EVERY time, not once.
select ck('H5 and fails again, and again — ten checks, ten failures',
          (select count(*)::int from generate_series(1, 10) g where tries() = 'raised'), 10);
select ck('H6 it names the problem in words a person can act on',
          errmsg() like 'LEAVEDESK KEEPALIVE IS STALE.%', true);
select ck('H7 and says how long it has been dead',
          errmsg() like '%ago%', true);
select ck('H8 and why it matters now rather than later',
          errmsg() like '%pauses a project after 7 idle days%', true);

do $$ begin raise notice ' '; raise notice '=== C. the grace period is a day and a half, not a day ==='; end $$;
-- A daily ping that runs a few hours late must not raise the alarm; two missed
-- days must. An alarm that cries wolf gets muted, and a muted alarm is no alarm.
update keepalive_heartbeat set last_ping_at = now() - interval '30 hours' where id = 1;
select ck('H9 30 hours late is still fine', tries(), 'no error');
update keepalive_heartbeat set last_ping_at = now() - interval '37 hours' where id = 1;
select ck('H10 37 hours is not', tries(), 'raised');

do $$ begin raise notice ' '; raise notice '=== D. it recovers by itself when the ping comes back ==='; end $$;
select keepalive_ping();
select ck('H11 one successful ping clears it', tries(), 'no error');

do $$ begin raise notice ' '; raise notice '=== E. a project that was never pinged at all ==='; end $$;
-- Different cause, same need: the job was created wrong and has never run.
delete from keepalive_heartbeat where id = 1;
select ck('H12 reported, not silently OK', tries(), 'raised');
select keepalive_ping();
select ck('H13 and healthy once the first ping lands', tries(), 'no error');

do $$ begin raise notice ' '; raise notice '=== F. who may call it ==='; end $$;
select ck('H14 anon can — monitors send the key in the URL',
          has_function_privilege('anon', 'public.keepalive_health()', 'EXECUTE'), true);
select ck('H15 PUBLIC may not',
          has_function_privilege('public', 'public.keepalive_health()', 'EXECUTE'), false);
select ck('H16 it is STABLE, so a plain GET is allowed through PostgREST',
          (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'keepalive_health'), 's'::"char");
select ck('H17 and it still cannot read the table directly as anon',
          has_table_privilege('anon', 'public.keepalive_heartbeat', 'SELECT'), false);

do $$ begin raise notice ' '; raise notice 'ALL t47 ASSERTIONS PASSED'; end $$;
