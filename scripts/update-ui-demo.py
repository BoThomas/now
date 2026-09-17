#!/usr/bin/env python3
"""Run the real updater UI in a signed fixture with disposable state and bundles."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = os.environ.get("NOW_SIGNING_IDENTITY_SHA1", "A505B08900C56A28709479297A049525A2A187C6")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def running_apps():
    """Fail closed if process discovery is unavailable; never depend on a shell PATH."""
    result = subprocess.run(["/usr/bin/pgrep", "-x", "now"], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError("Cannot inspect running now instances: " + result.stderr.strip())
    apps = {}
    for value in result.stdout.split():
        pid = int(value)
        files = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"],
                               capture_output=True, text=True)
        if files.returncode:
            if alive(pid):
                raise RuntimeError(f"Cannot inspect executable for now process {pid}")
            continue
        for line in files.stdout.splitlines():
            if line.startswith("n") and line.endswith("/now.app/Contents/MacOS/now"):
                apps[pid] = Path(line[1:]).parents[2]
                break
    return apps


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop_apps(apps):
    for pid, bundle in apps.items():
        if running_apps().get(pid) == bundle:
            os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while set(apps) & set(running_apps()):
        if time.monotonic() > deadline:
            raise RuntimeError("An app did not quit; leaving its files intact")
        time.sleep(0.1)


def seed_profile(domain, work, escalation, version):
    """Only this uniquely named suite is ever written or deleted."""
    if not domain.startswith("com.thomasboch.now.updater-smoke."):
        raise ValueError("The demo requires a disposable preferences domain")
    state = {"subscriptions": [], "nativeCalendars": [], "settings": {
        "automaticUpdateChecks": True, "launchAtLogin": False, "soundEnabled": False,
        "reminderScreen": "mainDisplay"
    }}
    values = {
        "local.tboch.now.state.v1": json.dumps(state).encode(),
        "local.tboch.now.feature-guides.v1": json.dumps({
            "encountered": ["notification-setup-v1"],
            "pendingSettings": [], "pendingPresentation": []
        }).encode()
    }
    # The new fixture introduces only the display card, after the health-checked update.
    if escalation:
        now = time.time() - 978307200
        values["local.tboch.now.updates.v1"] = json.dumps({
            "lastSuccessCheckDate": now - 25 * 3600, "lastAttemptDate": now - 25 * 3600,
            "attemptsToday": 0, "attemptsDayStamp": "", "firstSeenUpdateVersion": version,
            "firstSeenUpdateDate": now - 4 * 86400
        }).encode()
    preferences = work / "preferences.plist"
    preferences.write_bytes(plistlib.dumps(values))
    run("/usr/bin/defaults", "import", domain, str(preferences))


class QuietServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def prepare_release(work):
    fixture = ROOT / "outputs/testing/release/now.app"
    app = work / "run/now.app"
    shutil.copytree(fixture, app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = str(int(info["CFBundleShortVersionString"].split(".")[0]) + 1) + ".0.0"
    forged = work / "forge/now.app"
    shutil.copytree(fixture, forged)
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = str(int(info["CFBundleVersion"]) + 1)
    (forged / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    run("/usr/bin/codesign", "--force", "--deep", "--sign", IDENTITY, "--entitlements",
        str(ROOT / "now.entitlements"), str(forged))
    www = work / "www"
    release = www / "ok/api/repos/BoThomas/now/releases/latest"
    release.parent.mkdir(parents=True)
    archive = www / f"ok/now-v{version}.zip"
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(forged), str(archive))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietServer, directory=str(www)))
    base = f"http://127.0.0.1:{server.server_port}/ok"
    release.write_text(json.dumps({
        "tag_name": "v" + version, "published_at": "2026-01-01T00:00:00Z",
        "body": "### Added\n- Pick your reminder display\n\n### Fixed\n- Isolated update tour",
        "assets": [{"name": archive.name, "browser_download_url": base + "/" + archive.name,
                    "size": archive.stat().st_size}]
    }))
    return app, version, server, base + "/api"


def run_session(work, domain, escalation, smoke):
    app, version, server, api = prepare_release(work)
    seed_profile(domain, work, escalation, version)
    (work / "home/.Trash").mkdir(parents=True)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("NOW_SMOKE_", "NOW_TEST_", "NOW_UPDATE_", "NOW_HEALTH_"))}
    environment.update(NOW_TEST_PREFERENCES_DOMAIN=domain, NOW_TEST_CACHE_ROOT=str(work / "cache"),
                       NOW_TEST_DEMO_ROOT=str(work), NOW_UPDATE_API_BASE=api,
                       NOW_TEST_DEMO_VERSION=version)
    if smoke:
        environment["NOW_TEST_DEMO_SMOKE"] = "1"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    child = None
    try:
        print(f"Session: {work}\nPreferences: {domain}", flush=True)
        print("Menu → update → Install & Relaunch → Update Complete → Check for Updates again.", flush=True)
        print("Only the session copy is updated. Ctrl-C ends the tour and cleans up.", flush=True)
        with (work / "app.log").open("w") as log:
            child = subprocess.Popen([str(app / "Contents/MacOS/now")], env=environment, stdout=log, stderr=log)
            deadline = time.monotonic() + 120
            while True:
                child.poll()  # Reap the old app so the helper's PID-exit check can proceed.
                if smoke and (work / "gui-success").exists() and list((work / "home/.Trash").glob("now-old-*.app")):
                    assert (work / "gui-success").read_text() == version
                    print("UPDATE DEMO SMOKE OK — real GUI install/relaunch, retained profile, health commit, isolated Trash", flush=True)
                    return
                if smoke and time.monotonic() > deadline:
                    raise RuntimeError("GUI update timed out: " + (work / "app.log").read_text())
                if child.returncode is not None and not (work / "helper-pid").exists():
                    if smoke or child.returncode:
                        raise RuntimeError("Demo exited before install: " + (work / "app.log").read_text())
                    return
                time.sleep(0.2)
    finally:
        server.shutdown()
        server.server_close()
        if child is not None:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=10)


def cleanup(work, domain):
    app = work / "run/now.app"
    stop_apps({pid: bundle for pid, bundle in running_apps().items() if bundle == app})
    # Ctrl-C can land during a swap. Let its helper finish before removing any files,
    # then stop a possible newly launched/rolled-back child as well.
    helper = work / "helper-pid"
    if helper.exists():
        pid = int(helper.read_text())
        deadline = time.monotonic() + 40
        while alive(pid):
            if time.monotonic() > deadline:
                raise RuntimeError(f"Helper still running; preserving session at {work}")
            time.sleep(0.1)
    stop_apps({pid: bundle for pid, bundle in running_apps().items() if bundle == app})
    subprocess.run(["/usr/bin/defaults", "delete", domain], capture_output=True)
    shutil.rmtree(work)


def installed_preferences():
    snapshots = {}
    for domain in ("com.thomasboch.now", "local.tboch.now"):
        result = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True)
        if result.returncode and b"does not exist" not in result.stderr and b"not found" not in result.stderr:
            raise RuntimeError("Cannot inspect installed preferences for " + domain)
        snapshots[domain] = plistlib.loads(result.stdout) if result.returncode == 0 else None
    return snapshots


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--escalation", action="store_true", help="seed a four-day-old update offer")
    parser.add_argument("--smoke", action="store_true", help="automate the GUI install and verify isolation; temporarily quit/reopen now")
    args = parser.parse_args()
    previous = running_apps()
    if previous and not args.smoke:
        parser.error("Quit the running now first (the real multi-instance guard remains enabled)")
    for app in previous.values():
        if b"NOW_TEST_PREFERENCES_DOMAIN" in (app / "Contents/MacOS/now").read_bytes():
            parser.error("Close the other updater fixture first; it requires its own session environment")
    work = None
    snapshots = None
    domain = "com.thomasboch.now.updater-smoke." + uuid.uuid4().hex
    try:
        if args.smoke:
            stop_apps(previous)
            snapshots = installed_preferences()
        run(str(ROOT / "build-app.sh"), "--require-identity", "--release", "--test-updater", cwd=ROOT)
        if running_apps():
            raise RuntimeError("Another now instance started; refusing to launch the demo")
        work = Path(tempfile.mkdtemp(prefix="now update demo ")).resolve()
        run_session(work, domain, args.escalation, args.smoke)
    finally:
        try:
            if work is not None:
                cleanup(work, domain)
            if snapshots is not None:
                if installed_preferences() != snapshots:
                    raise RuntimeError("Installed preferences changed during the isolated demo")
                print("PASS: installed current and legacy preferences unchanged", flush=True)
        finally:
            if args.smoke:
                for app in set(previous.values()):
                    run("/usr/bin/open", str(app))


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
