#!/bin/sh
# Does export_settings.sql really carry the settings, and really leave the people behind?
#
# Asked for as: "it should be a clean system without any employee data but keeps all
# other setting totaly same. meaning i only migrate the whole code whole system there"
#
# Both halves of that sentence are checked, and the only way to check them honestly is
# to build TWO databases: the old company with its own settings and its staff, and a
# brand-new one from install.sql alone. Then export, import, and compare the two
# dictionaries column by column — a comparison written out by hand would only ever check
# the columns I remembered.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SB=$HERE/../supabase
PGB=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
D=${TMPDIR:-/tmp}/leavedesk-export
pass=0; fail=0
ok() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "ok    $2"; else fail=$((fail+1)); echo "FAIL  $2  $3"; fi; }
eq() { if [ "$2" = "$3" ]; then ok ok "$1"; else ok no "$1" "got [$2] want [$3]"; fi; }

runuser -u postgres -- $PGB/pg_ctl -D $D/data stop -m immediate >/dev/null 2>&1 || true
rm -rf $D; mkdir -p $D; chown postgres:postgres $D
runuser -u postgres -- $PGB/initdb -D $D/data -U postgres -A trust >/dev/null 2>&1
echo "listen_addresses=''" >> $D/data/postgresql.conf
runuser -u postgres -- $PGB/pg_ctl -D $D/data -o "-k $D" -l $D/log -w start >/dev/null 2>&1
chmod 777 $D
mk() { $PGB/psql -h $D -U postgres -d postgres -q -c "drop database if exists $1" >/dev/null
       $PGB/psql -h $D -U postgres -d postgres -q -c "create database $1" >/dev/null
       $PGB/psql -h $D -U postgres -d $1 -q -v ON_ERROR_STOP=1 -f "$HERE/supabase_shim.sql" >/dev/null 2>&1
       $PGB/psql -h $D -U postgres -d $1 -q -v ON_ERROR_STOP=1 -f "$SB/install.sql" >/dev/null 2>&1; }
Q() { $PGB/psql -h $D -U postgres -d "$1" -t -A -v ON_ERROR_STOP=1 -c "$2"; }

echo "--- the OLD company: install.sql, then settings changed and staff hired ---"
mk old
$PGB/psql -h $D -U postgres -d old -q -v ON_ERROR_STOP=1 -f "$HERE/seed_lifecycle.sql" >/dev/null 2>&1
# The settings the user actually changed, plus a couple nobody would guess.
$PGB/psql -h $D -U postgres -d old -q -v ON_ERROR_STOP=1 >/dev/null <<'EOF'
update org_settings set company_name = 'Shanghai School Uniforms Pte Ltd',
  email_domain = 'shanghai-uniforms.com', default_annual_base = 14, default_carry_cap = 5,
  annual_cap = 21, carry_expiry_month = 12, carry_expiry_day = 31,
  oil_expiry_month = 9, oil_expiry_day = 10 where id = 1;
update leave_types set default_days = 57 where code = 'hosp';
update leave_types set default_days = 65 where code = 'shared_parental';
update leave_types set default_days = 3  where code = 'compassionate';
update leave_types set allow_half_day = true, requires_attachment = true where code = 'childcare';
-- a leave type the company does not use at all
delete from leave_types where code = 'ns';
-- a holiday they keyed in by hand, and one of the seeded ones they removed
insert into public_holidays values ('2026-12-26', 'Boxing Day (company)') on conflict do nothing;
delete from public_holidays where holiday = '2026-03-21';
insert into departments (name, works_saturday) values ('Warehouse', true) on conflict (name)
  do update set works_saturday = true;
-- the testing throttle, which must NOT travel
update org_settings set notify_only_emp = (select id from employees limit 1) where id = 1;
EOF
ok ok "the old company has staff and history"
eq "it has employees"      "$(Q old 'select count(*)>0 from employees')" "t"
eq "and ledger rows"       "$(Q old 'select count(*)>0 from leave_ledger')" "t"
eq "and applications"      "$(Q old 'select count(*)>0 from applications')" "t"

echo
echo "--- export, then a brand-new empty company, then import ---"
$PGB/psql -h $D -U postgres -d old -t -A -v ON_ERROR_STOP=1 -f "$SB/export_settings.sql" > "$D/carry.sql"
eq "the export produced a script" "$(grep -c 'update org_settings set' "$D/carry.sql")" "2"
eq "and it mentions no employee table" "$(grep -ciE 'insert into (employees|applications|leave_ledger|annual_carry)' "$D/carry.sql")" "0"
mk new
$PGB/psql -h $D -U postgres -d new -q -v ON_ERROR_STOP=1 -f "$D/carry.sql" > "$D/import.log" 2>&1 \
  && ok ok "it runs on the new project without an error" \
  || { ok no "it runs on the new project without an error" "$(tail -3 $D/import.log)"; }

echo
echo "--- every settings column, compared rather than remembered ---"
# to_jsonb of the whole row, minus the three columns that must differ, as one string.
ORGQ="select to_jsonb(o) - 'notify_url' - 'notify_key' - 'notify_only_emp' from org_settings o where id = 1"
eq "org_settings is identical, column for column" "$(Q new "$ORGQ")" "$(Q old "$ORGQ")"
eq "the email throttle did NOT travel" "$(Q new "select coalesce(notify_only_emp::text, 'NULL') from org_settings where id=1")" "NULL"
LTQ="select string_agg(to_jsonb(l)::text, '|' order by code) from leave_types l"
# Leave types are deliberately NOT applied: asked to be set up fresh on the new system.
# They are still PRINTED, commented out, so the decision costs nothing to reverse. Both
# halves of that are checked -- the default, and what happens when it is opted into.
eq "leave types are NOT carried by default"  "$(Q new "select default_days::text from leave_types where code='hosp'")" "60.0"
eq "so the new system has the MOM Shared Parental" "$(Q new "select default_days::text from leave_types where code='shared_parental'")" "70.0"
eq "and a type the old company deleted is still present" "$(Q new "select count(*) from leave_types where code='ns'")" "1"
eq "but the old figures ARE in the script, for reference" "$(grep -c 'Hospitalisation Leave 57' "$D/carry.sql")" "1"
eq "every leave-type line is commented out" \
   "$(grep -c '^-- insert into leave_types' "$D/carry.sql")" "$(Q old 'select count(*) from leave_types')"
eq "none of them is live"  "$(grep -c '^insert into leave_types' "$D/carry.sql")" "0"

echo
echo "--- opting leave types in is one edit, and then they DO carry ---"
sed 's/^-- insert into leave_types/insert into leave_types/; s/^-- delete from leave_types/delete from leave_types/' \
    "$D/carry.sql" > "$D/carry_with_types.sql"
$PGB/psql -h $D -U postgres -d new -q -v ON_ERROR_STOP=1 -f "$D/carry_with_types.sql" >/dev/null 2>&1 \
  && ok ok "the opted-in script runs" || ok no "the opted-in script runs"
eq "every leave type is now identical"     "$(Q new "$LTQ")" "$(Q old "$LTQ")"
eq "Hospitalisation is 57"                 "$(Q new "select default_days::text from leave_types where code='hosp'")" "57.0"
eq "Shared Parental is 65"                 "$(Q new "select default_days::text from leave_types where code='shared_parental'")" "65.0"
eq "and the type they deleted is gone"     "$(Q new "select count(*) from leave_types where code='ns'")" "0"
eq "still no employees"                    "$(Q new 'select count(*) from employees')" "0"
# Put the new database back to the default-path state for the checks that follow.
$PGB/psql -h $D -U postgres -d new -q -c "update leave_types set default_days = 60 where code='hosp'" >/dev/null
$PGB/psql -h $D -U postgres -d new -q -c "update leave_types set default_days = 70 where code='shared_parental'" >/dev/null
eq "off-in-lieu expiry came across"        "$(Q new "select oil_expiry_month || '-' || oil_expiry_day from org_settings where id=1")" "9-10"
PHQ="select string_agg(holiday::text||'='||name, '|' order by holiday) from public_holidays"
eq "public holidays are identical"    "$(Q new "$PHQ")" "$(Q old "$PHQ")"
eq "the holiday they removed is still removed" "$(Q new "select count(*) from public_holidays where holiday='2026-03-21'")" "0"
eq "the one they added by hand is there"       "$(Q new "select name from public_holidays where holiday='2026-12-26'")" "Boxing Day (company)"
DQ="select string_agg(name||'='||works_saturday, '|' order by name) from departments"
eq "teams are identical, Saturdays included" "$(Q new "$DQ")" "$(Q old "$DQ")"

echo
echo "--- and the new company really is clean ---"
for t in employees applications approval_steps application_events leave_ledger annual_carry hr_amendments; do
  eq "no rows in $t" "$(Q new "select count(*) from $t")" "0"
done

echo
echo "--- running it twice changes nothing ---"
BEFORE=$(Q new "$LTQ$(printf '')" ; Q new "$PHQ"; Q new "$ORGQ")
$PGB/psql -h $D -U postgres -d new -q -v ON_ERROR_STOP=1 -f "$D/carry.sql" >/dev/null 2>&1
AFTER=$(Q new "$LTQ"; Q new "$PHQ"; Q new "$ORGQ")
eq "a second import is a no-op" "$AFTER" "$BEFORE"
eq "and still no employees" "$(Q new 'select count(*) from employees')" "0"

runuser -u postgres -- $PGB/pg_ctl -D $D/data stop -m immediate >/dev/null 2>&1 || true
echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
