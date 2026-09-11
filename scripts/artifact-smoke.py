#!/usr/bin/env python3
"""Check the shipping boundary, then launch production code in a disposable signed bundle."""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import http.server
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "outputs/now.app").resolve()
executable = app / "Contents/MacOS/now"
metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert metadata == plistlib.loads((ROOT / "Info.plist").read_bytes()), "bundle metadata drift"
assert (app / "Contents/Resources/AppIcon.png").is_file()
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
identity = os.environ.get("NOW_SIGNING_IDENTITY_SHA1", "A505B08900C56A28709479297A049525A2A187C6")
requirement = subprocess.check_output(["codesign", "-d", "-r-", str(app)], stderr=subprocess.STDOUT, text=True)
assert 'identifier "com.thomasboch.now"' in requirement, requirement
assert 'certificate root = H"' + identity.lower() + '"' in requirement, requirement
entitlements = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL)
assert plistlib.loads(entitlements) == plistlib.loads((ROOT / "now.entitlements").read_bytes())
architecture = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
assert architecture == "arm64", architecture
load_commands = subprocess.check_output(["vtool", "-show-build", str(executable)], text=True)
assert "minos 13.0" in load_commands, load_commands
binary = executable.read_bytes()
for fixture in (b"SELFTEST OK", b"SELFTEST FAILED", b"SMOKE: old app", b"smokeCommitEvents",
                b"SelfTestRunner", b"UpdaterTestRunner", b"NOW_TEST_PREFERENCES_DOMAIN"):
    assert fixture not in binary, "shipping fixture: " + repr(fixture)
for flag in ("--selftest", "--update-smoke"):
    result = subprocess.run([str(executable), flag], capture_output=True, text=True, timeout=10)
    assert result.returncode == 64, result
print("PASS: shipping metadata, arm64/macOS 13, signature and fixture exclusion", flush=True)

class NoReleases(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(404)
        self.end_headers()

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NoReleases)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    base = f"http://127.0.0.1:{server.server_port}"
    result = subprocess.run([str(executable), "--update-check"], capture_output=True, text=True,
                            timeout=10, env=dict(os.environ, NOW_UPDATE_API_BASE=base))
    assert result.returncode == 0 and "no releases (404)" in result.stdout, result
    print("PASS: shipping read-only update diagnostic handles a synthetic 404", flush=True)
finally:
    server.shutdown()
    server.server_close()

with tempfile.TemporaryDirectory(prefix="now-shipping-smoke-") as folder:
    root = pathlib.Path(folder)
    feed = root / "empty.ics"
    feed.write_text("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n")
    result = subprocess.run([str(executable), "--parse", str(feed)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and "ERROR" not in result.stdout, result
    clone = root / "ShippingSmoke.app"
    shutil.copytree(app, clone)
    domain = "com.thomasboch.now.shipping-smoke." + uuid.uuid4().hex
    metadata["CFBundleIdentifier"] = domain
    (clone / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
    subprocess.run(["codesign", "--force", "--sign", identity, "--entitlements",
                    str(ROOT / "now.entitlements"), str(clone)], check=True)
    # A present empty profile prevents migration from the installed app's legacy domain.
    preferences = root / "preferences.plist"
    preferences.write_bytes(plistlib.dumps({"local.tboch.now.state.v1": json.dumps({
        "subscriptions": [], "nativeCalendars": [],
        "settings": {"automaticUpdateChecks": False, "launchAtLogin": False}
    }).encode()}))
    child = None
    try:
        subprocess.run(["defaults", "import", domain, str(preferences)], check=True)
        with (root / "launch.log").open("w") as log:
            child = subprocess.Popen([str(clone / "Contents/MacOS/now")], stdout=log, stderr=log)
            time.sleep(5)
            assert child.poll() is None, (root / "launch.log").read_text()
        print("PASS: production GUI entry remained live for five seconds in disposable domain", flush=True)
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            child.wait(timeout=10)
        subprocess.run(["defaults", "delete", domain], capture_output=True)
print("ARTIFACT SMOKE OK")
