// Build ONE file that stands up the whole database, for a brand-new Supabase project.
//
// Why this exists, in the user's words: "all the migration why i have to do one by one,
// omg... cant you just compile into one". They were right. Nineteen separate pastes in the
// correct order, none skipped, is not a setup procedure — and the guide itself proved the
// point by listing only thirteen of them for months.
//
// The individual files STAY. They are the upgrade path for a database that already exists.
// This is only for a new one.
//
// Generated, never hand-edited: `node build-install.mjs`. install.sql is proved by building
// a fresh Postgres from it ALONE and running the entire SQL suite against the result.
import fs from 'fs';
const dir = new URL('.', import.meta.url).pathname;

// Order is the whole point. schema first, then every migration by number, then the heartbeat.
const nums = fs.readdirSync(dir)
  .map(f => (f.match(/^migration_app_v(\d+)\.sql$/) || [])[1])
  .filter(Boolean).map(Number).sort((a, b) => a - b);

const parts = ['schema.sql', ...nums.map(n => `migration_app_v${n}.sql`), 'keepalive_ping_v3.sql'];
for (const f of parts)
  if (!fs.existsSync(dir + f)) { console.error('BUILD FAILED — missing', f); process.exit(1); }

const head = `-- ============================================================================
-- LeaveDesk — install.sql   ⚙️  GENERATED FILE, do not edit by hand
--
-- ONE paste sets up a brand-new database. Supabase Dashboard → SQL Editor →
-- New query → paste all of this → Run. It takes a few seconds.
--
-- Then run ONE more file: bootstrap_owner.sql — kept separate because you have to
-- type your own email and password into it.
--
-- This replaces the old procedure of pasting ${parts.length} files one at a time in the
-- right order. Missing one left the system subtly wrong in a single place, which is
-- very hard to work out later.
--
-- ⚠️ For a NEW, EMPTY project only. If your database already exists, do NOT run this —
--    use the individual migration_app_vNN.sql files, which upgrade it in place.
--
-- Contains, in order:
${parts.map((f, i) => `--   ${String(i + 1).padStart(2)}. ${f}`).join('\n')}
--
-- Regenerate with:  node build-install.mjs
-- ============================================================================

`;


const CONFIG = `-- ============================================================================
--  ✏️  FILL THIS IN — the only part of this file you edit
-- ============================================================================
--  Change the values between the quotes, then run the whole file.
--  Leave project_ref / anon_key blank if you are not setting up email yet;
--  you can run just the last section again later to add it.
-- ----------------------------------------------------------------------------
drop table if exists _leavedesk_setup;
create table _leavedesk_setup (
  company_name         text,     -- appears on screen and in every email
  email_domain         text,     -- staff email addresses, e.g. shanghai-uniforms.com
  default_annual_leave numeric,  -- days a new employee starts on
  default_carry_cap    numeric,  -- most days anyone may carry into next year
  owner_name           text,     -- YOU — the first HR/Owner account
  owner_email          text,     -- must match the login you created in Authentication
  project_ref          text,     -- from your project URL: https://XXXX.supabase.co
  anon_key             text      -- Settings -> API -> anon public key
);
insert into _leavedesk_setup values (
  'My Company',
  'company.com',
  14,
  5,
  'Owner Name',
  'owner@company.com',
  '',
  ''
);
-- ============================================================================
--  Nothing below here needs editing.
-- ============================================================================

`;

const FOOTER = `

-- ============================================================================
--  Apply your settings, link your Owner account, and switch email on.
--  Reads the values you typed at the top of this file.
-- ============================================================================
do $$
declare c _leavedesk_setup%rowtype; n int; fn_url text;
begin
  select * into c from _leavedesk_setup;

  -- ---- 1. company settings -------------------------------------------------
  update org_settings set
    company_name        = coalesce(nullif(trim(c.company_name), ''), company_name),
    email_domain        = nullif(trim(c.email_domain), ''),
    default_annual_base = coalesce(c.default_annual_leave, default_annual_base),
    default_carry_cap   = coalesce(c.default_carry_cap, default_carry_cap)
  where id = 1;
  raise notice 'Company set to: %', c.company_name;

  -- ---- 2. link the Owner to the login you made in Authentication -----------
  -- The login itself is created in the dashboard (Authentication -> Add user).
  -- SQL cannot make one: it belongs to Supabase's own auth system.
  insert into employees (name, email, join_date, role, active, auth_user_id, dept, gender)
  select c.owner_name, lower(trim(c.owner_email)), current_date, 'admin', true, u.id,
         (select name from departments order by name limit 1), 'F'
    from auth.users u
   where lower(u.email) = lower(trim(c.owner_email))
     and not exists (select 1 from employees e where lower(e.email) = lower(trim(c.owner_email)));
  get diagnostics n = row_count;
  if n > 0 then
    raise notice 'Owner created and linked: %', c.owner_email;
  elsif exists (select 1 from employees where lower(email) = lower(trim(c.owner_email))) then
    raise notice 'Owner already existed: %', c.owner_email;
  else
    raise warning 'NO LOGIN FOUND for %. Create it first: Authentication -> Add user (tick Auto Confirm User), then run just this last section again.', c.owner_email;
  end if;

  -- ---- 3. email notifications ---------------------------------------------
  -- Replaces the Database Webhook you would otherwise create by hand, including
  -- its timeout box, which defaults to 1000 ms and is shorter than the function
  -- takes -- notifications then fail intermittently with nothing on screen.
  if coalesce(nullif(trim(c.project_ref), ''), '') = '' then
    raise notice 'Email not switched on (project_ref blank). Fill it in and re-run this last section when you are ready.';
  else
    fn_url := 'https://' || trim(c.project_ref) || '.supabase.co/functions/v1/send-notification';
    begin
      create extension if not exists pg_net;
    exception when others then
      raise warning 'pg_net could not be enabled (%). Email will not send.', sqlerrm;
    end;
    execute format($f$
      create or replace function leavedesk_notify() returns trigger
      language plpgsql security definer set search_path = public as $body$
      begin
        -- Email must NEVER block a leave application. If anything here fails,
        -- swallow it: the leave is already recorded, the email is a courtesy.
        begin
          perform net.http_post(
            url := %L,
            headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || %L),
            body := jsonb_build_object('type','INSERT','table','application_events',
                                       'schema','public','record', to_jsonb(new)),
            timeout_milliseconds := 15000);
        exception when others then null;
        end;
        return new;
      end $body$;$f$, fn_url, trim(c.anon_key));

    drop trigger if exists trg_leavedesk_notify on application_events;
    create trigger trg_leavedesk_notify after insert on application_events
      for each row execute function leavedesk_notify();
    raise notice 'Email notifications wired to %', fn_url;
  end if;
end $$;

drop table if exists _leavedesk_setup;

-- ============================================================================
--  Done.
-- ============================================================================
do $$
begin
  raise notice ' ';
  raise notice 'LeaveDesk installed. Next: deploy the two Edge Functions, then point';
  raise notice 'app.html at this project (two lines near the top).';
  raise notice ' ';
end $$;
`;

let out = head + CONFIG;
for (const f of parts) {
  const body = fs.readFileSync(dir + f, 'utf8');
  out += `\n\n-- ===========================================================================\n`
       + `-- ${f}\n`
       + `-- ===========================================================================\n\n`
       + body.trimEnd() + '\n';
}

out += FOOTER;

// A psql meta-command (\\i, \\set) would work in a terminal and fail silently-ish in the
// Supabase SQL editor, which is where this is actually pasted.
const meta = out.split('\n').find(l => /^\\\\[a-z]/.test(l));
if (meta) { console.error('BUILD FAILED — psql meta-command will not run in the dashboard:', meta); process.exit(1); }

fs.writeFileSync(dir + 'install.sql', out);
console.log(`wrote install.sql — ${parts.length} files, ${out.split('\n').length} lines`);
console.log('  ' + parts.join('  '));
