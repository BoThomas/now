#!/usr/bin/env python3
"""Headless SDK gate and SwiftPM argument/exit propagation regressions."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("build_metadata", ROOT / "scripts/build_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


def commands(sdk="27.0", minimum="13.0", platform="MACOS"):
    return f"Load command 10\n cmd LC_BUILD_VERSION\n cmdsize 32\n platform {platform}\n minos {minimum}\n sdk {sdk}\n ntools 1\n"


class SDKMetadataTests(unittest.TestCase):
    def test_matching_sdk_and_target(self):
        self.assertEqual(metadata.validate_metadata("arm64\n", commands(), "27.0.0")["sdk"], "27.0")

    def test_deployment_target_is_not_sdk(self):
        with self.assertRaisesRegex(ValueError, "SDK mismatch"):
            metadata.validate_metadata("arm64", commands(sdk="13.0"), "27.0")

    def test_wrong_minimum(self):
        with self.assertRaisesRegex(ValueError, "deployment target"):
            metadata.validate_metadata("arm64", commands(minimum="14.0"), "27")

    def test_wrong_architecture_or_platform(self):
        for architecture, platform in [("arm64 x86_64", "MACOS"), ("x86_64", "MACOS"), ("arm64", "IOS")]:
            with self.subTest(architecture=architecture, platform=platform), self.assertRaises(ValueError):
                metadata.validate_metadata(architecture, commands(platform=platform), "27")

    def test_missing_duplicate_and_malformed_metadata(self):
        for text in ["", commands() + commands(), commands().replace(" sdk 27.0\n", ""), commands(sdk="invalid")]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                metadata.validate_metadata("arm64", text, "27.0")

    def test_invalid_expected_version(self):
        with self.assertRaises(ValueError):
            metadata.validate_metadata("arm64", commands(), "not-an-sdk")

    def test_provenance_allows_source_archive_without_claiming_clean_git(self):
        with tempfile.TemporaryDirectory(prefix="now-build-info-") as name:
            executable = Path(name) / "binary"
            executable.write_bytes(b"synthetic executable")
            destination = Path(name) / "build-info.json"
            fields = metadata.validate_metadata("arm64", commands(), "27")
            no_git = subprocess.CompletedProcess([], 128, stdout="", stderr="not a repository")
            with mock.patch.dict(os.environ, NOW_SWIFTC="/fake/swiftc", NOW_SWIFTPM_BACKEND="native"), \
                    mock.patch.object(metadata.subprocess, "run", return_value=no_git), \
                    mock.patch.object(metadata.subprocess, "check_output", return_value="selected toolchain"):
                metadata.record_provenance(executable, fields, destination)
            record = json.loads(destination.read_text())
            self.assertIsNone(record["sourceRevision"])
            self.assertIsNone(record["workingTreeDirty"])
            self.assertEqual(record["buildVersion"]["sdk"], "27.0")
            self.assertEqual(record["backend"], "native")

    def test_failed_sdk_gate_does_not_write_provenance(self):
        with tempfile.TemporaryDirectory(prefix="now-rejected-build-") as name:
            destination = Path(name) / "build-info.json"
            with mock.patch.object(sys, "argv", ["check", "binary", "--sdk", "27", "--record", str(destination)]), \
                    mock.patch.object(metadata, "check_binary", side_effect=ValueError("SDK mismatch")), \
                    mock.patch.object(sys, "stderr"), self.assertRaises(SystemExit) as stopped:
                metadata.main()
            self.assertEqual(stopped.exception.code, 1)
            self.assertFalse(destination.exists())


@unittest.skipUnless(shutil.which("zsh"), "wrapper probes require zsh")
class WrapperTests(unittest.TestCase):
    def test_arguments_and_failures_are_preserved(self):
        with tempfile.TemporaryDirectory(prefix="now-build-wrapper-") as name:
            root = Path(name)
            (root / "scripts").mkdir()
            shutil.copy2(ROOT / "scripts/swiftpm.sh", root / "scripts/swiftpm.sh")
            fake = root / "fake swift"
            fake.write_text("#!" + sys.executable + "\nimport os,sys,json\n"
                            "open(os.environ['RECORD'], 'w').write(json.dumps(sys.argv[1:]))\n"
                            "sys.exit(int(os.environ['FAKE_EXIT']))\n")
            fake.chmod(0o755)
            (root / "scripts/macos-toolchain.sh").write_text(
                'export NOW_SWIFT="$FAKE_SWIFT" SDK_PATH="$FAKE_SDK" NOW_SWIFTPM_BACKEND=native\n')
            record = root / "arguments.json"
            env = dict(os.environ, FAKE_SWIFT=str(fake), FAKE_SDK=str(root / "SDK With Space.sdk"),
                       RECORD=str(record), FAKE_EXIT="0")
            command = ["zsh", str(root / "scripts/swiftpm.sh"), "build", "--scratch-path", "scratch with space", "--show-bin-path"]
            self.assertEqual(subprocess.run(command, env=env).returncode, 0)
            args = json.loads(record.read_text())
            self.assertEqual(args[:5], ["build", "--build-system", "native", "--sdk", env["FAKE_SDK"]])
            self.assertEqual(args[-3:], ["--scratch-path", "scratch with space", "--show-bin-path"])
            self.assertNotIn("-Xswiftc", args)
            self.assertEqual(subprocess.run(command, env=dict(env, FAKE_EXIT="42")).returncode, 42)

    def test_invalid_explicit_developer_directory_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="now-not-xcode-") as name:
            result = subprocess.run(["zsh", "-ec", 'source "$1"', "zsh", str(ROOT / "scripts/macos-toolchain.sh")],
                                    env=dict(os.environ, DEVELOPER_DIR=name), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must select full Xcode", result.stderr)


if __name__ == "__main__":
    unittest.main()
