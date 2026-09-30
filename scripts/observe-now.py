#!/usr/bin/env python3
"""Sample the running now app and append one CSV row per interval.

Local observation tool for validating the CPU-overhead improvements from
PR #25 against the real, installed app over hours or days. It only reads
process state and file metadata; it never writes app data. Output stays in
outputs/observations/ (gitignored).

Metrics per sample:
- liveness, pid, uptime, cumulative CPU seconds (ps), ps %CPU, RSS
- platform idle wakeup COUNTER (top IDLEW is cumulative, not a rate; the
  renderer derives wakeups/min from deltas between samples)
- power source (pmset) as CPU-frequency context
- preferences plist + app-support cache size/mtime and change flags,
  which makes "change-conditional tracker writes" visible from outside

Run detached:   python3 scripts/observe-now.py --detach
Check:          python3 scripts/observe-now.py --status
Stop:           python3 scripts/observe-now.py --stop
Render graphs:  python3 scripts/render-observations.py
"""
from __future__ import annotations

import argparse
import csv
import datetime
import os
import pathlib
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = ROOT / "outputs" / "observations"
PROCESS_NAME = "now"
PREFS_PLIST = pathlib.Path.home() / "Library" / "Preferences" / "com.thomasboch.now.plist"
APP_SUPPORT = pathlib.Path.home() / "Library" / "Application Support" / "com.thomasboch.now"
PIDFILE_NAME = "observer.pid"

FIELDS = [
    "ts_iso", "epoch_s", "running", "pid", "uptime_s", "cpu_cum_s", "cpu_pct", "rss_kb",
    "idlew", "power", "prefs_bytes", "prefs_age_s", "prefs_changed",
    "cache_files", "cache_bytes", "cache_age_s", "cache_changed", "note",
]

stop_requested = False


def request_stop(_signum: int, _frame: object) -> None:
    global stop_requested
    stop_requested = True


def run_json_free(command: list[str], timeout: float) -> str | None:
    """Run a command and return stdout, or None on any failure."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def find_pid() -> int | None:
    out = run_json_free(["pgrep", "-x", PROCESS_NAME], timeout=5)
    if not out:
        return None
    pids = [int(token) for token in out.split() if token.isdigit()]
    return min(pids) if pids else None


def parse_elapsed(text: str) -> float | None:
    """Parse ps elapsed/time formats: [[dd-]hh:]mm:ss[.cc]."""
    text = text.strip()
    if not text or not any(ch.isdigit() for ch in text):
        return None
    days = 0.0
    if "-" in text:
        day_part, text = text.split("-", 1)
        if not day_part.strip().isdigit():
            return None
        days = float(day_part)
    parts = text.split(":")
    if not 2 <= len(parts) <= 3:
        return None
    try:
        numbers = [float(part) for part in parts]
    except ValueError:
        return None
    if any(part < 0 for part in numbers):
        return None
    seconds = numbers[-1]
    minutes = numbers[-2] if len(numbers) >= 2 else 0.0
    hours = numbers[-3] if len(numbers) == 3 else 0.0
    return days * 86400.0 + hours * 3600.0 + minutes * 60.0 + seconds


def sample_ps(pid: int) -> dict[str, str]:
    out = run_json_free(
        ["ps", "-o", "pid=,etime=,time=,%cpu=,rss=", "-p", str(pid)], timeout=5)
    row: dict[str, str] = {}
    if not out:
        return row
    fields = out.strip().split(None, 4)
    if len(fields) < 5:
        return row
    _, elapsed, cpu_time, cpu_pct, rss = fields
    uptime = parse_elapsed(elapsed)
    cpu_cum = parse_elapsed(cpu_time)
    if uptime is not None:
        row["uptime_s"] = f"{uptime:.1f}"
    if cpu_cum is not None:
        row["cpu_cum_s"] = f"{cpu_cum:.2f}"
    if cpu_pct:
        row["cpu_pct"] = cpu_pct
    if rss.isdigit():
        row["rss_kb"] = rss
    return row


def sample_wakeups(pid: int) -> str:
    """Idle wakeups between top's two samples (~1s), best effort."""
    out = run_json_free(
        ["top", "-l", "2", "-s", "1", "-pid", str(pid), "-stats", "pid,idlew"], timeout=15)
    if not out:
        return ""
    value = ""
    for line in out.splitlines():
        tokens = line.split()
        if len(tokens) == 2 and tokens[0] == str(pid):
            digits = tokens[1].rstrip("+-")
            if digits.isdigit():
                value = digits
    return value


def sample_power() -> str:
    out = run_json_free(["pmset", "-g", "ps"], timeout=5)
    if not out:
        return ""
    return "batt" if "Battery" in out else "ac"


def scan_tree(root: pathlib.Path, cap: int = 5000) -> tuple[int, int, float | None, dict[str, tuple[int, int]] | None]:
    """Return (file count, total bytes, newest-write age, signature) below root."""
    if not root.is_dir():
        return 0, 0, None, None
    signature: dict[str, tuple[int, int]] = {}
    count = 0
    total = 0
    newest: float | None = None
    stack = [root]
    while stack and count < cap:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            try:
                if entry.is_dir(follow_symlinks=False):
                    stack.append(pathlib.Path(entry.path))
                    continue
                info = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            count += 1
            total += info.st_size
            signature[entry.path] = (info.st_size, info.st_mtime_ns)
            age = time.time() - info.st_mtime
            if age >= 0 and (newest is None or age < newest):
                newest = age
    return count, total, newest, signature


def sample(prior: dict | None, wakeups: bool) -> dict[str, str]:
    row: dict[str, str] = {name: "" for name in FIELDS}
    now = time.time()
    row["epoch_s"] = f"{now:.0f}"
    row["ts_iso"] = datetime.datetime.fromtimestamp(now).isoformat(timespec="seconds")
    row["power"] = sample_power()

    pid = find_pid()
    running = pid is not None
    row["running"] = "1" if running else "0"
    if running:
        row["pid"] = str(pid)
        row.update(sample_ps(pid))
        if wakeups:
            row["idlew"] = sample_wakeups(pid)
    if prior is not None:
        was_running = prior.get("running") == "1"
        if running and was_running and prior.get("pid") not in ("", str(pid)):
            row["note"] = f"pid-change:{prior.get('pid')}->{pid}"
        elif running and not was_running:
            row["note"] = "app-launched"
        elif not running and was_running:
            row["note"] = "app-exited"

    try:
        stats = PREFS_PLIST.stat()
        row["prefs_bytes"] = str(stats.st_size)
        row["prefs_age_s"] = f"{max(0.0, now - stats.st_mtime):.0f}"
        prefs_sig = (stats.st_size, stats.st_mtime_ns)
    except OSError:
        prefs_sig = None
    if prior is not None and prefs_sig is not None and prefs_sig != prior.get("_prefs_sig"):
        row["prefs_changed"] = "1"

    count, total, newest, signature = scan_tree(APP_SUPPORT)
    row["cache_files"] = str(count)
    row["cache_bytes"] = str(total)
    if newest is not None:
        row["cache_age_s"] = f"{newest:.0f}"
    if (prior is not None and signature is not None and signature != prior.get("_cache_sig")):
        row["cache_changed"] = "1"

    row["_prefs_sig"] = prefs_sig  # type: ignore[assignment]
    row["_cache_sig"] = signature  # type: ignore[assignment]
    return row


def csv_row(row: dict[str, str]) -> list[str]:
    return [row.get(name, "") for name in FIELDS]


def observe(args: argparse.Namespace) -> int:
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    started = datetime.datetime.now()
    csv_path = out_dir / f"now-obs-{started.strftime('%Y%m%d-%H%M%S')}.csv"
    new_file = not csv_path.exists()
    handle = csv_path.open("a", newline="")
    writer = csv.writer(handle)
    if new_file:
        writer.writerow(FIELDS)
        handle.flush()

    print(f"observing '{PROCESS_NAME}' every {args.interval}s -> {csv_path}")
    # The deadline uses wall time: time.monotonic() on macOS pauses during
    # system sleep, so a monotonic deadline would silently extend past the
    # requested window by every lid-closed hour.
    deadline = time.time() + args.max_hours * 3600 if args.max_hours else None
    prior: dict | None = None
    next_sample = time.monotonic()
    try:
        while not stop_requested:
            row = sample(prior, wakeups=not args.no_wakeups)
            if prior is None:
                row["note"] = "observer-start"
            writer.writerow(csv_row(row))
            handle.flush()
            prior = row
            if deadline is not None and time.time() >= deadline:
                break
            next_sample += args.interval
            delay = next_sample - time.monotonic()
            while delay > 0 and not stop_requested:
                time.sleep(min(delay, 1.0))
                delay = next_sample - time.monotonic()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            end = sample(prior, wakeups=False)
            end["note"] = "observer-stopped"
            writer.writerow(csv_row(end))
        except Exception:
            pass
        handle.flush()
        handle.close()
    print(f"wrote {csv_path}")
    return 0


def write_pidfile(out_dir: pathlib.Path, pid: int) -> None:
    (out_dir / PIDFILE_NAME).write_text(f"{pid}\n")


def read_pidfile(out_dir: pathlib.Path) -> int | None:
    try:
        return int((out_dir / PIDFILE_NAME).read_text().strip())
    except (OSError, ValueError):
        return None


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def detach(args: argparse.Namespace, log_path: pathlib.Path) -> int:
    pid = os.fork()
    if pid > 0:
        os.waitpid(pid, 0)
        time.sleep(0.8)
        child = read_pidfile(pathlib.Path(args.out_dir))
        if child and alive(child):
            print(f"observer detached, pid {child}; log: {log_path}")
            return 0
        print(f"observer may have failed; check {log_path}")
        return 1
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDONLY)
    log = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(devnull, 0)
    os.dup2(log, 1)
    os.dup2(log, 2)
    os.close(devnull)
    os.close(log)
    write_pidfile(pathlib.Path(args.out_dir), os.getpid())
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    return observe(args)


def stop(args: argparse.Namespace) -> int:
    out_dir = pathlib.Path(args.out_dir)
    pid = read_pidfile(out_dir)
    if pid is None or not alive(pid):
        print("no running observer found")
        (out_dir / PIDFILE_NAME).unlink(missing_ok=True)
        return 0
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if not alive(pid):
            break
        time.sleep(0.1)
    if alive(pid):
        os.kill(pid, signal.SIGKILL)
        print(f"observer pid {pid} killed")
    else:
        print(f"observer pid {pid} stopped")
    (out_dir / PIDFILE_NAME).unlink(missing_ok=True)
    return 0


def status(args: argparse.Namespace) -> int:
    out_dir = pathlib.Path(args.out_dir)
    pid = read_pidfile(out_dir)
    if pid and alive(pid):
        print(f"observer running, pid {pid}")
    else:
        print("observer not running")
    files = sorted(out_dir.glob("now-obs-*.csv"))
    for path in files:
        try:
            last = pathlib.Path(path).read_text().strip().splitlines()
            tail = last[-1].split(",")[0] if len(last) > 1 else "-"
            print(f"  {path.name}: {max(0, len(last) - 1)} samples, last {tail}")
        except OSError:
            continue
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Observe the running now app and log samples.")
    parser.add_argument("--interval", type=float, default=30.0, help="seconds between samples")
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR))
    parser.add_argument("--max-hours", type=float, default=0.0,
                        help="stop after this many hours (0 = run until stopped)")
    parser.add_argument("--no-wakeups", action="store_true",
                        help="skip the ~2s top sampling of the idle wakeup counter")
    parser.add_argument("--detach", action="store_true", help="run in the background")
    parser.add_argument("--stop", action="store_true", help="stop a detached observer")
    parser.add_argument("--status", action="store_true", help="show observer and file status")
    args = parser.parse_args()

    out_dir = pathlib.Path(args.out_dir)
    if args.stop:
        return stop(args)
    if args.status:
        return status(args)

    if args.detach:
        existing = read_pidfile(out_dir)
        if existing and alive(existing):
            print(f"observer already running, pid {existing}")
            return 1
        out_dir.mkdir(parents=True, exist_ok=True)
        log_path = out_dir / f"observer-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.log"
        return detach(args, log_path)

    return observe(args)


if __name__ == "__main__":
    sys.exit(main())
