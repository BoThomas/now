#!/usr/bin/env python3
"""Check SwiftPM source ownership for every runner; optional parsing is syntax-only."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SUITES = [None, "core", "selftest", "notification", "reminder", "cache", "fetch", "workload", "parser", "updater"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parse", action="store_true", help="also syntax-parse consumers (not SDK typechecking)")
    args = parser.parse_args()
    for suite in SUITES:
        environment = dict(os.environ)
        environment.pop("NOW_TEST_SUITE", None)
        if suite is not None:
            environment["NOW_TEST_SUITE"] = suite
        result = subprocess.run(["swift", "package", "--scratch-path", ".build/tests/core", "describe", "--type", "json"],
                                cwd=ROOT, env=environment, text=True, capture_output=True, check=True)
        # Dependency fetch progress is allowed; manifest warnings are not.
        assert "warning:" not in result.stderr, result.stderr
        targets = {target["name"]: target for target in json.loads(result.stdout)["targets"]}
        name = "NowApp" if suite is None else "NowCoreTests" if suite == "core" else "NowHarness"
        assert set(targets) == {"NowCore", name}, targets.keys()
        core, consumer = targets["NowCore"], targets[name]
        assert consumer["target_dependencies"] == ["NowCore"], consumer
        core_sources = {(ROOT / core["path"] / source).resolve() for source in core["sources"]}
        sources = [(ROOT / consumer["path"] / source).resolve() for source in consumer["sources"]]
        assert core_sources and sources and core_sources.isdisjoint(sources), "Core recompiled inside a consumer"
        assert all(source.is_relative_to(ROOT / "Sources/NowCore") for source in core_sources)
        if suite == "core":
            assert all(source.is_relative_to(ROOT / "Tests/NowCoreTests") for source in sources)
        else:
            assert not any(source.is_relative_to(ROOT / "Tests/NowCoreTests") for source in sources)
        if args.parse:
            flags = [] if suite in (None, "core") else ["-D", "NOW_TESTING", "-D", "NOW_" + suite.upper() + "_TESTS"]
            subprocess.run(["swiftc", "-frontend", "-parse", "-swift-version", "5", "-package-name", "now",
                            "-module-name", name] + flags + list(map(str, sources)), cwd=ROOT, check=True)
        print("PASS: module ownership" + (" / syntax only" if args.parse else "") + ": " + (suite or "shipping"))


if __name__ == "__main__":
    main()
