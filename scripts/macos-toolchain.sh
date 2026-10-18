# Source from the macOS build/check entry points. Never change global xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  NOW_SELECTED_DEVELOPER=$(/usr/bin/xcode-select -p 2>/dev/null || true)
  if [[ -n "$NOW_SELECTED_DEVELOPER" && -x "$NOW_SELECTED_DEVELOPER/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$NOW_SELECTED_DEVELOPER"
  elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    print -u2 "Full Xcode is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer."
    return 1
  fi
fi
if [[ -d "$DEVELOPER_DIR/Contents/Developer" ]]; then
  export DEVELOPER_DIR="$DEVELOPER_DIR/Contents/Developer"
fi
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || {
  print -u2 "DEVELOPER_DIR must select full Xcode, not standalone Command Line Tools."
  return 1
}
NOW_SWIFT=$(/usr/bin/xcrun --find swift) || return $?
NOW_SWIFTC=$(/usr/bin/xcrun --find swiftc) || return $?
export NOW_SWIFT NOW_SWIFTC
export NOW_SWIFTPM_BACKEND=native
if [[ -z "${SDK_PATH:-}" ]]; then
  SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path) || return $?
fi
export SDK_PATH
[[ -d "$SDK_PATH" ]] || { print -u2 "SDK_PATH is not an SDK directory: $SDK_PATH"; return 1; }
# An inherited CLT SDKROOT must not silently override the selected Xcode SDK.
export SDKROOT="$SDK_PATH"
NOW_SDK_VERSION=$(/usr/bin/xcrun --sdk "$SDK_PATH" --show-sdk-version) || return $?
export NOW_SDK_VERSION
