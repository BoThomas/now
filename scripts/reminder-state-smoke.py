#!/usr/bin/env python3
"""Exercise reminder retention and the native paused menu with synthetic data only."""
import datetime
import http.server
import json
import pathlib
import plistlib
import subprocess
import tempfile
import threading
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
state = {"empty": False, "fail_b": False, "fail_all": False, "revision": "Synthetic"}
counts = {}
counts_lock = threading.Lock()
anchor = datetime.datetime.now(datetime.timezone.utc)

def feed(uid):
    if uid == "a" and state["empty"]:
        event = ""
    else:
        start = anchor + datetime.timedelta(seconds=120 if uid == "a" else 7200)
        end = start + datetime.timedelta(hours=1)
        event = (f"BEGIN:VEVENT\nUID:{uid}\nSUMMARY:{state['revision']} {uid.upper()}\n"
                 f"DTSTART:{start:%Y%m%dT%H%M%SZ}\nDTEND:{end:%Y%m%dT%H%M%SZ}\n"
                 f"URL:https://zoom.us/j/{123 if uid == 'a' else 456}\nEND:VEVENT\n")
    return ("BEGIN:VCALENDAR\nVERSION:2.0\n" + event + "END:VCALENDAR\n").encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        status = 200
        if self.path == "/stats":
            with counts_lock:
                body = json.dumps(counts).encode()
        elif self.path in ("/all-fail", "/all-ok"):
            state["fail_all"] = self.path == "/all-fail"
            body = b"ok"
        elif self.path in ("/b-fail", "/b-ok"):
            state["fail_b"] = self.path == "/b-fail"
            state["revision"] = "Updated"
            body = b"ok"
        elif self.path == "/a-empty":
            state["empty"] = True
            body = b"ok"
        elif self.path == "/a-full":
            state["empty"] = False
            body = b"ok"
        else:
            with counts_lock:
                counts[self.path] = counts.get(self.path, 0) + 1
            status = 503 if state["fail_all"] or (self.path == "/b" and state["fail_b"]) else 200
            body = b"offline" if status == 503 else feed(self.path.lstrip("/"))
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with tempfile.TemporaryDirectory(prefix="now-reminder-smoke-") as directory:
    directory = pathlib.Path(directory)
    bundle = directory / "ReminderSmoke.app" / "Contents"
    (bundle / "MacOS").mkdir(parents=True)
    identifier = "com.thomasboch.now.review-smoke." + uuid.uuid4().hex
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "reminder-smoke", "LSUIElement": True
    }))
    # Keep the production helpers and tick body; only change test entry/access.
    app = directory / "App.swift"
    app_text = (ROOT / "Sources/App.swift").read_text().replace("@main\nenum NowApp", "enum NowApp", 1)
    # Exercise the production quit routing/dialog construction without actually
    # quitting or blocking on a modal. Only the disposable test copy gets hooks.
    app_text = app_text.replace("private var settingsWindow:", "var settingsWindow:")
    app_text = app_text.replace("private var updateWindow:", "var updateWindow:")
    app_text = app_text.replace("private func handleQuitFromWindow(", "func handleQuitFromWindow(")
    app_text = app_text.replace("alert.runModal()", "QuitSmoke.respond(to: alert)")
    app_text = app_text.replace("NSApp.terminate(nil)", "QuitSmoke.terminate()")
    app.write_text(app_text)
    store = directory / "AppStore.swift"
    store.write_text((ROOT / "Sources/AppStore.swift").read_text().replace("private func tick()", "func tick()", 1))
    # Full-refresh tests exercise production ICS orchestration without querying
    # the user's native Calendar store. This test-only stub replaces that query.
    store_text = store.read_text()
    store_text = store_text.replace("eventCache: CalendarEventCache = CalendarEventCache()", "eventCache: CalendarEventCache = CalendarEventCache(directory: URL(fileURLWithPath: " + json.dumps(str(directory / "cache")) + "))")
    store_text = store_text.replace("    private func commitEvents(", "    func commitEvents(", 1)
    store_text = store_text.replace("@Published private(set) var loginItemState", "@Published var loginItemState")
    native_start = store_text.index("    func fetchNativeEvents() {")
    native_end = store_text.index("    private func scheduleNativeStoreRefresh()", native_start)
    store.write_text(store_text[:native_start] + "    func fetchNativeEvents() { precondition(nativeCalendars.isEmpty) }\n\n" + store_text[native_end:])
    menu = directory / "MenuBar.swift"
    menu_text = (ROOT / "Sources/MenuBar.swift").read_text()
    menu_text = menu_text.replace("    deinit {", "    var smokeMenu: NSMenu { statusItem.menu! }\n    func smokeBeginTracking() { menuIsTracking = true }\n    func smokeEndTracking() { menuIsTracking = false }\n    func smokeRefreshMenu(at date: Date) { refreshOpenMenu(now: date) }\n\n    deinit {", 1)
    menu.write_text(menu_text)
    sources = sorted(str(p) for p in (ROOT / "Sources").glob("*.swift") if p.name not in ["App.swift", "AppStore.swift", "MenuBar.swift"])
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    executable = bundle / "MacOS/reminder-smoke"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
                    "-target", "arm64-apple-macos13.0", "-module-cache-path", str(directory / "modules"),
                    *sources, str(app), str(store), str(menu), str(ROOT / "scripts/reminder-state-smoke.swift"),
                    "-o", str(executable), "-framework", "SwiftUI", "-framework", "AppKit",
                    "-framework", "ServiceManagement", "-framework", "EventKit", "-framework", "CoreAudio"], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}"], check=True, timeout=30)
        subprocess.run([str(executable), "--quit"], check=True, timeout=30)
    finally:
        server.shutdown()
        server.server_close()
