#!/bin/zsh
# End-to-end update smoke test — fully local, no GitHub, no real releases.
#
# Exercises the REAL updater path against a forged "9.9.9" release served by
# a local HTTP server: check → download → ditto-extract → signature gate →
# swap helper → relaunch (the relaunched child reports its version through
# NOW_SMOKE_REPORT and exits). Plus negative variants: tampered (ad-hoc
# re-signed) zip must be REFUSED, an older tag/404 must read as up-to-date,
# and a stuck quit must leave everything untouched.
#
# The test install lives at a path CONTAINING A SPACE (cheapest possible
# quoting-bug net for the shell helper), and the helper's HOME is sandboxed
# so the trashed old bundle never touches the developer's real ~/.Trash.
#
# NOTE: this test requires the stable "now Developer" signing identity —
# an ad-hoc build cannot pass the pinned-DR gate (by design).
#
# Usage: ./scripts/update-smoke.sh [--app outputs/now.app]
#   --app  reuse an already-built app instead of running ./build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_PATH="${2:?}"; shift ;;
    *) print -u2 "usage: $0 [--app path/to/now.app]"; exit 1 ;;
  esac
  shift
done

SIGNING_IDENTITY_SHA1="${NOW_SIGNING_IDENTITY_SHA1:-A505B08900C56A28709479297A049525A2A187C6}"
security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY_SHA1" || {
  print -u2 "update-smoke: stable signing identity $SIGNING_IDENTITY_SHA1 not found —"
  print -u2 "              the updater's pinned-DR gate cannot pass with ad-hoc signing (by design)."
  exit 1
}

if [[ -n "$APP_PATH" ]]; then
  [[ -d "$APP_PATH" ]] || { print -u2 "update-smoke: no app at $APP_PATH"; exit 1 }
  print "• Using existing app: $APP_PATH"
else
  print "• Building"
  ./build-app.sh >/dev/null
  APP_PATH="outputs/now.app"
fi

WORK="$(mktemp -d "${TMPDIR}now update test.XXXXXX")"   # note the space — on purpose
SERVER_PID=""
declare -a REOPEN_AFTER=()

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
  for path in "${REOPEN_AFTER[@]:-}"; do
    [[ -n "$path" ]] && open "$path" 2>/dev/null || true
  done
}
trap cleanup EXIT

fail() { print -u2 "update-smoke: $*"; exit 1 }

# The updater's multi-instance guard (and LaunchServices) get confused by a
# running copy of now with the same bundle id — quit it for the test and
# re-open the same paths afterwards.
print "• Checking for running now instances"
RUNNING=$(pgrep -f "/now\.app/Contents/MacOS/now$" 2>/dev/null || true)
if [[ -n "$RUNNING" ]]; then
  for pid in ${(f)RUNNING}; do
    app_path=$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt" && $9 ~ /\/now\.app\/Contents\/MacOS\/now$/ {print $9; exit}')
    if [[ -n "$app_path" ]]; then REOPEN_AFTER+=("${app_path%/Contents/MacOS/now}") ; fi
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  print "  (quit ${#REOPEN_AFTER} running instance(s); will re-open after the test)"
fi

version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" }

print "• Installing test copy (path contains a space: $WORK)"
mkdir -p "$WORK/home/.Trash"
cp -R "$APP_PATH" "$WORK/now.app"
ORIG_VERSION=$(version_of "$WORK/now.app")
[[ "$ORIG_VERSION" == "9.9.9" ]] && fail "the provided app is already 9.9.9 — forge a different version"

forge() {
  # $1 = destination zip path, $2 = version, $3 = build
  local dest="$1" version="$2" build="$3"
  rm -rf "$WORK/forge"
  mkdir -p "$WORK/forge"
  cp -R "$APP_PATH" "$WORK/forge/now.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$WORK/forge/now.app/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$WORK/forge/now.app/Contents/Info.plist" >/dev/null
  # KEEP IN SYNC with build-app.sh's codesign invocation (flags, entitlements,
  # fingerprint) — they WILL drift otherwise.
  codesign --force --deep --sign "$SIGNING_IDENTITY_SHA1" --entitlements now.entitlements "$WORK/forge/now.app" >/dev/null 2>&1
  mkdir -p "$(dirname "$dest")"
  ( cd "$WORK/forge" && ditto -c -k --sequesterRsrc --keepParent now.app "$dest" )
}

print "• Forging releases"
mkdir -p "$WORK/www"
forge "$WORK/www/ok/now-v9.9.9.zip" 9.9.9 999999
GOOD_SIZE=$(stat -f%z "$WORK/www/ok/now-v9.9.9.zip")
# Tampered: re-sign AD-HOC (valid signature, wrong anchor — the "attacker
# re-signed it with their own key" case). Must fail the pinned-DR gate.
# (Appending bytes to the Mach-O instead just makes codesign refuse with
# "strict validation" — not a signable tamper.)
forge "$WORK/www/bad/now-v9.9.9.zip" 9.9.9 999999
codesign --force --deep --sign - "$WORK/forge/now.app" >/dev/null 2>&1
( cd "$WORK/forge" && ditto -c -k --sequesterRsrc --keepParent now.app "$WORK/www/bad/now-v9.9.9.zip" )
BAD_SIZE=$(stat -f%z "$WORK/www/bad/now-v9.9.9.zip")
# Older tag: content irrelevant (decision happens before download).
cp "$WORK/www/ok/now-v9.9.9.zip" "$WORK/www/old/now-v0.0.1.zip" 2>/dev/null || { mkdir -p "$WORK/www/old"; cp "$WORK/www/ok/now-v9.9.9.zip" "$WORK/www/old/now-v0.0.1.zip"; }

PUBLISHED=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)   # 2 days old: past the age gate
make_latest() {
  # $1 = base dir under www, $2 = tag, $3 = asset name, $4 = asset size
  local dir="$WORK/www/$1/api/repos/BoThomas/now/releases"
  mkdir -p "$dir"
  cat > "$dir/latest" <<EOF
{"tag_name":"$2","published_at":"$PUBLISHED","body":"- Forged smoke release\n\nFull changelog: https://github.com/BoThomas/now/compare/x","assets":[{"name":"$3","browser_download_url":"http://127.0.0.1:PORT/$1/$3","size":$4}]}
EOF
}
make_latest ok v9.9.9 now-v9.9.9.zip "$GOOD_SIZE"
make_latest bad v9.9.9 now-v9.9.9.zip "$BAD_SIZE"
make_latest old v0.0.1 now-v0.0.1.zip "$GOOD_SIZE"

print "• Starting local server"
PORT=""
for _ in {1..20}; do
  CANDIDATE=$(( (RANDOM % 2000) + 8000 ))
  python3 -m http.server "$CANDIDATE" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
  SERVER_PID=$!
  sleep 0.4
  if curl -sf "http://127.0.0.1:$CANDIDATE/ok/api/repos/BoThomas/now/releases/latest" >/dev/null 2>&1; then
    PORT=$CANDIDATE
    break
  fi
  kill "$SERVER_PID" 2>/dev/null || true
done
[[ -n "$PORT" ]] || fail "could not start local server"
# Bake the real port into the asset URLs.
for f in "$WORK/www/ok/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/bad/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/old/api/repos/BoThomas/now/releases/latest"; do
  sed -i '' "s/127.0.0.1:PORT/127.0.0.1:$PORT/" "$f"
done
print "  http://127.0.0.1:$PORT"

run_smoke() {
  # $1 = base path segment (ok/bad/old/missing); the updater appends
  # /repos/:repo/releases/latest to the base, so each scenario's base is
  # http://…/<segment>/api — matching the www/<segment>/api file layout.
  local segment="$1"; shift
  env NOW_UPDATE_API_BASE="http://127.0.0.1:$PORT/$segment/api" \
      NOW_UPDATE_REPO="BoThomas/now" \
      NOW_SMOKE_HOME="$WORK/home" \
      "$@" \
      "$WORK/now.app/Contents/MacOS/now" --update-smoke
}

reset_install() {
  rm -rf "$WORK/now.app"
  cp -R "$APP_PATH" "$WORK/now.app"
}

print "• [1/5] Positive: forge → check → stage → swap → relaunch"
rm -f "$WORK/report"
run_smoke ok NOW_SMOKE_REPORT="$WORK/report" | tee "$WORK/log1"
grep -q "SMOKE: INSTALLED v9.9.9" "$WORK/log1" || fail "positive run did not reach install"
for _ in {1..60}; do
  [[ -f "$WORK/report" ]] && break
  sleep 0.5
done
[[ -f "$WORK/report" ]] || fail "relaunched child never reported (timeout 30s)"
[[ "$(cat "$WORK/report")" == "9.9.9" ]] || fail "child reported $(cat "$WORK/report"), want 9.9.9"
[[ "$(version_of "$WORK/now.app")" == "9.9.9" ]] || fail "install path still at $(version_of "$WORK/now.app")"
TRASHED=("$WORK/home/.Trash/"now-old-*.app(N))
[[ ${#TRASHED} -eq 1 ]] || fail "expected exactly one trashed backup, found ${#TRASHED}"
STAGING_LEFT=("$WORK/".now-update-*(N))
[[ ${#STAGING_LEFT} -eq 0 ]] || fail "staging dir not cleaned by relaunched child"
BACKUP_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#BACKUP_LEFT} -eq 0 ]] || fail "stray now.app.old-* backup left behind"
print "  OK — updated to 9.9.9, old bundle trashed, staging clean"

print "• [2/5] Negative: tampered (ad-hoc) zip must be refused"
reset_install
set +e
run_smoke bad NOW_SMOKE_REPORT="$WORK/report2" > "$WORK/log2" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "tampered zip: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log2")"
grep -q "SMOKE: REFUSED .*signed with a trusted identity" "$WORK/log2" || fail "tampered zip refused for the wrong reason: $(cat "$WORK/log2")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "tampered zip modified the install"
print "  OK — refused at the signature gate, install untouched"

print "• [3/5] Negative: older tag reads as up-to-date"
set +e
run_smoke old > "$WORK/log3" 2>&1
RC=$?
set -e
[[ $RC -eq 3 ]] || fail "older tag: expected exit 3 (UPTODATE), got $RC: $(cat "$WORK/log3")"
grep -q "SMOKE: UPTODATE" "$WORK/log3" || fail "older tag not reported as up-to-date"
print "  OK — no downgrade offered"

print "• [4/5] Negative: 404 (no releases) reads as up-to-date"
set +e
run_smoke missing > "$WORK/log4" 2>&1
RC=$?
set -e
[[ $RC -eq 3 ]] || fail "404: expected exit 3 (UPTODATE), got $RC: $(cat "$WORK/log4")"
print "  OK — 404 is up-to-date, not an error"

print "• [5/5] Negative: stuck quit — helper must bail, nothing moved"
reset_install
set +e
run_smoke ok NOW_SMOKE_POLL_TIMEOUT=3 NOW_SMOKE_SKIP_QUIT=1 > "$WORK/log5" 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "stuck quit: expected exit 0, got $RC: $(cat "$WORK/log5")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "stuck quit changed the install"
TRASHED2=("$WORK/home/.Trash/"now-old-*.app(N))
[[ ${#TRASHED2} -eq 1 ]] || fail "stuck quit trashed/moved a bundle (${#TRASHED2} backups after reset)"
print "  OK — helper bailed, app untouched"

print ""
print "UPDATE SMOKE OK — swap, signature gate, age/downgrade guards, stuck-quit all verified"
