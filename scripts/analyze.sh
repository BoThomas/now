#!/bin/zsh
# Read-only source checks. Reports/caches go in .build; no signing or app launch.
set -euo pipefail
cd "$(dirname "$0")/.."
REPORT=false
if [[ $# -eq 1 && "$1" == --report ]]; then
  REPORT=true
elif [[ $# -ne 0 ]]; then
  print -u2 "usage: $0 [--report]"
  exit 2
fi
for required_file in .swiftlint.yml analysis/swiftlint-baseline.json analysis/concurrency-baseline.json; do
  [[ -f "$required_file" ]] || {
    print -u2 "Missing analysis configuration: $required_file"
    exit 2
  }
done
SWIFTLINT="${SWIFTLINT:-$PWD/.tools/swiftlint/swiftlint}"
[[ -x "$SWIFTLINT" ]] || {
  print -u2 "SwiftLint missing. Run ./scripts/setup-analysis.sh first."
  exit 2
}
[[ "$("$SWIFTLINT" version)" == 0.65.1 ]] || {
  print -u2 "Expected SwiftLint 0.65.1; run ./scripts/setup-analysis.sh."
  exit 2
}
mkdir -p .build/analysis/ModuleCache
# Recent Command Line Tools put SourceKit here; SwiftLint does not discover it.
DEVELOPER_DIR_PATH=$(xcode-select -p)
if [[ -d "$DEVELOPER_DIR_PATH/usr/lib/sourcekitdInProc.framework" ]]; then
  export DYLD_FRAMEWORK_PATH="$DEVELOPER_DIR_PATH/usr/lib${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
fi
SDK_PATH="${SDK_PATH:-$(xcrun --show-sdk-path)}"
swiftc --version > .build/analysis/toolchain.txt 2>&1
print "Strict concurrency typecheck (Swift 5, arm64, macOS 13)…"
if ! swiftc -typecheck -parse-as-library -swift-version 5 -strict-concurrency=complete \
  -sdk "$SDK_PATH" -target arm64-apple-macos13.0 \
  -module-cache-path "$PWD/.build/analysis/ModuleCache" Sources/*.swift \
  > .build/analysis/concurrency.log 2>&1; then
  cat .build/analysis/concurrency.log
  exit 1
fi
RESULT=0
if [[ "$REPORT" == true ]]; then
  cat .build/analysis/concurrency.log
  python3 scripts/check-concurrency.py --report
  # An empty baseline exposes the entire backlog without changing the saved one.
  print '[]' > .build/analysis/empty-baseline.json
  "$SWIFTLINT" lint --config .swiftlint.yml --no-cache --quiet --lenient \
    --baseline .build/analysis/empty-baseline.json > .build/analysis/swiftlint.log || RESULT=1
else
  python3 scripts/check-concurrency.py || RESULT=1
  "$SWIFTLINT" lint --config .swiftlint.yml --no-cache --quiet --strict \
    > .build/analysis/swiftlint.log || RESULT=1
fi
cat .build/analysis/swiftlint.log
print "Analysis reports: .build/analysis/"
exit "$RESULT"
