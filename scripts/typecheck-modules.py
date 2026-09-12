#!/usr/bin/env python3
"""Check the actual core/consumer boundary; never flatten core into app sources."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk")
    parser.add_argument("--target")
    args = parser.parse_args()
    report = Path(".build/analysis")
    modules = report / "CoreModules"
    modules.mkdir(parents=True, exist_ok=True)
    common = ["swiftc", "-parse-as-library", "-swift-version", "5",
              "-strict-concurrency=complete", "-package-name", "now",
              "-module-cache-path", str(report / "ModuleCache")]
    if args.sdk:
        common += ["-sdk", args.sdk]
    if args.target:
        common += ["-target", args.target]

    def check(name, arguments, sources):
        if not sources:
            raise ValueError(f"No sources for {name}")
        result = subprocess.run(common + arguments + [str(source) for source in sources],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (report / (name + ".log")).write_text(result.stdout)
        if result.returncode:
            print(result.stdout, end="")
        return result.returncode == 0

    # Core has no suite defines in Package.swift. Emit it once, then import its
    # module using the same package identity in every consumer configuration.
    if not check("concurrency-core", ["-emit-module", "-module-name", "NowCore",
                                     "-emit-module-path", str(modules / "NowCore.swiftmodule")],
                 sorted(Path("Sources/NowCore").rglob("*.swift"))):
        return 1
    shell = sorted(source for source in Path("Sources").rglob("*.swift")
                   if not source.is_relative_to(Path("Sources/NowCore")))
    configurations = [
        ("concurrency-production", "NowApp", [], shell),
        ("concurrency", "NowHarness", ["-D", "NOW_TESTING", "-D", "NOW_SELFTEST_TESTS"],
         shell + sorted(Path("Tests/NowTests").rglob("*.swift"))),
        ("concurrency-updater", "NowHarness", ["-D", "NOW_TESTING", "-D", "NOW_UPDATER_TESTS"],
         shell + sorted(Path("Tests/Updater").rglob("*.swift"))),
        ("concurrency-core-tests", "NowCoreTests", [], sorted(Path("Tests/NowCoreTests").rglob("*.swift"))),
    ]
    success = True
    for name, module, flags, sources in configurations:
        passed = check(name, ["-typecheck", "-module-name", module, "-I", str(modules)] + flags, sources)
        success = passed and success
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
