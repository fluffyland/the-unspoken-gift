# Tests for v35 and v36

Two halves, both self-contained. Neither touches the live database and neither can
send an email.

    ./run.sh            both
    ./run.sh sql        the database half only
    ./run.sh browser    the page half only

## What each file is

| File | What it holds |
|---|---|
| `t35.sql` | The database rules, in five sections: a company with no previous year, the Leave types tab, a real second year, a rejected application, and the undo. |
| `t35_reported_case.sql` | The exact situation reported in September 2026 — the year's allowances granted by hand in July, top-ups in August, no earlier data — proved not to be able to happen again. |
| `t35_two_years.sql` | The upgrade on a company that has a real 2025: December leave keyed in January, year-end write-offs dated 2 January, and a carry-over expiring mid-year. |
| `seed_new_company.sql` | Four people, nothing granted yet. |
| `seed_reported_case.sql` | The same people with the July allowances and the August top-ups already in the ledger. |
| `seed_two_years.sql` | A company with history — see below for why this one has to exist. |
| `t35_joiners.sql` / `seed_joiners.sql` | The reported split: sick 13 / 14 / 27 in one company. Somebody added through **Add employee** is credited at whatever the leave type said the day they joined, and that credit was not recognised as the year's allowance — so the yearly run credited them again. Reproduces all three strata, then proves retyping the figure levels everyone without losing a day. |
| `t35_lifecycle.sql` / `seed_lifecycle.sql` | Every leave type and every employee — including one with no gender recorded, a leaver, and a mid-year joiner — through apply → approve → withdraw → reject → cancel → amend. After each step it re-checks `available == entitled + carried − taken − pending` for the whole company, **and** that nobody is left holding no allowance at all. That second check exists because the first one cannot see a person whose entitlement is simply missing: their figures agree with each other. |
| `t36_oil_expiry.sql` / `t36.mjs` | The off-in-lieu expiry date: off by default, forfeits the whole balance on the day, unusable even if every scheduled job is dead, and driven by the daily heartbeat rather than a job of its own. The browser half checks the control sits next to the annual-leave one and says out loud how the two rules differ. |
| `t37_expiry_parity.sql` | The two expiry dates are one mechanism: same cut-off algorithm, same forfeit, same Amendment record. Includes the root cause of "I set today's date and nothing happened" — a helper marked IMMUTABLE while reading `current_date`, which lets the planner freeze the date into a cached plan. Checked statically, because plan caching cannot be reproduced in a test. |
| `t35.mjs` | The page: that it reads the leave year off the entry instead of the day it was typed, that it still works against a database which has not been upgraded, and that starting a year already running is explained rather than attempted. |
| `t40.mjs` | Annual leave and carry-forward are two pots and no screen may count them twice. 14 entitled, 5 carried, 3 taken must read as **CF 2 · AL 14 / 14**, never CF 5 beside an Annual Leave figure that already contains those 5. Also that the carry left is worked out from the **ledger** and not from the list of approved applications — reading one while the balance reads the other is what made Annual Leave appear to grow as leave was taken. |
| `t41.mjs` | The same split on **My details → My leave entitlement**, the page the employee opens. v40 fixed HR's Balances tab and missed this one, so the fault survived exactly where the person complaining would see it: `Annual Leave 14 · 0 · 19` with `Carry Forward 5 · 0 · 5` — 24 days for 14 entitled. Asserts the invariant rather than the numbers: `Balance − Taken = Left` on both rows, and the two `Left` figures add up to what the database says can be booked. Also that days which **expired** are not reported as days the person took. |
| `t42_smoke.mjs` | **Every screen renders.** Every view as employee and as HR/Owner, every HR console tab, five un-upgraded database shapes, four carry states — asserting only that the screen produced content with no page error. It exists because v41 deleted a function the dashboard used by reference, blanking the first screen after sign-in, and no other suite rendered that screen at all. The cheapest suite here and the one whose absence cost a working app. |
| `t43_export_settings.sh` | **Settings move to a new company; people do not.** Builds two databases for real — the old company with its own settings and its staff, and a brand-new one from `install.sql` alone — then exports, imports, and compares every settings column with `to_jsonb(row)` rather than the columns somebody remembered. Also asserts the new company has zero rows in all seven people tables, that a leave type or holiday the old company deleted stays deleted, and that a second import is a no-op. Has its own script because it needs two databases at once. |
| `t44_owner_links_itself.sql` | **One paste, then one dashboard click.** The Owner employee row is created by a trigger on `auth.users` the moment that login appears, in either order, and the install records who it is to be. Checks the guard that matters most: a login on a *different* address, while the invitation is still open, must create nobody — the mutation run showed the one-shot clearing does not cover that case, so only the email comparison stands between a new staff login and company Owner. Also that a failure in the claim can never block a signup, and that `_leavedesk_setup` really is dropped, which is why the old advice to "re-run the last section" could never work. |
| `t45_setup_guard.mjs` | **A copy not yet pointed at a database must say so.** `createClient()` throws on a placeholder URL, before anything renders, so an unedited `index.html` used to be a white page with no clue which of 4,400 lines to look at. Now it is a screen naming both constants, the line number and where in the dashboard to find the values. Also that **both** key formats pass — the old `eyJ...` JWT and the `sb_publishable_...` one new projects issue — since rejecting the newer form would tell somebody with a correct setup it was wrong. |
| `t46_keepalive_grant.sql` | **The daily ping is allowed to run.** `anon` must hold EXECUTE on `keepalive_ping`, the counter must actually advance (a 200 from the cron service proves nothing on its own), and `anon` must still be unable to read or write the heartbeat table. Run twice by `run.sh`: on a fresh install, and again with v36 re-applied on top — the shape that produced `401 / 42501 permission denied` in production on 4 Sep 2026 and left the project drifting toward the 7-day idle pause. |
| `t47_keepalive_health.sql` | **A dead ping must be reported every time it is checked.** cron-job.org emails once on the transition to broken and then goes quiet, so `keepalive_health()` fails continuously while the heartbeat is stale and a monitor re-alerts on its own schedule. Asserts ten failures from ten checks, a 36-hour grace period (30 hours late is fine, 37 is not, so a slow scheduler does not cry wolf), self-recovery on the next good ping, the never-pinged case, and that anon may call it while PUBLIC may not and neither can read the table behind it. |
| `t48_oil_expiry_shown.mjs` | **Off-in-lieu says when it dies, wherever it is shown.** The date existed only on HR’s Company settings tab, while carry-forward annual leave has shown its expiry on three screens since v24 — so off-in-lieu could be forfeited in full on a date nobody had been shown. Now derived from the company setting on every render (no stored per-employee copy, which is what makes “it must always be updated” true by construction), displayed as the NEXT occurrence, “N/A” when no date is set, and today on the day itself. |
| `seed_explain_faults.sql` | Four planted faults, one of each shape `supabase/explain_balances.sql` claims to find: a previous year's leftover nobody wrote off, a leave type retyped to 65 while people still hold 70, a carry-forward with only one of its two halves, and somebody holding no allowance at all. `run.sh` runs the report on a healthy company first (it must stay quiet) and then on this one (it must name all four). |
| `seed.js` | An in-memory company for the page, so no Supabase project is needed. |
| `supabase_shim.sql` | The few things Supabase provides that a bare Postgres does not — `auth.uid()`, the storage tables, `net.http_post`. Small on purpose: the less this pretends, the more the tests mean. |

## Why there are several fixtures

`seed_reported_case.sql` is the real company's data, and every row in it sits in 2026.
That makes it useless for testing the year tags: "the year the wording names" and "the
year the row was typed in" always agree there, so a migration that filed everything
under the wrong year would produce results identical to one that got it right.

This was not theory. Four deliberate bugs — disabling the wording rule, filing leave by
the day it was keyed in, misclassifying write-offs as corrections — were introduced one
at a time and the reported-case fixture noticed **none** of them. It could not. A test
that cannot distinguish a right answer from a wrong one is not evidence.

`seed_two_years.sql` exists so those bugs have somewhere to show. In it the two years
disagree in three places on purpose, and all four bugs are caught.

## What you need installed

- PostgreSQL 16 (`/usr/lib/postgresql/16/bin`) and permission to run `runuser -u postgres`
- Node 18+ with Playwright and Chromium, for the browser half

## Reading a failure

Every assertion prints the number it got and the number it wanted. A failure is a
sentence, not a stack trace:

    FAIL  B16 an overspent year carries its debt forward — got 0, want -2

The name is the rule that broke. Fix the rule, not the number.
