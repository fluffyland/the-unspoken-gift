# LeaveDesk — Standard Operating Procedure (SOP)
## Setting up for a new company · Full system reset · First-day operations

_Last updated: 15 Jul 2026. Time needed: about 30–40 minutes for a complete new-company setup._

---

## 0. How the system is put together (read this first)

LeaveDesk is two independent pieces:

| Piece | What it is | Where it lives | Cost |
|---|---|---|---|
| **Frontend** (the website people open) | one file: `app.html`, served as `index.html` | GitHub Pages | free |
| **Backend** (data, logins, permissions) | a Supabase project | supabase.com | free tier is enough for 20–100 staff |

They are connected by **exactly two lines** near the top of `app.html`:

```js
const SUPABASE_URL      = "https://xxxxxxxx.supabase.co";   // ← line ~255
const SUPABASE_ANON_KEY = "eyJhbGciOi...";                   // ← line ~256
```

Change those two lines → the same website talks to a different company's
database. The anon key is **safe to be public** — all security is enforced
inside the database (RLS), not by hiding the key.

**Files you need** (all in the repo folder `hr-leave-system/`):

| File | Used for |
|---|---|
| `app.html` | the whole frontend |
| `supabase/schema.sql` | builds the entire backend in one run |
| `supabase/bootstrap_owner.sql` | creates the very first Owner account |
| `supabase/functions/create-login/index.ts` | one-click staff logins |
| `supabase/reset_all_data.sql` | full data wipe (SOP-2, Option B) |

---

## SOP-1 · Stand up LeaveDesk for a NEW company

### Step 1 — Create the Supabase project (≈5 min)
1. Go to **https://supabase.com/dashboard** → sign in → **New project**.
2. Fill in:
   - **Name**: anything, e.g. `leavedesk-newco`
   - **Database password**: click *Generate*, then **save it somewhere safe**
     (you rarely need it, but losing it is annoying)
   - **Region**: **Southeast Asia (Singapore)**
3. Click **Create new project** and wait ~2 minutes until the project opens.

### Step 2 — Copy the two connection values (≈1 min)
1. Left sidebar → **Settings** (gear icon) → **API**.
2. Copy and keep in a notepad:
   - **Project URL** — looks like `https://abcdefgh.supabase.co`
   - **anon public** key — the long string under *Project API keys*
     (NOT the `service_role` one — never copy that anywhere).

### Step 3 — Build the database (≈3 min)
1. Left sidebar → **SQL Editor** → **New query**.
2. Open `supabase/schema.sql`, select **all** of it (Ctrl+A), copy, paste
   into the editor.
3. Click **Run** (bottom-right).
4. ✅ Expected: **"Success. No rows returned."**
   ❌ If you get a red error instead, stop — copy the red text and get it
   checked (don't run it again blindly).

This single run creates: all tables, the balance ledger, the approval state
machine, row-level security, the `attachments` storage bucket, Singapore's
statutory leave types, and the public-holiday calendar. All messages English.

### Step 4 — Create the first Owner / Super Admin (≈4 min)
Every other account can be created inside the app — but the *first* person
must be made by hand (the app's "create login" checks that the caller is
already HR, and on day zero nobody is).

**4a. Make the login:**
1. Left sidebar → **Authentication** → **Users** → **Add user** →
   *Create new user*.
2. Email: the owner's real email. Password: `Ssu123@`.
3. Tick **Auto Confirm User** → **Create user**.

**4b. Make them an employee with Owner rights:**
1. Open `supabase/bootstrap_owner.sql` and edit the two marked lines
   (real name + the same email as 4a).
2. SQL Editor → New query → paste → **Run**.
3. ✅ The query at the bottom should return one row with `role = admin`
   and a non-empty `auth_user_id`.

### Step 5 — Deploy the create-login function (≈3 min)
This lets the Owner/HR create every future staff login with one click.
1. Left sidebar → **Edge Functions** (the `ƒ` icon) →
   **Deploy a new function** → choose **Via Editor**.
2. Function name: exactly `create-login`
3. Delete the sample code, paste the whole of
   `supabase/functions/create-login/index.ts`, click **Deploy**.
4. No secrets/environment variables needed — Supabase injects them.

### Step 6 — Point the website at the new backend (≈5 min)
Option A — new site for the new company (recommended):
1. Create a new GitHub repository (e.g. `newco-leave`).
2. Copy `app.html` into it, **renamed as `index.html`**.
3. Edit lines ~255–256: paste the **Project URL** and **anon public key**
   from Step 2.
4. Also copy `supabase.min.js` from the old repo into the new one
   (the app loads it from its own folder).
5. Repo → **Settings → Pages** → *Deploy from a branch* → branch `main`,
   folder `/ (root)` → Save. Wait 1–2 minutes.
6. Your site is at `https://<username>.github.io/<repo-name>/`.

Option B — reuse the existing site for a different backend: just edit the
same two lines in the current repo's `index.html` and push.

### Step 7 — First sign-in & company basics (≈10 min, inside the app)
1. Open the site → log in with the Owner email + `Ssu123@`.
2. Top-right **🔑 Password** → change away from the default.
3. **HR Console → Company settings**: company name, email domain,
   default annual-leave base, pro-rate cap if wanted. **Save changes**.
4. **HR Console → Leave types**: tick/untick attachment-required,
   half-day allowed; add company-specific types if any.
5. **HR Console → Employees & approval routes → Add employee** for each
   person. On save the app:
   - credits their pro-rated annual leave + standard entitlements, and
   - **auto-creates their login** with password `Ssu123@` (popup shows it).
   Add managers before their team members, so approvers exist when you
   assign approval routes.
6. Tell everyone: log in with work email + `Ssu123@`, then change password.

### Step 7b — Stop the free project from pausing (**REQUIRED**, ≈2 min)

免费版 Supabase **7 天没有活动就会自动暂停**，暂停后 HR 系统直接打不开，
而且 **暂停满 90 天项目会被永久删除**。

1. SQL Editor → New query → 粘贴 **`supabase/keepalive_ping_v2.sql`** → **Run**。
   最后一格应显示 **`ping_count = 2`**。
   （SQL Editor 一次跑多条语句时只显示最后一条的结果，前面两行的返回值看不到，
   这是正常的。计数器能到 2，就证明两次调用都真的写进了磁盘 —— 只读的旧版永远是 0。）
2. 确认 `.github/workflows/keepalive.yml` 在部署仓库的 **默认分支** 上。
   定时任务只从默认分支运行 —— 放在别的分支等于没放。
3. Actions 分页 → **Keep Supabase awake** → **Run workflow** 手动跑一次，确认绿灯。

> ⚠️ 2026-07 教训：旧版心跳只做「读」，每次都返回 HTTP 200，项目照样被暂停，
> 系统停摆两周才被发现。**纯读不算活动，必须写。**
> 写入也只是推断而非官方保证 —— 如果还会被暂停，就升级 Pro（US$25/月）。

### Step 8 — Optional extras (any time later)
| Want | Do | Where documented |
|---|---|---|
| Public holidays auto-update from MOM | deploy `sync-holidays` + pg_cron | `SETUP.md` §7 |
| Email on every approval step | deploy `send-notification` + Resend + webhook | `SETUP.md` §4 |
| Automatic 1 Jan carry-over + new-year grant | two pg_cron lines | `SETUP.md` "每年例行维护" |

> If you skip the holiday sync: the calendar ships with **2026** holidays.
> Add later years by hand in HR Console → Company settings, or deploy the
> sync function when needed.

### ✅ Completion checklist (SOP-1)
- [ ] schema.sql ran with "Success"
- [ ] Owner logs in and changed their password
- [ ] create-login deployed (name exactly `create-login`)
- [ ] Site live with the new URL + anon key
- [ ] `keepalive_ping_v2.sql` ran and the last result shows **`ping_count = 2`**
- [ ] `keepalive.yml` on the deploy repo's **default** branch, manually run once, green
- [ ] Company settings + teams + employees entered
- [ ] A test application → approve → shows in Decision history

---

## SOP-2 · FULL RESET (hand the system to a new company)

Two ways — pick one.

### Option A — Delete the whole Supabase project (cleanest, recommended)
Nothing survives: data, logins, files, functions all gone.
1. Supabase → **Settings → General** → scroll down → **Delete project**
   (type the project name to confirm).
2. Follow **SOP-1** from Step 1 with a brand-new project.

Use this when: you don't need to keep the same Supabase URL, and you want
zero chance of old data leaking to the new company.

### Option B — Keep the project, wipe the data
Same URL/keys stay, `create-login` stays deployed; all people & records go.
1. SQL Editor → paste **`supabase/reset_all_data.sql`** → **Run**.
   - Deletes: employees, all logins, applications, approvals, ledger,
     announcements, carry-over records, departments.
   - Keeps: table structure, permissions, SG leave types, public holidays.
   - The verification query at the end must show **all zeros**.
   - The optional block at the bottom sets the new company's name/domain
     (or do it later in the app).
2. **Storage → attachments**: delete leftover uploaded files (MC photos).
   SQL cannot remove files — this manual step matters for privacy.
3. Re-create the first Owner → **SOP-1 Step 4** (Add user + bootstrap_owner.sql).
4. If the new company gets a different website: **SOP-1 Step 6**.

### ⚠️ Before any reset
- This is **irreversible**. If the old company might ever ask for records
  (audits, MOM disputes), take a backup first:
  Supabase → **Database → Backups**, or export `employees`, `applications`,
  `leave_ledger` as CSV from the Table Editor.
- Do the reset outside working hours — everyone is logged out instantly.

---

## SOP-3 · Yearly routine (every company, once a year)

If you did NOT set up the pg_cron automation, run these two lines in the
SQL Editor each 1 January (order matters — carry-over first, then grant):

```sql
select rollover_annual_leave(2027);      -- carry unused AL (max 5) into the new year
select grant_annual_entitlements(2027);  -- credit everyone's new-year allowances
```

Both are idempotent — running them twice will not double-credit.

---

## Troubleshooting (the greatest hits)

| Symptom | Cause → Fix |
|---|---|
| Red error when running schema.sql | You pasted only part of the file. Ctrl+A to select ALL, re-copy, re-run in a **new** query tab. |
| "Add employee" errors about login | `create-login` not deployed, or name isn't exactly `create-login`. Check Edge Functions list. |
| Owner can't log in | Auth user email ≠ employee email, or **Auto Confirm** wasn't ticked. Check Authentication → Users, then re-run bootstrap_owner.sql. |
| Password `Ssu123@` rejected at creation | Authentication → *Policies/Providers*: set minimum password length ≤ 7 and disable leaked-password protection. |
| Site loads but login spins forever | The two lines in `index.html` point at the wrong project, or schema.sql was never run in this project. |
| GitHub file links 404 | Every file lives under the `hr-leave-system/` folder — the path must contain `hr-leave-system/supabase/...`. |
| Old Chinese text in ancient records | Cosmetic only; the app translates it on screen. New entries are English. |
| Approver left the company | Offboard them in the app — their pending items transfer to you and their team's routes are cleared automatically. |

---

## Quick answers

**Do I need to touch Supabase day-to-day?** No. After setup, everything —
adding staff, logins, password resets, offboarding, deleting test data —
is done inside the app by HR/Owner.

**Where are passwords stored? Can I see them?** Nowhere and no — passwords
are one-way hashed. Reset to `Ssu123@` from the Edit form when someone forgets.

**Can two companies share one Supabase project?** No — one project per
company. The app has no concept of "which company", so mixing them would
show everyone everything.

**What should I keep secret?** The database password (Step 1) and anything
labelled `service_role`. The anon key and the site URL are public by design.
