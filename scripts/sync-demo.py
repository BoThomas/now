#!/usr/bin/env python3
"""Run the built app with isolated preferences and two controllable local feeds."""
import argparse
import datetime
import html
import http.server
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEMO = pathlib.Path(tempfile.mkdtemp(prefix="now-sync-demo-"))
state = {"failed": False, "revision": 1, "requests": {}}
lock = threading.Lock()
anchor = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        status, content_type = 200, "text/html; charset=utf-8"
        if self.path in ("/fail", "/recover"):
            with lock:
                state["failed"] = self.path == "/fail"
                state["revision"] += 1
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()
            return
        with lock:
            if self.path in ("/working.ics", "/flaky.ics"):
                state["requests"][self.path] = state["requests"].get(self.path, 0) + 1
                if self.path == "/flaky.ics" and state["failed"]:
                    status, body = 503, b"Demo: this calendar is temporarily unavailable."
                else:
                    working = self.path == "/working.ics"
                    offsets = [45, 90, 24 * 60] if working else [60]
                    events = []
                    for index, offset in enumerate(offsets):
                        start = anchor + datetime.timedelta(minutes=offset)
                        end = start + datetime.timedelta(minutes=30)
                        name = "Working feed" if working else "Cached when offline"
                        events.append(f"BEGIN:VEVENT\r\nUID:demo-{working}-{index}\r\nSUMMARY:DEMO {name} v{state['revision']}\r\nDTSTART:{start:%Y%m%dT%H%M%SZ}\r\nDTEND:{end:%Y%m%dT%H%M%SZ}\r\nEND:VEVENT\r\n")
                    body = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + "".join(events) + "END:VCALENDAR\r\n").encode()
                    content_type = "text/calendar"
            else:
                mode = "FAILING (HTTP 503)" if state["failed"] else "WORKING"
                counts = html.escape(json.dumps(state["requests"], indent=2))
                body = f'''<!doctype html><meta charset="utf-8"><title>now Sync Demo</title>
<style>body{{font:18px system-ui;max-width:760px;margin:60px auto;padding:20px;background:#151920;color:#eee}}a{{color:#92c9ff}}.button{{display:inline-block;padding:14px 20px;background:#29384b;margin:8px 12px 8px 0;border-radius:10px;text-decoration:none}}li{{margin:14px 0}}pre{{background:#222a35;padding:15px}}</style>
<h1>now Sync Demo</h1><p>Two calendars on one local server. Your normal now preferences are separate.</p>
<p><b>Unreliable feed: {mode}</b> · data revision {state['revision']}</p>
<ol><li>Open the demo app's menu-bar countdown. Events start with <b>DEMO</b>.</li>
<li>Click <b>Make one feed fail</b> below, then <b>Refresh Calendars</b> in the app.</li>
<li>The working feed advances to the new revision. The failing feed keeps its cached meeting. <b>Last synced</b> advances and the failure summary opens Settings.</li>
<li>Click <b>Recover feed</b>, then refresh again. The error disappears.</li></ol>
<a class="button" href="/fail">Make one feed fail</a><a class="button" href="/recover">Recover feed</a>
<p>Feed URLs: <a href="/working.ics">working.ics</a> · <a href="/flaky.ics">flaky.ics</a></p>
<p>Requests (reload this page to update):</p><pre>{counts}</pre>
<p>Automatic updates and sound are disabled. No native calendars are configured. Use Quit now in the demo app when finished.</p>'''.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()
server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
base = f"http://127.0.0.1:{server.server_port}"
identifier = "com.thomasboch.now.sync-demo." + uuid.uuid4().hex
app = DEMO / "now Sync Demo.app"
shutil.copytree(ROOT / "outputs/now.app", app)
plist_path = app / "Contents/Info.plist"
info = plistlib.loads(plist_path.read_bytes())
info.update(CFBundleIdentifier=identifier, CFBundleName="now Sync Demo", CFBundleDisplayName="now Sync Demo")
plist_path.write_bytes(plistlib.dumps(info))
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subscriptions = [dict(id=str(uuid.uuid4()), name=name, url=base+path, colorIndex=i, colorHex=color, isEnabled=True, titleFilters=[])
                 for i, (name, path, color) in enumerate([("DEMO — Working feed", "/working.ics", "#4DB6AC"), ("DEMO — Fails on demand", "/flaky.ics", "#FFB74D")])]
seed = dict(subscriptions=subscriptions, nativeCalendars=[], settings=dict(automaticUpdateChecks=False, launchAtLogin=False, soundEnabled=False, refreshMinutes=60))
preferences = DEMO / "preferences.plist"
preferences.write_bytes(plistlib.dumps({"local.tboch.now.state.v1": json.dumps(seed).encode()}))
subprocess.run(["defaults", "import", identifier, str(preferences)], check=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
log = (DEMO / "app.log").open("w")
process = subprocess.Popen([str(app / "Contents/MacOS/now")], stdout=log, stderr=log)
(DEMO / "demo.json").write_text(json.dumps(dict(url=base, app=str(app), pid=process.pid, domain=identifier), indent=2))
print(json.dumps(dict(url=base, app=str(app), pid=process.pid, directory=str(DEMO)), indent=2), flush=True)
try:
    process.wait()
finally:
    server.shutdown()
    server.server_close()
    subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log.close()
