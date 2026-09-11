#!/usr/bin/env python3
from harness import build
"""Local calendar ingestion smoke; compiles production sources without starting the app."""
import argparse
import datetime
import gzip
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--structure-only", action="store_true", help="Run only HTTP feed-structure/cache checks")
args = parser.parse_args()
ROOT = pathlib.Path(__file__).resolve().parent.parent
CAP = 5_000_000
event_start = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).strftime("%Y%m%dT%H%M%SZ")
event = f"BEGIN:VEVENT\r\nUID:http-structure\r\nDTSTART:{event_start}\r\nSUMMARY:HTTP meeting\r\nEND:VEVENT\r\n".encode()
state = {"active": 0, "peak": 0, "stream_bytes": 0, "stream_stopped": False}
lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        try:
            if path == "/incomplete":
                body = b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:partial\r\nDTSTART:20260909T120000Z\r\n"
            elif path == "/incomplete-after-event":
                body = b"BEGIN:VCALENDAR\r\n" + event + b"BEGIN:VEVENT\r\nUID:partial\r\n"
            elif path == "/mismatched":
                body = b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nBEGIN:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
            elif path == "/populated":
                body = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + event + b"END:VCALENDAR\r\n"
            elif path == "/stats":
                with lock:
                    body = json.dumps(state).encode()
            elif path == "/hold":
                with lock:
                    state["active"] += 1
                    state["peak"] = max(state["peak"], state["active"])
                try:
                    time.sleep(0.4)
                    self.reply(b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n")
                finally:
                    with lock:
                        state["active"] -= 1
                return
            elif path == "/declared-large":
                self.send_response(200)
                self.send_header("Content-Length", str(CAP + 1))
                self.end_headers()
                # URLSession may withhold headers until an initial body chunk.
                # Only a tiny prefix arrives; rejection must precede the rest.
                self.wfile.write(b"x" * 1024)
                self.wfile.flush()
                time.sleep(3)
                return
            elif path == "/stream":
                self.send_response(200)
                self.end_headers()  # no Content-Length; size must be counted as it arrives
                sent = 0
                try:
                    while sent < CAP * 20:
                        self.wfile.write(b"x" * 16_384)
                        self.wfile.flush()
                        sent += 16_384
                        time.sleep(0.001)
                finally:
                    with lock:
                        state["stream_bytes"] = sent
                        state["stream_stopped"] = True
                return
            elif path == "/trickle":
                self.send_response(200)
                self.end_headers()
                for _ in range(400):  # stays active past the total 60s deadline
                    self.wfile.write(b"x")
                    self.wfile.flush()
                    time.sleep(0.2)
                return
            elif path == "/gzip":
                self.reply(gzip.compress(b"x" * (CAP + 1)), encoding="gzip")
                return
            elif path == "/exact":
                body = b"x" * CAP
            elif path == "/over":
                body = b"x" * (CAP + 1)
            elif path == "/error":
                self.reply(b"unavailable", status=503)
                return
            else:
                if path == "/slow":
                    time.sleep(3)
                body = b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n"
            self.reply(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def reply(self, body, status=200, encoding=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if encoding:
            self.send_header("Content-Encoding", encoding)
        self.end_headers()
        self.wfile.write(body)


with tempfile.TemporaryDirectory(prefix="now-calendar-smoke-") as directory:
    directory = pathlib.Path(directory)
    # Preserve the real CLI helpers used by SelfTest, replacing only the entry point.
    executable = directory / "fetch-smoke"
    build("fetch", executable)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}", *(["--structure-only"] if args.structure_only else [])], check=True, timeout=110)
    finally:
        server.shutdown()
        server.server_close()
