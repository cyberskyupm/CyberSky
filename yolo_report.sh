yolo_report.py:
#!/usr/bin/env python3
"""
yolo_report.py
Summarize YOLO detections from a CSV with columns:
timestamp, class, confidence, x1, y1, x2, y2

Outputs:
- Pretty text/markdown report (stdout, and optional --out report.md)
- Optional JSON summary (--json summary.json)
- Optional per-class CSV (--per_class per_class.csv)
- Optional per-minute CSV (--per_min per_minute.csv)

Usage examples:
  python3 yolo_report.py --csv detections.csv
  python3 yolo_report.py --csv detections.csv --out report.md --json summary.json --per_class per_class.csv --per_min per_minute.csv
"""

import argparse
import csv
import json
import math
import os
from collections import defaultdict, Counter
from datetime import datetime

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--csv", required=True, help="Path to detections.csv")
    p.add_argument("--out", default="", help="Optional: write markdown report to this path")
    p.add_argument("--json", default="", help="Optional: write summary JSON to this path")
    p.add_argument("--per_class", default="", help="Optional: write per-class CSV summary")
    p.add_argument("--per_min", default="", help="Optional: write per-minute CSV time series")
    p.add_argument("--top", type=int, default=10, help="How many top classes to list (default 10)")
    p.add_argument("--min_conf", type=float, default=0.0, help="Ignore detections below this confidence")
    return p.parse_args()

def parse_timestamp(ts):
    # Accept ISO8601 with/without trailing 'Z'
    ts = ts.rstrip("Z")
    try:
        return datetime.fromisoformat(ts)
    except Exception:
        # last resort: try common format
        try:
            return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%f")
        except Exception:
            return None

def safe_float(x, default=0.0):
    try:
        return float(x)
    except Exception:
        return default

def safe_int(x, default=0):
    try:
        return int(float(x))
    except Exception:
        return default

def median(lst):
    if not lst:
        return 0.0
    s = sorted(lst)
    n = len(s)
    mid = n // 2
    if n % 2:
        return float(s[mid])
    return (s[mid-1] + s[mid]) / 2.0

def load_detections(csv_path, min_conf=0.0):
    rows = []
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"{csv_path} not found")

    with open(csv_path, "r", newline="") as f:
        rd = csv.reader(f)
        header = next(rd, None)
        # Allow headerless files; assume canonical order if missing
        header_l = [h.strip().lower() for h in (header or [])]

        def col(name, default_idx):
            if header_l and name in header_l:
                return header_l.index(name)
            return default_idx

        idx_ts = col("timestamp", 0)
        idx_class = col("class", 1)
        idx_conf = col("confidence", 2)
        idx_x1 = col("x1", 3)
        idx_y1 = col("y1", 4)
        idx_x2 = col("x2", 5)
        idx_y2 = col("y2", 6)

        # If we used the earlier detect_and_log.py, this mapping is correct.
        for r in rd:
            if len(r) < 7:
                continue
            ts = parse_timestamp(r[idx_ts])
            if ts is None:
                continue
            cls = str(r[idx_class]).strip()
            conf = safe_float(r[idx_conf], 0.0)
            if conf < min_conf:
                continue
            x1 = safe_int(r[idx_x1]); y1 = safe_int(r[idx_y1])
            x2 = safe_int(r[idx_x2]); y2 = safe_int(r[idx_y2])
            area = max(0, (x2 - x1)) * max(0, (y2 - y1))
            rows.append({
                "timestamp": ts,
                "class": cls,
                "confidence": conf,
                "x1": x1, "y1": y1, "x2": x2, "y2": y2,
                "area": area
            })
    return rows

def summarize(rows, top_n=10):
    if not rows:
        return {
            "total_detections": 0,
            "time_start": None,
            "time_end": None,
            "classes": {},
            "top_classes": [],
            "per_minute": {},
        }

    # Time range
    times = [r["timestamp"] for r in rows]
    t0, t1 = min(times), max(times)

    # Class stats
    per_class = defaultdict(lambda: {
        "count": 0,
        "conf_list": [],
        "area_list": [],
        "first_seen": None,
        "last_seen": None
    })
    for r in rows:
        c = per_class[r["class"]]
        c["count"] += 1
        c["conf_list"].append(r["confidence"])
        c["area_list"].append(r["area"])
        if c["first_seen"] is None or r["timestamp"] < c["first_seen"]:
            c["first_seen"] = r["timestamp"]
        if c["last_seen"] is None or r["timestamp"] > c["last_seen"]:
            c["last_seen"] = r["timestamp"]

    # Compute stats per class
    classes_out = {}
    for cls, c in per_class.items():
        confs = c["conf_list"]
        areas = c["area_list"]
        classes_out[cls] = {
            "count": c["count"],
            "confidence_mean": sum(confs)/len(confs),
            "confidence_median": median(confs),
            "confidence_min": min(confs),
            "confidence_max": max(confs),
            "bbox_area_mean": (sum(areas)/len(areas)) if areas else 0,
            "first_seen": c["first_seen"].isoformat() + "Z",
            "last_seen": c["last_seen"].isoformat() + "Z",
        }

    # Top classes
    cls_counts = Counter({cls: data["count"] for cls, data in classes_out.items()})
    top_classes = cls_counts.most_common(top_n)

    # Per-minute activity
    per_min = defaultdict(int)
    for ts in times:
        key = ts.replace(second=0, microsecond=0).isoformat() + "Z"
        per_min[key] += 1

    summary = {
        "total_detections": len(rows),
        "unique_classes": len(classes_out),
        "time_start": t0.isoformat() + "Z",
        "time_end": t1.isoformat() + "Z",
        "duration_seconds": int((t1 - t0).total_seconds()),
        "classes": classes_out,
        "top_classes": top_classes,   # list of (class, count)
        "per_minute": dict(sorted(per_min.items())),
    }
    return summary

def fmt_hms(seconds):
    if seconds is None:
        return "-"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"

def build_report(summary, top_n=10):
    if summary["total_detections"] == 0:
        return "# YOLO Report\n\nNo detections found.\n"

    lines = []
    lines.append("# YOLO Detection Report\n")
    lines.append("## Overview")
    lines.append(f"- Total detections: **{summary['total_detections']}**")
    lines.append(f"- Unique classes: **{summary['unique_classes']}**")
    lines.append(f"- Time range: **{summary['time_start']} → {summary['time_end']}**")
    lines.append(f"- Duration: **{fmt_hms(summary['duration_seconds'])}**\n")

    # Top classes
    lines.append(f"## Top {min(top_n, len(summary['top_classes']))} classes")
    if summary["top_classes"]:
        for cls, cnt in summary["top_classes"][:top_n]:
            lines.append(f"- **{cls}** — {cnt}")
    else:
        lines.append("- (no classes)")
    lines.append("")

    # Per-class table
    lines.append("## Per-class statistics")
    lines.append("| Class | Count | Conf µ | Conf 50% | Conf min | Conf max | Mean BBox Area | First seen | Last seen |")
    lines.append("|------:|------:|-------:|---------:|---------:|---------:|---------------:|:-----------|:----------|")
    for cls, data in sorted(summary["classes"].items(), key=lambda kv: kv[1]["count"], reverse=True):
        lines.append(
            f"| {cls} | {data['count']} | "
            f"{data['confidence_mean']:.3f} | {data['confidence_median']:.3f} | "
            f"{data['confidence_min']:.3f} | {data['confidence_max']:.3f} | "
            f"{int(data['bbox_area_mean'])} | {data['first_seen']} | {data['last_seen']} |"
        )

    # Per-minute peak
    if summary["per_minute"]:
        peak_minute, peak_count = max(summary["per_minute"].items(), key=lambda kv: kv[1])
        lines.append("\n## Activity")
        lines.append(f"- Peak minute: **{peak_minute}** with **{peak_count}** detections")
        lines.append("- Detections per minute:")
        for minute, cnt in summary["per_minute"].items():
            lines.append(f"  - {minute}: {cnt}")

    return "\n".join(lines) + "\n"

def write_csv(path, rows, header):
    with open(path, "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(header)
        wr.writerows(rows)

def main():
    args = parse_args()
    rows = load_detections(args.csv, min_conf=args.min_conf)
    summary = summarize(rows, top_n=args.top)

    # Build text/markdown report
    report = build_report(summary, top_n=args.top)
    print(report)

    # Write optional outputs
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"[+] Wrote report: {args.out}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2)
        print(f"[+] Wrote JSON: {args.json}")

    if args.per_class:
        # Flatten per-class dict into rows
        header = ["class","count","conf_mean","conf_median","conf_min","conf_max","bbox_area_mean","first_seen","last_seen"]
        rows_out = []
        for cls, d in summary["classes"].items():
            rows_out.append([
                cls, d["count"], f"{d['confidence_mean']:.6f}", f"{d['confidence_median']:.6f}",
                f"{d['confidence_min']:.6f}", f"{d['confidence_max']:.6f}",
                int(d["bbox_area_mean"]), d["first_seen"], d["last_seen"]
            ])
        rows_out.sort(key=lambda r: int(r[1]), reverse=True)
        write_csv(args.per_class, rows_out, header)
        print(f"[+] Wrote per-class CSV: {args.per_class}")

    if args.per_min:
        header = ["minute_iso", "detections"]
        rows_out = [[m, c] for m, c in summary["per_minute"].items()]
        write_csv(args.per_min, rows_out, header)
        print(f"[+] Wrote per-minute CSV: {args.per_min}")

if __name__ == "__main__":
    main()


##################################
python3 yolo_report.py --csv detections.csv
