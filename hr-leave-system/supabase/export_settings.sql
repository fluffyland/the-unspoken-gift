-- ============================================================================
-- export_settings.sql — carry your SETTINGS to a new, empty LeaveDesk, and
-- nothing else.
--
-- Run this on the **OLD** project. It is read-only: it creates nothing, changes
-- nothing, deletes nothing. It prints a SQL script.
-- Copy that script and run it on the **NEW** project, after install.sql.
--
-- What it carries:
--     company settings (name, domain, defaults, caps, accrual, BOTH expiry dates)
--     leave types      (your days per type — Hospitalisation 57, SPL 65, …)
--     public holidays  (every date and name you have keyed in)
--     teams            (and whether each works Saturdays)
--
-- What it does NOT carry, by design — this is the "clean system" part:
--     employees · logins · applications · approvals · the ledger ·
--     carry-forward records · amendment records · attachments · announcements
--
-- The column lists are read from the database itself rather than typed here, so
-- a setting added by a later migration is carried without this file changing.
-- ============================================================================

with
-- Every column each settings table really has, in order. Read, not assumed.
cols as (
  select table_name::text as t, array_agg(column_name::text order by ordinal_position) as c
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('leave_types', 'public_holidays', 'departments')
   group by table_name
),
-- org_settings is one row, so it becomes one UPDATE. Three columns are left out
-- on purpose: `id` is always 1; notify_url / notify_key are written by the app
-- itself the first time an HR/Owner signs in, from the two lines at the top of
-- app.html, so copying them across would point the new system at the old one.
-- notify_only_emp points at an employee row, and the new system has none.
org as (
  select string_agg(format('      %I = %s', key, quote_nullable(value)), ',' || chr(10)
                    order by key) as sets
    from jsonb_each_text(to_jsonb((select o from org_settings o where o.id = 1)))
   where key not in ('id', 'notify_url', 'notify_key', 'notify_only_emp')
),
-- One INSERT … ON CONFLICT DO UPDATE per row, so the script is safe to re-run.
rowsql as (
  select 'leave_types' as t, lt.sort as ord, lt.code as k,
         format('insert into leave_types (%s) values (%s) on conflict (code) do update set %s;',
           (select string_agg(quote_ident(col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord)),
           (select string_agg(quote_nullable(to_jsonb(lt) ->> col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord)),
           (select string_agg(format('%I = excluded.%I', col, col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord) where col <> 'code')) as line
    from leave_types lt cross join cols c where c.t = 'leave_types'
  union all
  select 'public_holidays', 0, ph.holiday::text,
         format('insert into public_holidays (%s) values (%s) on conflict (holiday) do update set %s;',
           (select string_agg(quote_ident(col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord)),
           (select string_agg(quote_nullable(to_jsonb(ph) ->> col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord)),
           (select string_agg(format('%I = excluded.%I', col, col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord) where col <> 'holiday'))
    from public_holidays ph cross join cols c where c.t = 'public_holidays'
  union all
  select 'departments', 0, d.name,
         format('insert into departments (%s) values (%s) on conflict (name) do update set %s;',
           (select string_agg(quote_ident(col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord)),
           (select string_agg(quote_nullable(to_jsonb(d) ->> col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord)),
           (select string_agg(format('%I = excluded.%I', col, col), ', ' order by ord)
              from unnest(c.c) with ordinality u(col, ord) where col <> 'name'))
    from departments d cross join cols c where c.t = 'departments'
),
report as (
  select 0 as s, 0 as o, '-- =====================================================================' as line
  union all select 0, 1, format('-- LeaveDesk settings exported %s from "%s"',
                                to_char(now(), 'DD Mon YYYY HH24:MI'),
                                (select company_name from org_settings where id = 1))
  union all select 0, 2, '-- Paste this whole thing into the NEW project''s SQL Editor and Run.'
  union all select 0, 3, '-- It carries settings only. No employee, no application, no ledger row.'
  union all select 0, 4, '-- Safe to run more than once.'
  union all select 0, 5, '-- ====================================================================='
  union all select 0, 6, ''
  union all select 0, 7, 'begin;'
  union all select 0, 8, ''

  union all select 1, 0, '-- ---- 1. company settings, including both expiry dates ----------------'
  union all select 1, 1, 'update org_settings set' || chr(10) || (select sets from org) || chr(10)
                         || '  where id = 1;'
  union all select 1, 2, '-- notify_only_emp is deliberately left NULL: it is the "while testing,'
  union all select 1, 3, '-- only email this one person" throttle, and a new company wants everyone.'
  union all select 1, 4, 'update org_settings set notify_only_emp = null where id = 1;'
  union all select 1, 9, ''

  union all select 2, 0, '-- ---- 2. teams -------------------------------------------------------'
  union all select 2, 1, line from rowsql where t = 'departments'
  union all select 2, 9, ''

  union all select 3, 0, '-- ---- 3. leave types — your days, not the MOM defaults ---------------'
  union all select 3, 1 + ord, line from rowsql where t = 'leave_types'
  union all
  -- install.sql seeds the full MOM list. Anything the old company does not have
  -- should not survive into the new one, or "the same settings" is not true.
  select 3, 9000, format('delete from leave_types where code not in (%s);',
                         (select string_agg(quote_literal(code), ', ' order by code) from leave_types))
  union all select 3, 9001, ''

  union all select 4, 0, '-- ---- 4. public holidays ---------------------------------------------'
  union all
  select 4, 1, format('delete from public_holidays where holiday not in (%s);',
                      (select string_agg(quote_literal(holiday::text), ', ' order by holiday)
                         from public_holidays))
  union all select 4, 2, line from rowsql where t = 'public_holidays'
  union all select 4, 9, ''

  union all select 9, 0, 'commit;'
  union all select 9, 1, ''
  union all select 9, 2, '-- ---- what to check when it finishes ---------------------------------'
  union all select 9, 3, 'select company_name, email_domain, default_annual_base, default_carry_cap,'
  union all select 9, 4, '       carry_expiry_month, carry_expiry_day, oil_expiry_month, oil_expiry_day'
  union all select 9, 5, '  from org_settings where id = 1;'
  union all select 9, 6, 'select code, name_en, default_days, gender_eligibility, no_deduct'
  union all select 9, 7, '  from leave_types order by sort;'
  union all select 9, 8, format('-- expect %s leave types, %s holidays, %s teams, and ZERO employees',
                      (select count(*) from leave_types), (select count(*) from public_holidays),
                      (select count(*) from departments))
  union all select 9, 9, 'select count(*) as employees_should_be_zero from employees;'
)
select line as "copy this whole column, then run it on the NEW project"
  from report order by s, o, line;
