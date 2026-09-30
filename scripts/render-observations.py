#!/usr/bin/env python3
"""Render observe-now.py CSV logs into a self-contained HTML report.

Reads every now-obs-*.csv in the observations directory, aggregates per time
bucket, and writes one HTML file with inline SVG charts (no dependencies):

- CPU seconds per bucket (the headline: recurring overhead of the menu tick)
- idle wakeups and RSS over time
- preferences/cache write activity per bucket (change-conditional writes)
- running coverage with restart markers
- daily summary table

Usage: python3 scripts/render-observations.py [--open]
"""
from __future__ import annotations

import argparse
import csv
import datetime
import math
import pathlib
import statistics
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "outputs" / "observations"

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>now observations</title>
<style>
 body { font-family: -apple-system, Helvetica, sans-serif; margin: 0; background: #f6f7f9; color: #111827; }
 .wrap { max-width: 1140px; margin: 0 auto; padding: 28px 20px 60px; }
 h1 { font-size: 22px; margin: 0 0 4px; }
 .sub { color: #6b7280; font-size: 13px; margin-bottom: 20px; }
 .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 24px; }
 .card { background: #fff; border: 1px solid #e5e7eb; border-radius: 10px; padding: 10px 12px; }
 .card .k { font-size: 11px; color: #6b7280; text-transform: uppercase; letter-spacing: .04em; }
 .card .v { font-size: 18px; font-weight: 600; margin-top: 2px; }
 section { background: #fff; border: 1px solid #e5e7eb; border-radius: 10px; padding: 14px 16px 8px; margin-bottom: 18px; }
 section h2 { font-size: 14px; margin: 0; }
 section .hint { font-size: 12px; color: #6b7280; margin: 2px 0 8px; }
 table { border-collapse: collapse; width: 100%; font-size: 13px; }
 th, td { text-align: right; padding: 5px 8px; border-bottom: 1px solid #f1f2f4; }
 th:first-child, td:first-child { text-align: left; }
 .legend { font-size: 12px; color: #374151; margin-bottom: 6px; }
 .legend span { margin-right: 14px; }
 .dot { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 4px; vertical-align: -1px; }
</style></head><body><div class="wrap">
<h1>now &mdash; observation report</h1>
<div class="sub">__SUB__</div>
<div class="cards">__CARDS__</div>
<section><h2>Per-day summary</h2><div class="hint">One row per local day. CPU is cumulative-time deltas between consecutive samples of the same app process.</div>__TABLE__</section>
__PANELS__
<div class="sub">Generated __GENERATED__ &middot; all data local</div>
</div></body></html>
"""


def parse_row(row: dict) -> dict | None:
    try:
        return {
            "epoch": int(row["epoch_s"]),
            "running": row.get("running", "") == "1",
            "pid": row.get("pid", ""),
            "cpu_cum": float(row["cpu_cum_s"]) if row.get("cpu_cum_s") else None,
            "idlew": float(row["idlew"]) if row.get("idlew") else None,
            "rss": float(row["rss_kb"]) if row.get("rss_kb") else None,
            "prefs_w": row.get("prefs_changed") == "1",
            "cache_w": row.get("cache_changed") == "1",
            "note": row.get("note", ""),
        }
    except (KeyError, ValueError):
        return None


def load(directory: pathlib.Path) -> list[dict]:
    samples = []
    for path in sorted(directory.glob("now-obs-*.csv")):
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                parsed = parse_row(row)
                if parsed:
                    parsed["source"] = path.name
                    samples.append(parsed)
    samples.sort(key=lambda item: item["epoch"])
    return samples


def fmt_hms(seconds: float) -> str:
    if seconds != seconds or seconds <= 0:
        return "0"
    hours, remainder = divmod(int(seconds), 3600)
    minutes = remainder // 60
    return f"{hours}h{minutes:02d}m" if hours else f"{minutes}m"


def nice_max(value: float) -> float:
    if value <= 0:
        return 1.0
    exponent = math.floor(math.log10(value))
    for multiplier in (1, 2, 5, 10):
        candidate = multiplier * 10 ** exponent
        if candidate >= value:
            return candidate
    return value


class Panel:
    """One SVG chart sharing a common time axis."""

    def __init__(self, t0: float, t1: float, height: int = 190):
        self.t0, self.t1 = t0, t1
        self.left, self.right = 66, 16
        self.top, self.bottom = 10, 26
        self.height = height
        self.plot_w = max(10.0, 1064 - self.left - self.right)
        self.plot_h = height - self.top - self.bottom
        self.parts: list[str] = []

    def x(self, epoch: float) -> float:
        span = max(1e-9, self.t1 - self.t0)
        return self.left + (epoch - self.t0) / span * self.plot_w

    def y(self, value: float, vmax: float) -> float:
        return self.top + self.plot_h * (1 - min(value, vmax) / vmax)

    def text(self, x: float, y: float, content: str, anchor: str = "start", size: int = 11, fill: str = "#6b7280") -> None:
        self.parts.append(
            f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" text-anchor="{anchor}">{content}</text>')

    def y_axis(self, vmax: float, fmt) -> None:
        for step in range(5):
            value = vmax * step / 4
            y = self.y(value, vmax)
            self.parts.append(
                f'<line x1="{self.left}" y1="{y:.1f}" x2="{self.left + self.plot_w:.1f}" y2="{y:.1f}" stroke="#e5e7eb"/>')
            self.text(self.left - 6, y + 3.5, fmt(value), "end")

    def time_axis(self) -> None:
        self.parts.append(
            f'<line x1="{self.x(self.t0):.1f}" y1="{self.top + self.plot_h}" x2="{self.x(self.t1):.1f}" y2="{self.top + self.plot_h}" stroke="#9ca3af"/>')
        span = max(1.0, self.t1 - self.t0)
        if span <= 2 * 3600:
            step = 900
        elif span <= 8 * 3600:
            step = 3600
        elif span <= 3 * 86400:
            step = 6 * 3600
        else:
            step = 12 * 3600
        tick_epoch = int(self.t0 // step) * step
        while tick_epoch <= self.t1:
            if tick_epoch >= self.t0:
                x = self.x(tick_epoch)
                tick = datetime.datetime.fromtimestamp(tick_epoch)
                label = tick.strftime("%d.%m") if tick.hour == 0 and step >= 3600 else tick.strftime("%H:%M")
                self.parts.append(
                    f'<line x1="{x:.1f}" y1="{self.top + self.plot_h}" x2="{x:.1f}" y2="{self.top + self.plot_h + 4}" stroke="#9ca3af"/>')
                self.text(x, self.top + self.plot_h + 17, label, "middle")
            tick_epoch += step

    def svg(self) -> str:
        return (f'<svg viewBox="0 0 1064 {self.height}" width="100%" role="img">'
                + "".join(self.parts) + "</svg>")


def buckets_of(samples: list[dict], bucket_s: int) -> dict[int, dict]:
    buckets: dict[int, dict] = {}
    for sample in samples:
        index = sample["epoch"] // bucket_s
        slot = buckets.setdefault(index, {
            "n": 0, "running": 0, "cpu_s": 0.0, "span_s": 0.0, "rss": 0.0, "iw_rate": [],
            "prefs_w": 0, "cache_w": 0, "restarts": 0, "epoch": index * bucket_s,
        })
        slot["n"] += 1
        if sample["running"]:
            slot["running"] += 1
        if sample["rss"]:
            slot["rss"] = max(slot["rss"], sample["rss"])
        if sample.get("iw_rate") is not None:
            slot["iw_rate"].append(sample["iw_rate"])
        if sample["prefs_w"]:
            slot["prefs_w"] += 1
        if sample["cache_w"]:
            slot["cache_w"] += 1
        if sample.get("restart"):
            slot["restarts"] += 1
    return buckets


def main() -> int:
    parser = argparse.ArgumentParser(description="Render now observation CSVs into an HTML report.")
    parser.add_argument("--dir", default=str(DEFAULT_DIR))
    parser.add_argument("--out", default=None, help="output HTML path (default: <dir>/report.html)")
    parser.add_argument("--bucket-mins", type=int, default=10)
    parser.add_argument("--open", action="store_true", help="open the report in the default browser")
    args = parser.parse_args()

    directory = pathlib.Path(args.dir)
    samples = load(directory)
    if not samples:
        print(f"no samples found in {directory}; run scripts/observe-now.py first")
        return 1

    t0, t1 = samples[0]["epoch"], samples[-1]["epoch"]
    for sample in samples:
        sample["restart"] = False
    for previous, current in zip(samples, samples[1:]):
        was, is_now = previous["running"], current["running"]
        pid_changed = was and is_now and previous["pid"] != current["pid"]
        if (was and not is_now) or (not was and is_now) or pid_changed:
            current["restart"] = True
    bucket_s = args.bucket_mins * 60
    gaps = [b["epoch"] - a["epoch"] for a, b in zip(samples, samples[1:])]
    interval = statistics.median(gaps) if gaps else 30.0
    max_gap = max(180.0, 3 * interval)

    # top's IDLEW is a cumulative counter; derive the per-minute rate.
    idle_rates: list[tuple[float, float]] = []
    for a, b in zip(samples, samples[1:]):
        gap = b["epoch"] - a["epoch"]
        if (a["idlew"] is not None and b["idlew"] is not None and 0 < gap <= max_gap
                and a["pid"] == b["pid"] and a["running"] and b["running"]):
            rate = max(0.0, (b["idlew"] - a["idlew"]) * 60.0 / gap)
            idle_rates.append((b["epoch"], rate))
            b["iw_rate"] = rate

    buckets = buckets_of(samples, bucket_s)
    for previous, current in zip(samples, samples[1:]):
        gap = current["epoch"] - previous["epoch"]
        if (previous["running"] and current["running"] and previous["pid"] == current["pid"]
                and previous["cpu_cum"] is not None and current["cpu_cum"] is not None
                and 0 < gap <= max_gap):
            slot = buckets[current["epoch"] // bucket_s]
            slot["cpu_s"] += max(0.0, current["cpu_cum"] - previous["cpu_cum"])
            slot["span_s"] += gap

    total_cpu = sum(slot["cpu_s"] for slot in buckets.values())
    running_span = sum(slot["span_s"] for slot in buckets.values())
    wall = max(1, t1 - t0)
    avg_pct = 100 * total_cpu / running_span if running_span else 0.0
    rss_values = [s["rss"] for s in samples if s["rss"]]
    idle_rate_values = [rate for _, rate in idle_rates]
    days = max(1.0, wall / 86400)
    prefs_total = sum(1 for s in samples if s["prefs_w"])
    cache_total = sum(1 for s in samples if s["cache_w"])
    restarts = sum(1 for s in samples if s["restart"])

    first_day = datetime.datetime.fromtimestamp(t0).strftime("%Y-%m-%d %H:%M")
    last_day = datetime.datetime.fromtimestamp(t1).strftime("%Y-%m-%d %H:%M")

    cards = [
        ("Observed span", f"{days:.1f} d", first_day, last_day),
        ("Samples", f"{len(samples)}", f"~{interval:.0f}s cadence", f"{len(buckets)} buckets"),
        ("App running", f"{100 * running_span / wall:.1f}%", f"{fmt_hms(running_span)} of {fmt_hms(wall)}",
         f"{restarts} restart(s)"),
        ("Total CPU", fmt_hms(total_cpu), f"avg {avg_pct:.2f}% while running", f"{total_cpu / days / 60:.1f} min/day"),
        ("Idle wakeups", f"{statistics.median(idle_rate_values):.1f}/min" if idle_rate_values else "-",
         f"p95 {sorted(idle_rate_values)[int(0.95 * (len(idle_rate_values) - 1))]:.1f}/min" if idle_rate_values else "",
         "platform-idle rate from counter deltas"),
        ("RSS", f"{max(rss_values) / 1024:.0f} MB max" if rss_values else "-",
         f"{rss_values[0] / 1024:.0f} → {rss_values[-1] / 1024:.0f} MB" if rss_values else "",
         "growth = drift"),
        ("Prefs writes", f"{prefs_total}", f"{prefs_total / days:.0f}/day", "plist size/mtime changes"),
        ("Cache writes", f"{cache_total}", f"{cache_total / days:.0f}/day", "app-support file changes"),
    ]
    card_html = "".join(
        f'<div class="card"><div class="k">{k}</div><div class="v">{v}</div>'
        f'<div class="k" style="text-transform:none; letter-spacing:0">{a}</div>'
        f'<div class="k" style="text-transform:none; letter-spacing:0">{b}</div></div>'
        for k, v, a, b in cards)

    # Daily table.
    by_day: dict[str, dict] = {}
    for slot in buckets.values():
        stamp = datetime.datetime.fromtimestamp(slot["epoch"])
        day = by_day.setdefault(stamp.strftime("%Y-%m-%d"), {
            "cpu": 0.0, "span": 0.0, "wall": set(), "rss": 0.0, "iw_rate": [], "prefs": 0, "cache": 0, "restarts": 0})
        day["cpu"] += slot["cpu_s"]
        day["span"] += slot["span_s"]
        day["wall"].add(slot["epoch"])
        day["rss"] = max(day["rss"], slot["rss"])
        day["iw_rate"].extend(slot["iw_rate"])
        day["prefs"] += slot["prefs_w"]
        day["cache"] += slot["cache_w"]
        day["restarts"] += slot["restarts"]
    rows = ['<table><tr><th>Day</th><th>CPU total</th><th>avg %CPU</th><th>max RSS</th>'
            '<th>iw/min</th><th>prefs writes</th><th>cache writes</th><th>restarts</th></tr>']
    for date, day in sorted(by_day.items()):
        iw = statistics.median(day["iw_rate"]) if day["iw_rate"] else None
        pct = 100 * day["cpu"] / day["span"] if day["span"] else 0.0
        rows.append(
            f"<tr><td>{date}</td><td>{day['cpu']:.0f}s</td><td>{pct:.2f}%</td>"
            f"<td>{day['rss'] / 1024:.0f} MB</td><td>{iw:.1f}</td>"
            f"<td>{day['prefs']}</td><td>{day['cache']}</td><td>{day['restarts']}</td></tr>")
    rows.append("</table>")
    table_html = "".join(rows)

    ordered = [buckets[key] for key in sorted(buckets)]

    # Panel 1: CPU seconds per bucket (bars).
    cpu_panel = Panel(t0, t1)
    cpu_max = nice_max(max((slot["cpu_s"] for slot in ordered), default=1.0))
    cpu_panel.y_axis(cpu_max, lambda v: f"{v:.1f}s")
    bar_w = max(1.0, cpu_panel.plot_w / max(1, (t1 - t0) // bucket_s + 1) - 1)
    for slot in ordered:
        x = cpu_panel.x(slot["epoch"])
        height_px = cpu_panel.plot_h * slot["cpu_s"] / cpu_max
        y = cpu_panel.top + cpu_panel.plot_h - height_px
        label = datetime.datetime.fromtimestamp(slot["epoch"]).strftime("%a %H:%M")
        pct = 100 * slot["cpu_s"] / slot["span_s"] if slot["span_s"] else 0.0
        cpu_panel.parts.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{height_px:.1f}" fill="#3b82f6" rx="1">'
            f'<title>{label} &middot; {slot["cpu_s"]:.2f}s CPU ({pct:.2f}% avg) &middot; '
            f'{slot["prefs_w"]} prefs / {slot["cache_w"]} cache writes</title></rect>')
    cpu_panel.time_axis()

    # Panels 2 & 3: idle wakeup rate and RSS lines from derived points.
    def line_panel(points: list[tuple[float, float]], color: str, fmt,
                   vmax_override: float | None = None) -> str:
        values = [v for _, v in points]
        if not values:
            return ""
        panel = Panel(t0, t1)
        vmax = vmax_override if vmax_override else nice_max(max(values))
        panel.y_axis(vmax, fmt)
        path, previous = [], None
        for epoch, value in points:
            x, y = panel.x(epoch), panel.y(value, vmax)
            if previous is None or epoch - previous > max_gap:
                path.append(f"M{x:.1f},{y:.1f}")
            else:
                path.append(f"L{x:.1f},{y:.1f}")
            previous = epoch
        panel.parts.append(
            f'<path d="{" ".join(path)}" fill="none" stroke="{color}" stroke-width="1.4"/>')
        panel.time_axis()
        return panel.svg()

    wakeups_svg = line_panel(idle_rates, "#8b5cf6", lambda v: f"{v:.0f}")
    rss_points = [(s["epoch"], s["rss"]) for s in samples if s["rss"]]
    rss_svg = line_panel(rss_points, "#10b981", lambda v: f"{v / 1024:.0f}M")

    # Panel 4: write activity per bucket (stacked bars).
    writes_svg = ""
    if any(slot["prefs_w"] or slot["cache_w"] for slot in ordered):
        writes = Panel(t0, t1, height=150)
        w_max = nice_max(max(slot["prefs_w"] + slot["cache_w"] for slot in ordered))
        writes.y_axis(w_max, lambda v: f"{v:.0f}")
        for slot in ordered:
            x = writes.x(slot["epoch"])
            cache_px = writes.plot_h * slot["cache_w"] / w_max
            prefs_px = writes.plot_h * slot["prefs_w"] / w_max
            base = writes.top + writes.plot_h
            label = datetime.datetime.fromtimestamp(slot["epoch"]).strftime("%a %H:%M")
            writes.parts.append(
                f'<rect x="{x:.1f}" y="{base - cache_px:.1f}" width="{bar_w:.1f}" height="{cache_px:.1f}" fill="#3b82f6">'
                f'<title>{label} &middot; {slot["cache_w"]} cache writes</title></rect>')
            writes.parts.append(
                f'<rect x="{x:.1f}" y="{base - cache_px - prefs_px:.1f}" width="{bar_w:.1f}" height="{prefs_px:.1f}" fill="#f59e0b">'
                f'<title>{label} &middot; {slot["prefs_w"]} prefs writes</title></rect>')
        writes.time_axis()
        writes_svg = writes.svg()

    # Panel 5: coverage strip with restart markers.
    cover = Panel(t0, t1, height=64)
    strip_y = cover.top + 8
    for slot in ordered:
        fraction = slot["running"] / slot["n"] if slot["n"] else 0
        color = "#10b981" if fraction >= 0.99 else "#f59e0b" if fraction > 0 else "#d1d5db"
        label = datetime.datetime.fromtimestamp(slot["epoch"]).strftime("%a %H:%M")
        cover.parts.append(
            f'<rect x="{cover.x(slot["epoch"]):.1f}" y="{strip_y}" width="{bar_w:.1f}" height="12" fill="{color}">'
            f'<title>{label} &middot; {100 * fraction:.0f}% running</title></rect>')
    for sample in samples:
        if sample["restart"]:
            x = cover.x(sample["epoch"])
            cover.parts.append(f'<line x1="{x:.1f}" y1="{strip_y - 4}" x2="{x:.1f}" y2="{strip_y + 16}" stroke="#ef4444" stroke-width="2"/>')
    cover.time_axis()
    cover_svg = cover.svg()

    panels = [
        f'<section><h2>CPU seconds per {args.bucket_mins} min</h2>'
        f'<div class="hint">Cumulative-CPU deltas between consecutive samples (same process). '
        f'Lower and flatter while idle = the PR #25 goal.</div>{cpu_panel.svg()}</section>',
        f'<section><h2>Platform idle wakeups (per minute)</h2><div class="hint">Derived from '
        f'deltas of top&rsquo;s cumulative IDLEW counter between consecutive samples. '
        f'Lower is better; spikes align with active use.</div>{wakeups_svg}</section>',
        f'<section><h2>Resident memory (RSS)</h2><div class="hint">Should stay bounded across days; '
        f'a slow climb would suggest a leak.</div>{rss_svg}</section>',
    ]
    if writes_svg:
        panels.append(
            '<section><h2>Write activity</h2><div class="legend">'
            '<span><span class="dot" style="background:#f59e0b"></span>preferences plist</span>'
            '<span><span class="dot" style="background:#3b82f6"></span>app-support cache files</span></div>'
            f'<div class="hint">Detected file size/mtime changes per bucket; write storms here would '
            f'mean redundant tracker writes returned.</div>{writes_svg}</section>')
    panels.append(
        f'<section><h2>App running coverage</h2><div class="legend">'
        f'<span><span class="dot" style="background:#10b981"></span>running</span>'
        f'<span><span class="dot" style="background:#f59e0b"></span>partial</span>'
        f'<span><span class="dot" style="background:#ef4444"></span>restart</span></div>{cover_svg}</section>')

    generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    html = (PAGE
            .replace("__SUB__", f"{first_day} &rarr; {last_day} &middot; {len(samples)} samples &middot; bucket {args.bucket_mins} min")
            .replace("__CARDS__", card_html)
            .replace("__TABLE__", table_html)
            .replace("__PANELS__", "".join(panels))
            .replace("__GENERATED__", generated))
    out = pathlib.Path(args.out) if args.out else directory / "report.html"
    out.write_text(html)
    print(f"report: {out}")
    print(f"  span {days:.1f} d | total CPU {fmt_hms(total_cpu)} ({avg_pct:.2f}% avg while running) "
          f"| max RSS {max(rss_values) / 1024:.0f} MB | restarts {restarts}")
    if args.open:
        subprocess.run(["open", str(out)], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
