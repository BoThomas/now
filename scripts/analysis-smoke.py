#!/usr/bin/env python3
"""Exercise analysis gates using a disposable project, never the app's sources."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COMPILER_ONLY = "--compiler-only" in sys.argv
LINT_ONLY = "--lint-only" in sys.argv
if COMPILER_ONLY and LINT_ONLY:
    raise SystemExit("Choose --compiler-only or --lint-only, not both")

with tempfile.TemporaryDirectory(prefix="now-analysis-") as directory:
    project = Path(directory)
    for folder in ("scripts", "Sources", "analysis"):
        (project / folder).mkdir()
    for script in ("analyze.sh", "check-concurrency.py", "typecheck-modules.py"):
        shutil.copy2(ROOT / "scripts" / script, project / "scripts" / script)
    shutil.copy2(ROOT / ".swiftlint.yml", project / ".swiftlint.yml")
    for baseline in ("concurrency", "swiftlint"):
        (project / "analysis" / f"{baseline}-baseline.json").write_text("[]\n")
    (project / "Tests/NowTests").mkdir(parents=True)
    (project / "Tests/NowTests/Fixture.swift").write_text("// Fixture discovery probe\n")
    (project / "Tests/Updater").mkdir(parents=True)
    (project / "Tests/Updater/Fixture.swift").write_text("// Updater fixture discovery probe\n")
    (project / "Tests/NowCoreTests").mkdir(parents=True)
    (project / "Tests/NowCoreTests/Fixture.swift").write_text("// Core fixture discovery probe\n")
    (project / "Sources/NowCore").mkdir()
    core = project / "Sources/NowCore/Probe.swift"
    core.write_text("package func coreValue() -> Int { 1 }\n")
    environment = dict(os.environ, SWIFTLINT=os.environ.get(
        "SWIFTLINT", str(ROOT / ".tools/swiftlint/swiftlint")))
    source = project / "Sources/Probe.swift"

    if LINT_ONLY:
        # Portable linter probes use the same pinned configuration and empty
        # disposable baseline, without requiring an Apple SDK typecheck.
        linter = environment["SWIFTLINT"]
        assert subprocess.check_output([linter, "version"], text=True).strip() == "0.65.1"

        def lint(label, succeeds, report=False):
            result = subprocess.run([linter, "lint", "--config", ".swiftlint.yml", "--no-cache", "--quiet",
                                     "--lenient" if report else "--strict"], cwd=project, env=environment,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert (result.returncode == 0) == succeeds, (label, result.stdout)
            if label != "clean source":
                assert "force_try" in result.stdout, (label, result.stdout)
            print("PASS:", label)

        source.write_text("func value() -> Int { 1 }\n")
        lint("clean source", True)
        source.write_text("func value() throws -> Int { 1 }\nfunc probe() -> Int { try! value() }\n")
        lint("new shell lint finding", False)
        lint("informational lint report", True, report=True)
        source.write_text("func value() -> Int { 1 }\n")
        core.write_text("func value() throws -> Int { 1 }\nfunc probe() -> Int { try! value() }\n")
        lint("new core lint finding", False)
        print("ANALYSIS LINT SMOKE OK (compiler/SDK gates not run)")
        raise SystemExit(0)

    def run(label, succeeds, report=False, expected="", env=None):
        if COMPILER_ONLY:
            result = subprocess.run([sys.executable, "scripts/typecheck-modules.py"], cwd=project,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = result.stdout
            status = result.returncode
            if status == 0:
                for flag in ([], ["--production"], ["--updater"], ["--core"], ["--core-tests"]):
                    checked = subprocess.run([sys.executable, "scripts/check-concurrency.py"] + flag
                                             + (["--report"] if report else []), cwd=project, text=True,
                                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    output += checked.stdout
                    status = status or checked.returncode
            assert (status == 0) == succeeds, (label, output)
            assert expected in output, (label, output)
            print("PASS:", label)
            return
        result = subprocess.run(
            ["./scripts/analyze.sh"] + (["--report"] if report else []),
            cwd=project, env=env or environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        assert (result.returncode == 0) == succeeds, (label, result.stdout)
        assert expected in result.stdout, (label, result.stdout)
        print("PASS:", label)

    source.write_text("import NowCore\nfunc value() -> Int { coreValue() }\n")
    run("clean source", True)
    core.write_text("package func coreValue() -> Int { 1 }\nvar sharedCoreValue = 0\n")
    run("new core compiler warning", False, expected="new")
    core.write_text("func coreValue() -> Int { 1 }\n")
    run("internal core API cannot leak into shell", False, expected="error:")
    core.write_text("package func coreValue() -> Int { 1 }\n")
    core_fixture = project / "Tests/NowCoreTests/Fixture.swift"
    core_fixture.write_text("var sharedCoreFixture = 0\n")
    run("core fixture compiler warning", False, expected="new")
    core_fixture.write_text("// Core fixture discovery probe\n")
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
    if not COMPILER_ONLY:
        source.write_text("func value() throws -> Int { 1 }\nfunc probe() -> Int { try! value() }\n")
        run("new lint finding", False, expected="force_try")
        run("informational lint report", True, report=True, expected="force_try")
        source.write_text("func value() -> Int { 1 }\n")
        core.write_text("func coreValue() throws -> Int { 1 }\nfunc probe() -> Int { try! coreValue() }\n")
        run("new core lint finding", False, expected="force_try")
        core.write_text("package func coreValue() -> Int { 1 }\n")
    source.write_text("var differentSharedValue = 0\n")
    run("informational compiler warning", True, report=True, expected="1 new")
    source.write_text("func broken(\n")
    run("report still rejects compiler errors", False, report=True, expected="error:")
    if not COMPILER_ONLY:
        run("missing tool fails", False, expected="SwiftLint missing",
            env=dict(environment, SWIFTLINT=str(project / "missing")))
        (project / "analysis/swiftlint-baseline.json").unlink()
        run("missing baseline fails", False, expected="Missing analysis configuration")

print("ANALYSIS COMPILER SMOKE OK (lint/tool gates not run)" if COMPILER_ONLY else "ANALYSIS SMOKE OK")
