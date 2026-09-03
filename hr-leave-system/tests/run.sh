#!/bin/sh
# Run the v35 suite. Nothing here touches a real database and nothing can send an email.
#
#   ./run.sh sql        the database tests, on a throwaway Postgres 16
#   ./run.sh browser    the page tests, on the local app.html
#   ./run.sh            both
#
# The SQL half stands a fresh Postgres up in a temp folder, loads supabase_shim.sql
# (a small stand-in for what Supabase provides: auth.uid(), storage, pg_net), then
# ../supabase/install.sql, then the tests. It stops the server afterwards.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SB=$HERE/../supabase
PGB=$(ls -d /usr/lib/postgresql/*/bin | tail -1)
D=${TMPDIR:-/tmp}/leavedesk-test-pg

sql() {
  runuser -u postgres -- $PGB/pg_ctl -D $D/data stop -m immediate >/dev/null 2>&1 || true
  rm -rf $D; mkdir -p $D; chown postgres:postgres $D
  runuser -u postgres -- $PGB/initdb -D $D/data -U postgres -A trust >/dev/null 2>&1
  echo "listen_addresses=''" >> $D/data/postgresql.conf
  runuser -u postgres -- $PGB/pg_ctl -D $D/data -o "-k $D" -l $D/log -w start >/dev/null 2>&1
  chmod 777 $D
  P() { $PGB/psql -h $D -U postgres -d hr -v ON_ERROR_STOP=1 "$@"; }
  fresh() {
    $PGB/psql -h $D -U postgres -d postgres -q -c "drop database if exists hr" >/dev/null
    $PGB/psql -h $D -U postgres -d postgres -q -c "create database hr" >/dev/null
    P -q -f "$HERE/supabase_shim.sql" >/dev/null 2>&1
  }

  echo "--- a brand-new company, installed from install.sql alone ---"
  fresh; P -q -f "$SB/install.sql" >/dev/null 2>&1
  P -q -f "$HERE/seed_new_company.sql" >/dev/null 2>&1
  P -f "$HERE/t35.sql" 2>&1 | grep -E "NOTICE:  (ok|===)|FAIL|ERROR" | sed 's/^psql[^ ]* //'

  # install.sql with the v35 section cut out = the database as it is before the upgrade
  awk '/^-- migration_app_v35\.sql$/{s=1} /^-- keepalive_ping_v3\.sql$/{s=0} !s' "$SB/install.sql" > "$D/pre35.sql"

  # $1 = seed, $2 = assertions. Snapshot the balances BEFORE the migration: a snapshot
  # taken afterwards could never disagree, and a check that cannot fail is worse than none.
  upgrade() {
    fresh; P -q -f "$D/pre35.sql" >/dev/null 2>&1
    P -q -f "$HERE/$1" >/dev/null 2>&1
    P -q -c "create table _pre as select emp_id, leave_type, balance from leave_balances" >/dev/null
    P -q -f "$SB/migration_app_v35.sql" >/dev/null 2>&1
    P -f "$HERE/$2" 2>&1 | grep -E "NOTICE:  ok|FAIL|ERROR" | sed 's/^psql[^ ]* //'
  }

  echo
  echo "--- upgraded in place: the company that reported the bug (all of it in one year) ---"
  upgrade seed_reported_case.sql t35_reported_case.sql

  echo
  echo "--- upgraded in place: a company with a real previous year ---"
  # This fixture exists because the one above cannot test the year tags at all. Every
  # row in it sits in 2026, so "the year the wording names" and "the year it was typed"
  # always agree, and a migration that filed everything under the wrong year would look
  # exactly like one that got it right. Here they disagree in three places on purpose.
  upgrade seed_two_years.sql t35_two_years.sql

  runuser -u postgres -- $PGB/pg_ctl -D $D/data stop -m immediate >/dev/null 2>&1 || true
}

browser() { node "$HERE/t35.mjs"; }

case "${1:-both}" in
  sql) sql ;;
  browser) browser ;;
  *) sql; echo; browser ;;
esac
