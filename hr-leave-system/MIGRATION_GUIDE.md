# LeaveDesk — Full Setup Guide (new account, from zero)

**Who this is for:** you, setting the whole system up again on a brand-new
account, with nothing carried over.

Follow it top to bottom. Don't skip ahead — later steps need values from
earlier ones. Set aside about **90 minutes** for the first run.

Whenever you see a value in `<angle brackets>`, that's something *you* fill in
from your own setup. Write them into [Appendix A](#appendix-a--your-values)
as you go — you'll need several of them more than once.

---

## Part 0 — What you are building

Three separate things, on three separate services:

| Layer | What it is | Where it lives |
|---|---|---|
| **Database** | all the real data + all the security rules | Supabase |
| **Website** | one HTML file people open in a browser | GitHub Pages |
| **Keep-alive** | pokes the database daily so it never sleeps | 2 cron services + 1 monitor |

The website holds **no** secrets and enforces **no** security. Everything is
enforced inside the database. That is deliberate — even if someone edits the
website in their browser, they cannot see or change data they aren't entitled to.

### Accounts you will need

| # | Website | What for | Cost | Required? |
|---|---|---|---|---|
| 1 | https://supabase.com | the database | free | **yes** |
| 2 | https://github.com | hosting the website + backup keep-alive | free | **yes** |
| 3 | https://cron-job.org | keep-alive keeper #1 | free | **yes** |
| 4 | https://uptimerobot.com | monitoring + phone alerts | free | **strongly recommended** |
| 5 | https://resend.com | password-reset codes + notification emails | free tier | **yes** |

> **Use a company email you will still have in five years** for all of these —
> not a personal address, and not one tied to an employee who might leave.
> Losing access to the Supabase account means losing the database.

---

## Part 1 — Supabase (the database)

### 1.1 Create the project

1. Go to https://supabase.com → **Start your project** → sign up.
2. **New project**.
3. Name: `leavedesk` (anything you like).
4. **Region: Southeast Asia (Singapore)** — closest to your staff.
5. Set a database password. **Save it in your password manager now.** It is
   shown once and you cannot recover it later.
6. Wait ~2 minutes for the project to build.

### 1.2 Copy the two connection values

**Settings → API**, copy both into Appendix A:

- **Project URL** — looks like `https://abcdefgh.supabase.co`
- **anon public** key — a very long string starting `eyJ...`

> The anon key is **safe to make public**. It ends up in your website's source
> code where anyone can read it. It grants nothing by itself — every permission
> is enforced by database rules. Do **not** confuse it with the `service_role`
> key, which is a real secret and must never leave the dashboard.

### 1.3 Build the database

**SQL Editor → New query**, then run these **in order**, one at a time.
Wait for "Success" before starting the next.

| Order | File (from `hr-leave-system/supabase/`) | What it does |
|---|---|---|
| 1 | `schema.sql` | every table, view, function and security rule |
| 2 | `keepalive_ping_v2.sql` | the anti-sleep heartbeat |
| 3 | `bootstrap_owner.sql` | creates your first Owner account |
| 4 | `migration_app_v9.sql` | adds `org_settings.prorate_cap`, which v14 needs |
| 5 | `migration_app_v12.sql` | one working-day authority, Saturday support, cancellation safeguards |
| 6 | `migration_app_v13.sql` | holiday sync stops taking over manually added dates |
| 7 | `migration_app_v14.sql` | annual-leave maximum, and monthly accrual as an option |
| 8 | `migration_app_v15.sql` | cancelling leave that has no approver confirms immediately |
| 9 | `migration_app_v16.sql` | carry-forward per employee, configurable expiry, **the yearly reset**, and the one-button "Start a new year" with its permanent log |
| 10 | `migration_app_v18.sql` | **the Leave types page finally does something** — changing Days / year credits the difference to everyone; annual leave becomes one number you type; HR can apply leave for an employee; every manual change is recorded |
| 11 | `migration_app_v19.sql` | **the typed figure IS the year's entitlement** — saving it reconciles this year to that number instead of guessing from a reason string (v18 wrote nothing at all for anyone added through the app); plus one-click "+N days to every employee" |

⚠️ **v9 is easy to skip and it bites later.** It is the only place
`org_settings.prorate_cap` is created, and v14 rewrites a function that reads that
column — so a database missing v9 fails v14 with
`ERROR: 42703: column "prorate_cap" does not exist`. v14 now adds the column
defensively, so either order works, but running v9 keeps the history honest.
The column has **no control in the app** — a first year is already base × months ÷ 12,
which is below the base, so capping it could only ever reduce a new joiner further.
It exists, it is `null`, and the SQL still reads it.

> **v16 matters even if you skip the rest.** Without it, every leave type keeps
> accumulating: 14 sick days credited in 2026 plus 14 in 2027 is 28, because nothing has
> ever cleared the old year. v16 is what resets them. Until you run it, the app says so on
> the Company settings tab rather than pretending otherwise.

> **v18 is the one to run if you run only one.** Before it, changing "Days / year" on the
> Leave types tab did **nothing** for anyone already employed — it only affected the next
> yearly credit. The page looked like a control and was a note-to-self.

**v12–v18 are all idempotent** — running one twice changes nothing the second time,
and each ends with verification queries. If you are unsure whether one ran, run it
again rather than guessing.

**Before running `bootstrap_owner.sql`**, open it and edit the name and email
near the top to your own. That account becomes the Owner / Super Admin.

**Check `keepalive_ping_v2.sql` worked:** the last result should show
`ping_count = 2`. (The editor only displays the *last* statement's result when
you run several at once — the two lines above it produce output you won't see.
That's normal.)

### 1.4 Turn off public sign-up

**Authentication → Sign In / Providers → Email** → turn **off**
"Enable email signups" (or "Allow new users to sign up").

This matters. Leaving it on means anyone who finds your website URL can create
themselves an account. HR creates all logins from inside the app instead.

### 1.5 Attachment storage (for MC / supporting documents)

1. **Storage → New bucket** → name it exactly `attachments` → set it **Private**.
2. Add storage policies so a logged-in employee can upload to their own folder,
   and only that person, their approvers and HR can read it. Mirror the pattern
   used by the `applications` table policies in `schema.sql`.

> Skip this only if you don't want file attachments at all. Sick-leave types
> that require an MC will fail to submit without it.

### 1.6 Edge Functions

**Edge Functions → Create a new function** in the dashboard. For each one:
create it with the exact name below, paste the whole contents of the matching
`index.ts`, and click **Deploy**.

| Function | Name it exactly | Needed for | Skip it? |
|---|---|---|---|
| `create-login` | `create-login` | one-click staff logins, password resets, revoking access on offboard | **Don't skip.** Without it you create every login by hand in the dashboard. |
| `sync-holidays` | `sync-holidays` | monthly auto-update of Singapore public holidays | Optional — you'd add holidays by hand each year |
| `send-notification` | `send-notification` | email on every approval step | Optional — needs Resend (Part 5) |

> These need no API keys. Supabase injects what they need automatically.

**Test `sync-holidays` right away.** Easiest way, once the website is up: HR Console →
Company settings → Public holidays → **🔄 Sync now**. It reports how many dates were
added, renamed or removed, and says plainly if the function isn't deployed.

From a terminal instead (replace `<project-ref>` with the code from your Project URL):

```
curl -X POST https://<project-ref>.functions.supabase.co/sync-holidays
```

You want `{"ok":true,...}` back. Then check the `holiday_sync_log` table has a
row in it.

> The holiday data is MOM's own, published as a machine-readable feed on
> **data.gov.sg** (collection 691 — its metadata names the Ministry of Manpower as
> both the source and the manager). It is not scraped from the mom.gov.sg web page,
> which would break silently whenever that page was redesigned.

### 1.7 Schedule the automatic jobs

**SQL Editor**, once. Replace `<project-ref>` first:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Public holidays: re-check monthly, and load next year's when MOM publishes them
select cron.schedule('sync-holidays-monthly', '0 19 1 * *', $$
  select net.http_post(url := 'https://<project-ref>.functions.supabase.co/sync-holidays');
$$);

-- 31 Dec: carry forward unused annual leave, then grant the new year's allowance
select cron.schedule('annual-rollover', '0 17 31 12 *', $$
  select rollover_annual_leave(extract(year from (now() at time zone 'Asia/Singapore'))::int);
$$);
select cron.schedule('annual-grant', '30 17 31 12 *', $$
  select grant_annual_entitlements(extract(year from (now() at time zone 'Asia/Singapore'))::int);
$$);
```

> ⚠️ **Do not trust these blindly.** They are the exact jobs most likely to fail
> silently. [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md) tells you how to verify
> each one actually ran, and how to do it by hand if it didn't.

---

## Part 2 — GitHub (website + backup keep-alive)

You need **two** repositories. They must have different visibility, and both
reasons matter.

### 2.1 Repo A — the website (**PUBLIC**)

1. GitHub → **New repository**
2. Name: `hrleavesystem` (or anything)
3. **Public** ← required
4. Create it.

> **Why public:** on the GitHub **Free** plan, GitHub Pages only works from
> public repositories. Making this repo private **unpublishes the website** and
> your HR system goes offline. Only make it private if you pay for GitHub Pro.

Upload two files to the root:

- `index.html` — a copy of `hr-leave-system/app.html`
- `supabase.min.js` — copy it across unchanged (the app loads it from the same
  site rather than a CDN, on purpose)

### 2.2 Point the website at your database

Open `index.html` on GitHub → pencil icon (✎) → find **lines 258–259**:

```javascript
const SUPABASE_URL = "https://aypyolzkdupkpefpxius.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...";
```

Replace both with **your** Project URL and anon key from Appendix A. Commit.

> Get this wrong and the site loads but nobody can log in — it's still talking
> to the old database.

### 2.3 Switch on GitHub Pages

**Settings → Pages**

- Source: **Deploy from a branch**
- Branch: `main`, folder: `/ (root)`
- **Save**

Wait 1–2 minutes. Your site is at:

```
https://<your-github-username>.github.io/<repo-name>/
```

Open it. You should see the LeaveDesk sign-in page.

### 2.4 Repo B — the keep-alive (**PRIVATE**)

1. GitHub → **New repository**
2. Name: `leavedesk-keepalive`
3. **Private** ← required
4. Tick "Add a README"

Then **Add file → Create new file**, and type this as the filename *exactly*:

```
.github/workflows/keepalive.yml
```

(Typing the `/` characters makes GitHub create the folders for you.)

Paste in the keep-alive workflow, and **change the Supabase URL and anon key
near the top to yours**. Commit.

Then **Actions → Keep Supabase awake → Run workflow**. You want a green tick and
a log line reading `Heartbeat counter advanced N -> N+1`.

> **Why private:** GitHub automatically switches off scheduled workflows after
> 60 days without repository activity — but **only in public repositories**
> ([GitHub docs](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)).
> A private repo is exempt. Making this repo public re-arms a 60-day timer on the
> thing protecting your HR system, and a workflow that stops running raises no
> error — silence looks exactly like success.
>
> **Do not** try to dodge that rule with a marketplace "keep alive" action that
> auto-commits. The best-known one was **taken down by GitHub for a terms of
> service violation**. Your GitHub account also hosts the website — an
> enforcement action there would take the whole system down.

---

## Part 3 — Keep-alive and monitoring

Free Supabase projects **pause after 7 days of inactivity**, and are
**permanently deleted 90 days after pausing**. This part is not optional.

> **Read this before you assume a ping is enough.** In July 2026 a keep-alive
> pinged this database every 2 days and returned HTTP 200 every single time —
> and Supabase paused the project anyway. The HR system was down for two weeks.
> The pings were *reads*. **A read does not count as activity.** Everything
> below writes.
>
> Honest caveat: Supabase doesn't document what counts. A write is the best
> available inference, not a guarantee. If it pauses again anyway, stop patching
> and upgrade to Pro (US$25/month).

### 3.1 Keeper #1 — cron-job.org

Sign up, create a cronjob:

| Field | Value |
|---|---|
| URL | `https://<project-ref>.supabase.co/rest/v1/rpc/keepalive_ping?apikey=<anon key>` |
| Method | **POST** |
| Headers | **none** |
| Body | empty |
| Schedule | daily, morning |

> **Put the key in the URL, not in a header.** Web-form cron services often drop
> custom headers, and you get `{"message":"No API key found in request"}`.
> Verified working with no headers at all.
>
> **Must be POST.** GET returns 405 — the function writes, and PostgREST won't
> allow GET for a writing function.

Click **Run now**, then check in Supabase SQL Editor:

```sql
select ping_count from public.keepalive_heartbeat;
```

The number must have gone **up**. If it didn't, the job isn't reaching the
database — fix that before moving on.

### 3.2 Keeper #2 — the private GitHub repo

Already done in step 2.4. It runs daily at 21:17 SGT — deliberately about
**12 hours** from cron-job.org, so one service having a bad day still leaves a
poke that day.

It's the smarter of the two: it calls the function **twice** and requires the
counter to advance, so it can't be fooled by a 200 from a broken setup. On
failure it opens an issue in the repo, which the GitHub mobile app pushes to
your phone.

### 3.3 The watcher — UptimeRobot

The keepers keep it awake. Nothing so far **tells you** when it dies anyway.

1. Sign up at https://uptimerobot.com
2. **Add New Monitor** → type **HTTP(s)**
3. URL:
   ```
   https://<project-ref>.supabase.co/rest/v1/leave_types?select=code&limit=1&apikey=<anon key>
   ```
4. Interval: 5 minutes
5. **Install the UptimeRobot phone app and turn on push notifications.**

> ⚠️ **Monitor the database, not the website.** During the July outage the
> website was up the whole time — GitHub Pages never went down. The page loaded
> fine; people just couldn't log in. A website monitor would have shown green
> for all fourteen days.
>
> ⚠️ **Push notifications, not email.** In July the alerts *did* fire — 8 emails
> — and went unread for two weeks. An alert going somewhere nobody looks is not
> an alert.

Optionally add a second monitor for the website itself.

---

## Part 4 — First sign-in and company setup

1. Open your Pages URL and sign in as the Owner you created in `bootstrap_owner.sql`.
2. **Change your password immediately** — 🔑 **Password** button, top right.
3. **HR Console → Company settings**:
   - Company name (appears in the top bar)
   - Email domain (auto-fills addresses when adding staff)
   - Default Annual Leave Entitled / Yr
4. **HR Console → Leave types** — check the types and day allowances match your
   company policy.
5. **HR Console → Employees & approval routes** — add your people. Each one needs
   an approver; tick two-level approval where you need it.
6. **HR Console → Company settings → Yearly leave allowances** — pick the current
   year and click **Add … leave allowances**. Safe to run twice; anyone already
   set up is skipped.

New logins all get the default password **`Ssu123@`**, shown in a popup when you
add someone. Pass it to the employee and have them change it on first sign-in.

---

## Part 5 — Email (REQUIRED — password resets depend on it)

> ⚠️ **Supabase's built-in email sender cannot be used.** It is capped at **2
> messages per hour** and only delivers to your own team's addresses — it physically
> cannot email your staff. Custom SMTP is mandatory, not a nicety.
> ([docs](https://supabase.com/docs/guides/auth/auth-smtp))

**5a. Resend + custom SMTP**
1. Sign up at https://resend.com, add your company domain, add the **SPF and DKIM
   DNS records** they give you, wait for "Verified". *This is the slow part — DNS,
   not code. Start it early.*
2. Supabase → **Project Settings → Authentication → SMTP Settings** → enable custom
   SMTP with the Resend credentials. Sender must be on the verified domain.
3. **Authentication → Rate Limits** → raise the email limit (the 2/hour cap only
   applies to the built-in sender).

**5b. Password-reset codes**
4. **Authentication → Providers → Email** → make sure email OTP is on.
5. Set the **OTP expiry to ~600 seconds (10 minutes)**. The default is up to an hour,
   and a 6-digit code is only a million guesses — this is the weakest point in the
   flow if you leave it long.
6. **Authentication → Email Templates → Magic Link** — ⚠️ **the one that catches
   everyone:** the stock template sends `{{ .ConfirmationURL }}`, i.e. a *link*.
   Edit it to include **`{{ .Token }}`** or your staff receive an email with no code
   in it. Reword it as a password-reset code message.

**Test it before you move on:** sign-in page → *Forgot your password?* → the email
must arrive with a **6-digit number, not a link**. If it has a link, step 6 wasn't
done.

## Part 5c — Optional: approval notification emails

1. Sign up at https://resend.com (free tier ~100 emails/day), verify your sending
   domain, copy the API key.
2. Install the Supabase CLI, then from the `hr-leave-system/` directory:
   ```bash
   supabase login
   supabase link --project-ref <project-ref>
   supabase secrets set RESEND_API_KEY=re_xxx \
     MAIL_FROM="LeaveDesk <hr@yourcompany.sg>" \
     APP_URL=https://<your-github-username>.github.io/<repo-name>/
   supabase functions deploy send-notification --no-verify-jwt
   ```
3. **Database → Webhooks → Create**:
   - Table: `application_events`, Event: **INSERT**
   - Type: HTTP Request → the `send-notification` function URL

---

## Part 6 — Final verification

Don't call it done until **every** line passes.

### Database
- [ ] `schema.sql` ran with "Success"
- [ ] `keepalive_ping_v2.sql` ran, last result showed `ping_count = 2`
- [ ] Owner account created and password changed
- [ ] Public sign-up is **off**
- [ ] `attachments` bucket exists and is **Private**
- [ ] `create-login` deployed (named exactly `create-login`)
- [ ] `migration_app_v9.sql` ran — `prorate_cap` column exists
- [ ] `migration_app_v12.sql` ran — working-day authority, Saturday columns, safer cancellation
- [ ] `migration_app_v13.sql` ran — `public_holidays.updated_at` exists, manual dates survive a sync
- [ ] `migration_app_v14.sql` ran — `annual_cap` and `accrual_mode` exist in Company settings → Leave policy
- [ ] `migration_app_v16.sql` ran — Company settings shows **Start a new year** (not
      "Credit leave of…"), the Employees tab has a **Carry-forward** column, and
      `select count(*) from year_start_log;` returns a number rather than an error
- [ ] `keepalive_ping_v3.sql` ran — the daily ping now also expires carried days
      (`select keepalive_ping();` twice should return N then N+1)
- [ ] `migration_app_v18.sql` ran — the HR Console shows **Leave Application** and
      **Amendment records** tabs (not "Balance adjustments"), Edit employee says
      **Annual Leave Entitled / Yr**, and `select count(*) from hr_amendments;` returns a
      number rather than an error
- [ ] `migration_app_v19.sql` ran — `select bump_annual_all(0);` fails with "Enter a number
      of days" (it exists), and Leave types → Annual Leave → Edit shows a greyed, empty
      **Days / year** with **Credit to all employees** under it
- [ ] `migration_app_v15.sql` ran — last query shows **0** stuck cancellations
- [ ] Someone with **no approver** can cancel approved leave and the days come straight back
- [ ] Resend verified, custom SMTP on, OTP expiry ~10 min
- [ ] A reset code actually arrives, and it is a **6-digit number, not a link**
- [ ] `sync-holidays` returns `{"ok":true}` and `holiday_sync_log` has a row
- [ ] pg_cron jobs scheduled (`select * from cron.job;` lists three)

### Website
- [ ] Repo A is **public**, Pages is on, the URL loads
- [ ] Lines 258–259 point at **your** project, not the old one
- [ ] You can sign in, and a test employee can too

### Keep-alive
- [ ] cron-job.org job runs, `ping_count` goes up
- [ ] Repo B is **private**, workflow ran green
- [ ] The two are roughly 12 hours apart
- [ ] UptimeRobot watches the **database** URL
- [ ] **Phone push notifications are on and you have received a test one**

### End to end
- [ ] Employee applies for leave → approver sees it → approves → balance drops
- [ ] Company calendar shows Singapore public holidays
- [ ] A rejected/returned application behaves sensibly

---

## Part 7 — When something goes wrong

| Symptom | Almost always means |
|---|---|
| Site loads, nobody can log in | Lines 258–259 still point at the old project |
| `No API key found in request` | Key is in a header a cron service dropped — put it in the URL |
| `405 cannot execute UPDATE in a read-only transaction` | You used GET on the keep-alive; it must be POST |
| Keep-alive returns a timestamp, not a number | Old read-only function still installed — re-run `keepalive_ping_v2.sql` |
| Website up but nothing works | Database paused. Supabase dashboard → **Restore** |
| Employee can't submit sick leave | `attachments` bucket or its policies missing |
| "Add employee" doesn't create a login | `create-login` not deployed, or misnamed |
| Public holidays missing | See [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md) |
| Scheduled workflow stopped | Repo B was made public and hit the 60-day rule |

**If the project is paused:** Supabase dashboard → the project → **Restore**.
Takes a few minutes, and no data is lost — *provided* you're inside the 90-day
window. After 90 days it cannot be recovered.

---

## Appendix A — your values

Fill this in as you go. Keep it somewhere safe but not public.

| Item | Value |
|---|---|
| Supabase project URL | `https://__________.supabase.co` |
| Supabase project ref | `__________` (the bit before `.supabase.co`) |
| anon public key | `eyJ__________` |
| Database password | *(password manager — not here)* |
| Website repo | `github.com/______/______` (**public**) |
| Live website URL | `https://______.github.io/______/` |
| Keep-alive repo | `github.com/______/______` (**private**) |
| cron-job.org account | `__________` |
| UptimeRobot account | `__________` |
| Owner login email | `__________` |

## Appendix B — the three visibility rules

Getting these backwards is the easiest way to break everything, and none of
them announce themselves when they go wrong.

1. **Website repo must be PUBLIC** — private kills Pages on the Free plan, and
   the site goes offline.
2. **Keep-alive repo must be PRIVATE** — public re-arms the 60-day auto-disable,
   and it fails silently.
3. **The anon key is meant to be public** — it's in the website source by design.
   The `service_role` key is the real secret. Never put that in the website.

---

## Related documents

| Document | For |
|---|---|
| [`GUIDE_HR.md`](GUIDE_HR.md) | HR / Owner day-to-day operations |
| [`GUIDE_EMPLOYEE.md`](GUIDE_EMPLOYEE.md) | hand this to staff |
| [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md) | annual routine + what to verify |
| [`HANDOVER.md`](HANDOVER.md) | technical handover for a developer |
| [`NEW_COMPANY_SETUP.md`](NEW_COMPANY_SETUP.md) | resets and per-company SOP |
