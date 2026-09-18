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

# Validate the supplied shipping artifact, then exercise the same updater code
# with the explicit headless/fault runner. Test builds never replace release output.
codesign --verify --deep --strict "$APP_PATH"
./build-app.sh --require-identity --release --test-updater
APP_PATH="outputs/testing/release/now.app"

WORK="$(mktemp -d "${TMPDIR}now update test.XXXXXX")"   # note the space — on purpose
export NOW_TEST_PREFERENCES_DOMAIN="com.thomasboch.now.updater-smoke.$(uuidgen)"
export NOW_TEST_CACHE_ROOT="$WORK/cache"
SERVER_PID=""
MUTATION_PID=""
declare -a REOPEN_AFTER=()
typeset -A REOPEN_SEEN

cleanup() {
  # The staging handoff can fail while its CLI is still waiting. Stop and reap
  # that exact child before deleting its files or reopening the installed app.
  if [[ -n "$MUTATION_PID" ]]; then
    kill "$MUTATION_PID" 2>/dev/null || true
    wait "$MUTATION_PID" 2>/dev/null || true
  fi
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  defaults delete "$NOW_TEST_PREFERENCES_DOMAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  # NB: never name this loop variable "path" — in zsh that array is tied to
  # $PATH, and assigning it would break every subsequent command lookup
  # (including this very `open`, which `|| true` would then swallow).
  for app in "${REOPEN_AFTER[@]:-}"; do
    [[ -n "$app" ]] && /usr/bin/open "$app" 2>/dev/null || true
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
  # $1 = base dir under www, $2 = tag, $3 = asset name, $4 = asset size,
  # $5 = optional release body (default: the generic forged one)
  local dir="$WORK/www/$1/api/repos/BoThomas/now/releases"
  mkdir -p "$dir"
  local body="${5:-- Forged smoke release\n\nFull changelog: https://github.com/BoThomas/now/compare/x}"
  cat > "$dir/latest" <<EOF
{"tag_name":"$2","published_at":"$PUBLISHED","body":"$body","assets":[{"name":"$3","browser_download_url":"http://127.0.0.1:PORT/$1/$3","size":$4}]}
EOF
}
# Multi-version jump: an intermediate release sits between the installed and
# target versions. Bodies forge the recognized changelog categories so the
# consolidated What's-New merge can be asserted end to end. The list is served
# as `releases/index.html`: python http.server answers `/releases` with a 301
# to `/releases/` (allowed — same loopback host) which then serves index.html,
# while `/releases/latest` stays the file inside the same directory.
INTERMEDIATE_VERSION="$((VERSION_PARTS[1])).$((VERSION_PARTS[2] + 1)).0"
make_releases_list() {
  # $1 = base dir under www; list is newest-first, like the GitHub API
  local dir="$WORK/www/$1/api/repos/BoThomas/now/releases"
  mkdir -p "$dir"
  cat > "$dir/index.html" <<EOF
[{"tag_name":"v$SMOKE_VERSION","body":"### Added\n- Target release feature\n\nFull changelog: https://github.com/BoThomas/now/compare/x"},
{"tag_name":"v$INTERMEDIATE_VERSION","body":"### Fixed\n- Intermediate release fix"},
{"tag_name":"v$ORIG_VERSION","body":"- Already installed"},
{"tag_name":"v0.0.1","body":"- Ancient"}]
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
# Consolidated notes succeed against `multi`; `multi404` serves no releases
# list (404 → fallback), while the latest manifest still installs fine.
make_latest multi "v$SMOKE_VERSION" "$SMOKE_ASSET" "$GOOD_SIZE" "### Added\n- Target release feature\n\nFull changelog: https://github.com/BoThomas/now/compare/x"
cp "$WORK/www/ok/$SMOKE_ASSET" "$WORK/www/multi/$SMOKE_ASSET"
make_releases_list multi
make_latest multi404 "v$SMOKE_VERSION" "$SMOKE_ASSET" "$GOOD_SIZE"
cp "$WORK/www/ok/$SMOKE_ASSET" "$WORK/www/multi404/$SMOKE_ASSET"

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
         "$WORK/www/asset404/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/multi/api/repos/BoThomas/now/releases/latest" \
         "$WORK/www/multi404/api/repos/BoThomas/now/releases/latest"; do
  sed -i '' "s/127.0.0.1:PORT/127.0.0.1:$PORT/" "$f"
done
print "  http://127.0.0.1:$PORT"

run_smoke() {
  # In a background handoff, exec makes $! the CLI PID instead of a wrapper.
  local -a launcher=()
  if [[ "$1" == --exec ]]; then launcher=(exec); shift; fi
  # $1 = base path segment (ok/bad/old/missing); the updater appends
  # /repos/:repo/releases/latest to the base, so each scenario's base is
  # http://…/<segment>/api — matching the www/<segment>/api file layout.
  local segment="$1"; shift
  "${launcher[@]}" env -u NOW_SMOKE_REPORT -u NOW_SMOKE_FAILURE_REPORT -u NOW_SMOKE_HOME \
      -u NOW_SMOKE_POLL_TIMEOUT -u NOW_SMOKE_HEALTH_TIMEOUT -u NOW_SMOKE_HELPER_FAULT -u NOW_SMOKE_HELPER_DONE \
      -u NOW_SMOKE_ARCHIVE_LIMIT -u NOW_SMOKE_EXTRACTED_LIMIT -u NOW_SMOKE_SKIP_QUIT \
      -u NOW_SMOKE_STAGE_READY -u NOW_SMOKE_STAGE_CONTINUE \
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

print "• [1/16] Positive: forge → check → stage → swap → exact startup health acknowledgement"
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

print "• [2/16] Negative: tampered (ad-hoc) zip must be refused"
reset_install
set +e
run_smoke bad NOW_SMOKE_REPORT="$WORK/report2" > "$WORK/log2" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "tampered zip: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log2")"
grep -q "SMOKE: REFUSED .*signed with a trusted identity" "$WORK/log2" || fail "tampered zip refused for the wrong reason: $(cat "$WORK/log2")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "tampered zip modified the install"
print "  OK — refused at the signature gate, install untouched"

print "• [3/16] Negative: older tag reads as up-to-date"
set +e
run_smoke old > "$WORK/log3" 2>&1
RC=$?
set -e
[[ $RC -eq 3 ]] || fail "older tag: expected exit 3 (UPTODATE), got $RC: $(cat "$WORK/log3")"
grep -q "SMOKE: UPTODATE" "$WORK/log3" || fail "older tag not reported as up-to-date"
print "  OK — no downgrade offered"

print "• [4/16] Negative: 404 (no releases) reads as up-to-date"
set +e
run_smoke missing > "$WORK/log4" 2>&1
RC=$?
set -e
[[ $RC -eq 3 ]] || fail "404: expected exit 3 (UPTODATE), got $RC: $(cat "$WORK/log4")"
print "  OK — 404 is up-to-date, not an error"

print "• [5/16] Negative: streaming archive cap stops a lying response"
reset_install
set +e
run_smoke oversize NOW_SMOKE_ARCHIVE_LIMIT=65536 > "$WORK/log5" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "oversize response: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log5")"
grep -q "SMOKE: REFUSED update archive larger than" "$WORK/log5" || fail "oversize response refused for the wrong reason: $(cat "$WORK/log5")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "oversize response modified the install"
print "  OK — response stopped at the streaming byte limit"

print "• [6/16] Negative: downloaded size must match the release manifest"
reset_install
set +e
run_smoke mismatch > "$WORK/log6" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "size mismatch: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log6")"
grep -q "SMOKE: REFUSED download size .* expected" "$WORK/log6" || fail "size mismatch refused for the wrong reason: $(cat "$WORK/log6")"
print "  OK — mismatched asset size refused"

print "• [7/16] Negative: missing asset download must be an error"
reset_install
set +e
run_smoke asset404 > "$WORK/log7" 2>&1
RC=$?
set -e
[[ $RC -eq 2 ]] || fail "asset 404: expected exit 2 (REFUSED), got $RC: $(cat "$WORK/log7")"
grep -q "SMOKE: REFUSED download returned 404" "$WORK/log7" || fail "asset 404 refused for the wrong reason: $(cat "$WORK/log7")"
print "  OK — missing release asset refused"

print "• [8/16] Negative: old→backup failure reports and leaves old app intact"
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

print "• [9/16] Negative: post-swap relaunch failure restores old app"
reset_install
rm -f "$WORK/failure-relaunch"
run_smoke ok NOW_SMOKE_HELPER_FAULT=relaunch NOW_SMOKE_FAILURE_REPORT="$WORK/failure-relaunch" > "$WORK/log9" 2>&1
wait_for_file "$WORK/failure-relaunch" "relaunch-failure child never reported"
[[ "$(cat "$WORK/failure-relaunch")" == "$ORIG_VERSION|relaunch failed" ]] || fail "unexpected relaunch-failure report: $(cat "$WORK/failure-relaunch")"
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "relaunch failure did not restore old app"
RELAUNCH_BACKUP_LEFT=("$WORK/"now.app.old-*(N))
[[ ${#RELAUNCH_BACKUP_LEFT} -eq 0 ]] || fail "relaunch failure left a backup bundle"
print "  OK — new app removed, old app restored and relaunched with the error"

print "• [10/16] Negative: unacknowledged child exit restores old app before Trash"
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

print "• [11/16] Negative: startup health timeout restores old app before Trash"
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

print "• [12/16] Negative: stuck quit — helper must bail, nothing moved"
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

print "• [13/16] Stale NOW_UPDATE_ERROR must not reach the updated child"
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

print "• [14/16] Multi-version jump consolidates intermediate release notes"
reset_install
rm -f "$WORK/report14" "$WORK/helper-done14"
run_smoke multi NOW_SMOKE_REPORT="$WORK/report14" NOW_SMOKE_HELPER_DONE="$WORK/helper-done14" > "$WORK/log14" 2>&1
grep -q "SMOKE: NOTES consolidated" "$WORK/log14" || fail "multi-release jump did not consolidate notes: $(cat "$WORK/log14")"
grep -q "^### Added\$" "$WORK/log14" || fail "consolidated notes missing grouped Added header: $(cat "$WORK/log14")"
grep -q "^- Target release feature\$" "$WORK/log14" || fail "consolidated notes missing target-release bullet"
grep -q "^### Fixed\$" "$WORK/log14" || fail "consolidated notes missing grouped Fixed header"
grep -q "^- Intermediate release fix\$" "$WORK/log14" || fail "consolidated notes missing intermediate-release bullet"
grep -q "SMOKE: INSTALLED v$SMOKE_VERSION" "$WORK/log14" || fail "consolidated-notes run did not reach install"
wait_for_file "$WORK/report14" "consolidated-notes child never reported"
[[ "$(cat "$WORK/report14")" == "$SMOKE_VERSION" ]] || fail "consolidated-notes install reported $(cat "$WORK/report14")"
print "  OK — What's New lists every skipped release under its version heading, install unaffected"

print "• [15/16] Missing intermediate notes fall back and never block the install"
reset_install
rm -f "$WORK/report15" "$WORK/helper-done15"
run_smoke multi404 NOW_SMOKE_REPORT="$WORK/report15" NOW_SMOKE_HELPER_DONE="$WORK/helper-done15" > "$WORK/log15" 2>&1
grep -q "SMOKE: NOTES fallback" "$WORK/log15" || fail "missing releases list did not fall back: $(cat "$WORK/log15")"
grep -q "SMOKE: INSTALLED v$SMOKE_VERSION" "$WORK/log15" || fail "notes fallback delayed or blocked the install"
wait_for_file "$WORK/report15" "notes-fallback child never reported"
[[ "$(cat "$WORK/report15")" == "$SMOKE_VERSION" ]] || fail "notes-fallback install reported $(cat "$WORK/report15")"
print "  OK — cosmetic notes failure kept the latest-release body and the install path"

print "• [16/16] Brew mode: tracking-link detection, copy-command offer, no staging"
reset_install
# Lay out a Caskroom exactly as brew 7 does: the bundle is REAL in the app
# dir and the Caskroom holds a tracking symlink back to it (probe-verified
# 2026-09-18). Both detection directions run against the same release.
BREWROOM="$WORK/brewroom"
mkdir -p "$BREWROOM/now/$SMOKE_VERSION"
ln -s "$WORK/now.app" "$BREWROOM/now/$SMOKE_VERSION/now.app"
set +e
env NOW_UPDATE_API_BASE="http://127.0.0.1:$PORT/ok/api" NOW_UPDATE_REPO="BoThomas/now" \
    "$WORK/now.app/Contents/MacOS/now" --update-smoke-brew \
    --brew-caskroom "$BREWROOM" --brew-expect 1 > "$WORK/log16" 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "brew positive detection: expected exit 0, got $RC: $(cat "$WORK/log16")"
grep -q "SMOKE: BREW detected=1" "$WORK/log16" || fail "brew detection did not report 1: $(cat "$WORK/log16")"
grep -q "SMOKE: BREW action=copy-command brew upgrade --cask BoThomas/tap/now" "$WORK/log16" || fail "brew mode did not offer the copy command: $(cat "$WORK/log16")"
grep -q "SMOKE: BREW staging skipped" "$WORK/log16" || fail "brew staging gate did not hold: $(cat "$WORK/log16")"
# Negative detection: a tracking link to some other bundle must read 0.
OTHERROOM="$WORK/otherroom"
mkdir -p "$OTHERROOM/now/$SMOKE_VERSION"
ln -s "$WORK/nonexistent-parent/other.app" "$OTHERROOM/now/$SMOKE_VERSION/now.app"
set +e
env NOW_UPDATE_API_BASE="http://127.0.0.1:$PORT/ok/api" NOW_UPDATE_REPO="BoThomas/now" \
    "$WORK/now.app/Contents/MacOS/now" --update-smoke-brew \
    --brew-caskroom "$OTHERROOM" --brew-expect 0 > "$WORK/log16b" 2>&1
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "brew negative detection: expected exit 0, got $RC: $(cat "$WORK/log16b")"
grep -q "SMOKE: BREW detected=0" "$WORK/log16b" || fail "brew detection did not report 0: $(cat "$WORK/log16b")"
# Nothing was downloaded, staged, or installed: the bundle is untouched and
# no staging artifacts exist.
[[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "brew mode modified the install"
BREW_STAGING_LEFT=("$WORK/".now-update-*(N))
[[ ${#BREW_STAGING_LEFT} -eq 0 ]] || fail "brew mode left staging artifacts"
print "  OK — brew mode detected, offers the upgrade command, never stages"

print ""

print "• Install-time validation: verified staging modified before install"
for mutation in signature version; do
  reset_install
  rm -f "$WORK/stage-ready" "$WORK/stage-continue"
  run_smoke --exec ok NOW_SMOKE_STAGE_READY="$WORK/stage-ready" NOW_SMOKE_STAGE_CONTINUE="$WORK/stage-continue" > "$WORK/log-stage-$mutation" 2>&1 &
  MUTATION_PID=$!
  wait_for_file "$WORK/stage-ready" "staging handoff never arrived"
  STAGED_MUTATION_APP="$(cat "$WORK/stage-ready")"
  if [[ "$mutation" == signature ]]; then
    codesign --force --deep --sign - "$STAGED_MUTATION_APP" >/dev/null 2>&1
  else
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORIG_VERSION" "$STAGED_MUTATION_APP/Contents/Info.plist"
    codesign --force --deep --sign "$SIGNING_IDENTITY_SHA1" --entitlements now.entitlements "$STAGED_MUTATION_APP" >/dev/null 2>&1
  fi
  touch "$WORK/stage-continue"
  set +e
  wait "$MUTATION_PID"
  RC=$?
  MUTATION_PID=""
  set -e
  [[ $RC -eq 2 ]] || fail "post-stage $mutation: expected REFUSED, got $RC"
  grep -q 'SMOKE: REFUSED install-time validation:' "$WORK/log-stage-$mutation" || fail "post-stage $mutation bypassed validation"
  if [[ "$mutation" == signature ]]; then
    grep -q 'install-time validation: update is not signed with a trusted identity' "$WORK/log-stage-$mutation" || fail "post-stage signature refused for wrong reason"
  else
    grep -q 'install-time validation: staged version' "$WORK/log-stage-$mutation" || fail "post-stage trusted version refused for wrong reason"
  fi
  [[ "$(version_of "$WORK/now.app")" == "$ORIG_VERSION" ]] || fail "post-stage $mutation modified install"
  print "  OK — post-stage $mutation refused before swap"
done

print "UPDATE SMOKE OK — health-gated swap, staging/install signature and version gates, streaming limits, rollback, stuck-quit, stale-error-env, brew mode"
