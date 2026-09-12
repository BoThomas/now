"""Build explicit SwiftPM fixture targets without copying or rewriting app sources."""
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def build(suite, executable):
    configuration = os.environ.get("NOW_TEST_CONFIGURATION", "debug")
    if configuration not in ("debug", "release"):
        raise ValueError("NOW_TEST_CONFIGURATION must be debug or release")
    environment = dict(os.environ, NOW_TEST_SUITE=suite)
    command = [str(ROOT / "scripts/swiftpm.sh"), "build", "--scratch-path",
               str(ROOT / ".build/tests" / suite), "-c", configuration]
    subprocess.run(command + ["--product", "now-harness"], env=environment, check=True, cwd=ROOT)
    binary_dir = subprocess.check_output(command + ["--show-bin-path"], env=environment,
                                         text=True, cwd=ROOT).strip()
    shutil.copy2(pathlib.Path(binary_dir) / "now-harness", executable)
