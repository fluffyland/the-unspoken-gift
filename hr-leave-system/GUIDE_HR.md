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
| **Company settings** | company details, defaults, leave policy, public holidays, yearly allowances |

> Changes in the HR Console are **not saved as you type**. A **Save changes**
> bar appears at the top once you've edited something. Click it, or you lose
> the edit when you navigate away.

---

## New employee

**HR Console → Employees & approval routes → Add employee**

Fill in name, work email, hire date (`DD/MM/YYYY`) and job title. Set **approver 1**;
tick two-level approval and set **approver 2** where a second sign-off is needed.

**The email builds itself.** Type the name and the part before the `@` fills in from
it — `Lee Jian Wei` → `leejianwei`. Beside the box, greyed out, sits your company
domain, and it can't be typed over. Edit the prefix freely; once you do, it stops
following the name.

> The domain comes from **Company settings → Company details → Email domain**. If that
> box is empty there is nothing to lock to, so the form falls back to a plain email
> field and you type the whole address. Fill the domain in once and the auto-fill works
> for every hire after it.

**Four fields start on "— Select —" and must be chosen.** They used to arrive
pre-filled, which meant clicking through filed someone silently:

| Field | Why it isn't guessed for you |
|---|---|
| **Team / department** | drives who approves their leave |
| **Gender** | decides which leave types they're offered — maternity vs paternity |
| **Account type** | decides what they can see and do |
| **Works Saturdays** | changes what their leave costs: Mon–Sat is 6 days, not 5 |

Gender is the one worth pausing on. It used to default to Female, so half of all new
hires were set up with the wrong parental leave — and because the field *looked*
answered, nothing prompted anyone to check.

The **annual leave base** is pre-filled from Company settings and can be changed. It
cannot exceed the company maximum, if you've set one.

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

**Nothing is pre-selected.** Employee, leave type, days and reason are all required.
The form used to open on the first employee alphabetically with Off-in-Lieu and 1 day
already filled in, so an adjustment saved without touching the dropdowns landed on the
wrong person under the wrong leave type — and looked perfectly normal in the list.

As you type, the form shows the impact:

```
Adjustment Preview: +1.5 days
Current: 12.0 days ➔ New Total: 13.5 days
```

**It asks before saving.** A confirmation states the employee, the leave type, whether
it's an OIL credit or a manual adjustment, the before and after figures, and your
reason. Ledger entries are permanent — a wrong one can only be undone by adding a
second, opposite entry — so read it before confirming.

**Going below zero is allowed, but it asks first.** If the result would be negative
you get a warning and a tick box to confirm. Clawing back an over-grant is a real
need, so it isn't blocked — but it can't happen by accident either. Under monthly
accrual a negative balance is normal and expected; under yearly crediting it usually
means something is wrong, so read the warning before ticking.

A balance is always the sum of its entries, so every change is traceable. The
**Adjustments** table shows **every** entry ever made, with a search box — click any
column to sort, and the page stays where it is instead of jumping to the top.

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

**Per person:** their Edit form → **Works Saturdays** → **Yes** or **No**. This is now
a required answer rather than an inherited one, so each person's record states it
outright. Anyone whose record predates the change will be asked once, the first time
you open their Edit form.

The team-level tick still applies to those older records until they're answered.

> ⚠️ **This changes what leave costs.** For a Saturday worker, Mon–Sat is **6 days**,
> not 5. Set it before people apply for leave, not after — existing applications keep
> whatever they were worked out at, and are deliberately not recalculated.

Public holidays are still excluded for everyone, including on a Saturday.

## Public holidays

**HR Console → Company settings → Public holidays**

**One year at a time.** The heading shows the year you're looking at, with **◀** and
**▶** either side of it — ◀ for the earlier year, ▶ for the later one, the same as the
Calendar tab. The count in the heading always describes the rows underneath it, so 2026
and 2027 can never be mixed together in one list.

The list auto-syncs monthly from MOM's official data, and there's a **🔄 Sync now**
button if you don't want to wait. It tells you exactly what changed — how many dates
were added, renamed or removed, and how many of your own manual entries also appear in
MOM's list and were kept as yours. If it can't run, it says so; it never fails quietly.

> **⚠️ Automatic updates are not switched on for this system yet.** Press **🔄 Sync now**
> and it says so in as many words. Until someone switches it on, add each year's dates
> with **+ Add holiday**, or paste
> [`supabase/insert_holidays_2027.sql`](supabase/insert_holidays_2027.sql) into
> Supabase → SQL Editor, which loads all 12 of MOM's 2027 dates in one go and leaves
> 2026 untouched.

**Where the data comes from:** data.gov.sg collection 691, published by the **Ministry
of Manpower** — their own machine-readable feed, not a copy of the mom.gov.sg web page
(which would break silently whenever the page was redesigned). You can check the source
yourself at `api-production.data.gov.sg/v2/public/api/collections/691/metadata`.

**Adding a date by hand:** type it as **DD/MM/YYYY** — e.g. `15/07/2026`. Slashes,
dashes and dots all work.

The **Source** column shows where each date came from and when it last changed:

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

## Annual leave: the maximum, and how it's credited

**HR Console → Company settings → Leave policy**

Company settings is split into three cards, because "default" was doing two different
jobs in one box:

| Card | What it is |
|---|---|
| **Company details** | name and email domain |
| **Defaults for new employees** | a **pre-fill** for the Add employee form. Changing it moves nobody who already exists |
| **Leave policy** | **rules that apply to everyone**, at the next yearly grant |

**Maximum annual leave is a total, not an addition.** It is the most anyone can
reach, including long-service increases — **not** "base plus this much". Annual leave
rises by 1 day per year of service, and left blank it rises **for ever**: 20 years on
a base of 14 reaches 33 days. Set it to 21 and someone gets there after 7 years and
stays at 21.

**Nobody goes above the company maximum**, whatever their individual base. So the two
settings must not contradict each other, and the system refuses to let them:

- the maximum **cannot be saved below any employee's base** — it would cut them at the
  next grant. It names who is blocking it: *"can't be less than 20 — Amanda's base is
  20 days."* Lower that base first, or leave it blank.
- an employee's base **cannot be set above the maximum**, in Add employee, Edit, or
  the per-row box in the Employees list.

Setting the maximum equal to the base is allowed and meaningful: it means *annual
leave does not increase with service*.

> Blank is the existing behaviour, so nothing changes until you set a number.
> Setting one affects future grants, not leave already credited.

**Credit annual leave — all at once, or monthly.**

| Mode | What happens |
|---|---|
| **All at once (1 Jan)** | the whole year's entitlement lands on 1 January |
| **Monthly, as it is earned** | 1/12 each month |

Under monthly, someone who takes more than they have earned so far will show a
**negative balance**. That is correct, not a fault — they've used leave they haven't
accrued yet. The twelve instalments always add up to exactly the annual figure; a
mid-year joiner accrues from their joining month.

> **Don't switch mode part-way through a year** without checking the ledger. Each
> mode refuses to run while the other is active, so you can't double-credit by
> accident, but a year that's been part-credited one way needs reconciling by hand.

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

**People with no approver are approved — and cancelled — instantly.** Anyone whose
approver is blank (typically the Managing Director) has their leave auto-approved on
submit, and a cancellation confirmed on the spot, because there is nobody to route it
to. Nothing appears in anyone's Approvals inbox. If you ever see a cancellation
request sitting in your inbox marked as having no approver, confirm it yourself —
it means the routing found no one else.

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
