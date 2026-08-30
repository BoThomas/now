#!/bin/zsh
# Interactive UI review harness for the auto-updater — the GUI counterpart of
# scripts/update-smoke.sh. Serves a forged "9.9.9" release locally, resets
# update state, and launches the REAL app pointed at it. Blocks until Ctrl-C.
#
# What to try (the app never pops anything on its own — escalation requires
# 3 days; every window below opens through a click):
#   1. Wait ~12 s (launch + 10 s auto-check) → the menu dropdown gains
#      "Update to v9.9.9…" above Settings….
#   2. Click it → update window (notes, "Signature verified · ready to
#      install", Install & Relaunch = Return, Later = Esc).
#   3. Settings → General: "Check for updates automatically", "Check Now",
#      "v9.9.9 is ready to install" + Install… ; About: "v9.9.9 available".
#   4. "Check for Updates…" → same window (manual checks always answer).
#   5. Install & Relaunch → app quits, swaps, relaunches as 9.9.9 — the old
#      bundle lands in your REAL Finder Trash (that's correct here).
#   6. Afterwards: `./scripts/update-ui-demo.sh` again → Check for Updates…
#      → "You're up to date — now 9.9.9 is the latest version."
#   7. Error window (optional, without this script):
#      NOW_UPDATE_API_BASE=http://127.0.0.1:8999/ok/api \
#        outputs/now.app/Contents/MacOS/now >/dev/null 2>&1 &
#      → no server running → Check for Updates… → error + Try Again / Cancel.
#
# `./build-app.sh` afterwards restores a real build of outputs/now.app.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="outputs/now.app"
PORT=8999
SIGNING_IDENTITY_SHA1="${NOW_SIGNING_IDENTITY_SHA1:-A505B08900C56A28709479297A049525A2A187C6}"

[[ -d "$APP" ]] || { print -u2 "update-ui-demo: run ./build-app.sh first"; exit 1 }
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY_SHA1" || {
  print -u2 "update-ui-demo: stable signing identity missing — the DR gate would refuse everything."
  exit 1
}
lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && { print -u2 "update-ui-demo: port $PORT busy"; exit 1; }

# Fresh, deterministic state + no competing instance (a running copy would
# trip the multi-instance guard and steal the launch env).
defaults delete com.thomasboch.now local.tboch.now.updates.v1 2>/dev/null || true
RUNNING=$(pgrep -f "/now\.app/Contents/MacOS/now$" 2>/dev/null || true)
[[ -z "$RUNNING" ]] || { print -u2 "update-ui-demo: quit the running now first (multi-instance guard)."; exit 1; }

WORK="$(mktemp -d "${TMPDIR}now-ui-demo.XXXX")"
SRV=""
cleanup() {
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

print "• Forging 9.9.9"
mkdir -p "$WORK/www/ok/api/repos/BoThomas/now/releases" "$WORK/forge"
cp -R "$APP" "$WORK/forge/now.app"
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/forge/now.app/Contents/Info.plist")
if [[ "$V" == "9.9.9" ]]; then
  print "  (outputs/now.app is already the 9.9.9 demo build — re-run ./build-app.sh for the fresh-update flow)"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" "$WORK/forge/now.app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 999999" "$WORK/forge/now.app/Contents/Info.plist" >/dev/null
# KEEP IN SYNC with build-app.sh's codesign invocation (see update-smoke.sh too).
codesign --force --deep --sign "$SIGNING_IDENTITY_SHA1" --entitlements now.entitlements "$WORK/forge/now.app" >/dev/null 2>&1
( cd "$WORK/forge" && ditto -c -k --sequesterRsrc --keepParent now.app "$WORK/www/ok/now-v9.9.9.zip" )
SIZE=$(stat -f%z "$WORK/www/ok/now-v9.9.9.zip")
PUB=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)
cat > "$WORK/www/ok/api/repos/BoThomas/now/releases/latest" <<EOF
{"tag_name":"v9.9.9","published_at":"$PUB","body":"- Forged demo release for UI review\n- Second bullet so the notes scroll nicely if you add more lines\n\nFull changelog: https://github.com/BoThomas/now/compare/v1.4.0...v9.9.9","assets":[{"name":"now-v9.9.9.zip","browser_download_url":"http://127.0.0.1:$PORT/ok/now-v9.9.9.zip","size":$SIZE}]}
EOF

print "• Serving on 127.0.0.1:$PORT"
python3 -m http.server $PORT --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SRV=$!
for _ in {1..20}; do
  curl -sf "http://127.0.0.1:$PORT/ok/api/repos/BoThomas/now/releases/latest" >/dev/null 2>&1 && break
  sleep 0.3
done

print "• Launching the real app (update state reset, ~12 s until the menu item appears)"
NOW_UPDATE_API_BASE="http://127.0.0.1:$PORT/ok/api" "$APP/Contents/MacOS/now" >/dev/null 2>&1 &
APP_PID=$!

print ""
print "Checklist: menu item → window → Settings rows → Install & Relaunch → relaunch as 9.9.9."
print "Ctrl-C quits the app and the server. See the header of this script for the full tour."
wait $SRV
