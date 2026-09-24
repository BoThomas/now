#!/usr/bin/env python3
from harness import build
"""Measure per-second CPU hot paths with synthetic data in a disposable bundle."""
import os
import pathlib
import plistlib
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix="now-perf-smoke-") as directory:
    directory = pathlib.Path(directory)
    bundle = directory / "PerfSmoke.app" / "Contents"
    (bundle / "MacOS").mkdir(parents=True)
    identifier = "com.thomasboch.now.perf-smoke." + uuid.uuid4().hex
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "perf-smoke", "LSUIElement": True
    }))
    executable = bundle / "MacOS/perf-smoke"
    build("perf", executable)
    # cfprefsd flushes asynchronously, so removePersistentDomain can leave the
    # disposable domains' plists behind after exit. Sweep them (unique prefix,
    # never the installed app's com.thomasboch.now domain).
    preferences = pathlib.Path.home() / "Library" / "Preferences"
    before = set(preferences.glob("com.thomasboch.now.perf-smoke.*"))
    try:
        subprocess.run([str(executable)], check=True, timeout=900,
                       env=dict(os.environ, NOW_TEST_CACHE_ROOT=str(directory / "cache")))
    finally:
        for leftover in set(preferences.glob("com.thomasboch.now.perf-smoke.*")) | before:
            leftover.unlink(missing_ok=True)
