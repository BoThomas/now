#!/usr/bin/env python3
"""Full materialization equivalence across source/module layouts, plus workload timings."""
import argparse
import os
import pathlib
import subprocess
import tempfile
from harness import build

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
comparison = parser.add_mutually_exclusive_group()
comparison.add_argument("--compare-head", action="store_true", help="compare against committed HEAD")
comparison.add_argument("--compare-revision", help="compare against an explicit revision, e.g. d01dbd7")
args = parser.parse_args()
revision = "HEAD" if args.compare_head else args.compare_revision

with tempfile.TemporaryDirectory(prefix="now-parser-performance-") as folder:
    temp = pathlib.Path(folder)
    variants = [("working", root)]
    if revision:
        # Archive a complete revision so each variant uses its own module layout,
        # helpers and fixtures. Never mix a historical parser with current models.
        commit = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", revision + "^{commit}"],
                                         cwd=root, text=True).strip()
        historical = temp / "historical"
        historical.mkdir()
        with subprocess.Popen(["git", "archive", commit], cwd=root, stdout=subprocess.PIPE) as archive:
            subprocess.run(["tar", "-xf", "-", "-C", str(historical)], stdin=archive.stdout, check=True)
            archive.stdout.close()
            if archive.wait() != 0:
                raise RuntimeError("Could not archive comparison revision")
        print("Comparing complete revision " + commit, flush=True)
        variants.insert(0, ("committed", historical))
    digests = []
    os.environ["NOW_TEST_CONFIGURATION"] = "release"
    for label, project in variants:
        executable = temp / label
        build("parser", executable, root=project)
        result = subprocess.check_output([str(executable)], text=True, timeout=120)
        print(label + "\n" + result, flush=True)
        digest = [line.split("digest ")[1] for line in result.splitlines() if "digest " in line]
        assert len(digest) == 2, "Expected both materialization fixture digests"
        digests.append(digest)
    assert all(value == digests[0] for value in digests), "Parser extraction changed event output"
    print("PARSER PERFORMANCE SMOKE OK")
