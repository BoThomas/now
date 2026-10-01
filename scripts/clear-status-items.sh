#!/bin/zsh
# Clear ghost menu-bar status items and dead Dock app tiles left by killed
# apps (smoke harnesses, crashed menu bar tools). Both SystemUIServer and the
# Dock rebuild automatically: live icons and real tiles reappear, dead ones
# drop out. Running apps are unaffected.
set -euo pipefail
FAILED=0
if pgrep -x SystemUIServer > /dev/null; then
  killall SystemUIServer
  print "SystemUIServer restarted; ghost status items are gone."
else
  print "SystemUIServer is not running; skipping." >&2
fi
if pgrep -x Dock > /dev/null; then
  killall Dock
  print "Dock restarted; dead app tiles are gone."
else
  print "Dock is not running; skipping." >&2
fi
