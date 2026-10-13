-- ============================================================================
-- v43 — the Owner links itself. One paste, then one click, and you can sign in.
--
-- Asked for, after being told to scroll to the bottom of a 10,000-line file and
-- re-run a block out of the middle of it: "i dont want a paste and stitch job".
--
-- They were right, and the instruction was worse than fiddly — it could not work.
-- install.sql's last block reads _leavedesk_setup and then DROPS it on the next
-- line, so "run just this last section again" fails with
-- `relation "_leavedesk_setup" does not exist`. The one recovery step the setup
-- guide offered was broken.
--
-- What happens now:
--   1. paste install.sql once. It records who the Owner is to be.
--   2. Authentication -> Users -> Add user  (dashboard clicks, no pasting)
--   3. a trigger on auth.users notices that login appear and creates the Owner
--      employee row, linked, immediately. Nothing else to run.
--
-- Order does not matter. If the login already exists when install.sql runs, it is
-- linked there and then. If it turns up later, the trigger catches it.
--
-- The guard is the email, not "is this the first person". Anyone could be first;
-- only one address was named at install. It is also one-shot: the pending address
-- is cleared the moment it is claimed, so the trigger cannot mint a second Owner.
-- ============================================================================

alter table org_settings add column if not exists pending_owner_email text;
alter table org_settings add column if not exists pending_owner_name  text;
comment on column org_settings.pending_owner_email is
  'The address named as Owner at install, kept until a matching login appears. Cleared the moment it is claimed — it is a one-shot invitation, not a standing rule.';

-- ---------------------------------------------------------------- the claim
create or replace function claim_pending_owner(p_auth_user uuid, p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare want text; who text; n int;
begin
  if p_auth_user is null or coalesce(trim(p_email), '') = '' then return 'no email'; end if;

  -- An employee row already carrying this address: attach the login to it rather
  -- than making a second one. This is the case where somebody ran install.sql,
  -- deleted the login, and made it again.
  update employees set auth_user_id = p_auth_user
   where lower(email) = lower(trim(p_email)) and auth_user_id is distinct from p_auth_user;
  get diagnostics n = row_count;
  if n > 0 then return 'relinked existing employee'; end if;
  if exists (select 1 from employees where lower(email) = lower(trim(p_email)))
    then return 'already linked'; end if;

  select nullif(trim(pending_owner_email), ''), coalesce(nullif(trim(pending_owner_name), ''), 'Owner')
    into want, who from org_settings where id = 1;
  if want is null then return 'no owner pending'; end if;
  if lower(want) <> lower(trim(p_email)) then return 'not the pending owner'; end if;

  insert into employees (name, email, join_date, role, active, auth_user_id, dept)
  values (who, lower(trim(p_email)), current_date, 'admin', true, p_auth_user,
          (select name from departments order by name limit 1));
  -- One shot. A second login on the same address can no longer become an Owner.
  update org_settings set pending_owner_email = null where id = 1;
  return 'owner created';
end $$;
revoke execute on function claim_pending_owner(uuid, text) from anon, authenticated, public;

-- ---------------------------------------------------------------- the trigger
-- Wrapped so it can NEVER stop a login being created. A failure here must cost
-- the Owner row, not the account: an exception would roll back the dashboard's
-- own insert and the symptom would be "Add user doesn't work", with nothing to
-- say why.
create or replace function on_auth_user_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform claim_pending_owner(new.id, new.email);
  exception when others then
    raise warning 'LeaveDesk: could not link Owner for % — %', new.email, sqlerrm;
  end;
  return new;
end $$;

-- auth.users belongs to Supabase. Creating a trigger on it is their documented
-- pattern, but if the role running this file is not allowed to, the install must
-- still succeed — so this is attempted, not assumed, and the outcome is reported.
do $$
begin
  drop trigger if exists trg_leavedesk_owner on auth.users;
  create trigger trg_leavedesk_owner after insert on auth.users
    for each row execute function on_auth_user_created();
exception when others then
  raise warning 'LeaveDesk: no trigger on auth.users (%). The Owner will be linked '
                'when you first open the app instead.', sqlerrm;
end $$;

-- ---------------------------------------------------------------- who is it
-- install.sql creates _leavedesk_setup at the top with the six values typed into
-- it, and drops it at the very bottom. This migration runs in between, so it can
-- read them itself.
--
-- It is recorded HERE rather than in install.sql's footer deliberately: a footer
-- that reads a column added by a migration cannot run on a database built without
-- that migration, and the test harness builds exactly such a database to check the
-- upgrade path. A migration owning the data it introduces has no such problem.
do $$
begin
  if to_regclass('_leavedesk_setup') is null then return; end if;
  execute $q$
    update org_settings o set
      pending_owner_email = case
        when exists (select 1 from employees e
                      where lower(e.email) = lower(trim((select owner_email from _leavedesk_setup))))
          then null
        else lower(nullif(trim((select owner_email from _leavedesk_setup)), '')) end,
      pending_owner_name  = nullif(trim((select owner_name from _leavedesk_setup)), '')
    where o.id = 1
  $q$;
exception when others then
  raise warning 'LeaveDesk: could not record the pending Owner (%)', sqlerrm;
end $$;

-- ---------------------------------------------------------------- catch-up
-- The login may already exist: somebody adds the user first, then runs the SQL.
do $$
declare r record;
begin
  for r in select u.id, u.email from auth.users u
            join org_settings o on lower(o.pending_owner_email) = lower(u.email)
           where o.id = 1
  loop
    perform claim_pending_owner(r.id, r.email);
  end loop;
end $$;

-- ---------------------------------------------------------------- last resort
-- If the trigger could not be created, the app calls this on first load. It is
-- safe to expose: it only ever acts on the caller's OWN auth identity, and only
-- for the one address named at install.
create or replace function claim_owner_self()
returns text language plpgsql security definer set search_path = public as $$
declare e text;
begin
  if auth.uid() is null then return 'not signed in'; end if;
  select email into e from auth.users where id = auth.uid();
  return claim_pending_owner(auth.uid(), e);
end $$;
revoke execute on function claim_owner_self() from anon, public;
grant  execute on function claim_owner_self() to authenticated;
