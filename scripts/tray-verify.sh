#!/usr/bin/env bash
# Rendered-tray verification for the Linux v1 shell, designed for the dev
# container's desktop-lite session (X11 Fluxbox on DISPLAY=:1). Installs a
# StatusNotifierItem-capable panel (xfce4-panel), runs now-linux against a
# synthetic feed, and screenshots the tray so a human or agent can inspect the
# rendered icon and menu. Requires the post-create toolchain and a session bus.
set -euo pipefail
cd "$(dirname "$0")/.."

report="${1:-/tmp/now-tray-verify.png}"
root="$(mktemp -d /tmp/now-tray-XXXXXX)"
trap 'rm -rf "$root"; pkill -f "now-linux run" 2>/dev/null || true' EXIT

if ! command -v xfce4-panel >/dev/null 2>&1 || ! command -v import >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xfce4-panel imagemagick xdotool >/dev/null
fi

export NOW_TEST_SUITE=linux
swift build --scratch-path .build/tests/linux --jobs "${NOW_BUILD_JOBS:-4}" -c debug \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors --product now-linux

# Synthetic agenda: one running meeting with a join link, one upcoming.
stamp() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y%m%dT%H%M%SZ; }
cat > "$root/feed.ics" <<EOF
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:tray-1
DTSTART:$(stamp -120)
DTEND:$(stamp 1800)
SUMMARY:Retro
DESCRIPTION:Join at https://meet.example.com/j/retro
END:VEVENT
BEGIN:VEVENT
UID:tray-2
DTSTART:$(stamp 3000)
DTEND:$(stamp 4800)
SUMMARY:Design review
END:VEVENT
END:VCALENDAR
EOF

python3 - "$root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
prefs = {
    "subscriptions": [{"name": "Verify", "url": (root / "feed.ics").as_uri(), "colorIndex": 0, "colorHex": ""}],
    "settings": {"reminderLeadSeconds": [300]},
    "nativeCalendars": [],
    "pausedUntil": None,
}
(root / "preferences.json").write_text(json.dumps(prefs))
PY

# A panel with a StatusNotifier host owns the watcher name on the real session
# bus; desktop-lite exports the X display via VNC. Start both, then the app.
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/now-runtime}"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
eval "$(dbus-launch --sh-syntax)"
pkill -f xfce4-panel 2>/dev/null || true
xfce4-panel &
sleep 6

.build/tests/linux/debug/now-linux run --root "$root" --duration 25 --tick 5 &
sleep 8

import -window root "$report" 2>/dev/null || import -window root "png:$report"
echo "tray verification screenshot: $report"

# Sweep-click the tray icon group and capture each result; one frame will
# show the now agenda menu (NOW/NEXT rows, join/pause footer).
width=$(xdotool getdisplaygeometry | cut -d" " -f1)
height=$(xdotool getdisplaygeometry | cut -d" " -f2)
x=$((width / 2 - 150))
while [ $x -le $((width / 2 + 150)) ]; do
  xdotool mousemove "$x" $((height - 15)) click 1
  sleep 1
  import -window root "png:/tmp/now-tray-menu-$x.png" 2>/dev/null || true
  xdotool key Escape || true
  x=$((x + 34))
done
echo "menu sweep screenshots: /tmp/now-tray-menu-*.png"
wait
