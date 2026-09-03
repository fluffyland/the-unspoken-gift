-- ============================================================================
-- L. Every leave type, every employee, through the whole life of an application.
--
-- Asked for in these words: "check all leave one by one, try to apply and check
-- balance and try to withdraw and check balance and edit in leave type and check
-- balance, do what i suggest but not limited to what i suggest".
--
-- So this does not test one type or one person. After EVERY operation it re-checks
-- one invariant for EVERY employee and EVERY deductible leave type:
--
--     available  ==  entitled(this year) + carried in  -  taken(this year)  -  pending
--
-- If a single figure anywhere in the company drifts, the operation that did it is
-- named. That is the only way to answer "why is one employee still different".
-- ============================================================================
\set ON_ERROR_STOP on

create or replace function ck(p_what text, p_got anyelement, p_want anyelement)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then raise exception 'FAIL  %  — got %, want %', p_what, p_got, p_want; end if;
  raise notice 'ok    %  = %', p_what, p_got;
end $$;

create or replace function eid(p text) returns uuid language sql stable as $$
  select id from employees where name = p $$;
create or replace function whoami(p text) returns void language plpgsql as $$
begin delete from auth._whoami;
      insert into auth._whoami select auth_user_id from employees where name = p; end $$;
create or replace function ent(p text, c text) returns numeric language sql stable as $$
  select entitled_in_year(eid(p), c, extract(year from current_date)::int) $$;
create or replace function avail(p text, c text) returns numeric language sql stable as $$
  select coalesce((select available from leave_balances
                   where emp_id = eid(p) and leave_type = c), 0) $$;

-- Taken this year, from the tags, for any leave type.
create or replace function taken_y(p_emp uuid, p_code text) returns numeric language sql stable as $$
  select coalesce(-sum(delta_days), 0) from leave_ledger
   where emp_id = p_emp and leave_type = p_code
     and leave_year = extract(year from current_date)::int
     and kind in ('taken', 'refund') $$;
create or replace function carry_y(p_emp uuid, p_code text) returns numeric language sql stable as $$
  select coalesce(sum(delta_days), 0) from leave_ledger
   where emp_id = p_emp and leave_type = p_code
     and leave_year = extract(year from current_date)::int and kind = 'carry_in' $$;

-- THE invariant, across the whole company. Returns '' when everything agrees,
-- otherwise every disagreement, so one run names them all instead of the first.
create or replace function drift() returns text language plpgsql stable as $$
declare r record; out text := '';
begin
  for r in
    select e.name, t.code,
           avail(e.name, t.code) as have,
           ent(e.name, t.code) + carry_y(e.id, t.code) - taken_y(e.id, t.code)
             - coalesce((select sum(a.days) from applications a
                          where a.emp_id = e.id and a.leave_type = t.code
                            and a.status = 'pending'), 0) as should
      from employees e cross join leave_types t
     where e.active and not t.no_deduct
       and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
     order by e.name, t.sort
  loop
    if r.have is distinct from r.should then
      out := out || format('%s/%s have %s want %s; ', r.name, r.code,
                           trim_scale(r.have), trim_scale(r.should));
    end if;
  end loop;
  return out;
end $$;

-- Every active, eligible person on exactly the figure from the Leave types tab.
create or replace function off_figure() returns text language plpgsql stable as $$
declare r record; out text := '';
begin
  for r in
    select e.name, t.code, t.default_days as want, ent(e.name, t.code) as have
      from employees e cross join leave_types t
     where e.active and not t.no_deduct and t.code <> 'annual' and t.code <> 'oil'
       and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
     order by e.name, t.sort
  loop
    if r.have is distinct from r.want then
      out := out || format('%s/%s is %s not %s; ', r.name, r.code,
                           trim_scale(r.have), trim_scale(r.want));
    end if;
  end loop;
  return out;
end $$;

-- Somebody holding NO allowance at all for a type they are eligible for.
-- drift() cannot see this: their ledger is perfectly self-consistent, it is just
-- empty. That is the "-1 / 0" on the reported Balances tab — available minus one,
-- entitled nothing — and it needs its own check.
create or replace function missing_allowance() returns text language plpgsql stable as $$
declare r record; out text := '';
begin
  for r in
    select e.name, t.code
      from employees e cross join leave_types t
     where e.active and not t.no_deduct and t.code <> 'oil'
       and (t.default_days > 0 or t.code = 'annual')
       and (t.gender_eligibility is null or t.gender_eligibility = e.gender)
       and not exists (select 1 from leave_ledger l
                        where l.emp_id = e.id and l.leave_type = t.code
                          and l.leave_year = extract(year from current_date)::int
                          and l.kind = 'grant')
     order by e.name, t.sort
  loop out := out || format('%s/%s; ', r.name, r.code); end loop;
  return out;
end $$;

do $$ begin raise notice ' '; raise notice '=== A. before anything: where does this company actually stand? ==='; end $$;
select ck('L1 the invariant holds on the seeded data', drift(), '');
-- Joiner was credited at July's figures, everyone else in January. If those differ
-- this reports it — and it is the reported bug, so it must be visible here.
do $$ declare o text := off_figure();
begin if o = '' then raise notice 'ok    L2 everyone is already on the Leave types figure';
      else raise notice 'ok    L2 people are off the figure, as expected before levelling: %', left(o, 160); end if; end $$;

do $$ begin raise notice ' '; raise notice '=== B. level every leave type, then check every employee ==='; end $$;
select reconcile_all_leave_types(false);
select ck('L3 every active employee is on the Leave types figure, every type', off_figure(), '');
select ck('L4 and the invariant still holds', drift(), '');
select ck('L5 levelling again writes nothing',
          (select sum("People corrected")::int from reconcile_all_leave_types(false)), 0);

do $$ begin raise notice ' '; raise notice '=== B2. somebody with no allowance at all ==='; end $$;
-- Exactly ABB's shape on the reported screen: his annual allowance was removed by
-- the undo (it had been written by the bad year start) and he never had another,
-- so he holds nothing, has taken a day, and reads -1 / 0.
delete from leave_ledger where emp_id = eid('Male') and leave_type = 'annual' and kind = 'grant';
insert into applications (id, emp_id, leave_type, start_date, end_date, days, status, reason)
values ('c0000000-0000-0000-0000-0000000000aa', eid('Male'), 'annual', '2026-03-02','2026-03-02', 1, 'approved','x');
insert into leave_ledger (emp_id, leave_type, delta_days, reason, ref_application)
values (eid('Male'), 'annual', -1, 'Leave taken', 'c0000000-0000-0000-0000-0000000000aa');
select ck('L7 he reads minus one against nothing', trim_scale(avail('Male','annual')) || ' / ' || trim_scale(ent('Male','annual')), '-1 / 0');
select ck('L8 and the balance invariant CANNOT see it — his ledger is self-consistent', drift(), '');
select ck('L9 but the missing-allowance check names him', missing_allowance(), 'Male/annual; ');
select reconcile_all_leave_types(false);
select ck('L10 levelling everything gives him the allowance he was owed', missing_allowance(), '');
select ck('L11 his entitlement is his own figure, not a company one', ent('Male','annual'), 14::numeric);
select ck('L12 and the day he took is still taken', avail('Male','annual'), 13::numeric);
select ck('L13 the company still agrees', drift(), '');

do $$ begin raise notice ' '; raise notice '=== C. apply for every leave type, one type at a time ==='; end $$;
-- Each type: apply, check pending is reserved, approve, check the deduction is
-- exactly the days, and re-check the whole company after each step.
do $$
declare t record; app uuid; d numeric; before_av numeric; att text;
        -- Each type gets its own week: applications for one person may not overlap,
        -- and reusing one date silently tests only the first type in the list.
        wk date := date '2026-01-05';
begin
  for t in select code, name_en, requires_attachment from leave_types
            where not no_deduct and code <> 'oil'
              and (gender_eligibility is null or gender_eligibility = 'F')
            order by sort loop
    att := case when t.requires_attachment then 'mc.pdf' else null end;
    before_av := avail('Fem', t.code);
    perform whoami('Fem');
    app := submit_application(t.code, wk, wk + 1, 'test', att);
    wk := wk + 7;
    select days into d from applications where id = app;

    if avail('Fem', t.code) <> before_av - d then
      raise exception 'FAIL C/% : applying did not reserve the days — % then %',
        t.code, trim_scale(before_av), trim_scale(avail('Fem', t.code));
    end if;
    if drift() <> '' then raise exception 'FAIL C/% after applying: %', t.code, drift(); end if;

    perform whoami('Boss');
    -- ack = true: another member of the same team is away on some of these dates
    -- (B2 put one there on purpose), and the approver is expected to acknowledge it.
    perform act_on_step(app, 'approve', null, true);
    if avail('Fem', t.code) <> before_av - d then
      raise exception 'FAIL C/% : approving changed the balance again — % then %',
        t.code, trim_scale(before_av), trim_scale(avail('Fem', t.code));
    end if;
    if drift() <> '' then raise exception 'FAIL C/% after approving: %', t.code, drift(); end if;
    if taken_y(eid('Fem'), t.code) <> d then
      raise exception 'FAIL C/% : taken reads % not %', t.code, trim_scale(taken_y(eid('Fem'), t.code)), trim_scale(d);
    end if;
    raise notice 'ok    C %  applied and approved % day(s), balance % -> %',
      rpad(t.code, 16), trim_scale(d), trim_scale(before_av), trim_scale(avail('Fem', t.code));
  end loop;
end $$;
select ck('L6 the whole company still agrees after every type was applied for', drift(), '');

do $$ begin raise notice ' '; raise notice '=== D. withdraw, reject, cancel ==='; end $$;
do $$
declare app uuid; before_av numeric := avail('Male','childcare');
begin
  -- withdraw a pending one: nothing was ever deducted, nothing to give back
  perform whoami('Male');
  app := submit_application('childcare', '2026-10-12', '2026-10-13', 'test');
  if avail('Male','childcare') <> before_av - 2 then raise exception 'FAIL D withdraw: pending not reserved'; end if;
  perform withdraw_application(app);
  if avail('Male','childcare') <> before_av then raise exception 'FAIL D withdraw: balance not released'; end if;
  if drift() <> '' then raise exception 'FAIL D after withdraw: %', drift(); end if;
  raise notice 'ok    D withdraw  balance back to %', trim_scale(before_av);

  -- reject: also never deducted
  perform whoami('Male');
  app := submit_application('childcare', '2026-10-19', '2026-10-20', 'test');
  perform whoami('Boss');
  perform act_on_step(app, 'reject', 'no');
  if avail('Male','childcare') <> before_av then raise exception 'FAIL D reject: balance moved'; end if;
  if exists (select 1 from leave_ledger where ref_application = app) then
    raise exception 'FAIL D reject: a rejected application wrote to the ledger'; end if;
  if drift() <> '' then raise exception 'FAIL D after reject: %', drift(); end if;
  raise notice 'ok    D reject    balance untouched at %', trim_scale(before_av);

  -- cancel an approved one that has not started: the days come back
  perform whoami('Male');
  app := submit_application('childcare', '2026-12-07', '2026-12-08', 'test');
  perform whoami('Boss');
  perform act_on_step(app, 'approve', null, true);
  if avail('Male','childcare') <> before_av - 2 then raise exception 'FAIL D cancel: not deducted on approval'; end if;
  perform whoami('Male');
  perform request_cancel(app);
  perform whoami('Boss');
  perform confirm_cancel(app, true);
  if avail('Male','childcare') <> before_av then
    raise exception 'FAIL D cancel: % not returned to %', trim_scale(avail('Male','childcare')), trim_scale(before_av); end if;
  if taken_y(eid('Male'),'childcare') <> 0 then
    raise exception 'FAIL D cancel: taken still reads %', trim_scale(taken_y(eid('Male'),'childcare')); end if;
  if drift() <> '' then raise exception 'FAIL D after cancel: %', drift(); end if;
  raise notice 'ok    D cancel    balance back to %, taken back to 0', trim_scale(before_av);
end $$;

do $$ begin raise notice ' '; raise notice '=== E. edit a leave type up and down, with leave already taken ==='; end $$;
do $$
declare taken_before numeric; av numeric;
begin
  taken_before := taken_y(eid('Fem'), 'childcare');
  perform amend_leave_type_days('childcare', 9);
  if off_figure() <> '' then raise exception 'FAIL E raise: %', off_figure(); end if;
  if taken_y(eid('Fem'), 'childcare') <> taken_before then
    raise exception 'FAIL E raise: days already taken were disturbed'; end if;
  if drift() <> '' then raise exception 'FAIL E raise: %', drift(); end if;
  raise notice 'ok    E raise 6 -> 9   everyone on 9, taken still %', trim_scale(taken_before);

  perform amend_leave_type_days('childcare', 4);
  if off_figure() <> '' then raise exception 'FAIL E lower: %', off_figure(); end if;
  if taken_y(eid('Fem'), 'childcare') <> taken_before then
    raise exception 'FAIL E lower: days already taken were disturbed'; end if;
  if drift() <> '' then raise exception 'FAIL E lower: %', drift(); end if;
  raise notice 'ok    E lower 9 -> 4   everyone on 4, taken still %', trim_scale(taken_before);

  perform amend_leave_type_days('childcare', 6);
  raise notice 'ok    E back to 6      everyone on 6';
end $$;

do $$ begin raise notice ' '; raise notice '=== F. the awkward employees ==='; end $$;
select ck('F1 someone with no gender recorded is outside gendered types, consistently',
          (select count(*)::int from leave_ledger
            where emp_id = eid('Nogender') and leave_type in ('maternity','paternity','adoption')), 0);
select ck('F2 and holds every ungendered type at the figure',
          (select count(*)::int from leave_types t where not t.no_deduct
             and t.code <> 'annual' and t.code <> 'oil' and t.gender_eligibility is null
             and ent('Nogender', t.code) <> t.default_days), 0);
select ck('F3 a leaver is not touched by levelling',
          (select count(*)::int from leave_ledger l
            where l.emp_id = eid('Gone') and l.reason like '%set to%'), 0);
select ck('F4 a leaver''s ledger is frozen',
          (select case when count(*) = 0 then 'frozen' else 'writable' end
             from leave_ledger where emp_id = eid('Gone') and reason like '%set to%'), 'frozen');
select ck('F5 Joiner, credited on joining, is on the figure like everyone else',
          (select count(*)::int from leave_types t where not t.no_deduct
             and t.code <> 'annual' and t.code <> 'oil'
             and (t.gender_eligibility is null or t.gender_eligibility = 'F')
             and ent('Joiner', t.code) <> t.default_days), 0);
select ck('F6 and holds exactly one allowance per type',
          (select count(*)::int from (
             select leave_type from leave_ledger
              where emp_id = eid('Joiner') and kind = 'grant'
                and leave_year = extract(year from current_date)::int
              group by leave_type having count(*) > 1) d), 0);

do $$ begin raise notice ' '; raise notice '=== G. the yearly run, after all of that ==='; end $$;
select ck('G1 nobody is credited a second time',
          grant_annual_entitlements(extract(year from current_date)::int), 0);
select ck('G2 the company still agrees', drift(), '');
select ck('G3 and everybody is still on the figure', off_figure(), '');
select ck('G4 nobody anywhere is missing an allowance', missing_allowance(), '');

do $$ begin raise notice ' '; raise notice 'ALL t35-L ASSERTIONS PASSED'; end $$;
