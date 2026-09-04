-- ============================================================================
-- Give three people 5 carried-forward annual leave days, so the expiry can be tested.
--
--   「please credit 5 carryfoward AL to Lee Jian Wei, Amanda and ABB.
--     i will need to test the function too.」
--
-- Run migration_app_v37.sql FIRST — this uses credit_carry_forward(), which it adds.
--
-- Why a function rather than a hand-written INSERT: carried leave has TWO halves and
-- both must be written, or the balance and the expiry disagree —
--   · a ledger entry, which is what actually makes the days usable
--   · an annual_carry row, which is what the expiry job reads
-- Writing one and forgetting the other is easy, and looks fine until the expiry date
-- arrives and takes away days the screen never showed, or leaves days it should have.
--
-- Safe to read first: change `false` to `true` on the last line to see who it would
-- touch without writing anything.
-- ============================================================================
do $$
declare
  v_names text[] := array['Lee Jian Wei', 'Amanda', 'ABB'];   -- ← edit names here
  v_days  numeric := 5;                                        -- ← and days here
  v_preview boolean := false;                                  -- ← true = look only
  r record; v_res jsonb; v_missing text[] := '{}'; v_one text;
begin
  -- Name every person who is not found BEFORE writing anything: a typo should not
  -- leave two of the three credited and the third silently skipped.
  foreach v_one in array v_names loop
    if not exists (select 1 from employees where name = v_one and active) then
      v_missing := v_missing || v_one;
    end if;
  end loop;
  if array_length(v_missing, 1) > 0 then
    raise exception 'Not found on the active employee list: %. Nothing has been credited. Check the spelling against the Employees tab.',
      array_to_string(v_missing, ', ');
  end if;

  for r in select id, name from employees where name = any(v_names) and active order by name loop
    if v_preview then
      raise notice 'WOULD credit % with % day(s) of carry-forward', r.name, trim_scale(v_days);
    else
      v_res := credit_carry_forward(r.id, v_days);
      raise notice 'credited % : now holding % carried day(s), expiring %',
        r.name, v_res->>'carry_now', coalesce(v_res->>'expires_on', 'never (no date set)');
    end if;
  end loop;
end $$;

-- What they hold now, and when it dies.
select e.name                                   as "Employee",
       trim_scale(ac.carry_in)                  as "Carried forward",
       coalesce(to_char(ac.expires_on, 'DD Mon YYYY'), 'never expires') as "Expires on",
       case when ac.expired_at is not null then 'already written off' else 'live' end as "State",
       trim_scale(coalesce((select balance from leave_balances
                            where emp_id = e.id and leave_type = 'annual'), 0)) as "Annual balance"
  from employees e
  join annual_carry ac on ac.emp_id = e.id and ac.year = extract(year from current_date)::int
 where e.name in ('Lee Jian Wei', 'Amanda', 'ABB')
 order by e.name;
