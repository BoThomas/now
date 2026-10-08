#!/bin/bash
# Collects read-only diagnostics about the "now" app for support requests:
# version/uptime, a CPU measurement, call-stack profiles, and the last hour of
# app logs, zipped to ~/Desktop/now-debug.zip. Nothing is modified.
# The archive may contain meeting titles — ask people to share it privately.
#
# Run directly, or via:
#   curl -fsSL https://raw.githubusercontent.com/BoThomas/now/main/scripts/collect-support-diagnostics.sh | bash
set -eu

echo
echo "now-Diagnose (nur lesend, ~1-2 min, am besten ausführen wenn now gerade viel CPU braucht) → ~/Desktop/now-debug.zip"
echo
echo "Admin-Passwort wird nur für den 10-s-System-Profil-Schritt gebraucht:"
sudo -v || { echo "❌ Abbruch — ohne Passwort nicht möglich."; exit 1; }
echo "✅ Passwort ok"

PID=$(pgrep -x now | head -1)
[ -n "$PID" ] || { echo "❌ now läuft nicht."; exit 1; }

cd "$HOME/Desktop" || { echo "❌ Kein Zugriff auf ~/Desktop."; exit 1; }
rm -rf now-debug now-debug.zip
mkdir now-debug
cd now-debug || { echo "❌ Ordner now-debug konnte nicht erstellt werden."; exit 1; }

# Interaktive Shells ignorieren "set -e"; jeder Schritt validiert deshalb
# selbst, dass seine Ausgabedatei existiert und nicht leer ist.
ok(){ [ -s "$1" ] || { echo "❌ Schritt fehlgeschlagen ($1 fehlt oder leer) — Abbruch."; exit 1; }; }

{ sw_vers; sysctl -n machdep.cpu.brand_string; } > system.txt
ok system.txt
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' \
  "$(ps -p "$PID" -o comm= | sed 's|/Contents/MacOS/now||')/Contents/Info.plist" > version.txt \
  && ps -p "$PID" -o pid,etime,%cpu,time,command >> version.txt
ok version.txt

echo; echo "1/6 CPU-Messung, 10 s..."
top -l 5 -pid "$PID" -stats pid,cpu,time,th -s 2 > top.txt
ok top.txt

echo; echo "2/6 Aufruf-Profil, 10 s..."
sample "$PID" 10 -mayDie -file sample.txt
ok sample.txt

echo; echo "3/6 System-Profil, 10 s..."
sudo spindump "$PID" 10 -file spindump.txt
ok spindump.txt

echo; echo "4/6 Log der letzten Stunde (dauert bis zu 1 min)..."
log show --last 1h --style compact --predicate 'process == "now"' > log.txt 2>&1
ok log.txt

echo; echo "5/6 Zip..."
cd "$HOME/Desktop" || exit 1
zip -rq now-debug.zip now-debug
ok now-debug.zip
