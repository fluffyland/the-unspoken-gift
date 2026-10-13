#!/usr/bin/env bash
# Did the function actually START? — the check this project did not have.
#
# "Successfully deployed" means the file was uploaded. It does not mean the code runs.
# An entry point that imports a file which is not in the bundle never boots: every request
# then hangs with no error at all, and the dashboard still says success. That cost three
# deploys here. This answers the real question in about ten seconds.
#
# It only sends an OPTIONS preflight, so it CANNOT email anyone. Safe to run any time.
#
#   ./check-deploy.sh                  # reads the project URL out of app.html
#   ./check-deploy.sh https://xxx.supabase.co
set -u
FN=${FN:-send-notification}
BASE=${1:-}
if [ -z "$BASE" ]; then
  APP="$(cd "$(dirname "$0")/../../.." && pwd)/app.html"
  BASE=$(grep -o 'https://[a-z0-9]*\.supabase\.co' "$APP" | head -1)
fi
[ -n "$BASE" ] || { echo "Could not work out the project URL. Pass it: ./check-deploy.sh https://xxx.supabase.co"; exit 2; }
echo "project: $BASE"
echo

# OPTIONS needs no key and the function answers it on its first line with no I/O at all,
# so the time it takes is a clean measure of "is this thing alive".
probe() {  # probe <function-name> -> prints the line, returns the code in $CODE
  out=$(curl -s -o /dev/null -m 20 -X OPTIONS "$BASE/functions/v1/$1" \
        -H 'Origin: https://fluffyland.github.io' -w '%{http_code} %{time_total}')
  set -- $1 $out
  printf '%-24s HTTP %s in %ss\n' "$1" "$2" "$3"
  CODE=$2
}
probe "$FN";        S=$CODE
probe create-login; C=$CODE
echo
echo -n "==> "
case "$S" in
  200) echo "$FN is UP. It booted and is answering. Send test email is safe to press." ;;
  404) echo "$FN is NOT DEPLOYED — the gateway has never heard of that name. Check the spelling in Edge Functions." ;;
  000) echo "$FN EXISTS BUT DID NOT START."
       echo "    It cannot answer even a preflight, which needs no key, no database and no email."
       echo "    Almost always: the deployed index.ts imports a file that is not in the bundle."
       echo "      1. Edge Functions -> $FN -> delete every file that is not index.ts"
       echo "      2. paste the whole of the repo's generated index.ts into index.ts, Deploy"
       echo "      3. its Logs tab shows the module error verbatim if it still refuses" ;;
  *)   echo "$FN answered HTTP $S — unexpected. Its Logs tab will say why." ;;
esac
[ "$C" = "200" ] || echo "    (note: create-login answered $C too, so this may be the project, not the function)"

# A deliberately invalid key must come back 401 fast. If it does, the gateway is healthy and
# any hang above is the function's own boot, not the network or the project.
echo
printf '%-24s' 'gateway (bad key)'
curl -s -o /dev/null -m 20 -X POST "$BASE/functions/v1/$FN" \
  -H 'Authorization: Bearer not-a-real-key' -w 'HTTP %{http_code} in %{time_total}s  <- 401 here means the gateway is fine\n'
