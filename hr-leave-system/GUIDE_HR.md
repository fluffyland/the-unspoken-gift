# LeaveDesk — HR Guide

For whoever runs LeaveDesk day to day: **HR Admin** or **Owner / Super Admin**.

Employees have their own, much shorter guide:
[`GUIDE_EMPLOYEE.md`](GUIDE_EMPLOYEE.md) — send them that, not this one.

---

## The four account types

| Account type | Can do |
|---|---|
| **Employee** | apply for their own leave, see their own balances |
| **Manager / Supervisor** | the above, plus approve for people assigned to them |
| **HR Admin** | everything except changing an Owner |
| **Owner / Super Admin** | everything, including managing other Owners |

Anyone set as somebody's approver can approve, whatever their account type.

**Keep at least two Owners.** If the only Owner leaves or is locked out, nobody
can manage Owner accounts. HR Admins deliberately cannot reset an Owner's
password — that's what stops an HR account from taking over the system.

---

## Where things are

Top of the screen: **Overview · My details · Apply · My applications · Calendar**,
plus **Approvals** if you approve for anyone, plus **HR Console**.

HR Console has six tabs:

| Tab | For |
|---|---|
| **All records** | every application, searchable, exports to CSV |
| **Balances** | everyone's remaining days, exports to CSV |
| **Employees & approval routes** | add, edit, offboard staff; set who approves whom |
| **Leave types** | leave categories and how many days each carries |
| **Balance adjustments** | credit off-in-lieu, fix mistakes |
| **Company settings** | company defaults, public holidays, yearly allowances |

> Changes in the HR Console are **not saved as you type**. A **Save changes**
> bar appears at the top once you've edited something. Click it, or you lose
> the edit when you navigate away.

---

## New employee

**HR Console → Employees & approval routes → Add employee**

Fill in name, work email, hire date (`DD/MM/YYYY`), team, job title, and the
annual leave base. Set **approver 1**; tick two-level approval and set
**approver 2** where a second sign-off is needed.

Saving does three things automatically: creates their profile, creates their
login, and credits this year's leave (pro-rated if they joined mid-year).

A popup shows the temporary password — **`Ssu123@`** by default. Pass it to
them and tell them to change it on first sign-in.

> **No popup?** The `create-login` function isn't deployed. See
> [`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) §1.6. Until then you'd be creating
> logins by hand in the Supabase dashboard.

**Existing employee with no login:** open their **Edit** → **Create login**.

---

## Approving leave

**Approvals** tab. Each request shows who, what type, which dates, how many
working days, their remaining balance, and any attachment.

- **Approve** — passes to approver 2 if two-level, otherwise it's done
- **Reject** — declined, with a reason
- **Return** — sends it back to the employee to fix and resubmit

Return is the kind one: use it for a wrong date or a missing MC. The employee
edits and resubmits rather than starting over.

Weekends and Singapore public holidays are excluded from the day count
automatically. You don't need to check that arithmetic.

---

## Leave balances

**HR Console → Balances** — a grid of everyone against every leave type, shown
as **days left / entitled this year**. Pending requests are already reserved,
so what you see is genuinely available.

**⬇ Export CSV** for payroll or as a backup. Worth doing at least quarterly and
keeping it off-system — it's the only copy that survives losing the database.

---

## Off-in-lieu and corrections

**HR Console → Balance adjustments**

Pick the employee, the leave type, and the number of days. **Positive credits,
negative deducts.** The reason is required and permanent.

Typical uses:
- someone worked a weekend or public holiday → credit off-in-lieu (OIL)
- a balance is wrong after a data fix → correct it
- expiring days → deduct them

A balance is always the sum of its entries, so every change is traceable. The
**Recent adjustments** table shows the last 30 — click any column to sort.

---

## Leave types

**HR Console → Leave types** — the categories and their default day allowances.

Per type you can set: whether it deducts from a balance, whether half-days are
allowed, whether an MC attachment is compulsory, and who is eligible.

Changing a policy (say Shared Parental Leave going from 4 to 10 weeks) is done
here — edit the default days. Existing balances aren't retrospectively changed;
use **Balance adjustments** if people need topping up.

---

## Someone forgot their password

**They can now do it themselves** — sign-in page → *Forgot your password?* → a
6-digit code by email → set a new one. Point them at that first; you're no longer
the bottleneck.

**You still need to step in when** they can't reach their work email at all, or
share a mailbox with someone else.

**Their Edit form → Reset password.** Puts it back to `Ssu123@`; tell them to
change it after signing in.

> ⚠️ Every reset sets the **same** password, `Ssu123@`, which everyone in the
> company knows. Until that person changes it, their account is open to any
> colleague who tries it. Nudge them to change it immediately, and prefer
> self-service where you can.

Everyone gets an email whenever their password changes, whether they did it or you
did. If someone reports one they didn't trigger, treat it seriously.

## Someone changed their email address

Just edit it on their profile — the system now updates their **sign-in** email at
the same time, so they use the new address from then on.

> If you see *"Profile saved, but the sign-in email could not be updated"*, stop and
> get it fixed. That person is stuck signing in with the **old** address, and
> self-service reset won't work for them. It is not cosmetic.

Alternative, without the app: Supabase Dashboard → **Authentication → Users** →
find them → **Generate link (recovery)** → send them that link.

> An HR Admin **cannot** reset an Owner's password. Only another Owner can.
> This is deliberate.

---

## Someone leaves

**Their Edit form → Offboard.**

This settles their leave, marks them inactive, removes their login, and hands
any applications waiting on them to you so nothing gets stuck. They can no
longer sign in — the database enforces that, not just the screen.

Their records stay for reporting.

**Two buttons that are not offboarding:**

- **Clear leave records** — wipes their applications and balances, keeps profile
  and login. For fixing a bad import.
- **Delete permanently** — removes everything, no trace. For test data only.

Use **Offboard** for real departures. The other two destroy history you may need.

---

## Staff who work Saturdays

**HR Console → Employees & approval routes → Teams / departments** — tick
**Works Sat** for a team, and Saturday becomes a normal working day for everyone in
it.

**Individual exceptions:** their Edit form → **Works Saturdays** → *Follow team* /
*Yes* / *No*. "Follow team" is the default; use Yes or No only for someone who
differs from their team.

> ⚠️ **This changes what leave costs.** For a Saturday worker, Mon–Sat is **6 days**,
> not 5. Set it before people apply for leave, not after — existing applications keep
> whatever they were worked out at, and are deliberately not recalculated.

Public holidays are still excluded for everyone, including on a Saturday.

## Public holidays

**HR Console → Company settings → Public holidays**

The list auto-syncs monthly from MOM's official data. The **Source** column shows
where each date came from and when it last changed:

| | |
|---|---|
| 🔄 Sync · 01/08/2026 09:17 | came from MOM, confirmed on that date |
| ✋ Manual · 15/07/2026 14:03 | you added or edited it then |

Above the table, **"Last checked against MOM"** tells you when the sync last *ran*.
That's the one to watch: a sync that runs and finds nothing changes no rows, so
without this line a working sync and a dead one look identical. If it's more than
about 45 days old the system warns you — the schedule has stopped.

**Your manual entries are protected.** The sync will never delete a date you added,
and never renames one. If you add a date that MOM later publishes too, it stays
yours and HR gets told: *"1 date you added by hand also appears in MOM's list — kept
as yours."*

> **Check this every January.** The sync is the single most likely thing to fail
> quietly — see [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md) for exactly how to
> verify it and what to do when it hasn't worked.

---

## Yearly allowances

**HR Console → Company settings → Yearly leave allowances**

Pick the year, click the button. Annual leave is worked out from each person's
base plus years of service; new joiners are pro-rated.

Safe to run twice — anyone already set up for that year is skipped.

Normally 31 December handles this automatically. Verify it did rather than
assuming — again, [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md).

---

## Records and reporting

**HR Console → All records** — every application ever. Filter by status, search
by name, **⬇ Export CSV**.

Statuses: Pending · Approved · Rejected · Returned · Withdrawn ·
Cancellation requested · Cancelled.

---

## Things worth knowing before they bite

**The system doesn't email you when it breaks.** Monitoring is a separate
service (UptimeRobot). If you're not getting phone alerts, you have no alerting.

**"The website is down" usually isn't the website.** The page is served by
GitHub and rarely fails. If it loads but nothing works, the *database* is
asleep or down. Supabase dashboard → **Restore**.

**Free database sleeps if unused.** Two keep-alive services poke it daily. Don't
switch them off, and don't change the keep-alive repo from private to public.

**Export a CSV backup regularly.** Balances and All records. Cheap insurance.

---

## Monthly, five minutes

- [ ] Anyone left or joined without being recorded?
- [ ] Applications stuck **Pending** for over a week?
- [ ] Export **Balances** and **All records** to CSV, keep it off-system
- [ ] Heartbeat is alive — Supabase SQL Editor:
      `select last_ping_at, ping_count from public.keepalive_heartbeat;`
      `last_ping_at` should be **within a day or two**

---

## Related documents

| Document | For |
|---|---|
| [`GUIDE_EMPLOYEE.md`](GUIDE_EMPLOYEE.md) | give this to staff |
| [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md) | the annual routine |
| [`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) | rebuilding from scratch |
| [`NEW_COMPANY_SETUP.md`](NEW_COMPANY_SETUP.md) | resets, new company SOP |
