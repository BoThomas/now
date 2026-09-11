#!/usr/bin/env python3
from harness import build
"""Exercise reminder retention and the native paused menu with synthetic data only."""
import os
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
    executable = bundle / "MacOS/reminder-smoke"
    build("reminder", executable)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}"], check=True, timeout=30, env=dict(os.environ, NOW_TEST_CACHE_ROOT=str(directory / "cache")))
        subprocess.run([str(executable), "--quit"], check=True, timeout=30, env=dict(os.environ, NOW_TEST_CACHE_ROOT=str(directory / "cache")))
    finally:
        server.shutdown()
        server.server_close()
