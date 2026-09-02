#!/bin/zsh
# End-to-end update smoke test — fully local, no GitHub, no real releases.
#
# Exercises the REAL updater path against a dynamically newer release served by
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
typeset -A REOPEN_SEEN

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
  for path in "${REOPEN_AFTER[@]:-}"; do
    [[ -n "$path" ]] && open "$path" 2>/dev/null || true
  done
}
trap cleanup EXIT

fail() { print -u2 "update-smoke: $*"; exit 1 }

executable_path() {
  local pid="$1" line
  while IFS= read -r line; do
    [[ "$line" == n* ]] || continue
    print -r -- "${line#n}"
    return 0
  done < <(lsof -a -p "$pid" -d txt -Fn 2>/dev/null)
  return 1
}

# The updater's multi-instance guard (and LaunchServices) get confused by a
# running copy of now with the same bundle id — quit it for the test and
# re-open the same paths afterwards.
print "• Checking for running now instances"
RUNNING=$(pgrep -x now 2>/dev/null || true)
if [[ -n "$RUNNING" ]]; then
  for pid in ${(f)RUNNING}; do
    app_path=$(executable_path "$pid" || true)
    [[ "$app_path" == */now.app/Contents/MacOS/now ]] || continue
    bundle_path="${app_path%/Contents/MacOS/now}"
    if [[ -z "${REOPEN_SEEN[$bundle_path]-}" ]]; then
      REOPEN_AFTER+=("$bundle_path")
      REOPEN_SEEN[$bundle_path]=1
    fi
    kill "$pid" 2>/dev/null || true
    STOPPED=false
    for _ in {1..50}; do
      if ! kill -0 "$pid" 2>/dev/null; then STOPPED=true; break; fi
      sleep 0.1
    done
    $STOPPED || fail "running app at $bundle_path did not exit after SIGTERM"
  done
  print "  (quit ${#REOPEN_AFTER} running instance(s); will re-open after the test)"
fi

version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" }

print "• Installing test copy (path contains a space: $WORK)"
mkdir -p "$WORK/home/.Trash"
cp -R "$APP_PATH" "$WORK/now.app"
ORIG_VERSION=$(version_of "$WORK/now.app")
[[ "$ORIG_VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || fail "unsupported app version: $ORIG_VERSION"
VERSION_PARTS=( ${(s:.:)ORIG_VERSION} )
SMOKE_VERSION="$((VERSION_PARTS[1] + 1)).0.0"
ORIG_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$WORK/now.app/Contents/Info.plist")
[[ "$ORIG_BUILD" =~ '^[0-9]+$' ]] || fail "unsupported app build: $ORIG_BUILD"
SMOKE_BUILD=$((ORIG_BUILD + 1))
SMOKE_ASSET="now-v$SMOKE_VERSION.zip"

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
forge "$WORK/www/ok/$SMOKE_ASSET" "$SMOKE_VERSION" "$SMOKE_BUILD"
GOOD_SIZE=$(stat -f%z "$WORK/www/ok/$SMOKE_ASSET")
# Tampered: re-sign AD-HOC (valid signature, wrong anchor — the "attacker
# re-signed it with their own key" case). Must fail the pinned-DR gate.
# (Appending bytes to the Mach-O instead just makes codesign refuse with
# "strict validation" — not a signable tamper.)
forge "$WORK/www/bad/$SMOKE_ASSET" "$SMOKE_VERSION" "$SMOKE_BUILD"
codesign --force --deep --sign - "$WORK/forge/now.app" >/dev/null 2>&1
( cd "$WORK/forge" && ditto -c -k --sequesterRsrc --keepParent now.app "$WORK/www/bad/$SMOKE_ASSET" )
BAD_SIZE=$(stat -f%z "$WORK/www/bad/$SMOKE_ASSET")
# Older tag: content irrelevant (decision happens before download).
cp "$WORK/www/ok/$SMOKE_ASSET" "$WORK/www/old/now-v0.0.1.zip" 2>/dev/null || { mkdir -p "$WORK/www/old"; cp "$WORK/www/ok/$SMOKE_ASSET" "$WORK/www/old/now-v0.0.1.zip"; }

PUBLISHED=$(date -u -v-2d +%Y-%m-%dT%H:%M:%SZ)   # 2 days old: past the age gate
make_latest() {
  # $1 = base dir under www, $2 = tag, $3 = asset name, $4 = asset size
  local dir="$WORK/www/$1/api/repos/BoThomas/now/releases"
  mkdir -p "$dir"
  cat > "$dir/latest" <<EOF
{"tag_name":"$2","published_at":"$PUBLISHED","body":"- Forged smoke release\n\nFull changelog: https://github.com/BoThomas/now/compare/x","assets":[{"name":"$3","browser_download_url":"http://127.0.0.1:PORT/$1/$3","size":$4}]}
EOF
}
make_latest ok "v$SMOKE_VERSION" "$SMOKE_ASSET" "$GOOD_SIZE"
make_latest bad "v$SMOKE_VERSION" "$SMOKE_ASSET" "$BAD_SIZE"
make_latest old v0.0.1 now-v0.0.1.zip "$GOOD_SIZE"
make_latest oversize "v$SMOKE_VERSION" "$SMOKE_ASSET" 1
cp "$WORK/www/ok/$SMOKE_ASSET" "$WORK/www/oversize/$SMOKE_ASSET"
make_latest mismatch "v$SMOKE_VERSION" "$SMOKE_ASSET" "$((GOOD_SIZE + 1))"
cp "$WORK/www/ok/$SMOKE_ASSET" "$WORK/www/mismatch/$SMOKE_ASSET"
make_latest asset404 "v$SMOKE_VERSION" "$SMOKE_ASSET" "$GOOD_SIZE"

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
         "$WORK/www/old/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/oversize/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/mismatch/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/asset404/api/repos/BoThomas/now/releases/latest"; do
  sed -i '' "s/127.0.0.1:PORT/127.0.0.1:$PORT/" "$f"
done
print "  http://127.0.0.1:$PORT"

run_smoke() {
  # $1 = base path segment (ok/bad/old/missing); the updater appends
  # /repos/:repo/releases/latest to the base, so each scenario's base is
  # http://…/<segment>/api — matching the www/<segment>/api file layout.
  local segment="$1"; shift
  env -u NOW_SMOKE_REPORT -u NOW_SMOKE_FAILURE_REPORT -u NOW_SMOKE_HOME \
      -u NOW_SMOKE_POLL_TIMEOUT -u NOW_SMOKE_HEALTH_TIMEOUT -u NOW_SMOKE_HELPER_FAULT -u NOW_SMOKE_HELPER_DONE \
      -u NOW_SMOKE_ARCHIVE_LIMIT -u NOW_SMOKE_EXTRACTED_LIMIT -u NOW_SMOKE_SKIP_QUIT \
      NOW_UPDATE_API_BASE="http://127.0.0.1:$PORT/$segment/api" \
      NOW_UPDATE_REPO="BoThomas/now" \
      NOW_SMOKE_HOME="$WORK/home" \
      "$@" \
      "$WORK/now.app/Contents/MacOS/now" --update-smoke
}

reset_install() {
  rm -rf "$WORK/now.app"
  cp -R "$APP_PATH" "$WORK/now.app"
}

wait_for_file() {
  local file="$1" label="$2"
  for _ in {1..60}; do
    [[ -f "$file" ]] && return 0
    sleep 0.5
  done
  fail "$label (timeout 30s)"
}

print "• [1/13] Positive: forge → check → stage → swap → exact startup health acknowledgement"
rm -f "$WORK/report" "$WORK/helper-done"
run_smoke ok NOW_SMOKE_REPORT="$WORK/report" NOW_SMOKE_HELPER_DONE="$WORK/helper-done" | tee "$WORK/log1"
grep -q "SMOKE: INSTALLED v$SMOKE_VERSION" "$WORK/log1" || fail "positive run did not reach install"
wait_for_file "$WORK/report" "relaunched child never reported"
wait_for_file "$WORK/helper-done" "install helper never completed"
[[ "$(cat "$WORK/report")" == "$SMOKE_VERSION" ]] || fail "child reported $(cat "$WORK/report"), want $SMOKE_VERSION"
[[ "$(version_of "$WORK/now.app")" == "$SMOKE_VERSION" ]] || fail "install path still at $(version_of "$WORK/now.app")"
TRASHED=("$WORK/home/.Trash/"now-old-*.app(N))
[[ ${#TRASHED} -eq 1 ]] || fail "expected exactly one trashed backup, found ${#TRASHED}"
STAGING_LEFT=("$WORK/".now-update-*(N))
[[ ${#STAGING_LEFT} -eq 0 ]] || fail "staging dir not cleaned by relaunched child"
BACKUP_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#BACKUP_LEFT} -eq 0 ]] || fail "stray now.app.old-* backup left behind"
print "  OK — updated to $SMOKE_VERSION, old bundle trashed, staging clean"

print "• [2/13] Negative: tampered (ad-hoc) zip must be refused"
reset_install
set +e
run_smoke bad NOW_SMOKE_REPORT="$WORK/report2" > "$WORK/log2" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "tampered zip: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log2")"
grep -q "SMOKE: REFUSED .*signed with a trusted identity" "$WORK/log2" || fail "tampered zip refused for the wrong reason: $(cat "$WORK/log2")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "tampered zip modified the install"
print "  OK — refused at the signature gate, install untouched"

print "• [3/13] Negative: older tag reads as up-to-date"
set +e
run_smoke old > "$WORK/log3" 2>&1
RC=$?
set -e
[[ $RC -eq 3 ]] || fail "older tag: expected exit 3 (UPTODATE), got $RC: $(cat "$WORK/log3")"
grep -q "SMOKE: UPTODATE" "$WORK/log3" || fail "older tag not reported as up-to-date"
print "  OK — no downgrade offered"

print "• [4/13] Negative: 404 (no releases) reads as up-to-date"
set +e
run_smoke missing > "$WORK/log4" 2>&1
RC=$?
set -e
[[ $RC -eq 3 ]] || fail "404: expected exit 3 (UPTODATE), got $RC: $(cat "$WORK/log4")"
print "  OK — 404 is up-to-date, not an error"

print "• [5/13] Negative: streaming archive cap stops a lying response"
reset_install
set +e
run_smoke oversize NOW_SMOKE_ARCHIVE_LIMIT=65536 > "$WORK/log5" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "oversize response: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log5")"
grep -q "SMOKE: REFUSED update archive larger than" "$WORK/log5" || fail "oversize response refused for the wrong reason: $(cat "$WORK/log5")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "oversize response modified the install"
print "  OK — response stopped at the streaming byte limit"

print "• [6/13] Negative: downloaded size must match the release manifest"
reset_install
set +e
run_smoke mismatch > "$WORK/log6" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "size mismatch: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log6")"
grep -q "SMOKE: REFUSED download size .* expected" "$WORK/log6" || fail "size mismatch refused for the wrong reason: $(cat "$WORK/log6")"
print "  OK — mismatched asset size refused"

print "• [7/13] Negative: missing asset download must be an error"
reset_install
set +e
run_smoke asset404 > "$WORK/log7" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "asset 404: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log7")"
grep -q "SMOKE: REFUSED download returned 404" "$WORK/log7" || fail "asset 404 refused for the wrong reason: $(cat "$WORK/log7")"
print "  OK — missing release asset refused"

print "• [8/13] Negative: old→backup failure reports and leaves old app intact"
reset_install
rm -f "$WORK/failure-backup"
run_smoke ok NOW_SMOKE_HELPER_FAULT=backup NOW_SMOKE_FAILURE_REPORT="$WORK/failure-backup" > "$WORK/log8" 2>&1
wait_for_file "$WORK/failure-backup" "backup-failure child never reported"
[[ "$(cat "$WORK/failure-backup")" == "$ORIG_VERSION|backup move failed" ]] || fail "unexpected backup-failure report: $(cat "$WORK/failure-backup")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "backup failure changed the install"
[[ ! -d "$WORK/now.app/now.app" ]] || fail "backup failure nested staged app inside old bundle"
BACKUP_FAILURE_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#BACKUP_FAILURE_LEFT} -eq 0 ]] || fail "backup failure left a backup bundle"
print "  OK — old app relaunched with the backup failure"

print "• [9/13] Negative: post-swap relaunch failure restores old app"
reset_install
rm -f "$WORK/failure-relaunch"
run_smoke ok NOW_SMOKE_HELPER_FAULT=relaunch NOW_SMOKE_FAILURE_REPORT="$WORK/failure-relaunch" > "$WORK/log9" 2>&1
wait_for_file "$WORK/failure-relaunch" "relaunch-failure child never reported"
[[ "$(cat "$WORK/failure-relaunch")" == "$ORIG_VERSION|relaunch failed" ]] || fail "unexpected relaunch-failure report: $(cat "$WORK/failure-relaunch")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "relaunch failure did not restore old app"
RELAUNCH_BACKUP_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#RELAUNCH_BACKUP_LEFT} -eq 0 ]] || fail "relaunch failure left a backup bundle"
print "  OK — new app removed, old app restored and relaunched with the error"

print "• [10/13] Negative: unacknowledged child exit restores old app before Trash"
reset_install
rm -f "$WORK/failure-health-exit" "$WORK/unhealthy-child"
run_smoke ok NOW_SMOKE_HELPER_FAULT=health NOW_SMOKE_REPORT="$WORK/unhealthy-child" NOW_SMOKE_FAILURE_REPORT="$WORK/failure-health-exit" > "$WORK/log10" 2>&1
wait_for_file "$WORK/failure-health-exit" "health-exit rollback child never reported"
[[ "$(cat "$WORK/failure-health-exit")" == "$ORIG_VERSION|updated app exited before startup health check" ]] || fail "unexpected health-exit report: $(cat "$WORK/failure-health-exit")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "health-exit failure did not restore old app"
HEALTH_BACKUP_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#HEALTH_BACKUP_LEFT} -eq 0 ]] || fail "health-exit failure left a backup bundle"
TRASHED_HEALTH=("$WORK/home/.Trash/"now-old-*.app(N))
[[ ${#TRASHED_HEALTH} -eq 1 ]] || fail "health-exit failure trashed the rollback backup"
print "  OK — unacknowledged child exit restored and relaunched the old app"

print "• [11/13] Negative: startup health timeout restores old app before Trash"
reset_install
rm -f "$WORK/failure-health-timeout"
run_smoke ok NOW_SMOKE_HELPER_FAULT=health NOW_SMOKE_HEALTH_TIMEOUT=3 NOW_SMOKE_FAILURE_REPORT="$WORK/failure-health-timeout" > "$WORK/log11" 2>&1
wait_for_file "$WORK/failure-health-timeout" "health-timeout rollback child never reported"
[[ "$(cat "$WORK/failure-health-timeout")" == "$ORIG_VERSION|updated app startup health check timed out" ]] || fail "unexpected health-timeout report: $(cat "$WORK/failure-health-timeout")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "health timeout did not restore old app"
HEALTH_TIMEOUT_BACKUP_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#HEALTH_TIMEOUT_BACKUP_LEFT} -eq 0 ]] || fail "health timeout left a backup bundle"
TRASHED_HEALTH_TIMEOUT=("$WORK/home/.Trash/"now-old-*.app(N))
[[ ${#TRASHED_HEALTH_TIMEOUT} -eq 1 ]] || fail "health timeout trashed the rollback backup"
print "  OK — missing acknowledgement timed out, restored, and relaunched the old app"

print "• [12/13] Negative: stuck quit — helper must bail, nothing moved"
reset_install
rm -f "$WORK/stuck-done"
set +e
run_smoke ok NOW_SMOKE_POLL_TIMEOUT=3 NOW_SMOKE_SKIP_QUIT=1 NOW_SMOKE_HELPER_DONE="$WORK/stuck-done" > "$WORK/log12" 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "stuck quit: expected exit 0, got $RC: $(cat "$WORK/log12")"
wait_for_file "$WORK/stuck-done" "stuck-quit helper never completed"
[[ "$(cat "$WORK/stuck-done")" == "timeout" ]] || fail "stuck-quit helper did not report timeout"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "stuck quit changed the install"
TRASHED2=("$WORK/home/.Trash/"now-old-*.app(N))
[[ ${#TRASHED2} -eq 1 ]] || fail "stuck quit trashed/moved a bundle (${#TRASHED2} backups after reset)"
STUCK_STAGING_LEFT=("$WORK/".now-update-*(N))
[[ ${#STUCK_STAGING_LEFT} -eq 0 ]] || fail "stuck quit left staging artifacts"
print "  OK — helper bailed, app untouched"

print "• [13/13] Stale NOW_UPDATE_ERROR must not reach the updated child"
# A failed install relaunches the old app with NOW_UPDATE_ERROR in its
# environment; that process's next install helper inherits the variable
# (spawnHelper passes the environment through). The success relaunch must
# strip it — otherwise the updated app processes the old failure at launch
# and reports the successful retry as another failure.
reset_install
rm -f "$WORK/report13" "$WORK/helper-done13"
run_smoke ok NOW_UPDATE_ERROR="stale from a failed install" NOW_SMOKE_REPORT="$WORK/report13" NOW_SMOKE_HELPER_DONE="$WORK/helper-done13" > "$WORK/log13" 2>&1
grep -q "SMOKE: INSTALLED v$SMOKE_VERSION" "$WORK/log13" || fail "stale-error run did not reach install: $(cat "$WORK/log13")"
wait_for_file "$WORK/report13" "relaunched child never reported (stale-error case)"
[[ "$(cat "$WORK/report13")" == "$SMOKE_VERSION" ]] || fail "updated child inherited a stale failure env: $(cat "$WORK/report13")"
[[ "$(version_of "$WORK/now.app")" == "$SMOKE_VERSION" ]] || fail "stale-error install did not complete"
wait_for_file "$WORK/helper-done13" "stale-error helper never completed"
print "  OK — updated child launched without the stale failure environment"

print ""
print "UPDATE SMOKE OK — health-gated swap, signature/streaming gates, downgrade/404, rollback, stuck-quit, and stale-error-env verified"
