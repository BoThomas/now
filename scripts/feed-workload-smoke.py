#!/usr/bin/env python3
"""Fixed-clock production workload probes; timings are observations, never limits."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="now-workload-smoke-") as directory:
    directory = pathlib.Path(directory)
    app = directory / "App.swift"
    app.write_text((root / "Sources/App.swift").read_text().replace("@main\nenum NowApp", "enum NowApp", 1))
    sources = sorted(str(p) for p in (root / "Sources").glob("*.swift") if p.name != "App.swift")
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    binary = directory / "workload-smoke"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
                    "-target", "arm64-apple-macos13.0", "-module-cache-path", str(directory / "modules"),
                    *sources, str(app), str(root / "scripts/feed-workload-smoke.swift"), "-o", str(binary),
                    "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "ServiceManagement",
                    "-framework", "EventKit", "-framework", "CoreAudio"], check=True)
    diagnostics = []
    for run in range(2):
        result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
        print(f"PROCESS RUN {run + 1}\n{result.stdout}", flush=True)
        diagnostics.append(next(line for line in result.stdout.splitlines() if line.startswith("DIAGNOSTIC ")))
    assert diagnostics[0] == diagnostics[1], "Different hash seeds changed the diagnostic"
    print("PASS: separate processes produce identical limit diagnostics")
