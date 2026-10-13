-- ============================================================================
-- explain_balances.sql — WHY a number on the Balances tab is what it is.
--
-- Read-only. It creates nothing, changes nothing, deletes nothing, and can be
-- run any number of times. Paste the whole file into the Supabase SQL Editor
-- and press Run. One table of plain lines comes back — copy all of it back to
-- me and the answer is arithmetic instead of a guess.
--
-- It is written as ONE query on purpose: the SQL Editor only shows you the
-- result of the last statement, so a file made of five separate SELECTs would
-- quietly throw four of them away.
--
-- The one rule everything here rests on:
--
--     available = entitled this year + carried forward - taken - forfeited - pending
--
-- Where a person's "shown" differs from that, days are being counted that do
-- not belong to this year, and section C lists the exact rows they come from.
-- ============================================================================

with
y as (select extract(year from current_date)::int as yr),

-- Everything each person holds, split by which year and which kind of row it is.
sums as (
  select l.emp_id, l.leave_type,
         sum(l.delta_days)                                                                as alltime,
         coalesce(sum(l.delta_days) filter (where l.leave_year = (select yr from y)
                                              and l.kind in ('grant','adjust')), 0)       as entitled,
         coalesce(sum(l.delta_days) filter (where l.leave_year = (select yr from y)
                                              and l.kind = 'carry_in'), 0)                as carried,
         coalesce(-sum(l.delta_days) filter (where l.leave_year = (select yr from y)
                                              and l.kind in ('taken','refund')), 0)       as taken,
         coalesce(-sum(l.delta_days) filter (where l.leave_year = (select yr from y)
                                              and l.kind = 'writeoff'), 0)                as forfeited,
         coalesce(sum(l.delta_days) filter (where l.leave_year is distinct from (select yr from y)), 0)
                                                                                          as other_years,
         count(*) filter (where l.leave_year is null or l.kind is null)                   as untagged
    from leave_ledger l
   group by l.emp_id, l.leave_type
),
rows_ as (
  select e.name as emp, t.name_en as ltype, t.code, t.sort, t.default_days,
         s.entitled, s.carried, s.taken, s.forfeited, s.other_years, s.untagged,
         coalesce(b.pending, 0)   as pending,
         coalesce(b.available, 0) as shown,
         s.entitled + s.carried - s.taken - s.forfeited - coalesce(b.pending, 0) as should_be
    from sums s
    join employees   e on e.id   = s.emp_id
    join leave_types t on t.code = s.leave_type
    left join leave_balances b on b.emp_id = s.emp_id and b.leave_type = s.leave_type
   where e.active and not t.no_deduct
),
-- One line per finding, formatted so the columns line up when pasted back.
report as (

  select 0 as ord, 0 as sub, 'LEAVE YEAR ' || (select yr from y)
         || '   ·   report run ' || to_char(current_date, 'DD Mon YYYY') as line
  union all select 0, 1, ''

  ----------------------------------------------------------------- A
  union all select 1, 0, '=== A. where the number on screen is NOT this year''s arithmetic ==='
  union all select 1, 1, rpad('EMPLOYEE', 22) || rpad('LEAVE TYPE', 24)
                      || lpad('ENT', 6) || lpad('CARRY', 7) || lpad('TAKEN', 7)
                      || lpad('FORFT', 7) || lpad('PEND', 6)
                      || lpad('SHOULD', 8) || lpad('SHOWN', 8) || lpad('GAP', 7)
  union all
  select 1, 2, rpad(left(r.emp, 21), 22) || rpad(left(r.ltype, 23), 24)
             || lpad(trim_scale(r.entitled)::text,  6) || lpad(trim_scale(r.carried)::text, 7)
             || lpad(trim_scale(r.taken)::text,     7) || lpad(trim_scale(r.forfeited)::text, 7)
             || lpad(trim_scale(r.pending)::text,   6)
             || lpad(trim_scale(r.should_be)::text, 8) || lpad(trim_scale(r.shown)::text, 8)
             || lpad(trim_scale(r.shown - r.should_be)::text, 7)
    from rows_ r where r.shown <> r.should_be
  union all
  select 1, 3, '(none — every balance on screen is exactly this year''s arithmetic)'
   where not exists (select 1 from rows_ r where r.shown <> r.should_be)
  union all select 1, 9, ''

  ----------------------------------------------------------------- B
  union all select 2, 0, '=== B. where the entitlement does NOT match what the Leave type is set to ==='
  union all select 2, 1, '    (annual leave and off-in-lieu are excluded: those two are set per employee,'
  union all select 2, 2, '     not on the Leave types tab, so they are SUPPOSED to differ)'
  union all select 2, 3, rpad('EMPLOYEE', 22) || rpad('LEAVE TYPE', 24)
                      || lpad('TYPE SAYS', 11) || lpad('THEY HAVE', 11) || lpad('DIFF', 7)
  union all
  select 2, 4, rpad(left(r.emp, 21), 22) || rpad(left(r.ltype, 23), 24)
             || lpad(trim_scale(r.default_days)::text, 11)
             || lpad(trim_scale(r.entitled)::text, 11)
             || lpad(trim_scale(r.entitled - r.default_days)::text, 7)
    from rows_ r where r.code not in ('annual', 'oil') and r.entitled <> r.default_days
  union all
  -- A person with NO ledger row at all for an eligible type does not appear above:
  -- there is nothing to compare. Their figures agree with each other and are still
  -- wrong, which is the one fault a self-consistency check can never see.
  select 2, 5, rpad(left(e.name, 21), 22) || rpad(left(t.name_en, 23), 24)
             || lpad(trim_scale(t.default_days)::text, 11) || lpad('NOTHING', 11) || lpad('—', 7)
    from employees e cross join leave_types t
   where e.active and not t.no_deduct and t.code not in ('annual', 'oil')
     and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
     and not exists (select 1 from leave_ledger l
                      where l.emp_id = e.id and l.leave_type = t.code
                        and l.leave_year = (select yr from y) and l.kind in ('grant','adjust'))
  union all
  select 2, 6, '(none — everybody holds exactly what the Leave types tab says)'
   where not exists (select 1 from rows_ r where r.code not in ('annual','oil') and r.entitled <> r.default_days)
     and not exists (
       select 1 from employees e cross join leave_types t
        where e.active and not t.no_deduct and t.code not in ('annual', 'oil')
          and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
          and not exists (select 1 from leave_ledger l
                           where l.emp_id = e.id and l.leave_type = t.code
                             and l.leave_year = (select yr from y) and l.kind in ('grant','adjust')))
  union all select 2, 9, ''

  ----------------------------------------------------------------- C
  union all select 3, 0, '=== C. every ledger row that is NOT this year, or has no year tag ==='
  union all select 3, 1, '    (these rows are the source of every gap in section A)'
  union all
  select 3, 2, rpad(left(e.name, 21), 22) || rpad(left(t.name_en, 23), 24)
             || rpad(coalesce(l.leave_year::text, 'NO YEAR'), 9)
             || rpad(coalesce(l.kind, 'NO KIND'), 10)
             || lpad(trim_scale(l.delta_days)::text, 7) || '  '
             || to_char(l.created_at, 'DD Mon YYYY') || '  ' || l.reason
    from leave_ledger l
    join employees   e on e.id   = l.emp_id
    join leave_types t on t.code = l.leave_type
   where e.active
     and (l.leave_year is distinct from (select yr from y) or l.kind is null)
  union all
  select 3, 3, '(none — every row belongs to this year and is tagged)'
   where not exists (
     select 1 from leave_ledger l join employees e on e.id = l.emp_id
      where e.active and (l.leave_year is distinct from (select yr from y) or l.kind is null))
  union all select 3, 9, ''

  ----------------------------------------------------------------- D
  union all select 4, 0, '=== D. annual leave: one line per person, whether it adds up or not ==='
  union all select 4, 1, rpad('EMPLOYEE', 22)
                      || lpad('ENT', 6) || lpad('CARRY', 7) || lpad('TAKEN', 7)
                      || lpad('FORFT', 7) || lpad('PEND', 6)
                      || lpad('SHOULD', 8) || lpad('SHOWN', 8)
  union all
  select 4, 2, rpad(left(r.emp, 21), 22)
             || lpad(trim_scale(r.entitled)::text,  6) || lpad(trim_scale(r.carried)::text, 7)
             || lpad(trim_scale(r.taken)::text,     7) || lpad(trim_scale(r.forfeited)::text, 7)
             || lpad(trim_scale(r.pending)::text,   6)
             || lpad(trim_scale(r.should_be)::text, 8) || lpad(trim_scale(r.shown)::text, 8)
    from rows_ r where r.code = 'annual'
  union all select 4, 9, ''

  ----------------------------------------------------------------- E
  union all select 5, 0, '=== E. carry-forward has two halves — do they agree? ==='
  union all select 5, 1, rpad('EMPLOYEE', 22) || lpad('CARRY ROW', 11) || lpad('LEDGER', 9)
                      || lpad('WITHHELD', 10) || '  ' || rpad('EXPIRES', 14) || 'STATUS'
  union all
  select 5, 2, rpad(left(e.name, 21), 22)
             || lpad(trim_scale(ac.carry_in)::text, 11)
             || lpad(trim_scale(coalesce((select sum(l.delta_days) from leave_ledger l
                                           where l.emp_id = ac.emp_id and l.leave_type = 'annual'
                                             and l.kind = 'carry_in' and l.leave_year = ac.year), 0))::text, 9)
             || lpad(trim_scale(due_unwritten_carry(ac.emp_id, 'annual'))::text, 10) || '  '
             || rpad(coalesce(to_char(ac.expires_on, 'DD Mon YYYY'), 'never'), 14)
             || case when ac.expired_at is not null then 'already written off'
                     when ac.expires_on < current_date then 'PAST — days already withheld'
                     else 'still valid' end
    from annual_carry ac join employees e on e.id = ac.emp_id
   where e.active and ac.year = (select yr from y)
  union all
  select 5, 3, '(no carry-forward records for this year)'
   where not exists (select 1 from annual_carry ac join employees e on e.id = ac.emp_id
                      where e.active and ac.year = (select yr from y))
  union all select 5, 9, ''

  ----------------------------------------------------------------- F
  union all select 6, 0, '=== F. the settings these numbers are measured against ==='
  union all
  select 6, 1, rpad(left(t.name_en, 30), 32) || lpad(trim_scale(t.default_days)::text, 6)
             || ' days/yr   ' || rpad(coalesce(t.gender_eligibility, 'everyone'), 10)
             || case when t.no_deduct then 'record only' else '' end
    from leave_types t
  union all select 6, 8, ''
  union all
  select 6, 9, case when o.carry_expiry_month is null
                    then 'Carry-forward annual leave: never expires'
                    else 'Carry-forward annual leave expires '
                         || to_char(make_date(2000, o.carry_expiry_month, o.carry_expiry_day), 'DD Mon')
                         || ' every year' end
    from org_settings o where o.id = 1
  union all
  select 6, 10, case when o.oil_expiry_month is null
                     then 'Off-in-lieu: never expires'
                     else 'Off-in-lieu expires '
                          || to_char(make_date(2000, o.oil_expiry_month, o.oil_expiry_day), 'DD Mon')
                          || ' every year — the whole balance held on that day' end
    from org_settings o where o.id = 1
)
select line as "copy this whole column back to me"
  from report
 order by ord, sub, line;
