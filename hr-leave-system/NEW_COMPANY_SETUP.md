# Setting up LeaveDesk for a new company (and how to fully reset)

Two independent parts make up the system:

| Part | What it is | Where it lives |
|---|---|---|
| **Frontend** | one file, `app.html` → served as `index.html` | GitHub Pages (a repo) |
| **Backend** | Postgres tables + auth + storage + functions | a Supabase project |

The frontend is tied to a backend by **just two lines** in `app.html`:

```js
const SUPABASE_URL      = "https://<your-project-ref>.supabase.co";   // line ~255
const SUPABASE_ANON_KEY = "<your anon public key>";                    // line ~256
```

Everything else (permissions, who-can-see-what) is enforced by the Supabase
database, so the anon key is safe to put in the file.

---

## Part 1 — Stand up a brand-new company (recommended: fresh Supabase project)

### A. Create the backend
1. **New Supabase project** → https://supabase.com/dashboard → *New project*.
   Region **Southeast Asia (Singapore)**. Save the database password.
2. **Get the connection info**: Project *Settings → API* → copy the
   **Project URL** and the **anon public** key.
3. **Build the schema**: *SQL Editor → New query* → paste all of
   `supabase/schema.sql` → **Run**. (One shot: every table, view, function,
   RLS policy, the `attachments` storage bucket, and the SG leave-type +
   public-holiday seeds. All messages are in English.)
4. **First Owner account** (chicken-and-egg: one-click login needs an existing
   HR, so the very first person is made by hand):
   - *Authentication → Users → Add user*: their email, password `Ssu123@`,
     tick **Auto Confirm User**.
   - *SQL Editor* → run `supabase/bootstrap_owner.sql` (edit the name/email
     inside first). This inserts them as **Owner / Super Admin** and links the
     login.
5. **Deploy the `create-login` Edge Function** (so the Owner can create all
   other staff logins from the app, no Supabase needed again):
   *Edge Functions → Create a new function* → name it exactly `create-login`
   → paste `supabase/functions/create-login/index.ts` → **Deploy**.
   (No secrets to set — the platform injects them.)

That is the minimum to be fully operational.

### B. Point a frontend at it
Two ways:

- **Reuse this app, new site**: create a new GitHub repo, copy `app.html` into
  it as `index.html`, change the two lines (URL + anon key) to the new
  project's, enable **Settings → Pages → Deploy from branch**. Done.
- **Same repo, different backend**: just edit the two lines and redeploy.

### C. Optional extras (only if the company wants them)
- **Automatic public-holiday sync** (yearly MOM updates): deploy the
  `sync-holidays` Edge Function and add the pg_cron schedule — see
  `SETUP.md` §7.
- **Email notifications** on every approval step: deploy `send-notification`
  + Resend API key + a database webhook — see `SETUP.md` §4.
- **Yearly carry-over / grant automation**: the pg_cron lines in `SETUP.md`.
- **Cap pro-rated annual leave**: already in the schema (`org_settings.prorate_cap`),
  set it in the app under HR Console → Company settings.

### First-run checklist
- [ ] `schema.sql` run (no errors)
- [ ] Owner created + can log in with `Ssu123@`
- [ ] `create-login` deployed
- [ ] `app.html` two lines updated + site live
- [ ] Owner adds departments, then employees (logins auto-created)

---

## Part 2 — Fully reset / wipe, to hand over to a new company

Pick one:

### Option A — Delete the project and start fresh (cleanest, zero leftovers)
1. Supabase → *Settings → General → Delete project* (removes all data, auth,
   storage, functions — nothing survives).
2. Do **Part 1** above with a new project.
This is the safest "full reset" and what I recommend if you don't need to keep
the same URL.

### Option B — Reuse the same project, wipe the data
Keeps the project (same URL/keys, `create-login` stays deployed) but clears all
people and records:
1. *SQL Editor* → run `supabase/reset_all_data.sql`.
   - Deletes: all employees, logins, applications, ledger, announcements, carry.
   - Keeps: the SG leave types and public holidays (statutory config).
   - The verification query at the end should show all zeros.
2. *(Optional)* also clear Storage: *Storage → attachments* → delete any
   leftover uploaded files (the SQL doesn't touch uploaded files).
3. Re-bootstrap the first Owner (step A4 above) — Add user + `bootstrap_owner.sql`.

> Note: SQL cannot delete Storage files; if the old company uploaded MC/attachments,
> clear them in the Storage UI (or delete the whole `attachments` bucket and let
> `schema.sql` recreate it).

---

## What each helper file is for
| File | Purpose |
|---|---|
| `supabase/schema.sql` | The complete backend. Run once per new project. |
| `supabase/bootstrap_owner.sql` | Create the very first Owner / Super Admin. |
| `supabase/reset_all_data.sql` | Wipe all data but keep the project (Option B). |
| `supabase/functions/create-login/index.ts` | One-click staff logins (create / reset / remove). |
| `SETUP.md` | The optional extras (holiday sync, email, cron). |
