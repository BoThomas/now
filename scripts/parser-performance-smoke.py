#!/usr/bin/env python3
"""Parser equivalence and bounded workload measurements without EventKit.
--compare-head also measures the committed parser against the working copy.
"""
import pathlib
import subprocess
import sys
import tempfile
from harness import build
import os

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="now-parser-performance-") as folder:
    temp = pathlib.Path(folder)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    variants = [("working", root / "Sources/ICS.swift")]
    if "--compare-head" in sys.argv:
        old = temp / "ICS.swift"
        old.write_bytes(subprocess.check_output(["git", "show", "HEAD:Sources/ICS.swift"], cwd=root))
        variants.insert(0, ("committed", old))
    digests = []
    for label, parser in variants:
        executable = temp / label
        if label == "working":
            os.environ["NOW_TEST_CONFIGURATION"] = "release"
            build("parser", executable)
        else:
            sources = [root / "Sources" / name for name in ["Models.swift", "Helpers.swift", "TitleFilter.swift", "Preferences.swift"]]
            subprocess.run(["swiftc", "-O", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
                            "-target", "arm64-apple-macos13.0", "-module-cache-path", str(temp / "modules"),
                            *map(str, sources), str(parser), str(root / "scripts/parser-performance-smoke.swift"), "-o", str(executable)], check=True)
        result = subprocess.check_output([str(executable)], text=True, timeout=120)
        print(label + "\n" + result, flush=True)
        digests.append([line.split("digest ")[1] for line in result.splitlines()])
    assert all(value == digests[0] for value in digests), "Parser optimization changed event output"
    print("PARSER PERFORMANCE SMOKE OK")
