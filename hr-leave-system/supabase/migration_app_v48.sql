-- ============================================================================
-- v48 — an account created by the Supabase trigger is an ordinary employee.
--
-- Reported: "for the account that created via supabase i found there is some bug,
-- the annual leave unable to credited in ... please make it follow the format
-- exactly as employee created via leave desk system. dont make it difference."
--
-- Two faults, one symptom.
--
-- 1. claim_pending_owner (v43) inserted the employees row and stopped there.
--    Add employee in the app writes a joining allowance for EVERY eligible leave
--    type. So the Owner began life holding nothing at all, while anybody added
--    through the app began life with 14 / 14 / 60 / 6 / ... That is the "different"
--    the user is seeing, and the balance of 0 is the consequence.
--
-- 2. set_annual_entitlement refused to credit anyone who had no annual allowance
--    yet this year: it updated annual_base, wrote an Amendment record, and
--    returned 0. The reasoning was "the year-start grant will use the new number" --
--    true for a company that runs a year start, useless for an account that will
--    never be picked up by one. So HR typed 14, saw an Amendment record appear, and
--    the balance stayed empty. Typing a number has to credit that number.
-- ============================================================================

-- ---------- 1. the same joining credits the app writes ----------------------
create or replace function credit_joining_allowances(p_emp uuid)
returns int language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; t record; amt numeric; n int := 0;
        y int := extract(year from current_date)::int;
begin
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if not e.active then return 0; end if;

  for t in select * from leave_types
            where not no_deduct
              and (gender_eligibility is null or gender_eligibility = e.gender)
            order by sort
  loop
    -- Annual leave is the figure on the person's own record; everything else is the
    -- company figure from the Leave types tab. Exactly what Add employee does.
    amt := case when t.code = 'annual' then e.annual_base else t.default_days end;
    if coalesce(amt, 0) <= 0 then continue; end if;      -- off-in-lieu is earned, not granted
    -- Never a second allowance for the same year. ux_ledger_one_grant would refuse it
    -- anyway; checking first means this can be called again without raising.
    if exists (select 1 from leave_ledger
                where emp_id = p_emp and leave_type = t.code
                  and leave_year = y and kind = 'grant') then continue; end if;
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
    values (p_emp, t.code, amt,
            case when t.code = 'annual' then 'Annual leave allowance on joining'
                 else 'Leave allowance on joining' end,
            nullif(current_emp_id(), p_emp), y, 'grant');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function credit_joining_allowances(uuid) from anon, public;
grant  execute on function credit_joining_allowances(uuid) to authenticated;

-- ---------- 2. the trigger path now does it too -----------------------------
create or replace function claim_pending_owner(p_auth_user uuid, p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare want text; who text; n int; new_id uuid;
begin
  if p_auth_user is null or coalesce(trim(p_email), '') = '' then return 'no email'; end if;

  update employees set auth_user_id = p_auth_user
   where lower(email) = lower(trim(p_email)) and auth_user_id is distinct from p_auth_user;
  get diagnostics n = row_count;
  if n > 0 then return 'relinked existing employee'; end if;
  if exists (select 1 from employees where lower(email) = lower(trim(p_email)))
    then return 'already linked'; end if;

  select nullif(trim(pending_owner_email), ''), coalesce(nullif(trim(pending_owner_name), ''), 'Owner')
    into want, who from org_settings where id = 1;
  if want is null then return 'no owner pending'; end if;
  if lower(want) <> lower(trim(p_email)) then return 'not the pending owner'; end if;

  insert into employees (name, email, join_date, role, active, auth_user_id, dept)
  values (who, lower(trim(p_email)), current_date, 'admin', true, p_auth_user,
          (select name from departments order by name limit 1))
  returning id into new_id;
  -- The piece that was missing: start them off like anybody added through the app.
  perform credit_joining_allowances(new_id);
  update org_settings set pending_owner_email = null where id = 1;
  return 'owner created';
end $$;
revoke execute on function claim_pending_owner(uuid, text) from anon, authenticated, public;

-- ---------- 3. typing a number credits that number --------------------------
create or replace function set_annual_entitlement(p_emp uuid, p_days numeric)
returns numeric language plpgsql security definer set search_path = public as $$
declare e employees%rowtype; cap numeric; before_days numeric; ent numeric; adj numeric;
        y int := extract(year from current_date)::int; had boolean;
begin
  if not is_hr() and session_user <> 'postgres' then raise exception 'Only HR can change an entitlement'; end if;
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'Employee not found'; end if;
  if p_days is null or p_days < 0 then raise exception 'Annual leave cannot be negative'; end if;
  cap := (select annual_cap from org_settings where id = 1);
  if cap is not null and p_days > cap then
    raise exception 'Annual leave cannot be more than the company maximum of % days', fmt_days(cap);
  end if;

  before_days := e.annual_base;
  update employees set annual_base = p_days where id = p_emp;

  had := exists (select 1 from leave_ledger
                  where emp_id = p_emp and leave_type = 'annual'
                    and leave_year = y and kind in ('grant', 'adjust'));

  if not had then
    -- This used to credit nothing and return 0, on the reasoning that the year-start
    -- grant would use the new number. An account the year start never reaches -- the
    -- Owner created by the Supabase trigger -- therefore stayed on zero no matter what
    -- HR typed, while an Amendment record said the entitlement had been set. Write the
    -- allowance, as a grant, so the yearly run recognises it and cannot double it.
    if p_days > 0 then
      insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
      values (p_emp, 'annual', p_days, y || ' annual allowance', current_emp_id(), y, 'grant');
    end if;
    perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, p_days, 1, '');
    return p_days;
  end if;

  ent := annual_entitled_in_year(p_emp, y);
  adj := p_days - ent;
  if adj <> 0 then
    insert into leave_ledger (emp_id, leave_type, delta_days, reason, created_by, leave_year, kind)
    values (p_emp, 'annual', adj,
            y || ' annual entitlement set to ' || fmt_days(p_days), current_emp_id(), y, 'adjust');
  end if;
  perform log_amendment(p_emp, e.name, 'annual', 'entitlement', before_days, p_days, adj, 1, '');
  return adj;
end $$;
revoke execute on function set_annual_entitlement(uuid, numeric) from anon, public;
grant  execute on function set_annual_entitlement(uuid, numeric) to authenticated;

-- ---------- 4. repair the account that is already in this state -------------
-- Anybody active holding no allowance at all for the current year gets the same
-- start as everybody else. In practice: the Owner the trigger created.
do $$
declare r record; n int := 0; total int := 0;
begin
  for r in select e.id, e.name from employees e
            where e.active
              and not exists (select 1 from leave_ledger l
                               where l.emp_id = e.id
                                 and l.leave_year = extract(year from current_date)::int
                                 and l.kind = 'grant')
  loop
    n := credit_joining_allowances(r.id);
    if n > 0 then total := total + 1; raise notice 'v48: credited % leave types to %', n, r.name; end if;
  end loop;
  raise notice 'v48: % employee(s) who held nothing now hold their allowances', total;
end $$;

select 'v48 installed' as status,
       (select count(*) from employees e where e.active
          and not exists (select 1 from leave_ledger l where l.emp_id = e.id
                           and l.leave_year = extract(year from current_date)::int and l.kind = 'grant'))
         as "active employees still holding nothing";
