#!/usr/bin/env python3
"""Real process restarts with production cache, transport, AppStore and native menu.
Only synthetic feeds, a temporary cache and a disposable preferences domain are used.
"""
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
phase = "seed"
anchor = datetime.datetime.now(datetime.timezone.utc)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        uid = self.path.strip("/")
        status = 503 if phase == "mixed" and uid == "b" else 200
        start = anchor + datetime.timedelta(seconds=120 if uid == "a" else 7200)
        end = start + datetime.timedelta(hours=1)
        title = "Recovered" if phase == "recovery" else "Saved"
        event = (f"BEGIN:VEVENT\nUID:{uid}\nSUMMARY:{title} {uid}\n"
                 f"DTSTART:{start:%Y%m%dT%H%M%SZ}\nDTEND:{end:%Y%m%dT%H%M%SZ}\n"
                 "LOCATION:Test room\nDESCRIPTION:Synthetic notes\nURL:https://zoom.us/j/123\nEND:VEVENT\n")
        if phase == "empty" and uid == "a":
            event = ""
        body = ("BEGIN:VCALENDAR\nVERSION:2.0\n" + event + "END:VCALENDAR\n").encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with tempfile.TemporaryDirectory(prefix="now-cache-smoke-") as folder:
    directory = pathlib.Path(folder)
    bundle = directory / "CacheSmoke.app" / "Contents"
    (bundle / "MacOS").mkdir(parents=True)
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.thomasboch.now.cache-smoke." + uuid.uuid4().hex,
        "CFBundleExecutable": "cache-smoke", "LSUIElement": True
    }))
    app = directory / "App.swift"
    app.write_text((ROOT / "Sources/App.swift").read_text().replace("@main\nenum NowApp", "enum NowApp", 1))
    store = directory / "AppStore.swift"
    text = (ROOT / "Sources/AppStore.swift").read_text().replace("private func tick()", "func tick()", 1)
    text = text.replace("private func merge(results:", "func merge(results:", 1)
    text = text.replace("private var fetchTracker", "var fetchTracker", 1)
    text = text.replace("eventCache: CalendarEventCache = CalendarEventCache()", "eventCache: CalendarEventCache = CalendarEventCache(directory: URL(fileURLWithPath: " + json.dumps(str(directory / "cache")) + "))")
    # Inject a URL loading failure, not a guessed error string or a network change.
    text = text.replace("let config = URLSessionConfiguration.ephemeral", "let config = URLSessionConfiguration.ephemeral\n        config.protocolClasses = [OfflineProtocol.self]")
    start = text.index("    func fetchNativeEvents() {")
    end = text.index("    private func scheduleNativeStoreRefresh()", start)
    text = text[:start] + "    func fetchNativeEvents() { precondition(nativeCalendars.isEmpty) }\n\n" + text[end:]
    store.write_text(text)
    sources = sorted(str(p) for p in (ROOT / "Sources").glob("*.swift") if p.name not in ["App.swift", "AppStore.swift"])
    executable = bundle / "MacOS/cache-smoke"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", "-sdk", sdk,
                    "-target", "arm64-apple-macos13.0", "-module-cache-path", str(directory / "modules"),
                    *sources, str(app), str(store), str(ROOT / "scripts/calendar-cache-smoke.swift"),
                    "-o", str(executable), "-framework", "SwiftUI", "-framework", "AppKit",
                    "-framework", "ServiceManagement", "-framework", "EventKit", "-framework", "CoreAudio"], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for phase in ["seed", "gui", "offline", "mixed", "recovery", "empty", "offline-empty", "seed", "edit", "seed", "corrupt", "storage"]:
            if phase == "corrupt":
                (directory / "cache" / "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.json").write_text("broken JSON")
            subprocess.run([str(executable), phase, f"http://127.0.0.1:{server.server_port}", str(directory / "cache")], check=True, timeout=30)
            if phase == "gui":
                saved = json.loads((directory / "cache" / "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.json").read_text())
                assert saved["meetings"][0]["title"] == "Quit snapshot", "normal quit did not finish the accepted write"
                print("PASS: normal AppKit quit drained the final accepted snapshot", flush=True)
    finally:
        server.shutdown()
        server.server_close()
