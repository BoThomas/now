#!/usr/bin/env python3
"""Exercise the production rollback helper with disposable, non-GUI children."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent


def helper_script():
    source = (ROOT / "Sources/Updater.swift").read_text()
    return textwrap.dedent(source.split('static let helperScript = """\n', 1)[1].split('\n    """', 1)[0])


class UpdateHelperTests(unittest.TestCase):
    def check_rollback(self, ignores_term):
        with tempfile.TemporaryDirectory(prefix="now helper test ") as folder:
            root = Path(folder)
            app = root / "now.app"
            staged = root / "staging/extracted/now.app"
            app.mkdir()
            (app / "version").write_text("old")
            executable = staged / "Contents/MacOS/now"
            executable.parent.mkdir(parents=True)
            (staged / "version").write_text("new")
            executable.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""\
                import os
                from pathlib import Path
                import signal
                import time
                root = Path(os.environ["TEST_ROOT"])
                def terminate(signum, frame):
                    time.sleep(0.5)
                    (root / "version-at-exit").write_text((root / "now.app/version").read_text())
                    raise SystemExit(0)
                signal.signal(signal.SIGTERM, signal.SIG_IGN if os.environ["TEST_IGNORE_TERM"] == "1" else terminate)
                (root / "child-pid").write_text(str(os.getpid()))
                while True:
                    time.sleep(0.1)
                """))
            executable.chmod(0o755)
            (root / "home/.Trash").mkdir(parents=True)
            env = dict(os.environ, TEST_ROOT=str(root), TEST_IGNORE_TERM=str(int(ignores_term)),
                       HOME=str(root / "home"), NOW_OLD_PID="99999999", NOW_APP_PATH=str(app),
                       NOW_STAGED_APP=str(staged), NOW_BACKUP_PATH=str(root / "backup.app"),
                       NOW_FAILED_PATH=str(root / "failed.app"), NOW_STAGING_ROOT=str(root / "staging"),
                       NOW_HEALTH_ACK=str(root / "staging/health-ack"), NOW_HEALTH_TOKEN="fixture-token",
                       NOW_SMOKE_HEALTH_TIMEOUT="2", NOW_RELEASES_URL="https://example.invalid/releases")
            for key in list(env):
                if key.startswith("NOW_SMOKE_") and key != "NOW_SMOKE_HEALTH_TIMEOUT":
                    del env[key]
            # Intercept only the final platform launch; every swap/termination command
            # still comes from the exact production helper. Never open a real app/URL.
            launch_probe = """
            open() {
              printf '%s\\n' "$@" > "$TEST_ROOT/open-args"
              if kill -0 "$(cat "$TEST_ROOT/child-pid")" 2>/dev/null; then
                printf alive > "$TEST_ROOT/child-at-open"
              else
                printf stopped > "$TEST_ROOT/child-at-open"
              fi
              cat "$NOW_APP_PATH/version" > "$TEST_ROOT/version-at-open"
            }
            """
            try:
                result = subprocess.run(["/bin/sh", "-c", launch_probe + helper_script()], env=env,
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual((root / "child-at-open").read_text(), "stopped",
                                 "rollback relaunch raced the still-running updated child")
                self.assertEqual((root / "version-at-open").read_text(), "old")
                self.assertIn("NOW_UPDATE_ERROR=updated app startup health check timed out",
                              (root / "open-args").read_text())
                self.assertFalse((root / "backup.app").exists())
                self.assertFalse((root / "failed.app").exists())
                self.assertFalse((root / "staging").exists())
                self.assertEqual(list((root / "home/.Trash").iterdir()), [])
                if not ignores_term:
                    self.assertEqual((root / "version-at-exit").read_text(), "new",
                                     "bundle was restored before the updated child exited")
            finally:
                if (root / "child-pid").exists():
                    try:
                        os.kill(int((root / "child-pid").read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_rollback_waits_for_delayed_termination(self):
        self.check_rollback(ignores_term=False)

    def test_rollback_bounds_a_child_ignoring_termination(self):
        self.check_rollback(ignores_term=True)


if __name__ == "__main__":
    unittest.main()
