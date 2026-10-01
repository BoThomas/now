"""Build explicit SwiftPM fixture targets without copying or rewriting app sources."""
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def build(suite, executable, root=ROOT):
    configuration = os.environ.get("NOW_TEST_CONFIGURATION", "debug")
    if configuration not in ("debug", "release"):
        raise ValueError("NOW_TEST_CONFIGURATION must be debug or release")
    environment = dict(os.environ, NOW_TEST_SUITE=suite)
    command = [str(root / "scripts/swiftpm.sh"), "build", "--scratch-path",
               str(root / ".build/tests" / suite), "-c", configuration]
    subprocess.run(command + ["--product", "now-harness"], env=environment, check=True, cwd=root)
    binary_dir = subprocess.check_output(command + ["--show-bin-path"], env=environment,
                                         text=True, cwd=root).strip()
    shutil.copy2(pathlib.Path(binary_dir) / "now-harness", executable)


def unregister_bundle(contents):
    """Remove a disposable smoke bundle (.app) from LaunchServices.

    Launching a bundled harness executable registers the throwaway app
    implicitly, even without lsregister -f; stale dead-temp registrations
    otherwise accumulate in the LaunchServices database.
    """
    subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                    "LaunchServices.framework/Support/lsregister", "-u", str(contents)],
                   capture_output=True)


def run_smoke(args, timeout, env=None):
    """Run a smoke child, escalating SIGTERM before SIGKILL on hangs.

    Smoke harnesses unregister their menu-bar status item at exit and on
    SIGTERM; an immediate SIGKILL timeout would leave a ghost icon in the
    developer's menu bar.
    """
    child = subprocess.Popen(args, env=env)
    try:
        code = child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.terminate()
        try:
            code = child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            code = child.wait()
    if code != 0:
        raise subprocess.CalledProcessError(code, args)
