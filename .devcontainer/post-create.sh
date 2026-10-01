#!/usr/bin/env bash
# Dev container / Codespace setup for the Linux v1 port.
# Installs a pinned Swift toolchain, session/D-Bus tooling, and runs the portable
# gates that must pass off the macOS SDK. Writes a report and a done marker so an
# agent can poll completion: /tmp/now-post-create-report.txt, /tmp/now-post-create.done.
set -euo pipefail

report="/tmp/now-post-create-report.txt"
marker="/tmp/now-post-create.done"
: >"$report"
log() { printf '\n[post-create] %s\n' "$*"; }
run() { local name="$1"; shift; log "$name"; if "$@" >>"$report" 2>&1; then printf 'PASS %s\n' "$name" >>"$report"; else printf 'FAIL %s\n' "$name" >>"$report"; return 1; fi; }

rm -f "$marker"

log "apt packages (Swift toolchain deps + D-Bus session tooling)"
sudo apt-get update -qq >>"$report" 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
  libpython3-dev libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata \
  unzip zip zlib1g-dev libncurses-dev \
  dbus dbus-x11 >>"$report" 2>&1

log "install pinned Swift toolchain to /opt/swift"
arch_flag=""
plat_dir="ubuntu2404"
case "$(uname -m)" in
  x86_64) arch_flag="" ;;
  aarch64) arch_flag="-aarch64"; plat_dir="ubuntu2404-aarch64" ;;
  *) printf 'unsupported arch %s\n' "$(uname -m)" >>"$report"; exit 2 ;;
esac
swift_dir=""
for version in 6.4.0 6.3.3 6.3.2 6.3.1 6.3 6.2.4 6.2.3 6.2; do
  url="https://download.swift.org/swift-${version}-release/${plat_dir}/swift-${version}-RELEASE/swift-${version}-RELEASE-ubuntu24.04${arch_flag}.tar.gz"
  if curl -fsSL --head "$url" >/dev/null 2>&1; then
    log "downloading Swift ${version}"
    curl -fsSL "$url" -o /tmp/swift.tar.gz >>"$report" 2>&1
    swift_dir="/tmp/swift-${version}-RELEASE-ubuntu24.04${arch_flag}"
    sudo mkdir -p /opt/swift
    sudo tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components=1
    rm /tmp/swift.tar.gz
    break
  fi
done
if [ -z "$swift_dir" ]; then
  printf 'no Swift release tarball found for ubuntu24.04%s\n' "$arch_flag" >>"$report"
  exit 2
fi
for binary in /opt/swift/usr/bin/*; do sudo ln -sf "$binary" "/usr/local/bin/$(basename "$binary")"; done
swift --version >>"$report" 2>&1

log "portable gates (debug; set NOW_SETUP_FULL=1 to also run release core)"
cd "${CODESPACE_VSCODE_FOLDER:-$(pwd)}"
run "core debug" ./scripts/test-core.sh
run "headless debug" ./scripts/test-headless.sh
run "module boundary parse" python3 scripts/module-boundary-smoke.py --parse
run "compiler smoke" python3 scripts/analysis-smoke.py --compiler-only
if [ "${NOW_SETUP_FULL:-0}" = "1" ]; then
  run "core release" env NOW_TEST_CONFIGURATION=release ./scripts/test-core.sh
  run "headless release" env NOW_TEST_CONFIGURATION=release ./scripts/test-headless.sh
fi

printf 'post-create complete %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$report"
touch "$marker"
log "done; report at $report"
