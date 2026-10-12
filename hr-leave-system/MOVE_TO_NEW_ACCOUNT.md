# Moving LeaveDesk to a new account — same system, same settings, no staff data

For: a new Supabase project and a new GitHub account under **hr@shanghai-uniforms.com**,
holding the identical system with the identical settings and **nobody in it yet**.

Nothing here touches the old system. It keeps running until you decide otherwise.

---

## What is being moved, and what is not

| | Moves | How |
|---|---|---|
| The whole application | ✅ | 3 files uploaded to the new GitHub repo |
| The whole database structure | ✅ | `supabase/install.sql`, one paste |
| Company settings, both expiry dates | ✅ | `supabase/export_settings.sql` |
| Leave types — **your** days (Hospitalisation 57, Shared Parental 65, …) | ✅ | same |
| Public holidays, every date and name | ✅ | same |
| Teams, and which work Saturdays | ✅ | same |
| Employees, logins, applications, approvals, the ledger, carry-forwards, amendment records, MC attachments | ❌ **by design** | nothing carries them |

`install.sql` on its own gives you the **MOM defaults** — Hospitalisation 60, Shared
Parental 70, the standard holiday list. That is not your setup. `export_settings.sql` is
what makes the new system match the old one, and it is checked by
`tests/t43_export_settings.sh`: it builds both databases for real, exports, imports, and
compares every settings column rather than the ones somebody remembered.

---

## The two keys that connect the halves

```js
const SUPABASE_URL      = "https://xxxxxxxx.supabase.co";   // app.html, line ~263
const SUPABASE_ANON_KEY = "eyJhbGciOi...";                   // app.html, line ~264
```

Change those two lines and the same website talks to the new company's database. The
anon key is **meant to be public** — every permission is enforced inside the database
(RLS), never by hiding the key. It is safe in a public repo and safe to paste into chat.

The **service_role** / `sb_secret_…` key is the opposite: it bypasses every permission.
It is never needed for any step below. Do not paste one anywhere.

---

## Order of work

### A · On the OLD project — take the settings out (2 min)

1. Supabase dashboard → the **old** project → **SQL Editor** → **New query**.
2. Paste the whole of `supabase/export_settings.sql` → **Run**.
3. One column of text comes back. **Copy all of it** and keep it — that is your settings
   script. It is read-only; it changed nothing.

### B · On the NEW account — build the database (10 min)

4. **supabase.com** → sign in as **hr@shanghai-uniforms.com** → **New project**.
   Region **Southeast Asia (Singapore)**. Save the database password somewhere safe.
5. Wait for the project to open, then **SQL Editor → New query**.
6. Paste `supabase/install.sql`. **Before running, edit the six values at the top:**

   | Value | Put |
   |---|---|
   | `company_name` | Shanghai School Uniforms Pte Ltd |
   | `email_domain` | shanghai-uniforms.com |
   | `default_annual_leave` | 14 |
   | `default_carry_cap` | 5 |
   | `owner_name` | your name |
   | `owner_email` | hr@shanghai-uniforms.com |

   Run it. It ends by printing
   **"LeaveDesk installed — now run bootstrap_owner.sql…"**.
   It will warn that it found no login for the Owner yet. That is expected — step 7.
7. **Authentication → Users → Add user**: email `hr@shanghai-uniforms.com`, a password
   you choose, and **tick Auto Confirm User**. Without the tick the account cannot sign in.
8. **SQL Editor → New query** → paste the last section of `install.sql` again (the
   `do $$ … end $$;` block at the very bottom) and Run. It now finds the login and links
   it to the Owner record. It will say `Owner created and linked: hr@shanghai-uniforms.com`.
9. **SQL Editor → New query** → paste the settings script from step 3 → **Run**. It ends
   by printing your settings and `employees_should_be_zero`. Check that number is **0**
   and that Hospitalisation reads 57 and Shared Parental 65.

### C · On the NEW account — put the website up (10 min)

10. **github.com** → sign in to the new account → **New repository**.
    Name it anything (e.g. `hrleavesystem`). It **must be Public** — GitHub Pages does
    not serve a private repo on the free plan.
11. Upload three files from `hr-leave-system/`:
    - `app.html`, **renamed to `index.html`**, with lines 263–264 changed to the new
      project's URL and anon key (Supabase → **Project Settings → API**)
    - `supabase.min.js` — exactly as it is
    - `year-start-flowchart.html` — exactly as it is
12. Repo → **Settings → Pages** → Source: **Deploy from a branch** → branch `main`,
    folder `/ (root)` → Save. Two minutes later the site is at
    `https://<new-account>.github.io/<repo>/`.
13. Open it, sign in as `hr@shanghai-uniforms.com`, and check the HR console →
    **Leave types** shows 57 and 65, and **Company settings** shows both expiry dates.

### D · On the NEW account — the parts that are easy to forget (15 min)

14. **Storage** → the attachments bucket is created by `install.sql`. Nothing to do.
15. **Edge Functions.** Two of them, in `supabase/functions/`:
    - `create-login` — the one-click staff login button. Without it, HR cannot create
      logins from the app.
    - `send-notification` — the approval emails.
    Deploy both (Supabase dashboard → Edge Functions → Deploy, or the CLI).
    `send-notification` needs a secret: **`RESEND_API_KEY`**, from your Resend account.
    The app writes its own address into the database the first time you sign in as
    HR/Owner, so there is nothing to copy for that.
16. **Keep the project awake.** The free plan pauses a project after **7 idle days**.
    This has already caused a two-week outage once. Point a daily ping at the new
    project — `cron-job.org`, calling `keepalive_ping` — and add it to UptimeRobot.
    `MIGRATION_GUIDE.md` has the exact URLs and headers.
    **If the new account is on a paid Supabase plan, skip this step entirely.** It exists
    only to work around the free tier.

### E · Afterwards

17. Add your staff: HR console → **Employees & approval routes → Add employee**.
    Each person's annual-leave entitlement is set here, per employee.
18. Nothing has been deleted from the old system. When you are satisfied the new one is
    right, decide separately whether to retire the old project, and move its keepalive
    ping over rather than leaving two pointing at the old one.

---

## Checking it worked

Run `supabase/explain_balances.sql` on the **new** project. On a correct empty system:

- sections A, C, D and E come back empty — there are no people to have balances
- section B lists nothing — there is nobody holding the wrong entitlement
- section F shows **your** figures: Hospitalisation 57, Shared Parental 65,
  Compassionate 3, and both expiry dates as you set them

If section F shows 60 and 70, the settings script from step 3 was not run. Run it.

---

## What cannot be done for you

The new GitHub and Supabase accounts are yours, and nothing in this session can sign in
to them: no project can be created, no SQL run, and no file pushed to the new repo from
here. Steps B, C and D are dashboard work in your own browser. What can be prepared for
you is everything that is a file or a script — including an `index.html` with the new
URL and anon key already filled in, if you paste those two values.
