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
| ⏳ v16 / v18 / v19 + `keepalive_ping_v3` | carry-forward and the yearly reset · Leave types crediting everyone, HR applying on behalf, amendment records · the typed figure IS the year's entitlement + one-click company credit | **written, tested against a real Postgres, NOT yet run by the user.** The frontend feature-detects all three (`db.orgV16`, `db.orgV18`), so the deployed site works without them and simply shows the older screens. Order matters: **v16 → v18 → v19** |

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
navigation), `t8.mjs` 34 (the popup/`render()` rule, the year search bar, layout),
`t9.mjs` 35 (per-employee carry cap, the Apply split, Start a new year),
`t10.mjs` 51 (the Leave types credit, the entitlement, the two record books, HR applying
on behalf, the year-scoped figures, the swallowed click).

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
