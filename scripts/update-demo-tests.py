#!/usr/bin/env python3
"""Regression checks for process discovery and disposable demo preferences."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("demo", Path(__file__).with_name("update-ui-demo.py"))
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)


class DemoTests(unittest.TestCase):
    def test_process_discovery_preserves_path_and_handles_spaces(self):
        original = os.environ.get("PATH")
        results = [subprocess.CompletedProcess([], 0, "123\n456\n", ""),
                   subprocess.CompletedProcess([], 0, "p123\nn/tmp/a space/now.app/Contents/MacOS/now\n", ""),
                   subprocess.CompletedProcess([], 0, "p456\nn/tmp/unrelated/now\n", "")]
        with patch.object(demo.subprocess, "run", side_effect=results) as run:
            self.assertEqual(demo.running_apps(), {123: Path("/tmp/a space/now.app")})
            self.assertEqual(run.call_args_list[0].args[0][0], "/usr/bin/pgrep")
            self.assertEqual(run.call_args_list[1].args[0][0], "/usr/sbin/lsof")
        self.assertEqual(os.environ.get("PATH"), original)

    def test_process_discovery_fails_closed(self):
        with patch.object(demo.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, "", "denied")):
            with self.assertRaisesRegex(RuntimeError, "Cannot inspect"):
                demo.running_apps()

    def test_live_process_without_executable_fails_closed(self):
        results = [subprocess.CompletedProcess([], 0, "123\n", ""),
                   subprocess.CompletedProcess([], 1, "", "denied")]
        with patch.object(demo.subprocess, "run", side_effect=results), patch.object(demo, "alive", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "Cannot inspect executable"):
                demo.running_apps()

    def test_session_seeds_only_its_domain(self):
        for escalation in (False, True):
            with tempfile.TemporaryDirectory() as folder, patch.object(demo, "run") as run:
                root = Path(folder)
                domain = "com.thomasboch.now.updater-smoke.test"
                demo.seed_profile(domain, root, escalation, "3.0.0")
                run.assert_called_once_with("/usr/bin/defaults", "import", domain, str(root / "preferences.plist"))
                values = plistlib.loads((root / "preferences.plist").read_bytes())
                profile = json.loads(values["local.tboch.now.state.v1"])
                self.assertEqual(profile["subscriptions"], [])
                self.assertEqual(profile["nativeCalendars"], [])
                self.assertFalse(profile["settings"]["launchAtLogin"])
                self.assertEqual("local.tboch.now.updates.v1" in values, escalation)

    def test_installed_domain_is_rejected_before_writing(self):
        with patch.object(demo, "run") as run:
            with self.assertRaises(ValueError):
                demo.seed_profile("com.thomasboch.now", Path("/tmp"), False, "3.0.0")
            run.assert_not_called()

    def test_interactive_rejects_running_app_before_any_mutation(self):
        with patch("sys.argv", ["update-ui-demo.py"]), patch.object(demo, "running_apps", return_value={123: Path("/Applications/now.app")}), patch.object(demo, "run") as run:
            with self.assertRaises(SystemExit):
                demo.main()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
