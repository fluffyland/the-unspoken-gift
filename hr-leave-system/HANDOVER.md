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
- **When they give you a sentence, ship that sentence.** They have twice supplied
  exact wording and twice got something "improved" back, with the reply *"dont add
  your own word if i given you some sentence just follow because you always make it
  worst"*. If their text needs a change to fit (a template already prefixing ⚠, a
  tense that would contradict the line above it), make the template fit their words —
  or use a shorter subset of their own words. Never substitute your own.
- **They hate jargon in user-facing copy.** "Edge Function", "deployed",
  "sync-holidays" in a dialog got *"what the fuck is this"*. Error messages must say
  what happened, what it means, and what to do — in words an HR clerk uses.
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
  (no .github/workflows — the keep-alive is NOT a GitHub Action, see below)

KEEP-ALIVE / MONITORING  (three external services, none of them in this repo)

  Free Supabase pauses after 7 idle days and is DELETED 90 days after pausing.
  Two independent "keepers" poke it; one "watcher" reports when it dies anyway.

  KEEPER 1  cron-job.org                POST daily, morning SGT
    URL: https://aypyolzkdupkpefpxius.supabase.co/rest/v1/rpc/keepalive_ping?apikey=<anon key>
    NO headers, empty body.
    - Key goes in the URL, NOT a header: web-form cron services often drop custom
      headers, giving {"message":"No API key found in request"}. Verified working
      with no headers at all, and with either json or form content-type.
    - Must be POST. GET returns 405 — keepalive_ping() writes.

  KEEPER 2  github.com/fluffyland/leavedesk-keepalive  (PRIVATE)  21:17 SGT
    A repo containing only .github/workflows/keepalive.yml. Deliberately 12h
    offset from keeper 1, so one service having a bad day still leaves a poke.
    Smarter than a web-form cron: it calls the function TWICE and requires the
    counter to advance, so it cannot be fooled by a 200 from a broken setup —
    exactly the check that would have caught July. Opens a GitHub issue on
    failure (the mobile app pushes those).
    ⚠️ MUST STAY PRIVATE. GitHub auto-disables scheduled workflows after 60 days
       of no repo activity IN PUBLIC REPOS ONLY. Making it public re-arms that
       timer on the thing protecting the HR system.
    ⚠️ Do NOT move it into hrleavesystem, and do NOT make that repo private:
       on the Free plan a private repo cannot publish Pages, so the website
       would be unpublished and the HR system would go offline.

  WATCHER   UptimeRobot — LIVE since 2026-08-19, 5-min interval, EMAIL alerts
    Monitor the DATABASE, plain GET, key in URL:
      https://aypyolzkdupkpefpxius.supabase.co/rest/v1/leave_types?select=code&limit=1&apikey=<anon key>
      Returns 200 with [] — anon cannot read rows (RLS). The 200 is the signal.
    Optionally also the site: https://fluffyland.github.io/hrleavesystem/
    ⚠️ Watching only the WEBSITE would not have caught the July outage — Pages
       stayed up for all 14 days while the database was asleep.
    ✅ Alerting was TESTED, not just configured: the URL was deliberately broken,
       a down alert arrived, and the URL was restored. Do the same after any change
       to the monitor — a never-fired alarm is a setting, not an alarm.
    ⚠️ The user declined the phone app; alerts go to EMAIL only. That is the exact
       channel that failed in July (8 alerts, unread for two weeks). It is their
       informed choice, recorded here rather than re-litigated. If an outage is ever
       missed again, this is the first thing to revisit — not the monitor itself.

  WHY NOT GitHub Actions: it disables cron after 60 days with no commit, and a
  workflow that stops running raises no failure — silence looks like success.
  WHY NOT pg_cron: it runs inside the database, so it sleeps when the database
  does and can never wake it.

  Health check any time:
    select last_ping_at, ping_count from public.keepalive_heartbeat;
  last_ping_at older than ~2 days means both keepers have stopped.
  Free Supabase pauses after 7 idle days, and is DELETED 90 days after pausing.
  Deliberately NOT a GitHub Action: GitHub disables cron in repos with no commit
  for 60 days, and a workflow that stops running raises no failure — silence is
  indistinguishable from success. That is the same trap as the read-only ping.
  The function it calls must be installed first: supabase/keepalive_ping_v2.sql

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
| ✅ v9 | `org_settings.prorate_cap` + capped `annual_entitlement_for` | applied 2026-08-19, carried in by v14 after it failed with `42703: column prorate_cap does not exist`. The **control was later removed from the UI** (a first year is base × months/12, already below the base, so the cap can only push a joiner lower). Column and SQL stay — `annualCalc` still mirrors it. |
| ✅ v12 / v13 / v14 / v15 | working-day authority + Saturday + cancellation guards; holiday-sync ownership; annual maximum + monthly accrual; no-approver cancellation | user confirmed all four ran; v15 healed the stranded `cancel_requested` row |
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
| `sync-holidays` | ⚰️ **DEAD CODE — do not deploy.** Never deployed; confirmed 2026-08-19 when 🔄 Sync now returned *"Failed to send a request to the Edge Function"*. The whole feature was then **removed from the frontend** at the user's instruction (see §12). The file, `apply_holiday_sync` (v13), `holiday_sync_log` and the `source`/`synced_at` columns all still exist and are all unread. Deploying this would resurrect a feature the user deliberately killed |
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
| `MIGRATION_GUIDE.md` | **stand the whole system up from zero on a new account** — accounts to register, repos to create (and which must be public vs private), SQL to run, functions to deploy, keep-alive + monitoring, final verification checklist |
| `GUIDE_HR.md` | HR / Owner operations manual |
| `GUIDE_EMPLOYEE.md` | employee-facing manual — safe to hand to staff as-is |
| `YEARLY_CHECKLIST.md` | annual routine. Verifies OUTCOMES rather than schedules: holiday sync, rollover + grant, keep-alive liveness, whether alerts still reach a human |
| `README.md`, `DESIGN.md` | early design notes (partly outdated; trust code + this file) |
| `SETUP.md` | original backend setup guide + optional extras (email, cron, holiday sync) |
| `NEW_COMPANY_SETUP.md` | **SOP manual**: stand up a new company / full reset / yearly routine / troubleshooting |
| `HANDOVER.md` | this file |
| `supabase/keepalive_ping_v2.sql` | **run this once in the SQL Editor.** Write-based heartbeat, called daily by cron-job.org. v1 was read-only and did NOT prevent the 2026-07 pause (2-week outage) |
| `supabase/schema.sql` | **complete backend, one-shot, kept in sync with every migration** — the source of truth for a fresh install |
| `supabase/migration_app_v1..v15.sql` | incremental history. Applied on the live database: **v1–v15, including v9** (v9 was skipped for a long time and only went in with v14 on 2026-08-19 — see below) |
| `supabase/bootstrap_owner.sql` | create first Owner (edit name/email inside) |
| `supabase/reset_all_data.sql` | wipe all people/records/logins, keep types+holidays |
| `supabase/insert_holidays_2027.sql` | MOM's 12 public holidays for 2027 — bulk **manual** entry (`source = 'manual'`), a shortcut for typing them in, not a sync |
| `supabase/reset_all_passwords.sql` | set every login's password to `Ssu123@` |
| `supabase/delete_employee_fully.sql` / `clear_employee_records.sql` | standalone SQL-editor equivalents of the app's Delete/Clear buttons (needed because SQL editor runs as postgres where `is_hr()` is false) |
| `supabase/seed.sql` | demo data (early phase; superseded by real usage) |
| `supabase/functions/create-login/index.ts` | login lifecycle Edge Function (see §5) |
| `supabase/functions/sync-holidays/index.ts` | ⚰️ dead — the removed holiday sync. Kept for history only; see §12 before touching it |
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

Previous suites lived in the session scratchpad — **gone after the session ends**;
recreate on demand. As of 2026-08-26 there were seven, 152 assertions in total:
`t.mjs` 17, `t2.mjs` 21, `t3.mjs` 13, `t4.mjs` 32, `t5.mjs` 11, `t6.mjs` 24,
`t7.mjs` 34 (the caret, the holiday scroll jump, pasting MOM's table, year
navigation). A shared `seed.js` builds a plausible `db`/`me` and calls `render()`.
Also run `node --check` on the extracted script after every edit, and keep `$$`
counts even in any SQL file you touch.

**A test that asserts the old contract is not a regression — read it before "fixing"
the code.** Making the year arrows unbounded turned two `t2.mjs` assertions red; they
asserted the arrows were *disabled* at the ends, which was precisely what the change
removed. The assertions were updated, not the code.

**Know what this harness does NOT prove.** It seeds `db` and `me` by hand and calls
`render()`, so it tests *behaviour against your own assumptions about the data*, never
against the live database. A field you name wrongly in the seed is a field the tests
happily agree with. Two habits keep it honest:

- **Cross-check the seed against the real mappers**, not against memory — `mapEmp` /
  `mapType` (`app.html:298-305`) and the `applications` mapper are the source of truth for
  shape. Diffing the seed's keys against those three caught nothing in Aug 2026, which is
  the point: it is cheap and it is the only thing standing between a green suite and a
  fiction.
- **SQL is different — verify it for real.** A throwaway Postgres
  (`runuser -u postgres -- bash /tmp/script.sh`; `initdb` refuses to run as root) executes
  the actual statements. `insert_holidays_2027.sql` was checked that way: 12 inserted,
  2026 still 14, idempotent on a second run. Never ship SQL on a read-through alone — v14
  shipped that way and failed on the user's first attempt.
- **The user is the integration test.** Say so plainly when handing work over, and name
  the two or three things only they can click. Do not describe seeded assertions in a way
  that sounds like the live system was checked.

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

- ~~**v9 not applied**~~ — applied 2026-08-19. It stayed unapplied so long that a
  later migration (v14) referenced `prorate_cap` and failed with
  `42703: column does not exist`. **Lesson: this file said "through v11 EXCEPT v9"
  and that was ignored.** Never write a migration that assumes an earlier one ran —
  re-add the column with `if not exists`, or feature-detect. §5 is not decoration.
- **`rerender()` for filtering and sorting; `render()` for navigation.** `render()`
  resets scroll to 0 by design, which is right when the page changes and wrong every
  other time. **Three separate user bug reports have traced back to this one sentence
  not being followed** — the ledger sort jumping to the top, the search boxes jumping
  on every keystroke, and the two filter dropdowns (which nobody had reported yet).
  Before shipping any handler that changes what a list shows, check which one it calls.
  Two traps worth knowing:
    · ~~`focusKey()` only recognises `data-act`~~ — **fixed 2026-08-20, and this was the
      actual root cause all along.** Every form field carries `data-f`, so `focusKey`
      returned `null` for all of them: nothing was re-focused, the caret was lost, and the
      browser's scroll anchoring lurched. Three separate reports were "fixed" in three
      separate callers before anyone read the helper. It now matches `data-f` too, and
      appends `data-d` for the per-date half-day selects. **When a bug recurs in a third
      place, stop patching callers and go read the shared function.**
    · restoring focus with a bare `focus()` scrolls the element into view and undoes
      the scroll you just restored. Use `focus({ preventScroll: true })`, as
      `render()` itself does.
- **A pre-filled field looks answered.** Add employee used to default team, gender,
  account type and Saturdays. Gender in particular feeds `eligible()`, so the default
  silently decided who was offered maternity vs paternity leave. There is nothing on
  screen to prompt a check, because the field is not blank. If a field decides
  something, make it a choice.
- **The auto-approve path is a second code path, and it is easy to forget.**
  Anyone with `approver1 = null` (the Managing Director) is auto-approved on submit
  and gets **no `approval_steps` row at all**. Every feature that routes work to an
  approver — inbox filters, permission checks in SQL, "waiting for X" copy — must
  answer "what if there is no approver?" This was missed once (cancellation, v15:
  requests sat in `cancel_requested` forever, invisible to every user) and it
  reached production. When touching approvals, test as the MD, not just as a
  normal employee.
- **Storage orphans**: deleting/clearing an employee does NOT remove their
  uploaded MC files from the `attachments` bucket. Manual cleanup; a cleanup
  routine was offered, not requested.
- **The holiday sync was REMOVED, 2026-08-20. Do not rebuild it without being asked.**
  The user's words: *"what i want is it can automatically sync if unable to do that just
  remove the whole function. let HR manually do it."* Offered the choice between a
  browser-side sync (one migration, then it would genuinely run by itself — data.gov.sg
  serves `access-control-allow-origin: *`, so the fetch works from the page; only
  `apply_holiday_sync`'s grant would have needed changing) and deleting it, they chose
  **delete**. Out of `app.html`: the 🔄 button, `case "phsync"`, `phLastCheckLine()`,
  `phSourceCell()`, the Source column, and the `phSource` / `phWhen` / `phLastCheck`
  loads. Left in the database and the repo, all unread: `holiday_sync_log`,
  `apply_holiday_sync`, the `source` / `synced_at` / `updated_at` columns, and the Edge
  Function source.
  **Why they were right:** it had never once run in the months it existed, and it
  presented itself as automatic the whole time. A button that looks like it works is
  worse than no button — it stops anyone doing the job by hand.
  `GUIDE_HR.md` and `YEARLY_CHECKLIST.md` now say plainly that January's holiday entry is
  a person's job and nothing will remind them.
- **Superseded (kept for the reasoning):** sync-holidays was not deployed. The user
  pressed 🔄 Sync now on 2026-08-19 and got *"Failed to send a request to the Edge
  Function"*. Every `public_holidays` row is still `manual`. The function and the v13
  reconciliation are written and tested; nothing has ever invoked them.
  A stop-gap SQL file was shipped first; the user's response — *"actually is not consider
  sync automatically right? since its me that paste into the sql system"* — is what led to
  removing the feature a day later. **They were right, and the lesson is general: a
  workaround that needs a human every time is not the feature, and calling it one buys a
  day and costs trust.**
  Data source, recorded for history only, 2026-08: data.gov.sg collection 691, metadata naming the
  Ministry of Manpower as `sources` and `managedBy`. **2026 → 14 dates** (matching
  what is already in the system), **2027 → 12 dates, already published**.
- **Re-apply after cancelling: removed 2026-08-20.** Cancelling refunds the whole
  application, so someone who came back early owes a fresh, shorter application. The app
  used to offer to pre-fill that form for them (`case "reapply"`, plus a callout and two
  buttons). The user: *"I dont like the apply for days taken function... i only need the
  close button"*. Deleted outright — the on-screen sentence telling them to re-submit
  stays, because they wrote it. Don't rebuild the helper.
- **Wording the user dictated, and why it looks odd in the code.** The apply-form day
  count says *"Singapore public holidays excluded automatically"* and omits weekends,
  even though weekends ARE excluded — that is their text, given verbatim, and it is not a
  bug to fix. Same for *"All N days will be fully restored. Please re-submit a new
  request for any days actually taken."* Check §2 before "correcting" any of it.
- **"Managing Director" was hard-coded into the auto-approve path** in four places
  (`chainText`, `stepsView`, the apply-page sub-line, and the comment `submit_application`
  writes). Anyone with no approver saw it, whoever they were. All four now say
  *"No approver required"*. The database one is normalised on read (`autoComment` in
  `loadAll`) rather than migrated, so rows already written display correctly too.
- **`.modalback` is the scroller, not the window — this is what "the page jumps" actually
  was.** `.modalback` is `overflow-y:auto`, so while a modal is open `window.scrollY` sits
  at a constant 0. `render()` saved and restored the window and therefore preserved
  nothing, and every edit in a tall Edit-employee form threw you back to the top.
  **Reported three times and "fixed" twice** — once by moving callers to `rerender()`, once
  by teaching `focusKey()` about `data-f` (both were real bugs, neither was this one).
  It survived because **the test asserted `window.scrollY` was unchanged, and it never
  changes in that case**: the test passed for a reason unrelated to the bug.
  Lesson, and it is the important one in this file: **prove a regression test fails without
  the fix.** Revert the fix, watch it go red, put it back. `t5.mjs` was checked that way —
  5 failures without, 0 with. Two of this session's three bad tests would have been caught
  in thirty seconds by that habit.
- **`render()` must restore the CARET, not just the focus — and that is a third face of the
  same bug.** Putting the focus back on a rebuilt field without its `selectionStart` /
  `selectionEnd` drops the cursor at character 0, so every subsequent keystroke is inserted
  *in front* of the last one: typing `01` produced `10`, and backspace at position 0 did
  nothing. It showed up on the holiday paste box because that box re-renders on every
  keystroke to update its preview, but **it was never specific to that box** — any field
  that re-renders as you type had it. Fixed in `render()`, where focus is already restored;
  `selectionStart` throws on `number`/`date` inputs, hence the try/catch on both sides.
  Third time in a row the answer was in the shared function and not in the caller.
- **`reload()` scrolls to the top; `reloadKeep()` does not.** `reload()` is
  `loadAll(); render()`, and `render()`'s scroll-to-top is correct for navigation and wrong
  for a write that leaves you on the same screen. Removing a public holiday threw you back
  to the top of a long settings page. Any handler that writes and stays put should call
  `reloadKeep()` (`loadAll(); rerender()`): the holiday add/edit/remove actions, `orgsave`,
  `hrsave`, `grantgo`. **Same rule as `render()` vs `rerender()`, one layer up** — which is
  why it was missed.
- **Public holidays save immediately; everything else on the HR Console is a draft.**
  `saveDraft()` writes `leave_types`, `employees` and `org_settings` only. The holiday
  handlers write `public_holidays` on the click. Both behaviours are right, but the screen
  said nothing about the difference and a user reasonably assumed **Discard** would undo a
  **✕**. The card now says so out loud. If you add another immediate-write control to a
  page that has a Save bar, label it.
- **`parseHolidayLines` reads cells, not lines.** MOM's page is a four-column table whose
  copy-paste splits Chinese New Year's date and name across different lines, repeats the
  holiday name in two columns, and ends with a conditional in-lieu footnote. A line-at-a-time
  parser could not represent any of that. It now walks cells: a date opens a row awaiting a
  name, weekday words are dropped as the Day column, anything else names the oldest unnamed
  row, and a name with no row waiting is kept only if it elaborates the previous one
  (`New Year` → `New Year's Day`). **The in-lieu footnote is skipped on purpose** — that
  Monday is a holiday only for staff whose rest day is the Sunday, so it must never be added
  company-wide automatically. Lines that contribute nothing come back in `bad`; dates that
  never got a name come back in `noName`. Neither is ever guessed at.
- **Never dereference `emp()` / `lt()` for display.** They are `Array.find()`, so they
  return `undefined` for a row that isn't there — and a `TypeError` inside `render()` draws
  NOTHING: a white page, no message, nothing to click. Two live routes to it: `loadAll()`
  falls back from `employees_directory` to `employees`, whose RLS gives a non-HR user
  **only their own row**; and `delete_employee_fully.sql` is a documented tool. Use
  `empName()` / `ltName()` for a name, or `empSafe()` / `ltSafe()` for a whole record —
  they return stand-ins shaped like the real thing. Bare `emp()`/`lt()` stays where the
  code needs to know whether the row exists.
- **Removed as dead code, Aug 2026** — don't resurrect without checking why: `oilModal()`
  and its `oilopen`/`oilsave` handlers (the `+ OIL` button went in commit `79654c9`,
  10 Jul 2026; Balance adjustments replaced it), `wdCount()` (superseded by
  `wdCountHalf()`, and it still carried the pre-v12 rule that Saturday is never a working
  day), `nowTs()`, the `mailOpen`/`booting` globals, `data-stop="1"` (no JS ever read it —
  it *looked* like the thing protecting modals from click-through and never was), the
  `resultModal` follow-on button, and 15 CSS rules.
- **A modal that dismisses on the backdrop dismisses on its own body too.** The confirm
  and result dialogs put `data-act` on `.modalback`; the click delegator resolves
  `ev.target.closest("[data-act]")`, and the inner `.modal` carried no `data-act` — so a
  click on the dialog's own heading or text walked past it and hit the backdrop's close
  action. A confirmation dialog that vanishes when you click it is worse than no
  dialog. The guard is now keyed on `el.classList.contains("modalback")` rather than on
  the action name, so every future modal inherits it; confirm/result carry no backdrop
  action at all. `data-stop="1"` was never read by any JS — it looked like protection
  and was decoration.
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
