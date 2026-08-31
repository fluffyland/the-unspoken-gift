# LeaveDesk — HR Guide

For whoever runs LeaveDesk day to day: **HR Admin** or **Owner / Super Admin**.

Employees have their own, much shorter guide:
[`GUIDE_EMPLOYEE.md`](GUIDE_EMPLOYEE.md) — send them that, not this one.

---

## The four account types

Every person in LeaveDesk has exactly one **Account type**. You set it in
**HR Console → Employees & approval routes → Edit → Account type**.

It decides what someone is allowed to *do in the system*. It is not their job title —
that goes in **Occupation**. A Managing Director with nothing to administer can quite
correctly be an Employee.

The four are listed under the picker on the form itself, with the selected one highlighted,
so you do not need this page open to choose. You are only shown the types you can grant —
a plain HR Admin is not offered Owner.

| Account type | What they can do |
|---|---|
| **Employee** | Apply for their own leave. See their own balances, their own records, the shared calendar. Nothing about anybody else. |
| **Manager / Supervisor** | Everything an Employee can, plus they get an **Approvals** tab. |
| **HR Admin** | Everything above, plus the whole **HR Console**: add and edit staff, offboard, leave types, company settings, entitlements, start a new year, all records, all balances, all exports. |
| **Owner / Super Admin** | Everything an HR Admin can, plus the things HR deliberately cannot: create another Owner, and edit, offboard, delete or reset the password of an Owner. |

### The one thing people get wrong

**Approving is not granted by the account type. It is granted by the approval route.**

Somebody approves *Ahmad's* leave because they are set as **Ahmad's 1st level approver**
in Ahmad's record — not because their account type says Manager. Those are two separate
settings, and they do not talk to each other.

That has two consequences worth remembering:

- Give someone **Manager / Supervisor** and route nobody to them, and their Approvals
  tab is simply empty. The title alone approves nothing.
- Leave someone as **Employee** and name them as somebody's approver, and the
  Approvals tab appears for them anyway, with real leave to approve. This is correct
  and normal — a senior person who covers approvals while a manager is away does not
  need their account type changed.

So: **set the route first**. Change the account type only when you want to give
somebody the HR Console.

### Which one do I pick?

- Just does their job and takes leave → **Employee**
- Has people reporting to them → **Manager / Supervisor**, and set them as those
  people's 1st level approver
- Runs LeaveDesk day to day → **HR Admin**
- The business owner, and one trusted deputy → **Owner / Super Admin**

### Two rules about Owners

**Keep at least two Owners.** If the only Owner leaves or is locked out, nobody can
manage Owner accounts, and there is no way back in from inside the app.

**HR Admins cannot touch an Owner.** Not their record, not their password, not their
offboarding. That is deliberate — it is what stops an HR account from quietly taking
over the system. If you see *"Only the Owner / Super Admin can …"*, that is this rule,
working as intended.

One more, which applies to everybody including Owners: **nobody can change their own**
approvers, annual leave entitlement or account type. A 🔒 shows on your own row.
Someone else has to make that change for you.

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
| **Leave types** | leave categories and how many days each carries — **changing the days credits everyone the difference** |
| **Leave Application** | enter leave **for** an employee; approved on the spot |
| **Amendment records** | every manual change HR has made — entitlements, off-in-lieu, company-wide amendments |
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

**Annual Leave Entitled / Yr** is pre-filled from Company settings and can be changed. It
cannot exceed the company maximum, if you've set one.

The blue box at the foot of the form says exactly what will happen:

> You are crediting **18** days of AL to this employee. Other types of leave are will be
> added as standard amount

Saving does three things automatically: creates their profile, creates their login, and
credits that leave — **the whole figure you typed, not a part-year share of it**. If a
joiner should get less for their first part-year, work it out and type that number.

A popup shows the temporary password — **`Ssu123@`** by default. Pass it to
them and tell them to change it on first sign-in.

> **No popup?** The `create-login` function isn't deployed. See
> [`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) §1.6. Until then you'd be creating
> logins by hand in the Supabase dashboard.

**Existing employee with no login:** open their **Edit** → **Create login**.

### Teams / departments

**HR Console → Employees & approval routes → Teams / departments** — the list everyone
picks from. Add one, rename one, or **Delete** one.

Deleting asks first. A team that still has people in it **cannot** be deleted — you are
told how many members it has, and nothing is written. Move them to another team first,
then delete the empty one.

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

## Entering leave for an employee

**HR Console → Leave Application**

For the person who phoned in sick, or handed you a paper form. The tab opens with
**nobody chosen** — pick them from the list, and the leave form appears. Fill in the same
form they would, and submit.

- **Approved immediately** — you are HR; there is nobody to send it to.
- It appears in **their own My applications**, in **All records**, and on the **calendar**.
- The history shows **"Applied by HR on behalf"**, so nobody later mistakes it for
  something they submitted themselves.
- The employee list is the live one: add somebody and they are in it; offboard them and
  they are gone.

**It is literally the same form staff use**, so everything on the Leave types tab reaches
it: half-days, whether an MC is required, days per year, who is eligible. Change a setting
there and both forms follow it — there is no second copy to keep in step.

The balance rules are the same too. Not enough days, overlapping dates, or a missing MC
are refused for you exactly as they would be for them.

## Where the leave records live

Three books, deliberately separate:

| | What is in it | Where |
|---|---|---|
| **All records** | every leave application — by the employee, or by HR on their behalf | its own tab |
| **Amendment records** | every change HR made by hand: entitlements, off-in-lieu, company-wide leave amendments | its own tab |
| **Full ledger** | **every entry that makes up a balance** — yearly credits, joining credits, leave taken, refunds, off-in-lieu, expiry, forfeits and **offboarding settlements** | **Amendment records → Full ledger** |

A balance is always the sum of its entries. If a number looks wrong, the ledger is where
you find out why — it is the only screen that shows every line.

> This screen went missing for a while. It used to be the **Balance adjustments** tab, and
> when that tab became **Leave Application** the ledger went with it — the entries were
> still being written, and nothing displayed them. It is back, read-only, with search and
> an export.

## What happens to leave when someone leaves

**HR Console → Employees → Edit → Offboard.** Set the last working day and confirm — there
is no settlement choice to make. Whatever leave is left is written off on that day and kept
on record.

To see what someone had left, go to **Employees → Former employees** and click **Leave
left** beside their name:

> **Gone Person** — last working day 31/10/2026
> Annual Leave **7** · Off-in-Lieu **1.5** · Sick Leave **9** · **Total 17.5 days**

Those are the figures payroll needs, and there is an **Export CSV** on the Former employees
list for all leavers at once. The entries stay in the **Full ledger** permanently and the
person's history is kept.

### Once someone has left, their record is frozen

Offboarding settles the balance and that is the end of it. From that moment nothing touches
their leave again — no expiry, no company-wide credit, no adjustment, no off-in-lieu. The
record stays exactly as it was on their last working day.

This is enforced in the database itself, not just hidden on the screens, so it holds however
the change is attempted.

---

## Off-in-lieu

**HR Console → Employees → Edit → Credit Off-in-Lieu**

> Credit their off in lieu here. Their balance now: **1.5** days. Eg. If the employee
> entitled for 3 days, type 3 and it will credit 3 days OIL

Days and a reason, credited when you press **Save changes**. It is inside the employee's
own form because only some staff earn it — a company-wide box would invite crediting
everybody. **The reason is required** — the `*` appears beside the Reason box as soon as you type a
number of days, and nothing is demanded before that. A **negative** number takes days back
(type `-2` to remove two). Their balance updates
immediately and it is written to **Amendment records**.

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

### Changing how many days a leave type carries

**This is the one that used to do nothing.** Editing "Days / year" only affected the
*next* yearly credit — everyone already employed kept the old number, and nothing said so.

Now it **credits the difference to every eligible employee, immediately** — from the table
cell *and* from inside **Edit**, which was still doing a plain label change until v19:

> Hospitalisation Leave: 60 → **62** days per year.
> **+2 days** will be credited to **21 employees**.
> Days already taken are not affected — nobody is reset.

Somebody who has already used 5 days goes from 55 left to 57. Reducing the figure deducts
the same way, and says so first. Nothing is written until you confirm, and the whole thing
is recorded as **one** line in Amendment records — not twenty-one lines with names.

**Two types have no days box, on purpose.** **Annual Leave** is set per employee (Edit
employee → Annual Leave Entitled / Yr), and **Off-in-Lieu** is earned rather than granted.
Both boxes are greyed out and empty in the leave type's **Edit** form, and say where the
number really lives.

---

## Email notifications

**HR Console → Company settings → Email notifications**

LeaveDesk emails the people involved as leave moves along:

| When | Who hears about it |
|---|---|
| Someone applies | their approver, and the employee ("we have received it") |
| First of two approves | the second approver, and the employee ("one more to go") |
| Approved | the employee — **including how many days they have left** |
| Rejected · Returned | the employee |
| Withdrawn | the approver — nothing left for them to do |
| Cancellation asked for | the approver |
| Cancelled | the employee — days returned |
| You record leave for someone | that employee |

**Email never holds anything up.** If it is not set up, or the mail service is down, leave
and approvals carry on exactly as normal. The worst case is silence.

### While you are testing: hold everyone else back

**Only send notifications for** names one person. While it does, **only mail addressed to
them is sent** — nobody else in the company can receive anything by accident. Set it back to
**Everyone** when you are happy.

**Send test email** sends one sample to that person and tells you on screen whether it worked
or exactly what failed. It can only ever go to the person named in the dropdown, never to a
typed-in address.

Setting it up the first time is in
[`MIGRATION_GUIDE.md`](MIGRATION_GUIDE.md) — *Turning on leave-notification emails*.

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

### One application, one year

Leave cannot run across New Year. December days and January days are two applications,
because they come out of two different years' leave.

And **a year cannot be booked until you have started it.** In the first days of January,
before you press *Start a new year*, that year's leave does not exist yet — so applying for
it would spend last year's carry-forward without saying so. Staff see:

> *2027 leave has not been issued yet. HR starts the new year in the first days of January —
> you can apply for 2027 leave once they have.*

Press the button and the year opens for everyone.

## Staff who work Saturdays

**It is set per person, and only per person.**

**HR Console → Employees & approval routes → Edit** → **Required to work on Saturday**
→ **Yes** or **No**. It is a required answer, so every record states it outright.

There used to be a tick for a whole team as well. It has been removed: because every
employee now carries their own Yes/No, and their own answer always won, the team tick
reached nobody. Set it on the person.

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
to be standing on next year first. A year with nothing in it simply says so, and stays on
the list permanently once it has its first date.

**The 🔍 box beside the arrows goes straight to a year.** Type `2029` and the table below
switches to 2029 as you finish the fourth digit — no button to press. It shows the year you
are currently on, greyed out, until you type over it.

**Adding one date:** type it as **DD/MM/YYYY** — e.g. `15/07/2026` — give it a name, and
press **+ Add holiday**. Slashes, dashes and dots all work. **✎** edits a date, **✕**
removes one.

**Adding a whole year at once:** press **➕ Add whole year holiday**. When it finishes,
the table below is already showing the year you just added, so you can check it straight
away.

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
> Supabase → SQL Editor, from before the paste box existed. **➕ Add whole year holiday** does the
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

## Annual leave: the number you type

**HR Console → Employees → Edit → Annual Leave Entitled / Yr**

> This is the total AL the employee entitle. It will direct credit AL to this employee once
> saved. (Eg. If employee gain extra 1 Day AL change it from 14 to 15. System will change
> their total AL to 15)

Whatever you type **is** that person's annual leave for this year. Nothing is added for
years of service and nothing is pro-rated — if a new joiner should get 6 days for their
first part-year, type 6, then type their full figure next January.

Saving makes this year's entitlement *equal* that number. It writes the one correcting
line needed to get there, so the figure on screen and the figure in the database cannot
disagree. The box under the field shows the arithmetic before you save:

> Alice Tan — 14 → 15 days.
> Entitled this year: 15 days
> Already taken: 3 days
> Carried forward: 2 days
> Remaining: 14 days

**Days already taken are never disturbed.** Raising 14 to 15 gives one more day; it does
not reset anybody to 15.

**Your company maximum caps the number you type** — set it to 21 and the field refuses 25,
saying why. That applies on both routes: this form and the company-wide box below. (The
column on the Employees table is gone — one place to set it, not two.)

**If the figure on file and this year's balance ever disagree** — someone added before the
pro-rating was removed, say, showing 14 but only ever credited 6 — the box tells you so and
**pressing Save fixes it**, even though the number itself has not changed:

> **6 → 14 days.** Entitled this year: 14 · Already taken: 1 · Remaining: 13

Every change is written to **Amendment records**, never applied silently.

> **This changed twice.** Before v18 the field was called "Annual leave base" and the
> system quietly added **1 day per year of service** on top — somebody showing 14 was
> getting 20, and no screen connected the two. v18 removed that. v19 then made the number
> a *total* rather than a starting point, because v18 still only wrote a correction when it
> recognised the exact wording of a ledger line — so for anyone added through the app it
> changed the label and credited nobody, while the screen said it had.

### One more day for everybody

**HR Console → Leave types → Annual Leave → Edit → Credit annual leave to everyone**

Type the days and press **Save changes** — everything on that form is applied by Save
changes, so there is no second button competing with it. The box starts at **0**, so saving
the form never credits anybody unless you meant to.

Everyone's **Annual Leave Entitled / Yr** moves by that much **permanently** — next January
they get the new figure automatically — and the same days reach this year's total.

The box always shows a sign, so you can see at a glance which way it is going: `+1` credits,
`-1` takes back, `0` does nothing. Use the **▲▼** buttons beside it, or type the figure
yourself — **type a minus to take days back**, e.g. `-1`, if you credited by mistake.

The confirmation is titled **Crediting Annual leave** or **Deducting Annual leave** so
there is no doubt which one you are about to do.

You are told how many people it reaches before it happens. Anyone who would go over your
company maximum, or below zero, is **skipped and named**, not silently capped. It is
recorded as one company-wide line in **Amendment records**, not one line per person.

## Carry-forward, expiry, and what resets each year

### How many days each person may carry

**Per employee, not per company** — different people carry different amounts.

**HR Console → Employees → Edit → Carry Forward AL Maximum Day**, next to the entitlement.
(It used to be a column on the Employees table; that pushed the **Edit** button off the
side of the screen, so it lives in the form instead.)

Anything above that person's figure is **forfeited** when you start the new year, and you
see exactly who loses what before it happens.

**Company settings → Defaults for new employees → Default Carry Forward AL Maximum Day** sets the
starting figure for *someone new*. As that card says, changing it moves nobody already in
the system.

### When carried days expire

**Company settings → Leave policy → Carry Forward AL expiry date**, company-wide. Pick a
**month and a day** — set **31 December** and carried leave must be used by 31 December.

**It repeats every year on its own.** Set it once and you never touch it again: leave
carried into 2027 expires 31 Dec 2027, into 2028 expires 31 Dec 2028, and so on. There is
nothing to update each January.

Set the Month to **— Never expires —** and carried days keep forever. The Day picker
follows the Month, so a date that does not exist cannot be picked.

> ⚠️ **Changing it moves leave people are already holding.** That is on purpose — what you
> set is what everyone sees. It asks first, and tells you exactly how many employees are
> affected and, if the new date has already passed, **how many days expire the moment you
> agree**. Nothing is written until you press **Save changes** in that dialog. Days that
> were already written off under an earlier date stay written off — moving the date later
> does not bring them back.

Two things happen automatically, and neither needs you:

- **Carried days are used first.** Nothing you have to set, and leave someone has already
  taken is never taken back off them — only the unused remainder expires.
- **They stop counting on the date itself**, not when somebody presses a button. Staff
  cannot book August leave with days that died in June.

### What resets each year, and what doesn't

| | |
|---|---|
| **Resets to its yearly figure** | Sick, Hospitalisation, Childcare, Maternity, Paternity, Shared Parental, Adoption, Unpaid Infant Care, Compassionate, Marriage |
| **Carries forward** | Annual Leave, up to each person's maximum |
| **Never touched** | Off-in-Lieu — those days were earned by working overtime |

Resetting means exactly what you'd expect: sick leave is 14 a year, so 2 days left over
does **not** become 16 next year — it goes back to 14. The figure credited is whatever you
have set as **Days per year** on the **Leave types** tab. Change Childcare from 6 to 8
there and the next reset lands on 8; nothing is hard-coded.

> **Before `migration_app_v16.sql` this did not happen at all** — every type simply
> accumulated, year on year, because nothing had ever cleared the old one. If your Company
> settings tab still shows a warning saying so, run that migration.

## Start a new year

**HR Console → Company settings → Start a new year**

This is the one button you press each January. Everything below explains it from
scratch — no jargon, one step at a time. There is a picture of it further down.

### What it is for, in one sentence

Last year is finished, so LeaveDesk has to close it off and open the new one:
carry over the annual leave people are allowed to keep, throw away the rest,
clear the leave types that start fresh, and hand everybody their new allowance.

### Before you press it

Two things, both in **Company settings**, decide what happens:

- **Carry Forward AL Maximum Day** — the most annual leave one person may keep.
  There is a company default, and each employee can have their own in **Edit employee**.
  Somebody with `5` keeps at most 5 days, however many they have left.
- **Carry Forward AL expiry date** — the day the kept days die.
  Set **30 June** and they must be used by 30 June, or they are gone. It repeats every
  year. **— Never expires —** means they never expire.

Also make sure last year's leave is finished: nothing still sitting on **Pending**.

**LeaveDesk now enforces this.** If any application dated in the closing year is still
pending — or waiting on a cancellation — Start a new year **refuses to run** and lists them:

> ⚠ **3 applications are still waiting.** All dated in 2026. Approve, reject or cancel them
> before starting 2027 — otherwise those days count as unused and the people lose them.

That is not fussiness. Leave still awaiting approval does not come off the balance yet, so
the year start treats those days as unused and carries or forfeits them — and then deducts
them a second time when the approver finally says yes. The employee quietly ends up short.

### What it does to one person, step by step

Take **Siti**. She is entitled to 14 days a year, her maximum carry forward is 5,
and the expiry date is set to 30 June. During 2026 she took 6 days.

| Step | What LeaveDesk does | Siti |
|---|---|---|
| **1** | Look at anything carried into last year that has already passed its expiry date, and write those dead days off. | Nothing carried into 2026, so nothing happens. |
| **2** | Work out what she has left of last year's annual leave. | 14 entitled − 6 taken = **8 days left**. |
| **3** | Compare that with her maximum. Whatever fits, **carries forward**. | Her maximum is 5, so **5 days carry into 2027**. |
| **4** | Whatever does not fit is **forfeited** — written off, not paid out. | 8 − 5 = **3 days forfeited**. |
| **5** | Stamp the expiry date on the days that carried. | The date is set to 30 June → **use by 30 June 2027**. |
| **6** | Every other leave type that starts fresh each year (sick, hospitalisation, and so on) is cleared to zero, whatever was left in it. | Her 9 unused sick days are written off. |
| **7** | Write one permanent line into **Past runs** saying exactly all of the above, with her name on it. | Done — readable in 2030. |
| **8** | Once everybody has been through steps 1–7, hand out the new year's allowances. | Siti is credited **14 days for 2027**, on top of the 5 she carried. |

So on 2 January Siti opens LeaveDesk and sees **19 days**: 14 new, plus 5 carried
that she must use by 30 June. Her 3 forfeited days and her leftover sick leave
are gone, and both are written down in Past runs.

> **Why step 8 is last.** If the new allowance were credited first, step 6 would
> clear it away again the moment it arrived. The order is not optional.

Two smaller points, so nothing surprises you:

- Annual leave sits in **one pot**. If Siti had carried 2 days into 2026 and still
  had them, step 2 would count them too — there is no separate bucket. Days that
  had already passed their expiry date were taken out in step 1, so they cannot carry twice.
- **Nothing is pro-rated.** Whatever is typed in *Annual Leave Entitled / Yr* is what that
  person gets, joiner or not. If a new starter should get 6 days for their first part-year,
  type 6, then type their full figure next January. (An earlier version of this page said
  joiners were pro-rated automatically. That was wrong — see *Annual leave: the number you
  type* above, which has always had it right.)

### The same thing as a picture

Open [`year-start-flowchart.html`](year-start-flowchart.html) in a browser —
double-click the file, no internet needed.

### Preview: seeing it before it is real

**Nothing is written until you confirm.** Pressing the button first shows you a
preview: every employee, one row each — annual leave taken last year, what was
left, their own maximum, what carries, **what they forfeit** (in red), and what
expires. **⬇ Export CSV** if payroll wants the forfeited figures.

Preview works out every single number the real run would, and writes **nothing**.
Read it, close it, change somebody's maximum in **Edit employee**, press it again.
You can do that as many times as you like. Only the confirmation writes.

### What if you press it twice?

**Nothing happens twice.** It is safe.

The moment the real run finishes with a person, it writes their name into the log
for that year (step 7). Press it again and it reaches that name, sees it is already
there, and skips straight past them. Press **Start 2026** again today and it will
report **0 employees processed** — no leave carried, none forfeited, none cleared,
nothing credited.

This also means it is safe if it stops halfway — a laptop closing, the internet
dropping. Press it again and it picks up exactly where it left off, finishing the
people it never reached and leaving everyone else alone.

### What it never touches

- **Off-in-lieu.** Never cleared, never expired, never credited by the year start.
  It is earned day by day, so it stays until it is used.
- **Anyone who has left.** Offboarded employees are skipped entirely.
- **Leave already taken.** Days used last year stay used. Nothing is refunded.
- **Leave types you have set not to reset yearly.** Those keep their balance.
- **The past.** Last year's records, applications and approvals are never altered.

### A form for last year turns up after you have closed it

It happens: someone hands you a December form in January. LeaveDesk now handles it
properly, because the carry-forward was worked out from what was left at the end of that
year — so adding leave to it has to put the carry-forward right too.

**Staff cannot do this themselves.** If an employee tries to apply for a date in a closed
year they are refused and told to hand the form to you:

> *2026 has been closed off. Leave dated in 2026 can no longer be applied for here — that
> year was finalised when the new year was started. Hand your form to HR and they can
> record it for you.*

**You can.** HR Console → Leave Application, enter it as normal with the real dates. Before
anything is written, you are shown exactly what it does:

> **Record leave in 2026?**
> **Siti** — 5 days dated in **2026**, a year that has already been closed off.
> 2026 taken goes from **6** to **11** days.
> **3 forfeited days come back** — those days were being thrown away anyway.
> Carry Forward drops from **5** to **3** days, so the right amount expires later.
> Past runs keeps what it recorded in January — this is written as a correction beside it.

Both numbers end up right: the days she should never have lost come back, and her
Carry Forward figure drops to what it should always have been, so the expiry later writes
off the right amount.

**Two things it will refuse**, because the sums could not be trusted:

- **Anything older than last year.** Unpicking two years of carry-forward is guesswork.
  Adjust that person's **Annual Leave Entitled / Yr** in Edit employee instead.
- **A carry-forward that has already expired.** Days written off cannot be un-written.
  Same advice.

Nothing overwrites **Past runs** — January's record stays exactly as January wrote it, and
the correction sits beside it in **Amendment records**.

### 📋 Past runs

The permanent record — one row per employee per year, kept forever and never overwritten.
Pick any past year, read the whole table, export it. "What happened at the end of 2027?"
is answerable in 2030 without touching SQL.

Normally you do this in the first week of January — see
[`YEARLY_CHECKLIST.md`](YEARLY_CHECKLIST.md).

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
