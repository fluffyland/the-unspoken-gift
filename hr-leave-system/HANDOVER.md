# HANDOVER — LeaveDesk SG (HR leave-management system)

_Audience: the next AI assistant (or developer) taking over this project._
_Written: 16 Jul 2026. Everything below was verified against the live system on that date._

---

## 1. What this project is

**LeaveDesk** is a leave-management web app for **Shanghai School Uniforms Pte Ltd**
(Singapore, ~20 staff). Employees apply for leave; managers approve; HR manages
balances, employees, logins and company settings. It implements Singapore MOM
statutory leave rules (14 types seeded), pro-rated annual leave, carry-forward
(max 5 days, used-first, expires 31 Dec), public-holiday awareness, and a
one/two-level approval state machine.

- **Live site**: https://fluffyland.github.io/hrleavesystem/
- **Status**: feature-complete, user is actively TESTING with throwaway data.
  Not yet in production use.

## 2. The user (important — read this)

- Communicates in casual English, sometimes mid-task via short messages.
- **Not a developer.** Give click-by-click dashboard instructions, never raw
  concepts. They struggled to find "Edge Functions" in Supabase; they broke
  GitHub links by hand-editing paths.
- **Verify, don't trust "done".** Twice they said they'd deployed/run
  something and it hadn't taken effect. Probe the live system (see §9) and
  report what you actually observed.
- They notice UI sloppiness (clumped text, Chinese leftovers) and call it
  out hard. Test the UI consequences of every change.
- Preferred password for everything: default `Ssu123@` (their choice).

## 3. Architecture (two repos + one Supabase project)

```
SOURCE REPO   github.com/fluffyland/the-unspoken-gift
  branch: claude/hr-leave-system-design-cnojo8
  folder: hr-leave-system/          ← ALL work happens here
  (repo root = an UNRELATED gift-box e-commerce site; its CLAUDE.md at the
   repo root is for THAT project. Do not apply it to LeaveDesk, and do not
   touch the gift-box files. Keep the two projects fully separate.)

DEPLOY REPO   github.com/fluffyland/hrleavesystem   (branch: main)
  index.html         ← copy of app.html; GitHub Pages serves this
  supabase.min.js    ← vendored supabase-js (same-origin, no CDN)
  .github/workflows/keepalive.yml  ← pings DB every 2 days (free tier pauses after 7 idle days)

BACKEND       Supabase project ref: aypyolzkdupkpefpxius
  URL:  https://aypyolzkdupkpefpxius.supabase.co
  Postgres (tables/RLS/functions) + Auth + Storage(attachments) + Edge Functions
```

**Frontend** = ONE file, `hr-leave-system/app.html` (~2000 lines: CSS + HTML
shell + a single inline `"use strict"` script). No build step, no framework.
It connects using the **anon public key** (embedded at lines ~255-256 — safe,
it's public by design). ALL security = database RLS + security-definer RPCs.
A hostile client can't do anything RLS doesn't allow.

## 4. Deployment procedure (every change)

```bash
cd hr-leave-system
# 1. edit app.html   2. verify (see §8)   3. then:
cp app.html index.html
cd .. && git add -A && git commit && git push -u origin claude/hr-leave-system-design-cnojo8
# 4. deploy repo (in a fresh session, clone it first):
cp hr-leave-system/index.html <clone-of-hrleavesystem>/index.html
cd <clone> && git add -A && git commit && git push -u origin main
# Pages redeploys automatically in 1-2 min.
```

Session-specific: in the session that wrote this, the deploy repo was cloned
at `/workspace/hrleavesystem`. A new session must re-clone it.

**Commit rules** (required): end every commit message with
`Co-Authored-By:` and `Claude-Session:` trailers (see git log for format).
Never put the AI model id in commits/PRs/code. **No PRs unless the user asks.**

## 5. Database state — what has actually been applied (verified 16 Jul 2026)

Migrations are cumulative SQL files the USER pastes into Supabase SQL Editor
(you have no direct DB access — you only write files and instruct).

| Applied? | What | Evidence |
|---|---|---|
| ✅ base schema + v1–v6 | tables, RLS, state machine, half-days, directory view | app works |
| ✅ v7 (inside v8) | holiday sync tables, announcements, carry-forward | works |
| ✅ v8 | emp_no/alias/mobile, new leave types, `is_admin()`, self-edit guard trigger | works |
| ❌ **v9 — NOT applied** | `org_settings.prorate_cap` + capped `annual_entitlement_for` | probed: `column org_settings.prorate_cap does not exist` |
| ✅ v10 | `purge_employee`, `clear_employee_records`, offboard hardening, guard bypass GUC | probed: functions exist |
| ✅ v11 | ALL DB messages/ledger reasons/announcements → English | probed: English errors |
| ❓ `reset_all_passwords.sql` | one-time reset of all logins to `Ssu123@` | user asked for it; not re-verified |

v9 is **optional** — the frontend feature-detects (`db.orgProrate`) and hides
the pro-rate-cap field until it's applied. Don't assume it; don't chase it
unless the user wants the cap feature.

**Edge Functions state:**
| Function | State |
|---|---|
| `create-login` | ✅ deployed, LATEST version (probe: returns "Only HR can manage logins.") — handles create / `action:"reset"` / `action:"remove"`, default pw `Ssu123@`, Owner-target protection |
| `sync-holidays` | written in repo; deployment to Supabase **unverified** — pg_cron schedule also unverified |
| `send-notification` | written in repo; **NOT set up** (needs Resend key + DB webhook; email flow never configured) |

**Auth model**: Supabase Auth users are linked to `employees.auth_user_id`
(FK, on delete set null). First-ever account is made manually
(`bootstrap_owner.sql`); all others via the app → `create-login` function.
Roles: `employee` / `approver` (Manager) / `hr` (HR Admin) / `admin`
(Owner/Super Admin — only Doris). HR cannot touch an Owner's login/data
(enforced in the Edge Function AND in SQL AND hidden in UI).

## 6. File inventory (`hr-leave-system/`)

| File | Purpose |
|---|---|
| `app.html` | THE app. Edit this, never index.html directly. |
| `index.html` | deploy copy of app.html (`cp`, then push to both repos) |
| `supabase.min.js` | vendored supabase-js v2 (same-origin; new sites must copy it too) |
| `README.md`, `DESIGN.md` | early design notes (partly outdated; trust code + this file) |
| `SETUP.md` | original backend setup guide + optional extras (email, cron, holiday sync) |
| `NEW_COMPANY_SETUP.md` | **SOP manual**: stand up a new company / full reset / yearly routine / troubleshooting |
| `HANDOVER.md` | this file |
| `keepalive.yml` | reference copy; live one is in deploy repo `.github/workflows/` |
| `supabase/schema.sql` | **complete backend, one-shot, kept in sync with every migration** — the source of truth for a fresh install |
| `supabase/migration_app_v1..v11.sql` | incremental history; user has applied through v11 EXCEPT v9 |
| `supabase/bootstrap_owner.sql` | create first Owner (edit name/email inside) |
| `supabase/reset_all_data.sql` | wipe all people/records/logins, keep types+holidays |
| `supabase/reset_all_passwords.sql` | set every login's password to `Ssu123@` |
| `supabase/delete_employee_fully.sql` / `clear_employee_records.sql` | standalone SQL-editor equivalents of the app's Delete/Clear buttons (needed because SQL editor runs as postgres where `is_hr()` is false) |
| `supabase/seed.sql` | demo data (early phase; superseded by real usage) |
| `supabase/functions/create-login/index.ts` | login lifecycle Edge Function (see §5) |
| `supabase/functions/sync-holidays/index.ts` | MOM public-holiday sync from data.gov.sg (collection 691) |
| `supabase/functions/send-notification/index.ts` | email notifications via Resend (not configured) |

## 7. Frontend internals (what you need to modify it safely)

Global state: `me` (current employee), `db` (all loaded data), `vp`
(view-local state incl. modals/drafts), `view` (current page), `hrTab`.
Flow: `loadAll()` fetches everything → `render()` rebuilds the whole DOM from
template strings → event delegation via ONE `document` click listener
(`data-act` attributes), one `change` listener (`data-f`), one `input`
listener (live text sync). `reload()` = loadAll + render.
**Pattern trap**: after a mutation, you must call `render()` — a missed
render caused the "approve did nothing" bug.

Key conventions:
- **Deploy-order safety**: frontend may ship before the user runs a
  migration. Feature-detect columns (`db.empExtra`, `db.ltHalf`,
  `db.orgProrate` flags set in `loadAll` via fallback queries) and degrade
  gracefully with a friendly "run the update first" message.
- **Staged saves** in HR Console: edits go to `vp.draft` (`stageType/
  stageEmp/stageOrg`, read via `tPick/ePick/oPick`), a save bar shows a
  change count, `saveDraft()` commits, discarding requires confirm
  (`leaveModal()`); navigation away is intercepted (`vp.leaveTo`).
- **Language safety nets**: `zhToEn()` (DB error translation), `reasonEn()`
  (old ledger rows), `annEn()` (old announcements). DB is English since v11,
  but old rows keep Chinese forever — never remove these.
- **Dates**: ISO `yyyy-mm-dd` internally, `fmtDMY()` renders DD/MM/YYYY,
  `dmyToIso()` parses typed DD/MM/YYYY (hire date is a free-typed text
  field, NOT `<input type=date>` — user hated the native picker).
- **Balances**: never stored — always `sum(leave_ledger.delta_days)` per
  type (`bal()` with `db.balCache`).
- Modals live in `vp.*Modal`; `case "closemodal"` must delete every modal key.
- `esc()` everything user-entered when templating.

## 8. Verification harness (no test framework — this pattern instead)

Headless Playwright (pre-installed at `/opt/node22/lib/node_modules/playwright`,
chromium at `/opt/pw-browsers`). Pattern: extract `<style>` + inline script
from app.html into a temp page, stub `window.supabase`, then call render
functions directly with fake `me`/`db`/`vp` and assert on returned HTML:

```js
const html = fs.readFileSync("app.html","utf8");
const style  = html.match(/<style>[\s\S]*?<\/style>/)[0];
const inline = html.match(/<script>\s*"use strict";[\s\S]*?<\/script>/)[0];
// build page with a supabase stub, page.evaluate(() => { me={...}; db={...}; vp={};
//   return approvalCard(app); }) → regex-assert on the HTML string
```

Previous suites (verify4–verify10, ~85 assertions) lived in the session
scratchpad — **gone after the session ends**; recreate on demand. Also run
`node --check` on the extracted script after every edit, and keep `$$`
counts even in any SQL file you touch.

## 9. Remote verification trick (use this instead of trusting "I ran it")

The anon key can probe what's ACTUALLY deployed (RLS makes it harmless):

```bash
ANON="<anon key from app.html line ~256>"
U="https://aypyolzkdupkpefpxius.supabase.co"
# Does a function exist / which language are its errors? (P0001 message tells you)
curl -s -X POST "$U/rest/v1/rpc/act_on_step" -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"p_app":"00000000-0000-0000-0000-000000000000","p_action":"approve","p_comment":null,"p_ack":false}'
# Does a column exist? (42703 = no)
curl -s "$U/rest/v1/org_settings?select=prorate_cap" -H "apikey: $ANON" -H "Authorization: Bearer $ANON"
# Which create-login version is live? old says "create logins", new says "manage logins"
curl -s -X POST "$U/functions/v1/create-login" -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{"action":"reset","email":"probe@nowhere.test"}'
```

## 10. Security invariants (NEVER break these)

1. A service_role key (`sb_secret_NpslWoCNtGAV2LRwbzU03g_...`) was **revoked**
   by the user. Never attempt to use any service key; Edge Functions get
   theirs auto-injected by the platform.
2. **Never write user passwords to files on disk.** (Chat display is OK —
   e.g. the default `Ssu123@` in docs is accepted by the user.)
3. The anon key is public by design — RLS is the trust boundary. Keep every
   privileged operation behind `is_hr()` / `is_admin()` checks server-side.
4. **Owner protection**: HR must not be able to reset/remove/create an
   Owner's login, or delete/offboard/clear an Owner. Enforced in three
   layers (Edge Function, SQL functions, UI gating on STORED role). Keep
   all three when refactoring.
5. Self-protection: nobody deletes/offboards themself; non-admin can't edit
   own approvers/leave-base/role (DB trigger `guard_employee_self_edit`;
   service functions bypass via transaction-local GUC `leavedesk.svc`).
6. Keep LeaveDesk and the gift-box site strictly separate.

## 11. Feature changelog (condensed; git log has details)

Base system (v1–v6): schema, RLS, state machine (submit → 1/2-level approve /
return / reject / withdraw / cancel+refund), ledger balances, half-days
(per-day AM/PM), attachments bucket, HR console, offboarding, mobile fixes,
login-stuck fix, iOS zoom fix.
Then: **v7** MOM holiday auto-sync + in-app announcements + next-year
view-only calendar + carry-forward(5, used-first) · required-field `*` ·
HR holiday editing + HR-only change alerts · **microcopy humanisation pass**
(one consistent plain-English voice) · **v8 HR-console overhaul** (14 items:
balances tidy, My details tab + entitlement view, emp_no/alias/mobile, new
record-only leave types incl. Overseas Trip/Training/Others, leave-type
add/edit UI, attachment-required toggles, Team/Account-type split, 4 roles,
Hire date, 1st/2nd approver relabels + auto two-level, self-edit lock, no
Chinese in UI) · staged saves + discard confirm · DD/MM/YYYY everywhere ·
pro-rate cap (needs v9) · **create-login one-click** (+ reset `Ssu123@`,
+ remove on offboard) · **v10** delete-permanently & clear-records buttons +
security audit (FK cleanups, stuck-approval reassignment, Owner protection,
approver-ref detach on offboard) · sortable Recent-adjustments · **v11**
all-English DB + client translation nets · approve-feedback render fix ·
approval-card redesign (labelled grid + half-day chips + red zero balance) ·
My team card (auto-updating same-dept roster) · free-typed hire date ·
SOP manual + bootstrap/reset scripts.

## 12. Known gaps / offered-but-not-built / watch-outs

- **v9 not applied** → pro-rate cap UI hidden. Harmless. Apply only if wanted.
- **Storage orphans**: deleting/clearing an employee does NOT remove their
  uploaded MC files from the `attachments` bucket. Manual cleanup; a cleanup
  routine was offered, not requested.
- **sync-holidays deployment + pg_cron: unverified.** Holidays seeded for
  2026 only — check before 2027 (SOP has manual fallback).
- **Email notifications**: never configured (needs Resend + webhook).
- **Offered, user never confirmed**: "Login ✓/✗" column in the Employees
  list; email-invite flow instead of default password.
- Old announcements/ledger rows keep bilingual/Chinese text in the DB —
  translated at display time only. Don't "fix" the data.
- `leave_types.name_zh` column still exists/seeded — unused by UI. Ignore.
- User runs migrations by hand and sometimes reports success when a red
  error occurred — always re-probe (§9).

## 13. If the user asks for X, the pattern is…

- **New feature** → edit `app.html`; if schema must change, write
  `migration_app_v12.sql` (idempotent!) AND mirror it into `schema.sql`;
  make the frontend feature-detect so deploy order never matters; verify
  (§8); deploy both repos (§4); tell the user exactly what to paste/run,
  then verify remotely (§9).
- **"It's broken"** → reproduce in the harness first; check whether the
  needed migration/function is actually live (§9) before touching code.
- **Anything with links** → curl the URL and confirm 200 before sending.
  Files live under `hr-leave-system/…` — path mistakes have burned trust.
- **Bigger asks** (multi-company, payroll export, etc.) → discuss design
  first; this is a single-tenant system by construction (§ Quick answers in
  NEW_COMPANY_SETUP.md).
