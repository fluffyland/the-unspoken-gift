-- ============================================================================
-- v46 — an alarm that goes off every time it is checked, not once.
--
-- Asked, after the keepalive ping had been dead for weeks:
--   "why it only email once after it fail and it stopped cannot it keep sending
--    everyday?"
--
-- It cannot. cron-job.org says so in the mail it sends: "we will send no further
-- failure notifications until then." It notifies on the TRANSITION from working to
-- broken, once. Miss that one mail and there is silence for as long as it stays
-- broken — which is exactly how a dead ping went unnoticed until the project was
-- nearly paused.
--
-- The deeper fault is the shape, not the setting: the thing doing the pinging was
-- also the only thing reporting on it. A ping that is never attempted sends no
-- failure mail at all, and a cron account that quietly disables a job sends
-- nothing either. So this is the other half — something a monitoring service can
-- poll forever, which FAILS while the heartbeat is stale, for any reason:
--
--     the cron job was deleted, paused, or never ran
--     the cron provider had an outage
--     a migration revoked the permission again (this is what happened)
--     the project is paused and nothing works at all
--
-- Because a monitor re-checks every few minutes and re-alerts on its own schedule,
-- "once" stops being a problem. The alarm is a state, not an event.
--
-- It raises rather than returning a value, so an ordinary HTTP monitor is enough:
-- PostgREST turns a raised exception into a non-2xx response, which is all any
-- uptime service needs. No keyword configuration to get wrong.
--
-- STABLE, so a plain GET works: PostgREST only allows GET on a function it knows
-- does not write, and most monitoring services only send GET.
-- ============================================================================

create or replace function public.keepalive_health()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare t timestamptz; n bigint;
begin
  select last_ping_at, ping_count into t, n from public.keepalive_heartbeat where id = 1;

  if t is null then
    raise exception
      'LEAVEDESK KEEPALIVE NEVER RAN. No heartbeat has ever been recorded. The daily '
      'ping has not reached this database once. Check the cron job exists, is enabled, '
      'uses POST, and that anon has execute on keepalive_ping().';
  end if;

  -- 36 hours: a daily ping may legitimately be a few hours late, but two missed days
  -- is not lateness. Tight enough to notice within a day, loose enough not to cry
  -- wolf over a slow scheduler.
  if t < now() - interval '36 hours' then
    raise exception
      'LEAVEDESK KEEPALIVE IS STALE. Last ping % (% ago), count %. Free Supabase '
      'pauses a project after 7 idle days, so this needs attention now, not later.',
      to_char(t, 'YYYY-MM-DD HH24:MI'), age(now(), t), n;
  end if;

  return 'OK last_ping=' || to_char(t, 'YYYY-MM-DD HH24:MI') || ' count=' || n;
end $$;

comment on function public.keepalive_health() is
  'Health endpoint for an uptime monitor. Returns OK while the daily keepalive ping is recent; raises (non-2xx over PostgREST) once it is more than 36 hours stale. Point a monitor at it so a dead ping is reported continuously rather than in a single email that can be missed.';

revoke execute on function public.keepalive_health() from public;
-- anon, for the same reason keepalive_ping() needs it: monitoring services send the
-- key in the URL and drop custom headers. It exposes one timestamp and one counter,
-- and cannot change anything — the function is STABLE.
grant execute on function public.keepalive_health() to anon, authenticated;

do $$
begin
  if not has_function_privilege('anon', 'public.keepalive_health()', 'EXECUTE') then
    raise exception 'v46 FAILED: anon cannot call keepalive_health, so no monitor can either';
  end if;
  raise notice 'v46 installed: keepalive_health() is callable by anon.';
end $$;
