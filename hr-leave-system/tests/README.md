# Tests for v35 — the leave-year tags

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
| `seed_new_company.sql` | Four people, nothing granted yet. |
| `seed_reported_case.sql` | The same people with the July allowances and the August top-ups already in the ledger. |
| `t35.mjs` | The page: that it reads the leave year off the entry instead of the day it was typed, that it still works against a database which has not been upgraded, and that starting a year already running is explained rather than attempted. |
| `seed.js` | An in-memory company for the page, so no Supabase project is needed. |
| `supabase_shim.sql` | The few things Supabase provides that a bare Postgres does not — `auth.uid()`, the storage tables, `net.http_post`. Small on purpose: the less this pretends, the more the tests mean. |

## What you need installed

- PostgreSQL 16 (`/usr/lib/postgresql/16/bin`) and permission to run `runuser -u postgres`
- Node 18+ with Playwright and Chromium, for the browser half

## Reading a failure

Every assertion prints the number it got and the number it wanted. A failure is a
sentence, not a stack trace:

    FAIL  B16 an overspent year carries its debt forward — got 0, want -2

The name is the rule that broke. Fix the rule, not the number.
