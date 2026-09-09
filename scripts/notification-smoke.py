#!/usr/bin/env python3
"""Production notification routing and async transport with synthetic calendars.
No Notification Center access, Calendar queries, live preferences, or fullscreen UI.
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
    app = directory / "App.swift"
    app_text = (ROOT / "Sources/App.swift").read_text().replace("@main\nenum NowApp", "enum NowApp", 1)
    app_text = app_text.replace("private lazy var setupAssistant", "lazy var setupAssistant")
    app_text = app_text.replace("private var setupWindow", "var setupWindow")
    app_text = app_text.replace("private func finishInitialSetup", "func finishInitialSetup")
    if "--startup-smoke" in sys.argv:
        app_text = app_text.replace("let transport = SystemNotificationTransport()", "let transport = FakeNotifications()")
    app.write_text(app_text)
    store = directory / "AppStore.swift"
    text = (ROOT / "Sources/AppStore.swift").read_text()
    text = text.replace('legacyDomain = "local.tboch.now"', 'legacyDomain = "' + identifier + '.legacy"')
    for method in ["tick", "commitEvents", "finishRefresh", "merge", "appBecameActive", "beginFullRefresh", "retryMeetingDetection"]:
        text = text.replace("private func " + method + "(", "func " + method + "(")
    text = text.replace("@Published private(set) var isRefreshing", "@Published var isRefreshing")
    # Make native fetch a no-op only in this disposable test compilation.
    start = text.index("    func fetchNativeEvents() {")
    end = text.index("    private func scheduleNativeStoreRefresh()", start)
    text = text[:start] + "    func fetchNativeEvents() { precondition(nativeCalendars.isEmpty) }\n\n" + text[end:]
    store.write_text(text)
    updater = directory / "Updater.swift"
    update_text = (ROOT / "Sources/Updater.swift").read_text()
    update_text = update_text.replace("private func applyDecision(", "func applyDecision(")
    update_text = update_text.replace("@Published private(set) var stagedVersion", "@Published var stagedVersion")
    update_text = update_text.replace("private(set) var state = UpdateState()", "var state = UpdateState()")
    # Exercise production decision/notification paths without network or archives.
    start = update_text.index("    private func beginStaging(")
    end = update_text.index("    func retryPreparation()", start)
    update_text = update_text[:start] + "    private func beginStaging(_ manifest: UpdateManifest) {}\n\n" + update_text[end:]
    updater.write_text(update_text)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    executable = contents / "MacOS/notification-smoke"
    sources = [str(p) for p in sorted((ROOT / "Sources").glob("*.swift")) if p.name not in ["App.swift", "AppStore.swift", "Updater.swift"]]
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
                    "-target", "arm64-apple-macos13.0", "-module-cache-path", str(directory / "modules"),
                    *sources, str(app), str(store), str(updater), str(ROOT / "scripts/notification-smoke.swift"), str(ROOT / "scripts/notification-preview.swift"), str(ROOT / "scripts/notification-lifecycle-smoke.swift"),
                    "-o", str(executable)], check=True)
    gui = "--gui" in sys.argv
    if gui:
        subprocess.run(["codesign", "--force", "--sign", "A505B08900C56A28709479297A049525A2A187C6", str(contents.parent)], check=True)
        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", str(contents.parent)], check=True)
        print("Isolated notification preview: " + str(contents.parent), flush=True)
    try:
        if "--startup-smoke" in sys.argv:
            for mode in ["--startup-new", "--startup-existing", "--startup-legacy"]:
                subprocess.run(["defaults", "delete", identifier], capture_output=True)
                subprocess.run([str(executable), str(directory), mode], check=True, timeout=15)
        else:
            subprocess.run([str(executable), str(directory)] + (["--gui"] if gui else []), check=True, timeout=1800 if gui else 60)
    finally:
        subprocess.run(["defaults", "delete", identifier], capture_output=True)
        subprocess.run(["defaults", "delete", identifier + ".legacy"], capture_output=True)
