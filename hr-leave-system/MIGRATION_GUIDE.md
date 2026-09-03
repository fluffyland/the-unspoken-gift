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

> **You do not run these one at a time.** Everything below is already combined into
> **`supabase/install.sql`** — **one paste** builds the whole database, in the right order,
> with nothing skipped. Then one more paste of `bootstrap_owner.sql` for your first login.
>
> The list is here so you know what is in it, and because the individual files are how you
> **upgrade a database that already exists**. For a new project, ignore them and use
> `install.sql`.

| # | File | What it gives you, in plain words |
|---|---|---|
| 1 | `schema.sql` | The database itself — staff, leave types, applications, the leave ledger, and all the security rules |
| 2 | `migration_app_v1` … `v15` | Years of fixes: English wording, working days and Saturdays, safer cancellation, holiday handling, the company-wide annual-leave maximum |
| 3 | `migration_app_v16.sql` | **Carry-forward, the yearly reset, and the "Start a new year" button** with its permanent record |
| 4 | `migration_app_v18.sql` | Changing a leave type's days credits the difference to everyone; HR can apply leave on someone's behalf; every manual change is recorded |
| 5 | `migration_app_v19.sql` | The number you type **is** that person's entitlement for the year, plus one-click "+N days to everybody" |
| 6 | `migration_app_v24.sql` | Carry-forward expires on **a date you choose** instead of "after N months" |
| 7 | `migration_app_v25.sql` | Closes a hole where an expiry could be silently read as "never expires" |
| 8 | `migration_app_v26.sql` | Handles leave dated in a year already closed off |
| 9 | `migration_app_v27.sql` | **Start a new year refuses to run while leave is awaiting approval**; leavers are frozen; one application cannot span two years |
| 10 | `migration_app_v28.sql` | The setting that limits notification emails to one person while testing |
| 11 | `migration_app_v31.sql` | **Annual leave never grows by itself** — no day per year of service, no first-year pro-rating |
| 12 | `migration_app_v32.sql` | Where notification emails are sent from — filled in by the website itself, not typed twice |
| 13 | `migration_app_v35.sql` | **Every leave record now says which year it belongs to.** Carry-forward is worked out from last year's actual entries instead of being guessed, and Start a new year refuses a year whose allowances have already been credited |
| 14 | `keepalive_ping_v3.sql` | The heartbeat that stops a free project sleeping, and expires due carry-over daily |
| 15 | `undo_year_start.sql` | Puts one "Start a new year" run back exactly as it was. Shows you what it would do before it does anything |

**How to know it worked:** `install.sql` finishes by printing
**"LeaveDesk installed — now run bootstrap_owner.sql to create your first Owner."**
If you see a red error instead, stop and get the message checked rather than running it again.

> **v16 matters even if you skip the rest.** Without it, every leave type keeps
> accumulating: 14 sick days credited in 2026 plus 14 in 2027 is 28, because nothing has
> ever cleared the old year. v16 is what resets them. Until you run it, the app says so on
> the Company settings tab rather than pretending otherwise.

> **v35 is the one to run if you run only one, on a system that is already live.**
> Before it, nothing recorded which leave year an entry belonged to — the system worked it
> out from the day the entry was typed and from the wording of its note. That is why, in
> September 2026, pressing **Start a new year** for a year whose allowances had already been
> credited in July read the top-ups given since July as "last year's leftover" and carried
> them forward, then cleared every other leave type and credited nothing back. v35 makes the
> year a recorded fact, and makes that button refuse a year that is already running.

> **v18 is the one to run if you run only one.** Before it, changing "Days / year" on the
> Leave types tab did **nothing** for anyone already employed — it only affected the next
> yearly credit. The page looked like a control and was a note-to-self.

**v12–v18 are all idempotent** — running one twice changes nothing the second time,
and each ends with verification queries. If you are unsure whether one ran, run it
again rather than guessing.

**Before running `bootstrap_owner.sql`**, open it and edit the name and email
near the top to your own. That account becomes the Owner / Super Admin.

**Check `keepalive_ping_v3.sql` worked:** the last result should show
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
`index.ts`, and click **Deploy**. One file per function — the dashboard deploys `index.ts`
and nothing else.

| Function | Name it exactly | Needed for | Skip it? |
|---|---|---|---|
| `create-login` | `create-login` | one-click staff logins, password resets, revoking access on offboard | **Don't skip.** Without it you create every login by hand in the dashboard. |
| `send-notification` | `send-notification` | email on every approval step | Optional — needs Resend (Part 5) |

> These need no API keys. Supabase injects what they need automatically.

**Public holidays are entered by hand.** There is no sync service: each January somebody
pastes next year's dates from MOM into HR Console → Company settings → Public holidays.
That is deliberate — one fewer thing to break.


> The holiday data is MOM's own, published as a machine-readable feed on
> **data.gov.sg** (collection 691 — its metadata names the Ministry of Manpower as
> both the source and the manager). It is not scraped from the mom.gov.sg web page,
> which would break silently whenever that page was redesigned.

### 1.7 Schedule the automatic jobs

**SQL Editor**, once. Replace `<project-ref>` first:

```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- (Public holidays are entered by hand each January — there is no sync job.)

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

### Turning on leave-notification emails, step by step

*Written out in full because this is where it has gone wrong before: the last Edge Function
in this project was never deployed and had to be deleted.*

**The one thing to understand first.** Two different addresses matter, and only one of them
needs any setup:

| | |
|---|---|
| **Who the email goes TO** | Any address, any time. Just the employee's email in LeaveDesk. Nothing to configure. |
| **Who it comes FROM** | This is what needs proving. Until you verify your domain, Resend will **only deliver to your own signup address** — a hard rule, so unverified accounts cannot be used for spam. |

**So sign up to Resend with the address you want the test emails to land in.** You can then
test the whole thing with no DNS at all. The domain step is only needed later, when you want
*staff* to receive them.

**1 — Resend account** (5 minutes)
1. Go to https://resend.com and sign up **with the address you want test emails to arrive at**.
2. **API Keys → Create API Key**. Name it `leavedesk`. Copy the key (starts `re_`). You only
   see it once.

**2 — Tell Supabase the key** (2 minutes)
Supabase Dashboard → your project → **Edge Functions → Secrets** (called *Manage secrets*),
and add three:

| Name | Value |
|---|---|
| `RESEND_API_KEY` | the `re_…` key you just copied |
| `MAIL_FROM` | `LeaveDesk <onboarding@resend.dev>` — change this only after step 5 |
| `APP_URL` | `https://fluffyland.github.io/hrleavesystem/` |

**3 — Deploy the function** (2 minutes) — **use the dashboard, not the CLI**

The CLI means installing Node tooling and Docker, logging in and linking the project; each
of those can fail for reasons that have nothing to do with your function. The dashboard is a
paste box.

> ### 🚩 The one rule: there must be exactly ONE file, and it is `index.ts`
>
> The dashboard deploys the entry point, `index.ts`, and nothing else. **Any other file you
> add there is not part of what gets deployed** — it simply is not there when the function
> runs, and it disappears from the editor next time you open it.
>
> That is why an earlier version of this guide cost three failed deploys. It said "paste
> `DEPLOY-single-file.ts`", which reads like *make a file called that* — so the code went
> into a file the deploy ignored, `index.ts` kept an import of a file that was not there, and
> the function **never started**. It could not answer anything, so the button sat on
> "Sending…" for ever, and the dashboard still said *successfully deployed* every time.
>
> **Deploying uploads the file. It does not run it.** "Successfully deployed" is not proof
> that anything works. Step 3.5 below is the proof.

1. Supabase Dashboard → **Edge Functions → Deploy a new function**.
2. Name it exactly **`send-notification`** — the app and the webhook both look for that name.
3. It opens with a file called **`index.ts`** holding sample code.
   - **If you see any file other than `index.ts`, delete it.**
   - Click into `index.ts`, select everything, delete it, and paste the whole of
     **`supabase/functions/send-notification/index.ts`** from the repo in its place.
     Same name in both places, on purpose — there is nothing else to reach for.
4. **Deploy.**

**3.5 — Prove it actually started** (10 seconds)

```
cd supabase/functions/send-notification && ./check-deploy.sh
```

It sends only a preflight, so it cannot email anybody. You want:

```
send-notification        HTTP 200 in 0.7s
==> send-notification is UP. It booted and is answering.
```

`HTTP 000` means it is deployed but **did not start** — go back to the rule above and make
sure `index.ts` is the only file. The function's **Logs** tab then shows the error verbatim.

> **Leave "Verify JWT with legacy secret" ON.** You will find it on the function's page
> after deploying. Supabase labels it *"Recommended: OFF with JWT and custom auth logic in
> your function code"* — read the condition: that advice is for functions that check the
> caller themselves. **This one deliberately does not**, so verification is what protects it.
>
> Its own help text says *"The anon key satisfies this"* — which is precisely what the
> webhook sends (step 4 below), and the Send test email button sends the signed-in user's
> token. Both pass, so ON costs nothing.
>
> Switched OFF, anyone who found the function's URL could POST to it. The test send is
> bounded — it resolves its recipient from Company settings, so it cannot be aimed at an
> arbitrary address — but a guessed application id could trigger a real notification about
> real leave. **ON.**

> **Why the repo has three files but you paste one.** `handler.ts` is the logic and
> `templates.js` is the wording; keeping the words in a file with no Deno imports is what lets
> the test suite check every sentence without sending an email. `node build-single.mjs`
> combines them into the self-contained **`index.ts`** you paste, refuses to write a file that
> still imports a sibling, and `node build-single.mjs --check` proves the three have not
> drifted apart. **Never edit `index.ts` by hand** — it is generated.

**4 — Tell the database to call it** — *already done, if you used `install.sql`*

`install.sql` creates this for you from the `project_ref` and `anon_key` you typed at the
top of it. Nothing to fill in by hand.

**If you left those blank**, or you are on a database built before this existed, open
`install.sql`, fill in those two values, and run **just the final section** (from
`-- Apply your settings` to the end). It prints
`Email notifications wired to https://…` when it has done it.

> **Why not the dashboard's Webhooks screen?** Its **timeout** box defaults to **1000 ms**,
> and the function takes 1,100–2,750 ms — measured. At the default, notifications fail now
> and then with nothing on screen to explain it. The SQL version sets 15000 ms.
>
> Either way, **email can never block a leave application**: if the mail call fails, the
> failure is swallowed and the leave is still recorded. Tested by making it throw on purpose.

**When the test email does not work**

| What you see | What it means | What to do |
|---|---|---|
| Spins on "Sending…", then **"it did not start"** | Deployed, but the code never ran. Almost always a second file left in the editor. | `index.ts` must be the only file. Re-paste, Deploy, then `./check-deploy.sh`. The **Logs** tab shows the module error. |
| **"Failed to send a request to the Edge Function"** | The browser could not reach it at all: not deployed, or deployed without the CORS headers. | Check the name appears in the Edge Functions list, and that you pasted the current generated `index.ts`, which answers `OPTIONS`. |
| **"Edge Function returned a non-2xx status code"** | It is deployed *and running* — it ran and refused. | The exact reason is printed underneath. Usually a missing secret. |
| **"RESEND_API_KEY is not set"** | The function is fine; the secret is missing. | Edge Functions → Secrets. |
| Says **sent**, nothing arrives | Resend accepted it. | Check spam. Before the domain is verified, Resend only delivers to your own signup address. |

> Your project's anon key (the long `eyJhbG…` one) **is accepted** by the Edge Functions
> gateway — verified by probe, alongside the newer `sb_publishable_…` key, which behaves
> identically. If a failure is ever really about the key, the response body says
> `INVALID_API_KEY` in as many words. Do not go changing keys on a guess.

**5 — Test it, before any staff member can receive anything**
1. In LeaveDesk: **HR Console → Company settings → Email notifications**.
2. Set **Only send notifications for** to one person, and make sure that person's email in
   *Employees* is the address you signed up to Resend with.
3. **Save changes**, then press **Send test email**.
4. The screen tells you it was sent, or shows the exact error. Check the inbox — first one
   often lands in spam.

While that dropdown names somebody, **only mail addressed to them is ever sent**. Nobody
else in the company can receive anything by accident. Set it back to **Everyone** when you
are happy.

**6 — Letting real staff receive emails: prove the domain is yours**

**Read this part even if the rest looks technical — it is the step that decides whether your
staff ever get an email.**

**Why it is needed.** Anyone can write any name on an envelope. Email is the same: without
proof, a message saying *"from hr@shanghai-uniforms.com"* could have been sent by anybody. So
two things are true until you do this step:

1. **Resend will only deliver to one address** — the one you signed up with. Everyone else is
   refused. This is not a setting you can switch off; it is how they stop spammers.
2. Even if it did send, **Gmail and Outlook would put it in Junk**, because nothing proves the
   mail really came from your company.

Proving it means adding **two short lines of text to your domain's settings**. You are not
changing your website or your email — you are adding a note that says *"Resend is allowed to
send on our behalf."*

**Who does it.** Whoever looks after `shanghai-uniforms.com` — your IT person, or whoever set
up the website. It takes them about five minutes. You do not need to understand the records;
you only need to pass them on.

**Step by step**

1. **Resend → Domains → Add Domain** → type `shanghai-uniforms.com` → **Add**.
2. Resend shows you a small table with **two rows**. Each row has a *Type* (`TXT`), a *Name*,
   and a *Value*. **Copy that whole table** — a screenshot is fine.
3. Send it to whoever manages your domain with this message:

   > *Please add these two TXT records to the DNS for shanghai-uniforms.com. They authorise
   > our HR system to send email from our domain (SPF and DKIM). They do not change our
   > website or our existing mailboxes.*

4. Wait. It is usually minutes, but it can take a few hours. Resend shows **Verified** in
   green when it is done. **Nothing to do meanwhile** — the system keeps working, it just
   keeps emailing only your own address.
5. Once it is green, two changes:
   - Supabase → **Edge Functions → Secrets** → change `MAIL_FROM` to
     `LeaveDesk <hr@shanghai-uniforms.com>`
   - In LeaveDesk → **HR Console → Company settings → Only send notifications for** →
     **Everyone**
6. Apply for a test leave and check that **someone other than you** receives it. That is the
   only test that proves this worked.

> **One thing to get right early:** create the **Resend account itself on a company address**
> (`hr@shanghai-uniforms.com`), not a personal Gmail. That account ends up owning your sending
> domain — you do not want it tied to one person's private mailbox.

> **Nothing here can break LeaveDesk.** Email is never a gate — if the key is missing, the
> function is not deployed, or Resend is down, leave applications and approvals carry on
> exactly as they do now. The worst case is silence.

**7 — There is no second kind of email**

Worth knowing, because it removes a step other guides would tell you to do: **Supabase itself
never sends anything.** Staff accounts are created already confirmed, and there is no
self-service password reset — if somebody forgets theirs, **HR opens Edit employee and presses
Reset password**, which sets it back to `Ssu123@`.

So there is no Supabase SMTP to configure and no hourly email limit to hit. The only email
this system sends is the leave notifications above, through Resend.

## Part 7 — When something goes wrong

| Symptom | Almost always means |
|---|---|
| Site loads, nobody can log in | Lines 258–259 still point at the old project |
| `No API key found in request` | Key is in a header a cron service dropped — put it in the URL |
| `405 cannot execute UPDATE in a read-only transaction` | You used GET on the keep-alive; it must be POST |
| Keep-alive returns a timestamp, not a number | Old read-only function still installed — re-run `keepalive_ping_v3.sql` |
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
