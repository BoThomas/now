#!/usr/bin/env python3
"""Compare compiler warnings by file, message and source text, ignoring line shifts."""
import collections
import json
from pathlib import Path
import re
import sys


def diagnostics(log):
    findings = []
    for line in log.splitlines():
        match = re.match(r"^((?:Sources|Tests)/[^:]+):(\d+):\d+: warning: (.*)$", line)
        if match:
            filename, number, message = match.groups()
            source = Path(filename).read_text().splitlines()[int(number) - 1].strip()
            findings.append({"file": filename, "message": message, "source": source})
        elif re.match(r"^.*:\d+:\d+: warning:", line) or line.startswith("warning:"):
            raise ValueError("Unrecognized compiler warning: " + line)
    return findings


def counts(findings):
    return collections.Counter(json.dumps(item, sort_keys=True) for item in findings)


def main():
    report = Path(".build/analysis")
    name = "concurrency-production" if "--production" in sys.argv else "concurrency"
    if "--updater" in sys.argv:
        name = "concurrency-updater"
    current = diagnostics((report / (name + ".log")).read_text())
    (report / (name + "-current.json")).write_text(json.dumps(current, indent=2) + "\n")
    baseline = json.loads(Path("analysis/concurrency-baseline.json").read_text())
    added = counts(current) - counts(baseline)
    removed = counts(baseline) - counts(current)
    print(f"Concurrency: {len(current)} existing/current warnings; "
          f"{sum(added.values())} new, {sum(removed.values())} resolved or changed.")
    for item, count in added.items():
        finding = json.loads(item)
        print(f"NEW ({count}): {finding['file']}: {finding['message']}\n  {finding['source']}")
    if removed:
        print("Review and prune resolved entries from analysis/concurrency-baseline.json.")
    return 1 if added and "--report" not in sys.argv else 0


if __name__ == "__main__":
    sys.exit(main())
