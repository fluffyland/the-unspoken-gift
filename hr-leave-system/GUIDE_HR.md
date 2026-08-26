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
| **All records** | every application, searchable, with remarks; exports to CSV |
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

**Someone who isn't on your domain** — a contractor, a part-timer with only a personal
address — can't be typed straight into the Add form, because the domain is locked on
purpose. Add them on the company domain, save, then open their profile and change the
email there: **Edit** keeps the full address box. It's two steps instead of one, and it's
the price of the lock.

**Four fields start on "— Select —" and must be chosen.** They used to arrive
pre-filled, which meant clicking through filed someone silently:

| Field | Why it isn't guessed for you |
|---|---|
| **Team / department** | drives who approves their leave |
| **Gender** | decides which leave types they're offered — maternity vs paternity |
| **Account type** | decides what they can see and do |
| **Required to work on Saturday** | changes what their leave costs: Mon–Sat is 6 days, not 5 |

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
**Required to work on Saturday** for a team, and Saturday becomes a normal working day
for everyone in it.

**Per person:** their Edit form → **Required to work on Saturday** → **Yes** or **No**. This is now
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

**You keep this list yourself.** There is no automatic updater — LeaveDesk had one, it
never once worked, and in August 2026 it was removed rather than left sitting there
looking automatic. Nothing about the leave maths changed: these dates are still excluded
from every leave calculation and still shown on the company calendar. The only difference
is that somebody has to type them in, and now it says so.

> **Holiday changes save immediately.** They are **not** part of **Save changes**, and
> **Discard** will not bring a removed date back. Everything else on the Company settings,
> Employees and Leave types tabs waits for Save changes; this list does not, because a list
> of dates is not a form. Delete carefully — a removed date is gone the moment you press ✕.

**One year at a time.** The heading shows the year you're looking at, with **◀** and **▶**
either side of it — ◀ earlier, ▶ later, the same as the Calendar tab. The count in the
heading always describes the rows underneath it, so 2026 and 2027 can never be mixed
together in one list.

**Every year is reachable, empty or not.** The arrows keep going — 2028, 2029, 2035 — even
before a single date exists for that year. That matters: to enter next year's dates you have
to be standing on next year first. **➕ Add year** jumps straight to any year between 2000
and 2100 without clicking ▶ ten times. A year with nothing in it simply says so, and stays
on the list permanently once it has its first date.

**Adding one date:** type it as **DD/MM/YYYY** — e.g. `15/07/2026` — give it a name, and
press **+ Add holiday**. Slashes, dashes and dots all work. **✎** edits a date, **✕**
removes one.

**Adding a whole year at once:** press **➕ Add a whole year**.

**Paste MOM's table straight in.** Select the holidays table on MOM's page, copy, paste.
The extra columns, the header row and the footnote about in-lieu days are all handled — you
do not have to tidy anything up first:

```
Date              Day        Holiday          Holiday
1 January 2027    Friday     New Year         New Year's Day
6 February 2027
7 February 2027   Saturday
Sunday            Chinese New Year             Chinese New Year
Monday, 8 February 2027, will be a public holiday if your rest day falls on 7 February 2027.
10 March 2027     Wednesday  Hari Raya Puasa  Hari Raya Puasa
```

That paste produces exactly four dates, correctly named — including both days of Chinese
New Year, whose date and name cells land on different lines when copied.

> **The in-lieu sentence is deliberately ignored.** "Monday, 8 February 2027, will be a
> public holiday if your rest day falls on 7 February 2027" is *conditional* — it applies
> only to staff whose rest day is that Sunday, so it is not gazetted for everyone and must
> not go on a company-wide list automatically. If it applies to your staff, add it yourself
> with **+ Add holiday**.

Or type them yourself, one per line — a date, a space, then the name:

```
01/01/2027  New Year's Day
06/02/2027  Chinese New Year
1 January 2028  New Year's Day
```

Dates can be `01/01/2027`, `2027-01-01` or `1 January 2027`. Before anything is saved you
see exactly what will be added, which dates are **already on the list** (those are skipped,
never overwritten), any date that arrived **without a name**, and any lines it **couldn't
read** — all shown to you rather than quietly dropped. Then **Add N dates**, or **Cancel**
and nothing happens.

**It tells you when next year is missing.** From September onwards, if next year has fewer
than 11 dates, a warning appears on this card and a ⚠️ appears on the **Company settings**
tab. It stays quiet before September because MOM usually publishes the following year around
April, and a warning that shows all year is a warning people learn to ignore.

**Where to get the dates:** MOM publishes them at
**https://www.mom.gov.sg/employment-practices/public-holidays**.

**Why a year shows more than 11 dates.** Singapore gazettes **11 public holidays a year**.
When one falls on a Sunday, the following Monday is a public holiday too and appears as its
own row — so a full year normally lists **11 to 15 dates**. 2026 has 14: eleven holidays
plus three observed Mondays.

**Both rows belong in the list**, and the count is correct as it stands. The Monday is the
actual day off, so it must be there or staff lose a day. The Sunday costs nothing, because
Sunday was never a working day. The heading counts **dates on the list**, not days off —
fewer than 11 means the year is incomplete.

> There is also [`supabase/insert_holidays_2027.sql`](supabase/insert_holidays_2027.sql) for
> Supabase → SQL Editor, from before the paste box existed. **➕ Add a whole year** does the
> same thing without leaving LeaveDesk; use that instead.

> **Do this every January**, for the year ahead. Nothing else will do it, and nothing will
> remind you — see [`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md).

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

The **Remarks** column shows the reason the employee typed, so you can scan a page of
requests without opening each one. Long ones are shortened with `…` — hover to read the
whole thing, or click the row for the full record. The same column appears on the
approver's team view, and the full text has always been in the CSV export.

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
