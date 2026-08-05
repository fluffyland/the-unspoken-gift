# LeaveDesk — Yearly Checklist (and what not to trust)

For HR / Owner. Most of this system is automatic. **Automatic is not the same as
verified**, and the automatic parts fail quietly — that's the whole problem with
them.

This document exists because in July 2026 a keep-alive reported success every
time while the database was dying. The lesson generalises: **check the outcome,
not the machinery.** Don't ask "is the job scheduled?" Ask "did the thing it was
supposed to do actually happen?"

---

## What you can trust vs what to verify

| Trust it | Verify it once a year |
|---|---|
| Working-day counting (weekends, holidays excluded) | **Public holidays are actually loaded** |
| Balance arithmetic — always the sum of its entries | **Rollover + new-year grant actually ran** |
| Permissions — enforced by the database, not the screen | **Keep-alive is still alive** |
| Approval routing | **You still have two Owners** |
| | **You have a recent CSV backup** |

The right-hand column is everything that depends on a scheduled job. Every one
of them can fail without producing an error anyone sees.

---

# JANUARY — the important one

Do this in the **first week of January**. It's about 20 minutes.

## 1. Public holidays — the most likely thing to be broken

The system syncs Singapore public holidays monthly from MOM's official open data
and loads next year's when they're published. It usually works. When it doesn't,
**nothing tells you** — you find out when someone books leave over a holiday and
loses a day.

### 1a. Look at it in the app

**HR Console → Company settings → Public holidays**

The heading says how many are loaded for the year. Auto-loaded dates are marked
**· auto**.

**Singapore has 11 gazetted public holidays a year.** When one falls on a Sunday
the following Monday is also a holiday, so the list may show a few more —
roughly **11 to 15 rows** is normal.

> **Fewer than 11 means it's broken.** Don't rationalise it.

### 1b. Check it properly in SQL

**Supabase → SQL Editor.** Replace the year with the one you're checking:

```sql
-- What have we got, and where did it come from?
select source, count(*)
from public_holidays
where holiday >= '2027-01-01' and holiday < '2028-01-01'
group by source;
```

`data.gov.sg` = auto-synced. `manual` = typed in by hand. Zero rows means the
sync has not run for that year at all.

```sql
-- The actual list — eyeball it against MOM's published dates
select holiday, to_char(holiday, 'Dy') as day, name, source
from public_holidays
where holiday >= '2027-01-01' and holiday < '2028-01-01'
order by holiday;
```

Compare against the official list at
**https://www.mom.gov.sg/employment-practices/public-holidays**.

### 1c. Did the sync job actually run?

```sql
select ran_at, source, years, total_seen, status, message
from holiday_sync_log
order by ran_at desc
limit 5;
```

- **No rows at all** → the sync has never run. The function or the schedule is missing.
- **Newest `ran_at` months old** → the schedule stopped.
- **`status` not `ok`** → read `message`.

### 1d. Fixing it

**First, just run it by hand.** Replace `<project-ref>`:

```
curl -X POST https://<project-ref>.functions.supabase.co/sync-holidays
```

`{"ok":true,...}` means it worked — re-check 1b, you're done.

**If that fails**, check the schedule exists:

```sql
select jobname, schedule, active from cron.job;
select jobname, status, return_message, start_time
from cron.job_run_details
order by start_time desc
limit 10;
```

You should see `sync-holidays-monthly`, `annual-rollover` and `annual-grant`,
all `active`. Missing? Re-run the scheduling SQL from
[`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) §1.7.

**If it still won't work — enter them by hand and move on.** Don't let a broken
sync hold up the year. Either use **+ Add holiday** in Company settings, or:

```sql
insert into public_holidays (holiday, name, source) values
  ('2027-01-01', 'New Year''s Day', 'manual'),
  ('2027-02-06', 'Chinese New Year', 'manual')
  -- ...the rest from MOM's list
on conflict (holiday) do update set name = excluded.name;
```

> Manual entries are **safe**. The sync only ever touches rows where
> `source = 'data.gov.sg'` — it will never overwrite or delete what you typed.
> That also means a wrong manual entry stays wrong until *you* fix it.

---

## 2. Did everyone get this year's leave?

31 December should have run rollover then grant, automatically.

**Check:** HR Console → **Balances**. Every active person should show a non-zero
**entitled** figure for the new year. If the column is zeros, it didn't run.

**Fix:** HR Console → Company settings → **Yearly leave allowances** → pick the
year → **Add … leave allowances**.

Safe to run even if it *did* work — anyone already set up is skipped.

Equivalent in SQL (also safe to repeat):

```sql
select rollover_annual_leave(2027);
select grant_annual_entitlements(2027);
```

> **Order matters:** rollover first, then grant. Rollover carries unused days
> forward (capped, expiring); grant issues the new year's allowance.

### Spot-check three people

Automation is easiest to trust when you've looked at actual numbers. Pick:

- someone who joined **mid-last-year** → should be pro-rated, not a full year
- someone **long-serving** → base plus service-based extra
- someone who **didn't use all** last year's leave → carried-forward days visible

If any look wrong, fix with **HR Console → Balance adjustments** and note why.

---

## 3. Is the keep-alive still alive?

```sql
select last_ping_at, ping_count from public.keepalive_heartbeat;
```

- `last_ping_at` should be **within the last day or two**
- `ping_count` should be **hundreds higher** than last January (two keepers ×
  daily × 365)

**If `last_ping_at` is old, both keepers have stopped.** Your database is
unprotected right now and may be days from pausing. Check:

1. **cron-job.org** — is the job still enabled? Free services do delete idle accounts.
2. **The private keep-alive repo** — Actions tab, is the workflow still running?
   **Was the repo made public?** That re-arms GitHub's 60-day auto-disable.
3. Re-run both by hand, then re-check `ping_count` went up.

---

## 4. Alerting still reaches a human

The single most important line in this document.

**Send yourself a test alert from UptimeRobot and confirm it reaches your phone.**

In July 2026 the failure alerts fired correctly — 8 emails — and went unread for
two weeks. Detection worked; the alert going somewhere nobody looks is what
turned a one-day problem into a fourteen-day outage.

- [ ] UptimeRobot monitor is **active** and pointed at the **database** URL
- [ ] Phone push notifications on
- [ ] You have received a test notification **this year**
- [ ] The alert goes to someone who still works here

---

## 5. Accounts

- [ ] **At least two Owner / Super Admin accounts.** One Owner leaving or being
      locked out means nobody can manage Owner accounts.
- [ ] Everyone who left last year is **offboarded** (not just ignored). Confirm
      they can't sign in.
- [ ] Approval routes still make sense after any reorganisation — nobody's
      approver has left.

---

## 6. Backup

- [ ] Export **HR Console → Balances → ⬇ Export CSV**
- [ ] Export **HR Console → All records → ⬇ Export CSV**
- [ ] Store both **off-system** — NAS, Google Drive, anywhere that isn't Supabase

Do this quarterly if you can. It's the only copy that survives losing the
database, and free-tier projects are **permanently deleted 90 days** after they
pause.

---

## 7. Policy review

- [ ] Leave types and day allowances still match company policy
      (HR Console → **Leave types**)
- [ ] Any statutory changes? MOM occasionally revises entitlements — e.g. Shared
      Parental Leave increasing. Update **default days** on the type.

> Changing a type doesn't retrospectively change existing balances. Top people
> up with **Balance adjustments** if a change should apply to the current year.

---

# MONTHLY — five minutes

- [ ] Applications stuck **Pending** more than a week
- [ ] Joiners and leavers recorded
- [ ] `select last_ping_at, ping_count from public.keepalive_heartbeat;` — recent?
- [ ] CSV export if it's quarter end

---

# The one-page version

If you only do five things in January:

1. **Count the public holidays.** Fewer than 11 → broken.
2. **Check Balances shows non-zero entitlements** for the new year.
3. **Check `last_ping_at` is recent.**
4. **Send yourself a test alert** and confirm it reaches your phone.
5. **Export two CSVs** and put them somewhere else.

Everything else in this document is detail for when one of those five fails.

---

## Related documents

| Document | For |
|---|---|
| [`GUIDE_HR.md`](GUIDE_HR.md) | day-to-day HR operations |
| [`GUIDE_EMPLOYEE.md`](GUIDE_EMPLOYEE.md) | give this to staff |
| [`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) | rebuilding from scratch |
| [`HANDOVER.md`](HANDOVER.md) | technical handover |
