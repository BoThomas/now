#!/bin/zsh
# Explicit installation only; analysis and release checks never download tools.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.65.1
SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
curl --fail --location --silent --show-error \
  "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip" \
  -o "$TEMP_DIR/swiftlint.zip"
print "$SHA256  $TEMP_DIR/swiftlint.zip" | shasum -a 256 -c -
ditto -x -k "$TEMP_DIR/swiftlint.zip" "$TEMP_DIR/unpacked"
[[ "$("$TEMP_DIR/unpacked/swiftlint" version)" == "$VERSION" ]]
mkdir -p .tools/swiftlint
cp "$TEMP_DIR/unpacked/swiftlint" .tools/swiftlint/swiftlint
print "Installed SwiftLint $VERSION locally in .tools/swiftlint"
