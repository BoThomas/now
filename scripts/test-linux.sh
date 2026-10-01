#!/usr/bin/env bash
# Portable SwiftPM runner for the Linux v1 shell; wraps the selftest in a
# private session bus so D-Bus registration runs without a desktop.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${NOW_TEST_CONFIGURATION:-debug}"
case "$configuration" in
  debug|release) ;;
  *) printf '%s\n' 'NOW_TEST_CONFIGURATION must be debug or release' >&2; exit 2 ;;
esac
export NOW_TEST_SUITE=linux
swift build --scratch-path .build/tests/linux --jobs "${NOW_BUILD_JOBS:-4}" -c "$configuration" \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --product now-linux
if ! command -v dbus-run-session >/dev/null 2>&1; then
  printf '%s\n' 'dbus-run-session not found; install dbus (dbus-x11) to run the Linux shell selftest' >&2
  exit 2
fi
exec dbus-run-session -- ".build/tests/linux/${configuration}/now-linux" selftest
