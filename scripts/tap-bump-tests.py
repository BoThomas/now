#!/usr/bin/env python3
"""Exercise tap publication against disposable local Git repositories, never GitHub."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("tap-bump.sh")


class TapBumpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="now-tap-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "release.zip"
        self.archive.write_bytes(b"disposable release fixture")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("NOW_TAP_", "GIT_"))}
        self.env.update(
            TMPDIR=str(self.root),
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="Tap Fixture",
            GIT_AUTHOR_EMAIL="fixture@example.invalid",
            GIT_COMMITTER_NAME="Tap Fixture",
            GIT_COMMITTER_EMAIL="fixture@example.invalid",
        )

    def run_command(self, *args, check=True):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, check=check)

    def make_tap(self, version, literal=False):
        source = self.root / "source"
        source.mkdir()
        casks = source / "Casks"
        casks.mkdir()
        url_version = version if literal else "#{version}"
        (casks / "now.rb").write_text(
            f'cask "now" do\n  version "{version}"\n  sha256 "{"0" * 64}"\n'
            f'  url "https://example.invalid/v{url_version}/now-v{url_version}.zip"\nend\n'
        )
        self.run_command("git", "init", "-q", str(source))
        self.run_command("git", "-C", str(source), "add", ".")
        self.run_command("git", "-C", str(source), "commit", "-qm", "fixture")
        self.remote = self.root / "remote.git"
        self.run_command("git", "clone", "--bare", "-q", str(source), str(self.remote))
        self.env["NOW_TAP_URL"] = str(self.remote)

    def remote_git(self, *args):
        return self.run_command("git", "--git-dir", str(self.remote), *args).stdout.strip()

    def bump(self, version):
        return self.run_command("/bin/zsh", str(SCRIPT), version, str(self.archive), check=False)

    def test_lookup_failures_are_errors(self):
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        gh = binary_dir / "gh"
        self.env["PATH"] = str(binary_dir) + os.pathsep + self.env["PATH"]
        for reason in ("HTTP 503: Service Unavailable", "HTTP 404: Not Found", "network unavailable"):
            with self.subTest(reason=reason):
                gh.write_text('#!/bin/sh\nif [ "$1" = auth ]; then exit 0; fi\n'
                              f'echo "{reason}" >&2\nexit 1\n')
                gh.chmod(0o755)
                result = self.bump("2.0.1")
                self.assertEqual(result.returncode, 1)
                self.assertIn(reason, result.stderr)
                self.assertIn("could not access tap repository", result.stderr)

    def test_downgrades_never_change_remote(self):
        self.make_tap("3.2.10")
        original = self.remote_git("rev-parse", "HEAD")
        for version in ("2.99.99", "3.1.99", "3.2.9"):
            with self.subTest(version=version):
                result = self.bump(version)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("refusing downgrade", result.stderr)
                self.assertEqual(self.remote_git("rev-parse", "HEAD"), original)

    def test_upgrade_and_retry(self):
        self.make_tap("2.0.9")
        for version in ("2.0.10", "2.1.0", "3.0.0"):
            with self.subTest(version=version):
                result = self.bump(version)
                self.assertEqual(result.returncode, 0, result.stderr)
                cask = self.remote_git("show", "HEAD:Casks/now.rb")
                self.assertIn(f'version "{version}"', cask)
                self.assertIn(hashlib.sha256(self.archive.read_bytes()).hexdigest(), cask)
                self.assertIn('/v#{version}/now-v#{version}.zip', cask)
                head = self.remote_git("rev-parse", "HEAD")
                self.assertEqual(self.bump(version).returncode, 0)
                self.assertEqual(self.remote_git("rev-parse", "HEAD"), head)

    def test_literal_asset_url(self):
        self.make_tap("2.0.9", literal=True)
        result = self.bump("2.0.10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/v2.0.10/now-v2.0.10.zip', self.remote_git("show", "HEAD:Casks/now.rb"))


if __name__ == "__main__":
    unittest.main()
