-- ============================================================================
-- Singapore public holidays 2027
-- ============================================================================
-- Paste this whole file into Supabase -> SQL Editor -> Run. It takes a second.
--
-- Where these dates come from
--   data.gov.sg collection 691, "Singapore Public Holidays".
--   That collection's own metadata names the Ministry of Manpower as both the
--   source and the manager of the data, so this is MOM's published list, not a
--   copy from a blog. Cross-check any date against:
--   https://www.mom.gov.sg/employment-practices/public-holidays
--
-- Why by hand
--   The automatic updater has not been switched on for this project, so the
--   "Sync now" button has nothing to call yet. This loads 2027 in the meantime
--   and changes nothing else.
--
-- Safe to run twice
--   ON CONFLICT DO NOTHING: any date already in the table is left exactly as it
--   is, including dates typed in by hand. Nothing is renamed and nothing is
--   deleted. 2026 is not touched.
--
-- source = 'data.gov.sg' is deliberate: these ARE MOM's rows, so if the
-- automatic sync is switched on later it will recognise them as its own and
-- keep them correct. Rows marked 'manual' are the ones the sync must never
-- touch, and marking these 'manual' would freeze them out of future updates.
-- ============================================================================

insert into public_holidays (holiday, name, source, synced_at) values
  ('2027-01-01', 'New Year''s Day',              'data.gov.sg', now()),
  ('2027-02-06', 'Chinese New Year',             'data.gov.sg', now()),
  ('2027-02-07', 'Chinese New Year',             'data.gov.sg', now()),
  ('2027-02-08', 'Chinese New Year (Observed)',  'data.gov.sg', now()),
  ('2027-03-10', 'Hari Raya Puasa',              'data.gov.sg', now()),
  ('2027-03-26', 'Good Friday',                  'data.gov.sg', now()),
  ('2027-05-01', 'Labour Day',                   'data.gov.sg', now()),
  ('2027-05-17', 'Hari Raya Haji',               'data.gov.sg', now()),
  ('2027-05-20', 'Vesak Day',                    'data.gov.sg', now()),
  ('2027-08-09', 'National Day',                 'data.gov.sg', now()),
  ('2027-10-28', 'Deepavali',                    'data.gov.sg', now()),
  ('2027-12-25', 'Christmas Day',                'data.gov.sg', now())
on conflict (holiday) do nothing;

-- Check: should return 12 rows.
select holiday, to_char(holiday, 'Dy') as day, name, source
from public_holidays
where holiday >= '2027-01-01' and holiday < '2028-01-01'
order by holiday;

-- Check: 2026 must be untouched (14 rows).
select count(*) as holidays_2026
from public_holidays
where holiday >= '2026-01-01' and holiday < '2027-01-01';
