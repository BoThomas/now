#!/bin/zsh
# Explicit installation only; analysis and release checks never download tools.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.65.1
case "$(uname -s)/$(uname -m)" in
  Darwin/*)
    ARCHIVE=portable_swiftlint.zip
    SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
    ;;
  Linux/x86_64)
    ARCHIVE=swiftlint_linux_amd64.zip
    SHA256=caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d
    ;;
  Linux/aarch64)
    ARCHIVE=swiftlint_linux_arm64.zip
    SHA256=9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8
    ;;
  *) print -u2 "Unsupported analysis host"; exit 2 ;;
esac
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
curl --fail --location --silent --show-error \
  "https://github.com/realm/SwiftLint/releases/download/$VERSION/$ARCHIVE" \
  -o "$TEMP_DIR/swiftlint.zip"
if [[ "$(uname -s)" == Darwin ]]; then
  print "$SHA256  $TEMP_DIR/swiftlint.zip" | shasum -a 256 -c -
  ditto -x -k "$TEMP_DIR/swiftlint.zip" "$TEMP_DIR/unpacked"
else
  print "$SHA256  $TEMP_DIR/swiftlint.zip" | sha256sum -c -
  unzip -q "$TEMP_DIR/swiftlint.zip" -d "$TEMP_DIR/unpacked"
fi
[[ "$("$TEMP_DIR/unpacked/swiftlint" version)" == "$VERSION" ]]
mkdir -p .tools/swiftlint
cp "$TEMP_DIR/unpacked/swiftlint" .tools/swiftlint/swiftlint
print "Installed SwiftLint $VERSION locally in .tools/swiftlint"
