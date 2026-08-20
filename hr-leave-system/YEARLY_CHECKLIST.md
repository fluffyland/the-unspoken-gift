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
| Working-day counting (weekends, holidays excluded) | **Next year's public holidays are entered — by you** |
| Balance arithmetic — always the sum of its entries | **Rollover + new-year grant actually ran** |
| Permissions — enforced by the database, not the screen | **Keep-alive is still alive** |
| Approval routing | **You still have two Owners** |
| | **You have a recent CSV backup** |

The right-hand column is everything that depends on a scheduled job, or on somebody
remembering. Every one of them can fail without producing an error anyone sees.

---

# JANUARY — the important one

Do this in the **first week of January**. It's about 20 minutes.

## 1. Public holidays — the one job nothing else will do

**This is manual, and nothing will remind you.** LeaveDesk used to claim a monthly sync
from MOM; it never once ran, and it was removed in August 2026 rather than left there
looking automatic. So next year's public holidays exist only if a person types them in.

If you skip this, nobody sees an error. What happens instead is that someone books leave
over Chinese New Year and quietly loses a day of annual leave.

### 1a. Look at next year

**HR Console → Company settings → Public holidays**, then press **▶** to move to next
year.

The heading reads **"◀ Public holidays — N dates in YYYY ▶"**, and N is counted from the
rows on screen, so it cannot disagree with the list.

**Singapore has 11 gazetted public holidays a year.** When one falls on a Sunday the
following Monday is a holiday too and gets its own row, so a year normally shows **11 to
15 dates**. Both rows are correct and both must stay: the Monday is the day off, and the
Sunday costs nothing because it was never a working day.

> **Fewer than 11 means the year hasn't been entered.** Don't rationalise it.

**LeaveDesk now tells you.** From September, if next year has fewer than 11 dates you get
a warning on the Public holidays card and a ⚠️ on the **Company settings** tab. That is a
prompt, not a guarantee — it can only count what is there, and nobody but you can add the
dates.

### 1b. Enter them

MOM publishes the list at
**https://www.mom.gov.sg/employment-practices/public-holidays**.

Either:

- **A whole year at once** — press **➕ Add a whole year** and paste the list, one per
  line: a date, a space, then the name. Dates can be `01/01/2027`, `2027-01-01` or
  `1 January 2027`. You see exactly what will be added before anything is saved, plus
  anything already on the list (skipped) and any line it couldn't read. **This is the
  quickest route and it works for any year.**
- **One at a time** — type the date as **DD/MM/YYYY**, give it a name, **+ Add holiday**.
  **✎** edits, **✕** removes.
- There is also [`supabase/insert_holidays_2027.sql`](supabase/insert_holidays_2027.sql)
  for the Supabase SQL Editor, from before the paste box existed. You no longer need it.

### 1c. Check it in SQL if you want certainty

```sql
select holiday, to_char(holiday, 'Dy') as day, name
from public_holidays
where holiday >= '2027-01-01' and holiday < '2028-01-01'
order by holiday;
```

Compare against MOM's published list. That is the whole check — there is no sync log to
read any more, and no schedule that can have stopped.

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

### If you switched to monthly accrual, this section works differently

Check which mode you are on: **Company settings → Leave policy → "Credit annual
leave"**. In SQL: `select accrual_mode from org_settings where id = 1;`

**On `monthly`, `grant_annual_entitlements` deliberately does nothing** — it refuses
to run so the two methods can never both credit the same year. Leave arrives in
twelve instalments instead, one per month:

```sql
select accrue_monthly_leave(2027, 1);   -- year, month
```

Each run credits *"what you should have by now, minus what you've already had"*, so
running it twice for the same month adds nothing, and a missed month is repaired by
the next run. **December always lands exactly on the full annual figure** — that is
the property to check, not each month's arithmetic.

**The January check is therefore different.** Balances will show roughly **one
twelfth**, not the full year. That is correct — it is not a failed grant. What to
verify instead: last year's **December** figure equals each person's full
entitlement. If it does not, a month was missed and never repaired.

⚠️ **Never switch modes part-way through a year without reconciling by hand.** Both
functions refuse to double-credit, but the halves of the year do not add up on their
own — you would need a manual adjustment to bridge them. Switch at 1 January.

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
- [ ] **Request a password-reset code for yourself and check it arrives.** Resend is
      an external service that can fail quietly — and a broken reset only shows up
      when someone is already locked out.
- [ ] **On monthly accrual only:** did this month's instalment land?
      `select created_at, reason from leave_ledger where reason like '%monthly accrual%' order by created_at desc limit 5;`
      Nothing this month → run `select accrue_monthly_leave(<year>, <month>);`
      (safe to repeat; it credits only what is missing).
- [ ] Any rows in `ledger_guard_failures`? Empty is normal. Rows mean a balance
      safeguard blocked a refund and needs looking at:
      `select at, app_id, message from ledger_guard_failures order by at desc limit 10;`

---

# The one-page version

If you only do five things in January:

1. **Press ▶ and enter next year's public holidays.** Nothing else will. Fewer than 11 → not done.
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
