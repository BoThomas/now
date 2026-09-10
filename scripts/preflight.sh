#!/bin/zsh
# Complete local release verification. All calendar/notification fixtures use
# disposable data. The updater test temporarily quits now and reopens it.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_PATH="outputs/now.app"
if [[ $# -eq 0 ]]; then
  ./build-app.sh --require-identity
elif [[ $# -eq 2 && "$1" == --app ]]; then
  APP_PATH="$2"
else
  print -u2 "usage: $0 [--app path/to/now.app]"
  exit 1
fi
[[ -x "$APP_PATH/Contents/MacOS/now" ]] || { print -u2 "Missing built app: $APP_PATH"; exit 1; }
"$APP_PATH/Contents/MacOS/now" --selftest
python3 scripts/notification-smoke.py --all-smokes
python3 scripts/reminder-state-smoke.py
python3 scripts/calendar-cache-smoke.py
python3 scripts/calendar-fetch-smoke.py
python3 scripts/feed-workload-smoke.py
python3 scripts/parser-performance-smoke.py
./scripts/update-smoke.sh --app "$APP_PATH"
print "RELEASE PREFLIGHT OK"
