# this File is for the Alerting:
monitor_detections.py:
#!/usr/bin/env python3
"""
monitor_detections.py

Watches a CSV (detections.csv) produced by your YOLO script and posts alerts to a local Flask app
when alert conditions are met.

Usage:
  python3 monitor_detections.py --csv detections.csv --url http://127.0.0.1:5000/alert --token SECRET_TOKEN

Configurable (in-code):
  - alert_classes: list of class names to always alert on (empty = alert on any class)
  - min_confidence: minimum confidence (0..1) to consider
  - repeat_within_seconds: if same class+bbox appears this many seconds after previous alert, suppress (prevents flooding)
  - count_window / count_threshold: if same class seen >= count_threshold within count_window seconds, trigger aggregate alert
"""

import argparse
import csv
import time
import requests
from datetime import datetime, timedelta
import os
import sys

# -------------------------
# Configurable rules
# -------------------------
alert_classes = []            # example: ["person", "knife"]  # empty => alert on any class
min_confidence = 0.30         # min confidence to consider an alert
repeat_within_seconds = 5     # suppress duplicate alerts for same class+bbox within this many seconds
count_window = 10             # seconds
count_threshold = 5           # if same class appears >= threshold within window, produce an aggregate alert
# -------------------------

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--csv', default='detections.csv', help='Path to detections CSV')
    p.add_argument('--url', default='http://127.0.0.1:5000/alert', help='Flask alert endpoint URL')
    p.add_argument('--token', default='changeme', help='Simple auth token to include in the Alert-Token header')
    p.add_argument('--poll', type=float, default=1.0, help='Polling interval in seconds')
    return p.parse_args()

def parse_ts(ts_str):
    # Accept ISO-format ending with Z or without
    if ts_str.endswith('Z'):
        ts_str = ts_str[:-1]
    try:
        return datetime.fromisoformat(ts_str)
    except Exception:
        # fallback to naive parse
        return datetime.utcnow()

def bbox_key(x1,y1,x2,y2):
    # make small tolerance to avoid tiny pixel diffs
    return f"{int(x1)}:{int(y1)}:{int(x2)}:{int(y2)}"

def post_alert(url, token, payload):
    headers = {'Content-Type': 'application/json', 'Alert-Token': token}
    try:
        r = requests.post(url, json=payload, headers=headers, timeout=3)
        r.raise_for_status()
        return True, r.text
    except Exception as e:
        return False, str(e)

def tail_headers(csv_path):
    """
    Returns file object positioned after header line, plus the header list.
    If file doesn't exist yet, create it and wait.
    """
    while True:
        if os.path.exists(csv_path):
            f = open(csv_path, 'r', newline='')
            reader = csv.reader(f)
            try:
                headers = next(reader)
            except StopIteration:
                headers = []
            # position to end-of-file for tailing
            f.seek(0, os.SEEK_END)
            return f, headers
        else:
            print(f"[monitor] waiting for {csv_path} to appear...")
            time.sleep(1)

def main():
    args = parse_args()
    csv_path = args.csv
    url = args.url
    token = args.token
    poll = args.poll

    f, headers = tail_headers(csv_path)
    print("[monitor] watching", csv_path, "->", url)
    # indices mapping: try to find columns
    header_map = {}
    for i,h in enumerate(headers):
        header_map[h.strip().lower()] = i

    # expected columns: timestamp, class, confidence, x1,y1,x2,y2
    # fallback to positional if header absent
    # Keep memory of processed rows using file position
    processed_pos = f.tell()

    # history to suppress duplicate alerts: (class, bbox_key) -> last_ts
    last_alert = {}
    # sliding window counts: class -> list[timestamps]
    class_hits = {}

    try:
        while True:
            st = os.stat(csv_path)
            if st.st_size < processed_pos:
                # file rotated/truncated, reopen
                f.close()
                f, headers = tail_headers(csv_path)
                processed_pos = f.tell()

            f.seek(processed_pos)
            new_lines = f.readlines()
            if new_lines:
                for line in new_lines:
                    line = line.strip()
                    if not line:
                        continue
                    # parse CSV row robustly
                    try:
                        row = next(csv.reader([line]))
                    except Exception:
                        continue
                    # map columns
                    if headers:
                        # attempt to lookup by header name
                        try:
                            ts = row[header_map.get('timestamp',0)]
                        except Exception:
                            ts = row[0]
                        try:
                            cls = row[header_map.get('class',1)]
                        except Exception:
                            cls = row[1] if len(row)>1 else "unknown"
                        try:
                            conf = float(row[header_map.get('confidence',2)])
                        except Exception:
                            conf = float(row[2]) if len(row)>2 else 0.0
                        try:
                            x1 = int(row[header_map.get('x1',3)])
                            y1 = int(row[header_map.get('y1',4)])
                            x2 = int(row[header_map.get('x2',5)])
                            y2 = int(row[header_map.get('y2',6)])
                        except Exception:
                            # fallback: if columns not enough, skip
                            if len(row) >= 7:
                                x1,y1,x2,y2 = map(int, row[3:7])
                            else:
                                continue
                    else:
                        # no header: positional
                        if len(row) < 7:
                            continue
                        ts, cls, conf_s, x1_s, y1_s, x2_s, y2_s = row[:7]
                        conf = float(conf_s)
                        x1,y1,x2,y2 = map(int, (x1_s,y1_s,x2_s,y2_s))

                    ts_dt = parse_ts(ts)
                    cls = cls.strip()
                    # rule: class filter
                    if alert_classes and cls not in alert_classes:
                        # skip if not in configured alert list
                        continue
                    if conf < min_confidence:
                        continue

                    key = (cls, bbox_key(x1,y1,x2,y2))
                    now = ts_dt

                    # suppression check
                    last = last_alert.get(key)
                    if last and (now - last).total_seconds() < repeat_within_seconds:
                        # duplicate within suppression window: ignore
                        continue

                    # add to class_hits and purge old
                    hits = class_hits.setdefault(cls, [])
                    hits.append(now)
                    cutoff = now - timedelta(seconds=count_window)
                    # keep only recent
                    hits = [t for t in hits if t >= cutoff]
                    class_hits[cls] = hits

                    # If number of hits >= threshold -> send aggregate alert
                    if len(hits) >= count_threshold:
                        payload = {
                            "type": "aggregate",
                            "class": cls,
                            "count": len(hits),
                            "window_seconds": count_window,
                            "timestamp": now.isoformat() + "Z",
                            "example_bbox": {"x1": x1, "y1": y1, "x2": x2, "y2": y2},
                        }
                        ok, resp = post_alert(url, token, payload)
                        if ok:
                            print(f"[monitor] sent AGGREGATE alert for {cls} count={len(hits)}")
                            # clear the hits for this class so we don't repeat immediately
                            class_hits[cls] = []
                            # mark last alert for the example bbox
                            last_alert[key] = now
                        else:
                            print("[monitor] failed to send aggregate alert:", resp)
                    else:
                        # send single detection alert
                        payload = {
                            "type": "single",
                            "class": cls,
                            "confidence": conf,
                            "bbox": {"x1": x1, "y1": y1, "x2": x2, "y2": y2},
                            "timestamp": now.isoformat() + "Z",
                        }
                        ok, resp = post_alert(url, token, payload)
                        if ok:
                            print(f"[monitor] sent alert: {cls} {conf:.2f}")
                            last_alert[key] = now
                        else:
                            print("[monitor] failed to send alert:", resp)

                # update processed_pos
                processed_pos = f.tell()
            time.sleep(poll)
    except KeyboardInterrupt:
        print("Stopping monitor.")
        f.close()
        sys.exit(0)

if __name__ == '__main__':
    main()

###########################################################################

flask_alert_app.py:
#!/usr/bin/env python3
"""
monitor_detections.py

Watches a CSV (detections.csv) produced by your YOLO script and posts alerts to a local Flask app
when alert conditions are met.

Usage:
  python3 monitor_detections.py --csv detections.csv --url http://127.0.0.1:5000/alert --token SECRET_TOKEN

Configurable (in-code):
  - alert_classes: list of class names to always alert on (empty = alert on any class)
  - min_confidence: minimum confidence (0..1) to consider
  - repeat_within_seconds: if same class+bbox appears this many seconds after previous alert, suppress (prevents flooding)
  - count_window / count_threshold: if same class seen >= count_threshold within count_window seconds, trigger aggregate alert
"""

import argparse
import csv
import time
import requests
from datetime import datetime, timedelta
import os
import sys

# -------------------------
# Configurable rules
# -------------------------
alert_classes = []            # example: ["person", "knife"]  # empty => alert on any class
min_confidence = 0.30         # min confidence to consider an alert
repeat_within_seconds = 5     # suppress duplicate alerts for same class+bbox within this many seconds
count_window = 10             # seconds
count_threshold = 5           # if same class appears >= threshold within window, produce an aggregate alert
# -------------------------

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--csv', default='detections.csv', help='Path to detections CSV')
    p.add_argument('--url', default='http://127.0.0.1:5000/alert', help='Flask alert endpoint URL')
    p.add_argument('--token', default='changeme', help='Simple auth token to include in the Alert-Token header')
    p.add_argument('--poll', type=float, default=1.0, help='Polling interval in seconds')
    return p.parse_args()

def parse_ts(ts_str):
    # Accept ISO-format ending with Z or without
    if ts_str.endswith('Z'):
        ts_str = ts_str[:-1]
    try:
        return datetime.fromisoformat(ts_str)
    except Exception:
        # fallback to naive parse
        return datetime.utcnow()

def bbox_key(x1,y1,x2,y2):
    # make small tolerance to avoid tiny pixel diffs
    return f"{int(x1)}:{int(y1)}:{int(x2)}:{int(y2)}"

def post_alert(url, token, payload):
    headers = {'Content-Type': 'application/json', 'Alert-Token': token}
    try:
        r = requests.post(url, json=payload, headers=headers, timeout=3)
        r.raise_for_status()
        return True, r.text
    except Exception as e:
        return False, str(e)

def tail_headers(csv_path):
    """
    Returns file object positioned after header line, plus the header list.
    If file doesn't exist yet, create it and wait.
    """
    while True:
        if os.path.exists(csv_path):
            f = open(csv_path, 'r', newline='')
            reader = csv.reader(f)
            try:
                headers = next(reader)
            except StopIteration:
                headers = []
            # position to end-of-file for tailing
            f.seek(0, os.SEEK_END)
            return f, headers
        else:
            print(f"[monitor] waiting for {csv_path} to appear...")
            time.sleep(1)

def main():
    args = parse_args()
    csv_path = args.csv
    url = args.url
    token = args.token
    poll = args.poll

    f, headers = tail_headers(csv_path)
    print("[monitor] watching", csv_path, "->", url)
    # indices mapping: try to find columns
    header_map = {}
    for i,h in enumerate(headers):
        header_map[h.strip().lower()] = i

    # expected columns: timestamp, class, confidence, x1,y1,x2,y2
    # fallback to positional if header absent
    # Keep memory of processed rows using file position
    processed_pos = f.tell()

    # history to suppress duplicate alerts: (class, bbox_key) -> last_ts
    last_alert = {}
    # sliding window counts: class -> list[timestamps]
    class_hits = {}

    try:
        while True:
            st = os.stat(csv_path)
            if st.st_size < processed_pos:
                # file rotated/truncated, reopen
                f.close()
                f, headers = tail_headers(csv_path)
                processed_pos = f.tell()

            f.seek(processed_pos)
            new_lines = f.readlines()
            if new_lines:
                for line in new_lines:
                    line = line.strip()
                    if not line:
                        continue
                    # parse CSV row robustly
                    try:
                        row = next(csv.reader([line]))
                    except Exception:
                        continue
                    # map columns
                    if headers:
                        # attempt to lookup by header name
                        try:
                            ts = row[header_map.get('timestamp',0)]
                        except Exception:
                            ts = row[0]
                        try:
                            cls = row[header_map.get('class',1)]
                        except Exception:
                            cls = row[1] if len(row)>1 else "unknown"
                        try:
                            conf = float(row[header_map.get('confidence',2)])
                        except Exception:
                            conf = float(row[2]) if len(row)>2 else 0.0
                        try:
                            x1 = int(row[header_map.get('x1',3)])
                            y1 = int(row[header_map.get('y1',4)])
                            x2 = int(row[header_map.get('x2',5)])
                            y2 = int(row[header_map.get('y2',6)])
                        except Exception:
                            # fallback: if columns not enough, skip
                            if len(row) >= 7:
                                x1,y1,x2,y2 = map(int, row[3:7])
                            else:
                                continue
                    else:
                        # no header: positional
                        if len(row) < 7:
                            continue
                        ts, cls, conf_s, x1_s, y1_s, x2_s, y2_s = row[:7]
                        conf = float(conf_s)
                        x1,y1,x2,y2 = map(int, (x1_s,y1_s,x2_s,y2_s))

                    ts_dt = parse_ts(ts)
                    cls = cls.strip()
                    # rule: class filter
                    if alert_classes and cls not in alert_classes:
                        # skip if not in configured alert list
                        continue
                    if conf < min_confidence:
                        continue

                    key = (cls, bbox_key(x1,y1,x2,y2))
                    now = ts_dt

                    # suppression check
                    last = last_alert.get(key)
                    if last and (now - last).total_seconds() < repeat_within_seconds:
                        # duplicate within suppression window: ignore
                        continue

                    # add to class_hits and purge old
                    hits = class_hits.setdefault(cls, [])
                    hits.append(now)
                    cutoff = now - timedelta(seconds=count_window)
                    # keep only recent
                    hits = [t for t in hits if t >= cutoff]
                    class_hits[cls] = hits

                    # If number of hits >= threshold -> send aggregate alert
                    if len(hits) >= count_threshold:
                        payload = {
                            "type": "aggregate",
                            "class": cls,
                            "count": len(hits),
                            "window_seconds": count_window,
                            "timestamp": now.isoformat() + "Z",
                            "example_bbox": {"x1": x1, "y1": y1, "x2": x2, "y2": y2},
                        }
                        ok, resp = post_alert(url, token, payload)
                        if ok:
                            print(f"[monitor] sent AGGREGATE alert for {cls} count={len(hits)}")
                            # clear the hits for this class so we don't repeat immediately
                            class_hits[cls] = []
                            # mark last alert for the example bbox
                            last_alert[key] = now
                        else:
                            print("[monitor] failed to send aggregate alert:", resp)
                    else:
                        # send single detection alert
                        payload = {
                            "type": "single",
                            "class": cls,
                            "confidence": conf,
                            "bbox": {"x1": x1, "y1": y1, "x2": x2, "y2": y2},
                            "timestamp": now.isoformat() + "Z",
                        }
                        ok, resp = post_alert(url, token, payload)
                        if ok:
                            print(f"[monitor] sent alert: {cls} {conf:.2f}")
                            last_alert[key] = now
                        else:
                            print("[monitor] failed to send alert:", resp)

                # update processed_pos
                processed_pos = f.tell()
            time.sleep(poll)
    except KeyboardInterrupt:
        print("Stopping monitor.")
        f.close()
        sys.exit(0)

if __name__ == '__main__':
    main()
########################################################
flask_alert_app.py:
#!/usr/bin/env python3
"""
flask_alert_app.py

Simple Flask app that receives POST /alert with JSON body.
It requires a matching Alert-Token header (simple lightweight auth).
Alerts are stored in-memory and appended to alerts.log.

Usage:
  export FLASK_APP=flask_alert_app.py
  python3 flask_alert_app.py
  # or: FLASK_ENV=development python3 flask_alert_app.py

Endpoints:
  POST /alert   - accepts JSON, header 'Alert-Token: SECRET_TOKEN'
  GET  /        - web UI: shows recent alerts
  GET  /api/alerts - returns alerts JSON
"""

from flask import Flask, request, jsonify, render_template_string, abort
import json
from datetime import datetime
import os

# simple config - use same token as monitor
ALERT_TOKEN = os.environ.get("ALERT_TOKEN", "changeme")
ALERT_LOG = "alerts.log"
MAX_HISTORY = 200

app = Flask(__name__)
alerts = []  # in-memory list of alerts (most recent last)

HTML_TEMPLATE = """
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Alert Dashboard</title>
  <style>
    body { font-family: Arial, sans-serif; max-width:900px; margin: 20px auto; color:#222; }
    .alert { border-left: 4px solid #cc3333; padding: 8px; margin: 8px 0; background:#fff7f7; }
    .aggregate { border-left-color:#3366cc; background:#f3f7ff; }
    .meta { color:#666; font-size:0.9em; }
    pre { background:#f4f4f4; padding:8px; overflow:auto; }
  </style>
</head>
<body>
  <h1>Alert Dashboard</h1>
  <p>Total alerts stored: {{ alerts|length }}</p>
  {% for a in alerts|reverse %}
    <div class="alert {% if a.get('type')=='aggregate' %}aggregate{% endif %}">
      <div><strong>{{ a.get('class','-') }}</strong> <span class="meta">at {{ a.get('timestamp') }}</span></div>
      <div class="meta">type: {{ a.get('type') }}, raw: <small>{{ a.get('confidence','-') }}</small></div>
      <pre>{{ a|tojson(indent=2) }}</pre>
    </div>
  {% endfor %}
</body>
</html>
"""

def append_log(entry):
    with open(ALERT_LOG, 'a') as f:
        f.write(json.dumps(entry) + "\n")

@app.route('/alert', methods=['POST'])
def receive_alert():
    token = request.headers.get('Alert-Token', '')
    if token != ALERT_TOKEN:
        return jsonify({"error":"invalid token"}), 403
    if not request.is_json:
        return jsonify({"error":"expected JSON"}), 400
    payload = request.get_json()
    # enrich with server-received timestamp
    payload.setdefault('received_at', datetime.utcnow().isoformat() + "Z")
    alerts.append(payload)
    # trim old
    if len(alerts) > MAX_HISTORY:
        del alerts[:len(alerts)-MAX_HISTORY]
    append_log(payload)
    return jsonify({"status":"ok", "received": payload}), 201

@app.route('/api/alerts', methods=['GET'])
def api_alerts():
    return jsonify(alerts)

@app.route('/', methods=['GET'])
def index():
    return render_template_string(HTML_TEMPLATE, alerts=alerts)

if __name__ == '__main__':
    # For demo, allow setting token via env
    app.run(host='0.0.0.0', port=5000)
##############################################################################
#How to run (step-by-step)
Put flask_alert_app.py and monitor_detections.py on the Pi (same folder). Make them executable or run with python3.

Start Flask app in a terminal:
export ALERT_TOKEN="SECRET_TOKEN"   # pick any secret, must match below
python3 flask_alert_app.py
# Flask listens on port 5000 by default (0.0.0.0)
Start your YOLO detection script so it writes/updates detections.csv. (The earlier detect_and_log.py writes UTC ISO timestamps ending with Z — compatible.)

Start the monitor in another terminal (use the same token):
python3 monitor_detections.py --csv detections.csv --url http://127.0.0.1:5000/alert --token SECRET_TOKEN

##Tuning alerts

Set alert_classes = ["person", "knife"] in monitor_detections.py to only alert on specific classes.
