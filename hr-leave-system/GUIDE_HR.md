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

**Their Edit form → Reset password.** Puts it back to `Ssu123@`; tell them to
change it after signing in.

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

## Public holidays

**HR Console → Company settings → Public holidays**

The list auto-syncs monthly from MOM's official data. Auto-loaded dates are
marked **· auto**. You can still add, edit (✎) or remove (✕) any date by hand,
and the sync won't overwrite your manual entries.

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
