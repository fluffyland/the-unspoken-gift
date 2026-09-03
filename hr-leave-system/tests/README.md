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
| `t35.mjs` | The page: that it reads the leave year off the entry instead of the day it was typed, that it still works against a database which has not been upgraded, and that starting a year already running is explained rather than attempted. |
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
