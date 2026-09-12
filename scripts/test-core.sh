#!/usr/bin/env bash
# Portable SwiftPM runner; intentionally bypasses the macOS SDK/architecture wrapper.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${NOW_TEST_CONFIGURATION:-debug}"
case "$configuration" in
  debug|release) ;;
  *) printf '%s\n' 'NOW_TEST_CONFIGURATION must be debug or release' >&2; exit 2 ;;
esac
export NOW_TEST_SUITE=core
swift run --scratch-path .build/tests/core --jobs "${NOW_BUILD_JOBS:-4}" -c "$configuration" \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors now-core-tests
