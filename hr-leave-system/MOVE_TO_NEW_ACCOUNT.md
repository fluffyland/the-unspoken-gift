# LeaveDesk on the new account — what was done, and what is left

**Never paste this file anywhere.** It is a `.md` — notes for reading. Pasting it into the
SQL Editor produces `syntax error at or near "|"`, because the tables below are Markdown,
not SQL. Only `.sql` files get pasted.

New project: `qpixlkcltjvzpamyspad` · Owner: `hr@shanghai-uniforms.com`
The old system is untouched and still running. Both stay live for now.

---

## Done

| | |
|---|---|
| ✅ | **Database built.** One paste. 17 leave types, 14 public holidays, 0 employees. |
| ✅ | **Owner created and signed in.** The employee row was made automatically when the login appeared in Authentication — no second script. |
| ✅ | **Website live.** `index.html`, `supabase.min.js`, `year-start-flowchart.html` in a public repo with Pages enabled. `index.html` already carries the new project's URL and anon key. |

Verified against the live project, not assumed: a table that does not exist returns 404
while `leave_types`, `org_settings` and `employees` return 200, so the schema is really
there; `keepalive_ping` answers, so the install reached its end; and reading as `anon`
returns empty — which is **RLS working**, not an empty database.

---

## Left to do

### 1 · Settings from the old project (5 min, two pastes)

The installer seeds Singapore MOM defaults. Your old company is not on all of them —
Hospitalisation is 57, not 60. This copies the differences across and carries **no**
employee data.

1. Supabase → the **OLD** project → SQL Editor → paste **`export_settings.sql`** → Run.
   It only reads. It prints one column of text.
2. Copy that whole column. Supabase → the **NEW** project → SQL Editor → paste it → Run.

It carries company settings and both expiry dates, public holidays, and teams.
It does **not** carry leave types — you chose to set those up fresh, so the new system
stays on Hospitalisation 60 / Shared Parental 70 until you retype them on the
**Leave types** tab. The old figures are printed in the script as a reference line, and
if you change your mind, delete the `-- ` from the front of section 3's lines and run it
again.

To confirm afterwards, run **`explain_balances.sql`** on the new project. Section F shows
what every leave type and both expiry dates are set to.

### 2 · The two Edge Functions (10 min, no GitHub)

These are pasted into the **Supabase dashboard**, not uploaded to GitHub.

| Function | What breaks without it |
|---|---|
| `create-login` | HR cannot create staff logins from the app |
| `send-notification` | No approval emails. **Nothing else** — leave applications and approvals never wait on email |

Dashboard → **Edge Functions** → Deploy a new function → name it exactly
`create-login` / `send-notification` → paste that function's `index.ts` → Deploy.

**Keep the name `index.ts`.** The dashboard deploys the entry point called `index.ts` and
silently ignores anything else in the editor. A file named something else looks deployed,
reports success, and never runs. That mistake cost this project three failed deploys.

Then **Edge Functions → Secrets**, three of them:

| Secret | Value |
|---|---|
| `RESEND_API_KEY` | from a Resend account **of your own** — see below |
| `MAIL_FROM` | `LeaveDesk <onboarding@resend.dev>` to start with |
| `APP_URL` | your new site's address, e.g. `https://<account>.github.io/<repo>/` |

`APP_URL` has no fallback on purpose: set it, or the links inside the emails are blank.
Leave **"Verify JWT with legacy secret" ON** for `send-notification` — the function has no
auth logic of its own, so that verification is what protects it.

**Resend must be a new account** under `hr@shanghai-uniforms.com`. Reusing the old API key
would leave the new system depending on an account tied to your old email, which is the
one thing you asked to avoid.

### 3 · Keep the project awake — you now need TWO of everything (15 min)

The free Supabase plan **pauses a project after 7 idle days** and deletes it 90 days
later. This already cost a two-week outage once. Both systems are staying live, so:

| | Old project | New project |
|---|---|---|
| cron-job.org daily ping | exists — **leave it pointing at the old one** | add a **second** job |
| UptimeRobot monitor | exists | add a **second** monitor |

The mistake to avoid is re-pointing the existing ping at the new project. The old one then
goes quiet and Supabase pauses it. `MIGRATION_GUIDE.md` has the exact URLs and headers.

**On a paid Supabase plan none of this section is needed.** It exists only to work around
the free tier, and it is the single change that removes the most moving parts.

### 4 · Then add your staff

HR console → **Employees & approval routes → Add employee**. Annual-leave entitlement is
set per employee there. Saving a figure on the **Leave types** tab levels everyone
eligible to it, so set the types before adding people and there is nothing to level.

---

## Independence from the old account — checked, not assumed

Every outbound URL and identifier in the code was searched. There are **no** hardcoded
links to the old account:

| Possible tie | Reality |
|---|---|
| Old Supabase project | Was only in `index.html` lines 263–264. The file you uploaded has zero occurrences of the old ref. |
| `fluffyland.github.io` in the email function | A **comment** showing an example. The real value is the `APP_URL` secret, per project, with no fallback. |
| `notify_url` / `notify_key` in the database | The app writes them from its own URL on first HR sign-in. `export_settings.sql` deliberately excludes them, so the new project cannot inherit the old one's address. |
| `supabase.min.js` | Committed and served from your own site. Nothing is fetched from any CDN at page load. |
| `mom.gov.sg` | A link HR clicks. Not a dependency. |
| Any personal email in the code | None. |

The three real shared-account risks are **Resend**, the **cron ping** and the **uptime
monitor** — all in section 2 and 3 above, all set up separately.

Still documenting the old project: `HANDOVER.md`, `SETUP.md` and `MIGRATION_GUIDE.md`.
That is history, not code, and cannot connect anything.

---

## Which file is which

| File | Run it on | Ends with |
|---|---|---|
| `LEAVEDESK-paste-this-once.sql` | NEW project, once | `as next_step;` |
| `2-owner-autolink.sql` | NEW project, once | `as next_step;` |
| `export_settings.sql` | **OLD** project | `"copy this whole column back to me"` |
| `explain_balances.sql` | either, any time | `"copy this whole column back to me"` |
| anything `.md` or `.txt` | **nowhere** — reading only | — |

If a SQL error mentions a line containing `|` characters, a `.md` was pasted by mistake.
