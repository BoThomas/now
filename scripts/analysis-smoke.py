#!/usr/bin/env python3
"""Exercise analysis gates using a disposable project, never the app's sources."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="now-analysis-") as directory:
    project = Path(directory)
    for folder in ("scripts", "Sources", "analysis"):
        (project / folder).mkdir()
    for script in ("analyze.sh", "check-concurrency.py"):
        shutil.copy2(ROOT / "scripts" / script, project / "scripts" / script)
    shutil.copy2(ROOT / ".swiftlint.yml", project / ".swiftlint.yml")
    for baseline in ("concurrency", "swiftlint"):
        (project / "analysis" / f"{baseline}-baseline.json").write_text("[]\n")
    (project / "Tests/NowTests").mkdir(parents=True)
    (project / "Tests/NowTests/Fixture.swift").write_text("// Fixture discovery probe\n")
    (project / "Tests/Updater").mkdir(parents=True)
    (project / "Tests/Updater/Fixture.swift").write_text("// Updater fixture discovery probe\n")
    environment = dict(os.environ, SWIFTLINT=os.environ.get(
        "SWIFTLINT", str(ROOT / ".tools/swiftlint/swiftlint")))
    source = project / "Sources/Probe.swift"

    def run(label, succeeds, report=False, expected="", env=None):
        result = subprocess.run(
            ["./scripts/analyze.sh"] + (["--report"] if report else []),
            cwd=project, env=env or environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        assert (result.returncode == 0) == succeeds, (label, result.stdout)
        assert expected in result.stdout, (label, result.stdout)
        print("PASS:", label)

    source.write_text("func value() -> Int { 1 }\n")
    run("clean source", True)
    source.write_text("#if NOW_TESTING\nvar sharedValue = 0\n#endif\n")
    run("test-only compiler warning", False, expected="1 new")
    source.write_text("#if !NOW_TESTING\nvar sharedValue = 0\n#endif\n")
    run("shipping-only compiler warning", False, expected="1 new")
    source.write_text("#if NOW_UPDATER_TESTS\nvar sharedValue = 0\n#endif\n")
    run("updater-only compiler warning", False, expected="1 new")
    source.write_text("var sharedValue = 0\n")
    run("new compiler warning", False, expected="1 new")
    snapshot = project / ".build/analysis/concurrency-current.json"
    shutil.copy2(snapshot, project / "analysis/concurrency-baseline.json")
    source.write_text("\n\nvar sharedValue = 0\n")
    run("baseline survives line shifts", True, expected="0 new")
    source.write_text("var differentSharedValue = 0\n")
    run("same warning count cannot hide replacement", False, expected="1 new")
    source.write_text("func value() throws -> Int { 1 }\nfunc probe() -> Int { try! value() }\n")
    run("new lint finding", False, expected="force_try")
    run("informational lint report", True, report=True, expected="force_try")
    source.write_text("var differentSharedValue = 0\n")
    run("informational compiler warning", True, report=True, expected="1 new")
    source.write_text("func broken(\n")
    run("report still rejects compiler errors", False, report=True, expected="error:")
    run("missing tool fails", False, expected="SwiftLint missing",
        env=dict(environment, SWIFTLINT=str(project / "missing")))
    (project / "analysis/swiftlint-baseline.json").unlink()
    run("missing baseline fails", False, expected="Missing analysis configuration")

print("ANALYSIS SMOKE OK")
