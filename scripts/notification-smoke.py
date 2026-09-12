#!/usr/bin/env python3
from harness import build
"""Production notification routing and async transport with synthetic calendars.
No Calendar queries or live preferences. --gui uses real Notification Center;
--activation-smoke / --all-smokes require an interactive, unlocked macOS desktop
and briefly present a synthetic fullscreen reminder to verify keyboard focus.
"""
import pathlib
import plistlib
import subprocess
import tempfile
import uuid
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


with tempfile.TemporaryDirectory(prefix="now-notification-smoke-") as name:
    directory = pathlib.Path(name)
    contents = directory / "NotificationSmoke.app" / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    identifier = "com.thomasboch.now.notification-smoke." + uuid.uuid4().hex
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "notification-smoke", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0", "CFBundleName": "now Notification Preview", "CFBundleDisplayName": "now Notification Preview", "LSUIElement": True
    }))
    executable = contents / "MacOS/notification-smoke"
    build("notification", executable)
    gui = "--gui" in sys.argv
    if gui or "--activation-smoke" in sys.argv or "--all-smokes" in sys.argv:
        subprocess.run(["codesign", "--force", "--sign", "A505B08900C56A28709479297A049525A2A187C6", str(contents.parent)], check=True)
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(contents.parent)], check=True)
        print("Isolated notification preview: " + str(contents.parent), flush=True)
    try:
        def run(mode=None, activation=False):
            subprocess.run(["defaults", "delete", identifier], capture_output=True)
            args = [str(executable), str(directory)] + ([mode] if mode else [])
            if activation:
                args.append("--activation-smoke")
            subprocess.run(args, check=True, timeout=1800 if gui else 60)
        if "--all-smokes" in sys.argv:
            run("--recovery-smoke")
            run()
            for mode in ["--startup-new", "--startup-existing", "--startup-legacy"]:
                run(mode)
            run("--startup-existing", activation=True)
        elif "--activation-smoke" in sys.argv:
            run("--startup-existing", activation=True)
        elif "--startup-smoke" in sys.argv:
            for mode in ["--startup-new", "--startup-existing", "--startup-legacy"]:
                run(mode)
        else:
            if not gui:
                run("--recovery-smoke")
            run("--gui" if gui else None)
    finally:
        if gui or "--activation-smoke" in sys.argv or "--all-smokes" in sys.argv:
            subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-u", str(contents.parent)], capture_output=True)
        subprocess.run(["defaults", "delete", identifier], capture_output=True)
        subprocess.run(["defaults", "delete", identifier + ".legacy"], capture_output=True)
