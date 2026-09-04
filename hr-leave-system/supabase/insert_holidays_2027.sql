-- ============================================================================
-- Singapore public holidays 2027 — bulk manual entry
-- ============================================================================
-- Paste this whole file into Supabase -> SQL Editor -> Run. It takes a second.
--
-- This is NOT a sync. There is no automatic holiday updater in LeaveDesk any
-- more — it was removed in August 2026 because it had never once run, and a
-- button that looks automatic while doing nothing is worse than no button.
-- Public holidays are a list HR keeps, in Company settings -> Public holidays.
--
-- This file is just a shortcut for one year, so you don't type twelve dates by
-- hand. Adding them one at a time with "+ Add holiday" gives exactly the same
-- result. Either way the rows are marked 'manual', because that is what they are.
--
-- Where the dates come from
--   data.gov.sg collection 691, "Singapore Public Holidays", whose own metadata
--   names the Ministry of Manpower as the source and the manager of the data.
--   Checked against it in August 2026. Verify any date against MOM directly:
--   https://www.mom.gov.sg/employment-practices/public-holidays
--
-- Safe to run twice
--   ON CONFLICT DO NOTHING: any date already in the table is left exactly as it
--   is. Nothing is renamed, nothing is deleted, 2026 is not touched. If a date
--   here is already in your list with a different name, YOUR name wins and this
--   file changes nothing — fix it in the app if you want it changed.
-- ============================================================================

insert into public_holidays (holiday, name, source) values
  ('2027-01-01', 'New Year''s Day',              'manual'),
  ('2027-02-06', 'Chinese New Year',             'manual'),
  ('2027-02-07', 'Chinese New Year',             'manual'),
  ('2027-02-08', 'Chinese New Year (Observed)',  'manual'),
  ('2027-03-10', 'Hari Raya Puasa',              'manual'),
  ('2027-03-26', 'Good Friday',                  'manual'),
  ('2027-05-01', 'Labour Day',                   'manual'),
  ('2027-05-17', 'Hari Raya Haji',               'manual'),
  ('2027-05-20', 'Vesak Day',                    'manual'),
  ('2027-08-09', 'National Day',                 'manual'),
  ('2027-10-28', 'Deepavali',                    'manual'),
  ('2027-12-25', 'Christmas Day',                'manual')
on conflict (holiday) do nothing;

-- Check: should return 12 rows.
select holiday, to_char(holiday, 'Dy') as day, name
from public_holidays
where holiday >= '2027-01-01' and holiday < '2028-01-01'
order by holiday;

-- Check: 2026 must be untouched (14 rows).
select count(*) as holidays_2026
from public_holidays
where holiday >= '2026-01-01' and holiday < '2027-01-01';
