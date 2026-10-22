#!/usr/bin/env bash
# Runs every test. Needs: Postgres 15+ (psql as the postgres user), Node 20+, and for the
# "live" tests a PostgREST binary at .tools/postgrest (or POSTGREST_BIN).
#   tests/run.sh          everything
#   tests/run.sh db       database only
#   tests/run.sh ui       screens in demo mode only (no database needed)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
what=${1:-all}
PSQL=${PSQL:-"psql -v ON_ERROR_STOP=1 -q -t -A"}

if [[ $what == all || $what == db ]]; then
  echo "== database smoke test"
  ${DROPDB:-dropdb} --if-exists sp_test 2>/dev/null || true
  ${CREATEDB:-createdb} sp_test
  cat supabase/tests/local_supabase_stub.sql supabase/migrations/*.sql supabase/seed.sql supabase/tests/smoke_test.sql \
    | $PSQL -d sp_test | grep -E "^(pass|ALL TESTS)" | tail -1
fi

if [[ $what == all || $what == ui ]]; then
  (cd tests/ui && [ -d node_modules ] || npm install --silent --no-audit --no-fund)
  run() { local out rc=0; out=$(cd tests/ui && node "$1" "$ROOT/$2" 2>&1) || rc=$?; local n; n=$(grep -c "^pass" <<<"$out" || true)
    if grep -q "^FAIL" <<<"$out"; then echo "FAIL $1"; grep -A2 "^FAIL" <<<"$out"; exit 1
    elif [[ $rc -ne 0 ]]; then echo "FAIL $1 (crashed)"; tail -8 <<<"$out"; exit 1; else echo "ok   $1 ($n checks)"; fi; }
  echo "== screens (demo data)"
  run console.js platform/console.html
  for f in dashboard1.js dashboard2.js dashboard3.js dashboard4.js dashboard5.js; do run $f dashboard/dashboard.html; done
  for i in 1 2 3 4 5 6 7 8 9 10 11; do run station$i.js station/station.html; done
  echo "== station updater (Pi)"
  python3 station/pi/test_station_updater.py | grep -E "^(FAIL|ALL)" || { echo "FAIL station updater"; exit 1; }
fi

if [[ $what == all ]] && [[ -x ${POSTGREST_BIN:-.tools/postgrest} ]]; then
  echo "== screens against a real database"
  run console_live.js platform/console.html
  run dashboard_live.js dashboard/dashboard.html
  run station_live.js station/station.html
fi
echo "done"
