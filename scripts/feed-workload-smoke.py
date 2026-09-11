#!/usr/bin/env python3
from harness import build
"""Fixed-clock production workload probes; timings are observations, never limits."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="now-workload-smoke-") as directory:
    directory = pathlib.Path(directory)
    binary = directory / "workload-smoke"
    build("workload", binary)
    diagnostics = []
    for run in range(2):
        result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
        print(f"PROCESS RUN {run + 1}\n{result.stdout}", flush=True)
        diagnostics.append(next(line for line in result.stdout.splitlines() if line.startswith("DIAGNOSTIC ")))
    assert diagnostics[0] == diagnostics[1], "Different hash seeds changed the diagnostic"
    print("PASS: separate processes produce identical limit diagnostics")
