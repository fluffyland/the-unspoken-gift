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
  → The COMPLETE list of every outside service, with the evidence for each, is
    NEW_COMPANY_SETUP.md §0b. Read that first. This section is the operational
    detail behind three of its rows. Answering "what does this depend on" from a
    grep of URLs missed all three of them once already.

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
  The function it calls must be installed first: supabase/keepalive_ping_v3.sql

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
| ✅ v16 / v18 / v19 | carry-forward and the yearly reset · Leave types crediting everyone, HR applying on behalf, amendment records · the typed figure IS the year's entitlement + one-click company credit | **APPLIED — probed 2026-08-28** with the anon key (§9): `run_year_start`, `bump_annual_all` and `annual_entitled_in_year` all answer (`42501 permission denied` = the function exists and is correctly revoked; `PGRST202` = wrong argument names, NOT absence — send the real ones before concluding anything). This row said "not yet run" for weeks after they had been. **Probe before you claim.** |
| ❓ `keepalive_ping_v3` | daily call to `expire_due_carry()` | **Cannot be probed** — `keepalive_ping` exists and answers, but its source is not readable from outside, so whether it is v3 is unknown. It matters less than it looks: `due_unwritten_carry` is subtracted inside the `leave_balances` view, so **expired days are unusable even if no scheduled job ever runs**; the daily call only makes the written record tidy sooner, and `run_year_start` + `set_carry_expiry` both call it too. Check with `select prosrc like '%expire_due_carry%' from pg_proc where proname='keepalive_ping';` in the SQL Editor |
| ✅ v24 | the carry-forward expiry becomes a date you pick, not a count of months | **APPLIED — probed 2026-08-31** (`set_carry_expiry` returns `42501`, i.e. exists and correctly revoked) and confirmed on screen: the backfill turned `12 months` into **December / 31**, the same day it always meant. The user first saw the old months box — that was **browser cache**; a hard refresh fixed it. Expect that on every deploy |
| ✅ v25 | `carry_expiry_for` → `security definer` | user ran it 2026-08-31 |
| ⏳ v27 | the audit fixes | **written, tested (t27.sql 41 assertions, 5 mutants), NOT yet run** |
| ⏳ v28 | `org_settings.notify_only_emp` for the email test mode | **written, tested, NOT yet run.** Needs the Edge Function deployed and Resend configured — see MIGRATION_GUIDE |
| ⏳ v35 | **every ledger entry records its leave year and kind** | **written, tested (51 SQL + 18 browser assertions, 7 mutants), NOT yet run.** Run `undo_year_start.sql` and the undo for the bad 2026 run FIRST, then v35 — the backfill should tag clean data. The frontend feature-detects it (`db.ledgerTagged`), so the page is safe either way |
| ⏳ v26 | leave dated in a closed year | **written, tested (t25.sql, 44 assertions, 4 of 5 mutants caught + 2 proven equivalent), NOT yet run.** The frontend feature-detects nothing here — without v26 the database simply has no closed-year rule, and the screen falls back to today's behaviour. **Contains a `drop function`: read the overload note in §12 before touching it** |

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
| `year-start-flowchart.html` | standalone page — what **Start a new year** does, step by step, with a worked example. No internet needed; double-click it. Linked from `GUIDE_HR.md` |
| `GUIDE_EMPLOYEE.md` | employee-facing manual — safe to hand to staff as-is |
| `YEARLY_CHECKLIST.md` | annual routine. Verifies OUTCOMES rather than schedules: holiday sync, rollover + grant, keep-alive liveness, whether alerts still reach a human |
| `README.md`, `DESIGN.md` | early design notes (partly outdated; trust code + this file) |
| `SETUP.md` | original backend setup guide + optional extras (email, cron, holiday sync) |
| `NEW_COMPANY_SETUP.md` | **SOP manual**: stand up a new company / full reset / yearly routine / troubleshooting |
| `HANDOVER.md` | this file |
| `supabase/keepalive_ping_v3.sql` | **run this once in the SQL Editor.** Write-based heartbeat, called daily by cron-job.org. v1 was read-only and did NOT prevent the 2026-07 pause (2-week outage) |
| `supabase/schema.sql` | **complete backend, one-shot, kept in sync with every migration** — the source of truth for a fresh install |
| `supabase/migration_app_v31.sql` | **no automatic yearly day, and one number for annual leave.** `annual_entitlement_for` reduced to `least(annual_base, annual_cap)`; `org_settings.prorate_cap` dropped; and a one-off repair setting `annual_base` to what each employee was actually granted this year — **it writes no ledger rows, so nobody gains or loses a day**. Idempotent, with a self-check that refuses to pass if `join_date` reappears in the rule |
| `supabase/migration_app_v27.sql` | **the audit fixes.** Pending leave blocks the year start (blockers listed in the preview); leavers frozen — a `leave_ledger` trigger plus `active` filters plus `offboard_employee` closing the carry, with `freeze_leaver_carry()` repairing old data; one-application-one-year and year-not-yet-started rules |
| `supabase/migration_app_v26.sql` | **leave dated in a year Start a new year has closed.** `year_closed_for`, `reconcile_closed_year` (preview + write, one arithmetic), the closed-year rule inside `submit_application` — and it **drops the two older `submit_application` signatures** |
| `supabase/migration_app_v25.sql` | **`carry_expiry_for` → `security definer`.** One function, one property. As an invoker it returned NULL for any caller who could not read `org_settings`, and NULL there means "never expires" — it disabled the expiry rule silently rather than erroring |
| `supabase/migration_app_v24.sql` | **the carry-forward expiry becomes a date you pick** — `carry_expiry_month`/`_day` (repeating every year), `carry_expiry_for()`, `set_carry_expiry()` (preview + write + restamp + clear), `run_year_start` reading the date. Not yet run by the user |
| `supabase/migration_app_v1..v15.sql` | incremental history. Applied on the live database: **v1–v15, including v9** (v9 was skipped for a long time and only went in with v14 on 2026-08-19 — see below) |
| `supabase/bootstrap_owner.sql` | create first Owner (edit name/email inside) |
| `supabase/reset_all_data.sql` | wipe all people/records/logins, keep types+holidays |
| `supabase/insert_holidays_2027.sql` | MOM's 12 public holidays for 2027 — bulk **manual** entry (`source = 'manual'`), a shortcut for typing them in, not a sync |
| `supabase/reset_all_passwords.sql` | set every login's password to `Ssu123@` |
| `supabase/delete_employee_fully.sql` / `clear_employee_records.sql` | standalone SQL-editor equivalents of the app's Delete/Clear buttons (needed because SQL editor runs as postgres where `is_hr()` is false) |
| `supabase/seed.sql` | demo data (early phase; superseded by real usage) |
| `supabase/functions/create-login/index.ts` | login lifecycle Edge Function (see §5) |
| `supabase/functions/sync-holidays/index.ts` | ⚰️ dead — the removed holiday sync. Kept for history only; see §12 before touching it |
| `supabase/functions/send-notification/index.ts` | **GENERATED — never edit by hand. This is the file that gets deployed.** `node build-single.mjs` builds it from `handler.ts` + `templates.js`; `--check` proves it has not drifted, and refuses to write a file that still imports a sibling. Named `index.ts` because the dashboard deploys the entry point and nothing else — see §5 |
| `supabase/functions/send-notification/handler.ts` | the editable logic. **Leave-notification emails, rewritten in English in v28.** The WORDS live in `templates.js` beside it — a plain ESM module with no Deno or Supabase imports, so `t29.mjs` imports the very same file and checks every sentence without sending anything |
| `supabase/functions/send-notification/check-deploy.sh` | "did it actually start?" — an `OPTIONS` probe, so it can never send email. The check this project did not have, and the only thing that distinguishes a deployed function from a working one |

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
navigation), `t8.mjs` 34 (the popup/`render()` rule, the year search bar, layout),
`t9.mjs` 35 (per-employee carry cap, the Apply split, Start a new year),
`t10.mjs` 52 (the Leave types credit, the entitlement, the two record books, HR applying
on behalf, the year-scoped figures, the swallowed click), and later `t11`–`t15`, `t21`,
`t22`. **As of 2026-08-28 there are 17 browser suites, 666 assertions**, all green:
`t` 17, `t2` 21, `t3` 13, `t4` 32, `t5` 11, `t6` 24, `t7` 34, `t8` 34, `t9` 35, `t10` 52,
`t11` 47, `t12` 106, `t13` 62, `t14` 47, `t15` 44, `t21` 49, `t22` 42, `t23` 45 —
**18 suites, 715 assertions** as of 2026-08-28.

**The v16 SQL is tested against a real Postgres, not the browser.** `pgup.sh` starts a
throwaway instance, `shim.sql` stands in for what Supabase provides (roles, `auth.uid()`),
then `schema.sql` + `migration_app_v16.sql` + `seed16.sql`, and `t16.sql` / `t16b.sql` /
`t16c.sql` assert 43 outcomes, and `t18.sql` / `t18b.sql` a further 45 (the leave-type
credit, the entitlement, HR-on-behalf, and the permission guards under
`SET SESSION AUTHORIZATION`). `chain.sh` builds that database the way the real one was
built — schema plus every migration in order — because basing a rewrite on `schema.sql`
alone silently picked up a stale `working_days_hd` signature — the reset, per-person caps, expiry by date, never-expires,
idempotency, and that running the grant first cannot inflate the carried figure. The
browser suite stubs `sb.rpc` with **the literal JSON that real Postgres returned**
(`preview.json`), so the two halves cannot drift apart unnoticed. A shared `seed.js` builds a plausible `db`/`me` and calls `render()`.
Also run `node --check` on the extracted script after every edit, and keep `$$`
counts even in any SQL file you touch.

**The SQL suites have an order and a seed — running one alone will look catastrophic.**
`runsql.sh` (scratchpad) encodes it: rebuild with `chain19.sh`, load `seed16.sql`, and
only then run the suite. `t16b`/`t16c` reuse the helper functions **`t16` creates**, so
all three share one database and must run in that order; `t20`'s last assertion needs
`keepalive_ping_v3.sql` installed first. Skip the seed and every suite fails at setup with
`null value in column "emp_id"` — that is a missing `seed16.sql`, not a broken migration.
**As of 2026-08-31: 239 SQL assertions**, all green — `t16` 22, `t16b` 15, `t16c` 6,
`t18` 29, `t18b` 16, `t19` 44, `t20` 22, `t24` 41, `t25` 44, `t27` 41 — **280 total**.
Browser: **21 suites, 814**.

**The SQL suites run as `postgres`, a SUPERUSER, which bypasses RLS entirely — so by
default they cannot catch an RLS bug at all.** `t18b.sql:65` has the pattern that fixes
this (`create role … ; grant …; set session authorization`), and `t24.sql` §10 now uses it.
Two details that make the difference between a real test and a fake one: the test role
needs the **table GRANT** (`grant select on org_settings to …`) or it errors on privilege
before RLS is ever consulted; and it must **not** be a member of `authenticated` if you
want to exercise the "policy does not apply" path, since every policy here is `to
authenticated`.

**A SQL suite reports a broken function as a MISSING assertion, not a failing one.** A
statement that raises never reaches its `chk()`, so the row is simply absent — and
"35 passed, 0 failed" reads exactly like success. Found by mutating v24's leap-day clamp:
every assertion still "passed". `t24.sql` now ends with an assertion on the **row count**
itself, which is what turns a silently-skipped test back into a visible failure. Worth
copying into the other suites. *Run a mutation before trusting a green suite: break the
thing on purpose and check the test actually goes red.*

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
- **Build the SQL through the real migration chain, and separately from `schema.sql`.**
  `chain19.sh` runs `shim.sql` (roles + `auth.uid()`), then `schema.sql`, then every
  `migration_app_v*.sql` in order — that is what the user's database actually is.
  `schema.sql` alone is what a *new company* gets. **They drifted apart and no test noticed
  for months** (see §12: the missing v12 Saturday family). Run both.
- **Drive the browser the way a person does.** `pg.fill()` sets `.value` in one assignment
  and sails straight past the whole class of caret bugs; `pg.keyboard.type(text, {delay})`
  after a real `click()` reproduces them. The reversed-typing fault was invisible to
  `fill()` and obvious to `type()`.
- **A screenshot is a test.** The Annual Leave editor showed `1` in its days box while the
  button read an unstaged value and answered "Enter a number of days" — every assertion was
  green because the test staged the field first. Look at the screen before shipping.
- **THE HR CONSOLE AUDIT (Aug 2026) — `t12.mjs` + `t13.mjs`, 164 assertions.** The user
  asked whether every control "really makes changes or just displays". The method that
  answered it, and the one to repeat: **stub `sb` and assert the WRITE**, not the label —
  capture `from(t).insert/update/delete` with its `.eq()` filters and every `sb.rpc`, drive
  each control, then check the payload *and* the target row. It covers all seven tabs, both
  modals, every tick, every cancel path, whether stored values read BACK into each control,
  and the pre-v18 Balance adjustments tab. Two things it found:
  1. **`annual_bump` printed as a raw key** in Amendment records and its CSV, because
     `kindName` was written out **twice** and v19's new kind was added to neither. Now one
     `AMD_KIND` map. *A fact written down twice is a fact that will disagree with itself.*
  2. **`case "orgsave"` was dead** — nothing rendered it since Company settings moved to the
     draft + save-bar model, and it wrote three of the seven settings straight from the DOM
     with **none** of the guards (blank name, maximum-below-entitlement). Removed. `t12.mjs`
     §O now derives both directions from source: no control without a handler, no handler
     without something to trigger it. It reads `case "x":` **unanchored** (two labels share
     one block) and treats `act: "x"` in a confirmation dialog as a trigger.
  Two stubbing traps worth knowing: **`sb.functions` is a getter** on the Supabase client,
  so `sb.functions = {...}` silently does nothing — use `Object.defineProperty`. And when
  asserting a filtered list, read the **name cell**, not the row: a row contains the
  approver dropdown, which lists everybody.
- **v20: bal() CLASSIFIED BY SIGN, and v18/v19 started writing negative corrections.**
  Positive meant entitlement, negative meant leave taken. Then a leave type amended 17 → 14
  began writing −3, and an entitlement corrected downwards wrote the difference — so both
  were counted as leave somebody had taken. The second figure on Balances never came down
  ("SL changed from 17 to 14 but still shows 17") and Taken was inflated by the same amount
  ("-2 / 17"). **Classify by what an entry IS:** `ref_application` set → leave (refunds are
  positive and net off); housekeeping wording → neither; everything else → entitlement,
  **summed with its sign**. Same rule as SQL `annual_entitled_in_year`, and `entChange`'s
  private copy was deleted rather than kept in step. One fix reached five screens.
  *A sign is not a category. When new kinds of entry appear, the classifier must change too.*
- **`numText()` ate the minus sign** — added in v19 to keep a text box numeric, applied to
  every field including the two that take a negative. `-30` of off-in-lieu was staged as
  `30`, and because staging does not redraw, the box still read `-30` until answering an
  unrelated question redrew it. `NEG_OK` now names the two fields that allow one. *The v19
  test for that box only ever typed positive numbers — a sanitiser needs a test for what it
  must NOT strip.*
- **The ledger had no screen for two rounds.** v18 replaced the *Balance adjustments* tab
  with *Leave Application*, and that tab was the only place the ledger was ever displayed.
  `offboard_employee` kept writing the encashment entries; nobody could read them. Now
  **Amendment records → Full ledger**. *Replacing a tab silently deletes every view it held
  — check what else was on it.*
- **The offboarding record needs no table.** `offboard_employee` already writes one entry
  per leave type with the remaining balance, the last day and encashed/cleared in the
  reason. Reading it back needs no migration and covers everyone already offboarded, which
  a new log table would not. Only the encashed/cleared **word** is parsed, and only for a
  label — if the wording changes, the days and types still show.
- **v21: the SAME bug, one screen further on — 957.** *My leave entitlement* printed
  `bal().used` (all-time, and counting every negative entry ever: expiry write-offs, carry
  forfeits, offboarding settlements, downward corrections) in a column beside *Allowance*,
  which was this year's. v20 fixed `yUsed` and switched the Apply tab and Balances over;
  this table was simply never switched. **When a shared figure changes meaning, grep every
  reader of it** — `yGranted`/`yUsed`/`granted`/`used` — and check each one is asking for
  the period its neighbours use.
- **All records is paged by year** (`recYearOf` = the leave's START date, the user's
  choice), reusing the public-holiday control verbatim: `PH_MIN`..`PH_MAX`, the same arrows
  and the same 🔍 box. `recFiltered()` is shared by the table and its CSV so the export can
  never disagree with what is on screen.
- **Offboarding no longer asks how to settle.** The user removed the choice: everything
  clears. `offboard_employee` keeps its `p_mode` parameter (no SQL change) and always
  receives `clear`. The consequence, stated to them once: the record can no longer say
  whether days were paid out. The settlement moved off the Former-employees list into a
  **Leave left** popup, and the encashed/cleared word is gone from the screen entirely —
  which also reads correctly for people offboarded before the change.
- **v22: comparing against the STORED number hid a whole class of mismatch.** Both
  `entChange` and the `empsave` entitlement branch asked `typed !== employees.annual_base`.
  For someone whose stored figure was already 14 while the ledger had only credited 6 (a
  pro-rated joiner added before v20), typing 14 did nothing at all — no preview, no RPC —
  and Balances kept reading 5 / 6. The screen that exists to FIX a mismatch could not see
  it. Both now also compare against `entNow()` = `bal().yGranted`, the same figure Balances
  prints. *A control that repairs state must be driven by the state it repairs, not by the
  setting that was supposed to produce it.*
- **`numText()` was called directly in one more place.** `NEG_OK` was added in v20 so only
  two fields keep a leading minus — but the `albump` handler called `numText(el.value)` with
  no flag, so the company-wide credit silently lost its minus, exactly as off-in-lieu had.
  Every call site now passes `allowsNeg(el)`. *A guard list only works if nothing routes
  around it; grep for the bare helper, not just the list.*
- **Carry-forward expiry was verified end to end, not read** (`t20.sql`, 22 assertions):
  carried days are consumed first because "what remains" is *carry-in minus annual leave
  taken since 1 January* — there is no separate bucket to drain. The balance excludes
  expired days **before** the job runs (`due_unwritten_carry` inside `leave_balances`), the
  job writes a `"<year> carry-over expired (unused)"` ledger line, records `expired_days`
  and `expired_at`, is idempotent, and leaves days used before the date alone. **Watch the
  test's own dates**: the first version hard-coded a 30 June expiry, which is already in the
  past for most of the year, so three assertions failed for a reason that had nothing to do
  with the code. Date fixtures must be relative to `current_date`.
- **Monthly accrual is switched off to users** at the user's instruction ("i no longer want
  to open this function to user"). The dropdown is `disabled`; the column and all the SQL
  behind it are untouched, so re-enabling it is deleting one attribute.
- **Add employee: the 1st level approver is a required decision.** It used to default to
  *(auto-approve)*, so clicking through filed somebody with no approval route. Three states
  now — unset (a `— Select —` placeholder), `APPR_NONE` (auto-approve, chosen on purpose),
  or an id — normalised by `appr1Id()`. Deliberately a **separate** `appr1Opts()` from
  `apprOpts()`, because the 2nd-level select and the Employees-table selects already treat
  `""` as "nobody" and must not change.
- **Closing Edit / Add employee asks before discarding.** The form as opened is snapshotted
  (`snapEmp()`), so `empDirty()` is a comparison, not a guess — an untouched form still
  closes instantly with no pointless dialog.
- **v23: the per-team Saturday tick reached nobody, and was removed rather than fixed.**
  `deptsat` wrote `departments.works_saturday` correctly — the write was never the problem.
  `emp_works_saturday()` prefers the employee's own column and only falls back to the team,
  and since v22 made that field a required answer, every employee has one, so the team value
  was dead weight on every row. The user's call was *"remove this fucntion from the
  teams/department section"*. The column, the paragraph and the handler are gone; the SQL
  column and the fallback stay, so nothing that predates the change breaks. *Before fixing a
  control that "does nothing", find out whether anything downstream still reads it.*
- **Teams: In use → Delete.** `deptdel` refuses an occupied team by name and member count
  and writes nothing; an empty one goes through a confirmation to `deptdelgo`. **`confirmyes`
  forwards only `act` and `id`** — it deletes the rest of `vp.confirmModal` before
  dispatching — so the team name travels as `id`. Anything else you hang on that object is
  gone by the time the handler runs.
- **The company-wide credit box is a signed stepper.** `albumpSet()` always writes an
  explicit sign (`+1`, `-1`, `0`) and the ▲▼ are buttons, not a native `type="number"`
  spinner: a native spinner needs `type="number"`, which is the exact thing THE CARET RULE
  forbids on a box that re-renders as you type. `numText()` now preserves a leading `+` as
  well as `-` when `allowNeg`.
- **Leave Application opens on nobody.** `vp.forEmp` starts unset with a `— Select —`
  placeholder and no form. Any suite that seeded `hrTab: 'apply'` and went straight for
  `[data-f="start"]` must now pick an employee first (`t11.mjs` §2).
- **v24: the expiry is a DATE, and `annual_carry.expires_on` always was one.** The months
  figure was only ever an input to one line inside `run_year_start`; every consumer — the
  balance view's `due_unwritten_carry`, `expire_due_carry`, the employee's "use them by" —
  already read the date. So replacing a count with a picker touched one calculation, not a
  pipeline. *Before rewriting a setting, find out how far its value actually travels.*
- **`carry_expiry_months` is deliberately still there.** `db.orgV16` is feature-detected
  from that column; dropping it would blind the probe on any database that has not run
  v24. v24 adds `carry_expiry_month` / `carry_expiry_day` beside it and backfills them, so
  no date moves on the day it runs.
- **Two `<select>`s beat a typed date box.** An impossible date cannot be picked, the Day
  list follows the Month (April drops the 31st rather than storing it), and — the reason
  that settles it — **a `<select>` has no caret to lose**, so the control sidesteps THE
  CARET RULE instead of having to obey it.
- **Changing the expiry restamps leave people are already holding.** The user's call
  ("what I set is what I see"), which makes it destructive: moving the date earlier kills
  days somebody holds right now. `set_carry_expiry(month, day, preview)` does the preview
  and the write in one function — v16's `run_year_start` pattern — so the count on the
  confirmation and the rows actually changed come from the same arithmetic. The confirmation
  is built from what the PREVIEW returned, never from a guess made client-side.
- **One gate, not two.** A leave-type day change and an expiry change pending together
  produce a single confirmation. `hrsave` already had the gate and the `hrsaveok`
  re-dispatch; extending it beat adding a second modal to click through.
- **`role` had to join the rerender list.** `em.role` staged its value but never redrew,
  so the account-type description list would have highlighted whatever was picked before.
  A field only needs a rerender when something else on the form reads it — which is easy
  to miss until you add the thing that reads it.
- **v25: a function whose failure mode is NULL is a function that fails silently.**
  `carry_expiry_for` was `language sql stable` — security *invoker* — and it reads
  `org_settings`, which has RLS (`org_read … to authenticated using (is_staff())`). Any
  caller who could not read that table got **NULL**, and NULL there means *"carried leave
  never expires."* It did not error; it quietly turned the rule off. Nothing was broken —
  both real callers are definer, and `run_year_start` was proven correct under RLS — but
  nothing stopped a third caller being added. Now `security definer`, revoked from anon.
  *When a function's "I could not read that" answer is indistinguishable from a valid
  answer, the answer is the bug.*
- **Found by probing, not by reading.** The lead was `carry_expiry_for(2027)` returning
  `null` to an anon probe. That specific null was the probe's own limitation and meant
  nothing — but chasing why is what surfaced the trap behind it. *Probe results you can
  explain away are still worth explaining.*
- **A green suite that runs as superuser proves less than it looks.** See §8 on
  `set session authorization`. Both v24 and v25 mutations were run before trusting green:
  revert the change on purpose, confirm the test goes red. v24's leap-day mutation went
  green the first time — the assertion was being *skipped*, not passed.
- **`tail -n +N` to fold a migration into `schema.sql` cuts the function header if N is
  off by a line.** It appended a bare `select …` body and left the `$$` count ODD (101),
  which is the tell. Derive N from `grep -n "^create or replace function"` rather than
  eyeballing it, and check the `$$` count after every append.
- **v26: ADDING A DEFAULTED PARAMETER TO A PUBLISHED FUNCTION CREATES AN OVERLOAD, AND THE
  OLD ONE DOES NOT GO AWAY.** This nearly shipped as a total outage. `submit_application`
  already had two signatures (v8's 9-arg, v18's 10-arg); the app worked only because it
  sends `p_for_emp`, which only the 10-arg has. Adding `p_closed_ok` made a third, and the
  app's key set then matched **two** candidates — PostgREST cannot choose, and *every leave
  application in the company fails*. Caught on the first test run with
  `function submit_application(unknown, date, date, unknown) is not unique`. v26 drops both
  old signatures, and `t25.sql` §0b asserts `count(*) = 1` forever. **Rule: adding a
  parameter to a live function means dropping the old signature in the same migration.**
- **The closed-year rule is the mirror of the next-year rule.** `submit_application` always
  refused a *future* year; there was nothing for a *past* one. But the carry-forward is
  derived from what was left at the end of a year, so late leave into a closed year must
  re-derive it — otherwise the days come off the current balance, when they would have been
  forfeited anyway, and the employee silently loses them. Staff are refused; HR passes
  `p_closed_ok` after reading a preview.
- **Re-run the year for one person; do not patch with a formula.**
  `reconcile_closed_year` recomputes from `year_start_log` (frozen history) plus
  `annual_used_in_year` (live), and writes only the differences. `left_now = left_then −
  (taken_now − taken_then)`. Two subtleties the tests pin down: the **forfeit must be
  computed from the UNCLAMPED leftover** (a negative leftover means the year was overdrawn,
  and clamping first hides it), and **already-returned days are summed out of the ledger**,
  so a second late form does not refund twice and a re-run is a no-op.
- **The correction's wording is load-bearing.** It must contain
  `above the carry-over cap`, because both `annual_entitled_in_year` (SQL) and
  `HOUSEKEEPING` (app.html:1099) classify by that phrase. Without it the returned days
  read as *new entitlement* and Balances shows the wrong figure for the year.
- **Two mutants were equivalent, not missed.** Clamping `v_new_carry` or `v_new_forfeit` at
  zero earlier changes nothing, because every use is already clamped and a negative leftover
  minus a non-negative cap is negative either way. Proved rather than assumed — check
  whether a surviving mutant is actually reachable before writing a test for it.
- **v27 came from ACTING like a user, not reading code.** Four fake employees, a year of
  leave, a year start, then carrying on in January. Two serious bugs fell straight out; no
  amount of re-reading had found them. *Run the system as somebody would use it, then check
  every number by hand.*
- **`run_year_start` read `balance`, which does not subtract PENDING leave.** Leave awaiting
  approval over New Year was treated as unused → carried or forfeited → then deducted again
  on approval. Reproduced exactly: 13 instead of 16, three days gone, silent, with
  `year_start_log` permanently recording "taken 6" against a reality of 12. Now the year
  start **refuses to run** and names them. Counting pending as *used* was rejected as a fix:
  a later **rejection** would have to refund into a closed year — the same bug reversed.
- **Offboarding cleared the balance but left the carry record open**, so the expiry deducted
  it again → **−5** for every leaver. The user's rule is "freeze everything", and the
  enforcement is a **trigger on `leave_ledger`** (with the v10 `leavedesk.svc` bypass so the
  settlement itself still writes) rather than five separate `active` filters — filters hold
  only until somebody writes a sixth function.
- **A surviving mutant is not automatically an equivalent mutant.** Removing the `active`
  filter from the expiry passed everything, because `offboard_employee` now closes the carry
  record first, so the filter was never exercised. It is the second line of defence for a
  record left open by an *older* offboarding — the pre-migration state. The test now
  re-opens the row to recreate that state, and the mutant goes red at **−5**. *Check whether
  the mutated line is reachable in your fixture before calling it equivalent.*
- **The year rule was wrong at the root.** Booking was allowed as soon as the *calendar*
  reached a year, whether or not any leave had been granted for it — so January leave booked
  before the button was pressed came out of the previous year's carry-forward. Now: one
  application, one year; and a year opens only when `year_start_log` says it has been
  started. A first-year company has no rows and is unaffected.
- **v28: the email wording lives in `templates.js`, not in the Edge Function.** A plain ESM
  module with no Deno or Supabase imports, so the test suite imports the *same file* the
  function sends from. Wording that can only be checked by sending real email never gets
  checked — and this function had sat in the repo **written entirely in Chinese** since v11
  translated everything else, precisely because nothing ever ran it.
- **Test mode filters by RECIPIENT, not by whose application it is.** `notify_only_emp` names
  one employee and only mail addressed to them goes out. The literal reading of the user's
  request, and the safe one: no real member of staff can receive anything by accident.
- **The test send takes no recipient.** It resolves the address from `notify_only_emp`
  server-side, so holding the public anon key does not let anyone mail an arbitrary address.
  Asserted in `t29.mjs`: the invoke body carries `test:true` and no `to`.
- **`sb.functions` is a GETTER — `sb.functions = {...}` silently does nothing.** Cost time
  again in `t29.mjs`; the stub was never installed and the assertion failed on an empty
  array. Use `Object.defineProperty(sb, 'functions', { configurable: true, value: … })`.
  (This is already noted further up. It bit twice.)
- **AN EDGE FUNCTION CALLED FROM THE BROWSER NEEDS CORS, AND ITS ABSENCE IS INVISIBLE.**
  Shipped `send-notification` with none. supabase-js reports a blocked preflight as
  *"Failed to send a request to the Edge Function"* — the **same words** you get when the
  function is not deployed at all, so the user chases deployment while the real fault is
  four missing headers. `create-login` had the right pattern all along (a `cors` object, an
  `OPTIONS` branch, and every reply through one `json()` helper); copy it. `t29.mjs` §5b now
  reads the source and asserts all of it, including that **no reply bypasses the helper**.
  *When two very different failures produce identical text, test for the one you cannot see.*
- **Deploy by dashboard, never by CLI, for this user.** The CLI needs Node tooling, Docker,
  a login and a project link — four things that can fail for reasons unrelated to the code,
  to somebody who is not a developer. The dashboard editor is a paste box. But it is ONE box,
  so a two-file function does not fit: hence the generated single file from
  `build-single.mjs`. *Keep the split that makes the code testable; generate the shape the
  person deploying can actually handle.*
- **A setup procedure with nineteen ordered pastes is not a procedure.** The install guide
  listed thirteen of them for months and nobody noticed, because nothing checks a document.
  `install.sql` is now generated from the file list by `build-install.mjs`, and `t31.mjs`
  asserts every migration in the repo is inside it — so adding v32 and forgetting to rebuild
  fails a test instead of shipping. *If a list must stay in step with the filesystem, have the
  filesystem write it.*
- **`schema.sql` only worked because the test chain ran it TWICE.** `annual_entitlement_for`
  is `language sql`, so its body is parsed at creation, and it reads `org_settings` — a table
  defined 270 lines further down. On a genuinely fresh database the first pass errored and the
  second succeeded, and `|| true` in the chain script hid it for months. One paste has no
  second pass, so the table moved to §8b, above the function. *A retry loop in a test harness
  is a place a bug can live.*
- **THE DASHBOARD DEPLOYS `index.ts` AND NOTHING ELSE.** A second file added in the editor is
  not in the bundle — it is gone when you reopen the function. So an entry point that imports
  a sibling **never boots**: it cannot answer any request, not even an `OPTIONS` preflight
  that needs no key and touches nothing, while the dashboard reports *successfully deployed*
  every time. The generated file used to be called `DEPLOY-single-file.ts` and the guide said
  in bold *"paste DEPLOY-single-file.ts, not index.ts"* — which reads as **make a file called
  that**. Three deploys were lost to it. *The fix was not clearer instructions; it was
  deleting the second name.* The file you copy and the file you paste into are both `index.ts`.
- **"Successfully deployed" means uploaded, not started.** Every check this project had on
  the function was static — it read the source and asserted structure. Static checks cannot
  see a bundle that does not boot. `check-deploy.sh` is the missing one: `OPTIONS` is answered
  on the handler's first line with no I/O, so the time it takes is a clean measure of alive.
  *If nothing you run actually executes the artifact, you are testing the source, not the
  thing you shipped.*
- **The legacy anon key is NOT rejected by the Functions gateway — I claimed it was, and was
  wrong.** Verified by probe: `POST` with the legacy `eyJhbG…` key in both `apikey` and
  `Authorization` (exactly as supabase-js sends it) passes the gateway identically to
  `sb_publishable_…`; a deliberately invalid key comes back `401` in 0.4s, and neither real
  key does. I had a real `INVALID_API_KEY` body from somewhere and generalised it into a
  diagnosis, then nearly swapped the key every user signs in with to fix a fault it was not
  causing. The client key was left alone. *A body that says `INVALID_API_KEY` is evidence;
  a failure that could be a key is not.*
- **A misleading error message costs more than a missing one.** The test button blamed
  deployment for every failure, so when the function was deployed *and running* the user
  went hunting through the dashboard for something already there — twice. It now reads the
  response body and distinguishes three causes: unreachable (not deployed, or no CORS),
  ran-and-refused, and the new-key rejection, and it prints what the function actually said.
  *If two very different failures can produce the same message, the message is a bug.*
- **PostgREST returns HTTP 401 for `42501 permission denied`.** I briefly believed the live
  app had broken because I started printing status codes having previously printed only
  bodies. A correctly-revoked function looks like an auth failure at the HTTP layer. *Read
  the body before raising an alarm — and check the app's own endpoints before concluding
  anything is down.*
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

**v35 — the leave-year tag (Sep 2026).** The one to understand before touching anything
in this area.

*What went wrong.* The user pressed **Start a new year** for 2026 in September 2026, on a
system whose 2026 allowances had been granted by hand in July. Five things happened at
once, all from one cause:

1. `run_year_start` worked out "last year's leftover" as
   *annual balance − the row whose reason is exactly `'2026 annual allowance'`*. Every
   other 2026 entry stayed in that figure, so the company-wide top-ups given in August
   (+3.5, +4, +5 …) were carried forward as if they were 2025 days — in a system that has
   no 2025 data at all.
2. The same run cleared every resetting leave type to zero…
3. …and then called `grant_annual_entitlements(2026)`, which skips anybody who already
   holds a row reading `'2026 annual allowance'` — which was everybody granted in July.
   **Cleared, and never credited back.** That is the "some employees became zero".
4. The Balances tab reads `available / entitled this year`, and *entitled this year* was
   computed in the page by bucketing entries on **the day they were typed** and classifying
   them by **the wording of their note**. Both are guesses.
5. `amend_leave_type_days` credited a flat difference to every active employee, including
   people whose allowance for the year had never been granted, and was not idempotent
   against the year — so a type could end up at twice its figure (sick 28, hospitalisation
   118) with no single row to point at.

*The fix, in one sentence:* `leave_ledger` now carries `leave_year` and `kind`, so the year
and the meaning of an entry are **recorded facts, not inferences**. All 77 inference sites
are gone. `entitled_in_year` / `annual_used_in_year` / `run_year_start` /
`grant_annual_entitlements` / `set_annual_entitlement` / `bump_annual_all` filter on the
tags. A unique index makes a second allowance for the same person, type and year impossible.
`amend_leave_type_days` now **reconciles to the number typed** rather than adding a
difference, which is what "if I set 14 everything follow 14" asks for and also heals an
inflated figure. And `run_year_start` refuses a year that already holds allowances, saying
so and naming the two screens that *do* change a running year's figures.

*Two things worth knowing before you change it:*

- **The carried days are a real ledger entry now** (`kind = 'carry_in'`, tagged the NEW
  year), and last year is closed with a write-off that takes its remainder to exactly zero.
  The balance moves by the forfeited amount only — identical to before — but the years are
  now separable. `annual_carry` keeps the expiry date and the figure; the days live in the
  ledger.
- **A debt carries too.** `v_carry := least(cap, left)` is deliberately not clamped at
  zero: somebody who overspent last year must start the new year owing those days.
  Clamping forgives them silently. There is a test for exactly this (`B16`).

*Two things the verification taught, worth keeping:*

- **Never build a scratch table in `public`.** v35 originally snapshotted balances into
  `_v35_before` to compare before and after. The Supabase dashboard stopped and asked the
  user to approve an RLS exception — a decision they cannot evaluate, in the middle of a
  repair. It was also unnecessary: the old rule reads only columns the backfill does not
  touch, so both rules can be computed side by side at the end. And the balance half of
  that check compared `sum(delta_days)` with `sum(delta_days)` while nothing writes that
  column — **a check that could not fail.** `install.sql` had the same shape
  (`_leavedesk_setup`); that one is genuinely needed, so it enables RLS with no policy.
- **A fixture that cannot distinguish right from wrong is not evidence.** The reported
  company's data sits entirely in 2026, so wording-year and typed-year always agree in it.
  Four deliberate year-tagging bugs were introduced and that fixture caught **none** of
  them. `tests/seed_two_years.sql` exists for this reason and catches all four. Check what
  a fixture can *discriminate*, not just that it passes.

Tests: `hr-leave-system/tests/` — `./run.sh` runs three scenarios plus the page
(65 SQL + 18 browser assertions). Mutants: 7 on the fresh-install path, 5 more on the
upgrade path (the wording classifier is only reachable there — every live code path sets
`kind` explicitly, so a broken classifier is invisible on a new install).

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
- **The Leave types page did nothing, for a year.** Editing "Days / year" wrote
  `leave_types.default_days` and stopped. Nobody already employed was affected — the new
  figure only reached them at the *next* yearly credit, which for most types is never,
  because those are granted once a year. The page looked like a control and was a
  note-to-self. **`amend_leave_type_days()` now credits the DIFFERENCE** to every eligible
  active employee (60 → 62 gives everybody +2 on top of what they have; somebody who used
  5 goes 55 → 57) and writes **one** company-wide row to `hr_amendments`, not one per
  person. **Annual and off-in-lieu are refused outright** — annual is per employee, and
  off-in-lieu is earned. Refusing beats storing a number nothing uses: it used to just
  skip the credit while still saving `default_days`, and `grant_annual_entitlements` then
  granted off-in-lieu to everybody. The test caught it (OIL went 1.5 → 4.5) — that is a
  silent gift of leave to the whole company, so the yearly grant now excludes `oil`
  explicitly as well. **Two defences, because one failure mode is invisible.**
- **Two numbers for one thing is a bug waiting for a Save.** The Edit employee box read
  `employees.annual_base` while the Balances tab read the ledger. They drifted — the 2026
  allowance had been granted under the old "base + a day per year of service" rule, so the
  extra days were in the ledger and never in the column. Barry showed **17.5** in one place
  and **20.5** in the other, and saving reconciled the ledger DOWN to the box: 6.5 days gone,
  silently, from a form the user had opened for another reason. *A screen that can disagree
  with the truth will eventually be used to overwrite it.* Both now read `entNow()`.
- **"It only fires when something disagrees" is not the same as "it only fires when you
  changed it."** The entitlement call was conditioned on the column disagreeing with the
  ledger — which, once the box showed the ledger, meant merely opening a profile and pressing
  Save rewrote that person's entitlement. It now compares against the figure the box was
  *opened* with. *Guard on the edit, not on the discrepancy.*
- **The rule was gone from the database and alive everywhere else.** v18 deleted it, but it
  survived in `schema.sql` (so a fresh install would restore it), in two lines of the
  Start-a-new-year screen, in the flow chart, and in `GUIDE_HR.md:579` — which contradicted
  line 623 of the same file. *Deleting behaviour is not finished until the screens and the
  install script agree with the code.*
- **The "1 day per year of service" rule was real, and invisible.**
  `annual_base + (year − joinYear − 1)` — someone showing 14 was getting 20, and no screen
  connected them. Removed in v18 along with first-year pro-rating: `annual_entitlement_for`
  is now `least(annual_base, annual_cap)`. **The lesson is not the formula, it is that a
  figure the user cannot derive from what is on screen will eventually be reported as a
  bug** — and they will be right, even when the arithmetic is correct.
- **Changing the entitlement now moves THIS year's balance.** `set_annual_entitlement()`
  writes the correction to the ledger and logs it. The screen used to carry a line saying
  "only affects future years — use Balance adjustments", which was true and useless: two
  places to change one fact.
- **v19: THE TYPED FIGURE IS THE TOTAL, and matching on a reason string was the bug.**
  v18's `set_annual_entitlement` only wrote a correction when it found a ledger row whose
  reason was *exactly* `'<year> annual allowance'`. Employees added through the app carry
  `'Pro-rated leave allowance (joined …)'` — no match, **so it silently wrote nothing while
  the screen said "This year's balance moves from 19 to 20, and it is recorded."** Two
  lessons, and the second is the bigger one:
  1. **Never key behaviour off a human-readable string another code path writes.** v19
     defines entitlement structurally instead: `annual_entitled_in_year()` sums this year's
     annual rows where `ref_application is null`. Leave taken *and* cancellation refunds
     both carry `ref_application` — and a refund is **positive**, so counting it as
     entitlement would have clawed those days off whoever cancelled. That single column
     separates the two categories exactly; only year-end write-offs still go by wording.
  2. **Reconcile beats delta when the user's mental model is a total.** Typing 15 makes
     this year's entitlement *equal* 15, which is what the user asked for in those words,
     and it self-heals a ledger inflated by a grant that ran repeatedly (their live data
     read `972 / 528`). A test seeds four stacked grants and asserts one save corrects it.
- **`bump_annual_all(days)` — one click, whole company, permanent.** Raises every active
  employee's `annual_base` and credits the same days to this year. Anyone who would exceed
  `annual_cap` is **skipped and returned by name**, never silently capped. It writes **no**
  amendment record when nobody was raised — a record saying "+1 day to every employee" when
  everybody was skipped is worse than no record.
- **THE REVERSED TYPING CAME BACK, and it was never the holiday box.**
  `<input type="number">` is not allowed to report a cursor position — `selectionStart`
  returns null — so `render()`'s caret restore silently gives up and the cursor lands at 0.
  Every number box that re-renders as you type therefore builds its number **backwards**
  ("15" → "51"). Fixed for text inputs two rounds earlier, and it returned on the first
  number box added afterwards. **Rule: a box that re-renders while you type must be
  `type="text" inputmode="decimal"` (the `NUMBOX` constant), staged through `numText()`.**
  Boxes that only settle on blur can stay `type="number"` — they never re-render mid-word.
- **`view === "apply"` was the wrong question.** HR's "Enter leave for an employee" is the
  *same renderer* at `view === "hr"` / `hrTab === "apply"`, but every field handler asked
  `view === "apply"` — so on HR's copy the date, the leave type, the half-days, the
  attachment and the remarks were **all** dead: picking a date left the old one. Use
  `onApplyView()`. **Sharing a renderer means sharing its handlers' conditions too.**
- **Three routes changed one number and only one of them credited anybody.** The
  entitlement had the Edit form (RPC), the Employees-table box (`saveDraft` → plain
  `annual_base` write) and the leave type's Days / year had the table cell (RPC) and the
  **Edit box** (plain `default_days` write). When one fact has several editors, **grep for
  every writer** — the user found both of the silent ones, not the tests.
- **`works_saturday` was written on the edit branch only**, so anyone added through the
  form saved it blank and the required question came back empty next time. It sat inside
  `} else {` where it read as if it applied to both.
- **`schema.sql` could not build a working system from scratch, and had not been able to
  for a while.** It was missing v12's whole per-employee-Saturday family
  (`emp_works_saturday`, `is_working_day`, `working_days(uuid,…)`,
  `working_days_hd(uuid,…)`) *and* the two `works_saturday` columns — while the v18
  `submit_application` folded into it calls them. A from-scratch build therefore produced a
  system that failed on the first half-day application. Nobody noticed because every test
  ran against the **migration chain**. **Run the suites against both paths** — `chain19.sh`
  and a bare `schema.sql` build — they are not the same database. Note also that helper
  functions written in `language sql` are parsed at CREATE time, so they must appear
  *after* the tables they read; plpgsql ones do not and will happily hide the problem.
- **`bal()` returns `yGranted` / `yUsed` as well as `avail`.** "Allowance" and "Used" were
  all-time sums while every label said "this year" — the source of *19 / 22* (a +1 credit
  raised the "entitlement") and of *972 / 528* after several years. They are now scoped to
  the current year and exclude `HOUSEKEEPING` lines (expiry write-offs, carry forfeits,
  resets), which are neither entitlement nor leave taken. **`avail` was deliberately left
  as the whole ledger** — carried days from last year are real days you may book, and that
  is the figure the database enforces.
- **THE SWALLOWED FIRST CLICK — a general trap, not one form.** Fields staged on `change`
  (which fires on **blur**) whose handler re-renders immediately: mouse-down blurs the
  field → re-render → mouse-up lands on a *different* element → **no click event fires at
  all**, because a click needs down and up on the same element. The second click works
  because nothing re-renders. It hit Balance adjustments and Company settings → Save
  changes. **Fix: stage those fields on `input` (as you type), and make the `change`
  handler a no-op when the value is already staged.** Any future field that re-renders on
  `change` has this bug; check it before shipping the form.
- **`SET ROLE` does not change `session_user`.** Every permission guard here reads
  `if not is_hr() and session_user <> 'postgres'`, so a test that uses `SET ROLE` still
  passes the escape hatch and proves nothing — three of four permission assertions were
  green for the wrong reason. **Use `SET SESSION AUTHORIZATION`.** Same family as the
  `pg.click()` and `window.scrollY` mistakes: the test agreed with the code without
  exercising it.
- **A table alias that matches a declared PL/pgSQL variable breaks at run time.**
  `cross join leave_types t` inside a function declaring `record t` gives
  `record "t" is not assigned yet` — only on the branch that reaches it, never at create
  time. Alias tables something the function does not declare.
- **Every leave type accumulated for ever, and nobody wrote that.** `leave_balances` is
  `sum(delta_days)` over the whole ledger with **no year boundary**, and
  `grant_annual_entitlements` credits a fresh quota every January. Nothing removed the old
  year, so 14 sick days in 2026 plus 14 in 2027 was 28. **It was a missing step, not a
  feature** — which is the most dangerous kind of bug in this codebase, because there is
  nothing to read that looks wrong. Fixed in v16 by `reset_statutory_leave`, which zeroes
  every type with `resets_yearly` (all but `annual` and `oil`) *before* the new grant.
  **When a system is defined as "the sum of everything", ask what removes things.**
- **The value credited on reset is read from `leave_types.default_days`, never a constant.**
  HR changes Childcare from 6 to 8 on the Leave types tab and the next reset lands on 8.
  There is a test that changes it mid-run for exactly this reason — a hard-coded 6 would
  have passed every other assertion.
- **Carry-forward expiry lives in the VIEW, not in a scheduled job.** `leave_balances`
  subtracts `due_unwritten_carry()` — carry whose `expires_on` has passed and which has not
  yet been written off. So the moment the date passes the days stop counting, and
  `submit_application` (which reads `available` from that view) refuses them **without any
  scheduler having run**. `expire_due_carry()` then materialises it into the ledger so the
  history is explicit; it is called from `keepalive_ping()` (already daily) and from
  `run_year_start`. No double-subtraction: writing the row sets `expired_at`, which is what
  the view's subquery filters on. **Given the July 2026 outage, anything whose correctness
  depends on a scheduler still running is not correct.**
- **`run_year_start(year, preview)` is ONE function for both the preview and the run.**
  `preview => true` computes everything and skips only the writes. The preview and the
  result therefore cannot disagree — that is a property of the code, not two
  implementations kept in step by hand. Any future "show me what this would do" should copy
  this shape rather than growing a second calculation.
- **A table alias called `t` inside a PL/pgSQL function with a `record t` silently breaks.**
  PL/pgSQL substitutes the variable into the query and you get
  `record "t" is not assigned yet` — at run time, not at create time, and only on the branch
  that reaches it. Cost an hour. Alias tables something the function does not declare.
- **A POPUP IS NOT NAVIGATION. Opening or closing one must use `rerender()`.** This is the
  rule that ends the "page jumps" reports, and it was hiding in plain sight: `render()`
  scrolls to 0 by design, and **every** modal handler in the app called it. `.modalback` is
  `position:fixed`, so the page behind holds its position on its own — nothing was keeping
  it there. Thirty handlers were converted at once (2026-08-26); before that, each report
  was fixed one button at a time, which is why it kept coming back on whatever was built
  next. **`render()` is only for changing page or tab** (`case "edit"`, the `hr*leave`
  handlers) — those assign `view` or `hrTab`, which is the tell.

  There is a **source-level test** for this in `t8.mjs`: it discovers the popup list by
  regexing `vp.X ? XModal` out of app.html at run time, then asserts that no handler
  touching one of those keys calls a bare `render()` without also navigating. A popup added
  later is therefore covered without anyone remembering to extend the test. **Prefer a rule
  checked against the source over a list of cases typed into a test** — the typed list is
  what let this survive three rounds.
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
