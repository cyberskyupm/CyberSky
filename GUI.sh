# this file is for the GUI
flask_control_gui.py:
#!/usr/bin/env python3
"""
flask_control_gui.py

Safe demonstration UI to "control" systems on a Raspberry Pi.
Buttons are SAFE: Wi-Fi deauth is simulated, Bluetooth actions are simulated.
YOLO start/stop will launch your existing detect_and_log.py if available.

Usage:
  pip3 install flask
  python3 flask_control_gui.py

Open http://<pi-ip>:5000/
"""

import os
import subprocess
import signal
import time
import threading
from pathlib import Path
from flask import Flask, render_template, jsonify, request, send_from_directory

APP_DIR = Path(__file__).resolve().parent
APP = Flask(__name__, template_folder=str(APP_DIR / "templates"), static_folder=str(APP_DIR / "static"))

# Config: paths and commands
WIFI_SCRIPT = APP_DIR / "wifi_deauth.sh"    # safe placeholder script
BT_SNIFF_PID = APP_DIR / "bt_sniff.pid"
BT_LOG = APP_DIR / "bt_sim.log"
BT_HIJACK_LOG = APP_DIR / "bt_hijack_sim.log"

YOLO_PID = APP_DIR / "yolo_process.pid"
YOLO_CMD = ["python3", str(APP_DIR / "detect_and_log.py"), "--source", "0", "--out", str(APP_DIR / "detections.csv")]
YOLO_SIMULATE = True   # If True, YOLO start will be simulated (no actual detect_and_log.py run).
                       # Set to False if you want the GUI to actually launch detect_and_log.py

ALERTS_LOG = APP_DIR / "alerts.log"   # used by the Flask alert app from previous steps
DETECTIONS_CSV = APP_DIR / "detections.csv"
REPORT_MD = APP_DIR / "report.md"

# Helper utilities
def is_running(pidfile):
    if not pidfile.exists():
        return False
    try:
        pid = int(pidfile.read_text().strip())
    except Exception:
        return False
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        # stale pidfile
        try:
            pidfile.unlink()
        except Exception:
            pass
        return False

def start_yolo(real_run=not YOLO_SIMULATE):
    """
    Start YOLO script as background process and write pidfile.
    If real_run is False, simulate by writing a fake pid and message.
    """
    if YOLO_PID.exists() and is_running(YOLO_PID):
        return False, "YOLO already running"
    if not real_run:
        # Simulate by creating a small background thread / fake pid
        pid = int(time.time())
        YOLO_PID.write_text(str(pid))
        return True, "YOLO simulated start"
    # Real run: start the detect_and_log.py in background
    try:
        p = subprocess.Popen(YOLO_CMD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        YOLO_PID.write_text(str(p.pid))
        return True, f"YOLO started pid={p.pid}"
    except FileNotFoundError:
        return False, "detect_and_log.py not found or python3 missing"
    except Exception as e:
        return False, str(e)

def stop_yolo():
    if not YOLO_PID.exists():
        return False, "YOLO not running (no pidfile)"
    try:
        pid = int(YOLO_PID.read_text().strip())
    except Exception:
        YOLO_PID.unlink(missing_ok=True)
        return False, "Invalid pidfile removed"
    try:
        os.kill(pid, signal.SIGTERM)
        # wait briefly for process to die
        time.sleep(0.5)
    except Exception:
        pass
    YOLO_PID.unlink(missing_ok=True)
    return True, f"YOLO stopped pid={pid}"

def simulate_bt_sniff(start=True):
    if start:
        # create pid file and append to log to simulate activity
        pid = int(time.time())
        Path(BT_SNIFF_PID).write_text(str(pid))
        with open(BT_LOG, "a") as f:
            f.write(f"{time.asctime()} - SIMULATED BT SNIFF START pid={pid}\n")
        return True, "Bluetooth sniffing simulated start"
    else:
        Path(BT_SNIFF_PID).unlink(missing_ok=True)
        with open(BT_LOG, "a") as f:
            f.write(f"{time.asctime()} - SIMULATED BT SNIFF STOP\n")
        return True, "Bluetooth sniffing simulated stop"

def simulate_bt_hijack():
    # simulated one-shot action: append to a log
    with open(BT_HIJACK_LOG, "a") as f:
        f.write(f"{time.asctime()} - SIMULATED BT HIJACK TRIGGERED (demo only)\n")
    return True, "Simulated BT hijack logged"

def run_wifi_deauth_sim():
    # Run the wifi_deauth.sh placeholder in background (safe)
    if not WIFI_SCRIPT.exists():
        return False, "wifi_deauth.sh not found"
    try:
        # run script in background and detach
        subprocess.Popen(["/bin/bash", str(WIFI_SCRIPT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True, "Simulated Wi-Fi deauth script executed"
    except Exception as e:
        return False, str(e)

def read_alerts(limit=200):
    if not ALERTS_LOG.exists():
        return []
    lines = ALERTS_LOG.read_text().splitlines()
    # last N
    return lines[-limit:]

def generate_report():
    # Run yolo_report.py to produce a markdown report (safe). If not present, simulate.
    rpt_script = APP_DIR / "yolo_report.py"
    if rpt_script.exists():
        try:
            subprocess.run(["python3", str(rpt_script), "--csv", str(DETECTIONS_CSV), "--out", str(REPORT_MD)], timeout=30)
            if REPORT_MD.exists():
                return True, "Report generated", REPORT_MD.name
            else:
                return False, "Report script ran but report not found", ""
        except subprocess.TimeoutExpired:
            return False, "Report generation timed out", ""
        except Exception as e:
            return False, str(e), ""
    else:
        # Simulate: write a tiny report
        REPORT_MD.write_text("# Simulated YOLO Report\n\nNo yolo_report.py found, this is a placeholder.\n")
        return True, "Simulated report created", REPORT_MD.name

# Flask routes
@APP.route("/")
def index():
    statuses = {
        "wifi_script_exists": WIFI_SCRIPT.exists(),
        "bt_sniff_running": is_running(Path(BT_SNIFF_PID)),
        "yolo_running": is_running(Path(YOLO_PID)),
        "alerts_log_exists": ALERTS_LOG.exists(),
        "detections_exists": Path(DETECTIONS_CSV).exists(),
        "report_exists": Path(REPORT_MD).exists(),
    }
    return render_template("index.html", statuses=statuses)

@APP.route("/api/action", methods=["POST"])
def api_action():
    data = request.get_json() or {}
    action = data.get("action", "")
    if action == "wifi_deauth":
        ok, msg = run_wifi_deauth_sim()
        return jsonify({"ok": ok, "msg": msg})
    if action == "bt_sniff_start":
        ok, msg = simulate_bt_sniff(start=True)
        return jsonify({"ok": ok, "msg": msg})
    if action == "bt_sniff_stop":
        ok, msg = simulate_bt_sniff(start=False)
        return jsonify({"ok": ok, "msg": msg})
    if action == "bt_hijack":
        ok, msg = simulate_bt_hijack()
        return jsonify({"ok": ok, "msg": msg})
    if action == "yolo_start":
        ok, msg = start_yolo(real_run=not YOLO_SIMULATE)
        return jsonify({"ok": ok, "msg": msg})
    if action == "yolo_stop":
        ok, msg = stop_yolo()
        return jsonify({"ok": ok, "msg": msg})
    if action == "alerts":
        logs = read_alerts(limit=200)
        return jsonify({"ok": True, "logs": logs})
    if action == "report":
        ok, msg, fname = generate_report()
        return jsonify({"ok": ok, "msg": msg, "report": fname})
    return jsonify({"ok": False, "msg": "unknown action"})

@APP.route("/reports/<path:fname>")
def serve_report(fname):
    # serve REPORT_MD if requested
    folder = str(APP_DIR)
    return send_from_directory(folder, fname)

if __name__ == "__main__":
    # ensure wifi script exists (if not, create a safe placeholder)
    if not WIFI_SCRIPT.exists():
        WIFI_SCRIPT.write_text("#!/bin/bash\n\necho \"SIMULATED wifi deauth script ran at $(date)\" >> \"" + str(APP_DIR / "wifi_sim.log") + "\"\n# harmless sleep to mimic work\nsleep 1\n")
        os.chmod(WIFI_SCRIPT, 0o755)
    APP.run(host="0.0.0.0", port=5000, debug=True)



###########################################
templates/index.html:
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Pi Control GUI — Demo</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial; max-width:900px; margin:20px auto; }
    button { padding:10px 16px; margin:6px; font-size:16px; }
    .group { border:1px solid #eee; padding:12px; margin:12px 0; border-radius:6px; background:#fafafa; }
    .status { font-size:0.9em; color:#666; }
    #logs { white-space:pre-wrap; background:#111; color:#0f0; padding:10px; height:240px; overflow:auto; font-family:monospace; }
  </style>
</head>
<body>
  <h1>Raspberry Pi — Safe Control GUI (Demo)</h1>

  <div class="group">
    <h3>Wi-Fi (SIMULATED)</h3>
    <button onclick="doAction('wifi_deauth')">Run Wi-Fi deauth script (SIMULATED)</button>
    <div class="status">wifi_deauth.sh present: <strong>{{ statuses.wifi_script_exists }}</strong></div>
  </div>

  <div class="group">
    <h3>Bluetooth (SIMULATED)</h3>
    <button onclick="doAction('bt_sniff_start')">Start BT sniff (SIMULATED)</button>
    <button onclick="doAction('bt_sniff_stop')">Stop BT sniff (SIMULATED)</button>
    <button onclick="doAction('bt_hijack')">Trigger BT hijack (SIMULATED)</button>
    <div class="status">BT sniff running: <strong id="bt_status">{{ statuses.bt_sniff_running }}</strong></div>
  </div>

  <div class="group">
    <h3>YOLO & Alerts</h3>
    <button onclick="doAction('yolo_start')">Start YOLO</button>
    <button onclick="doAction('yolo_stop')">Stop YOLO</button>
    <button onclick="doAction('alerts')">Show Alerts Log</button>
    <button onclick="doAction('report')">Generate Report</button>
    <div class="status">YOLO running: <strong id="yolo_status">{{ statuses.yolo_running }}</strong></div>
    <div style="margin-top:8px;">
      <h4>Alerts (last lines)</h4>
      <div id="logs">No logs loaded yet. Click "Show Alerts Log".</div>
    </div>
    <div id="report_link" style="margin-top:10px;"></div>
  </div>

  <script src="/static/main.js"></script>
  <script>
    // update UI statuses periodically
    setInterval(() => {
      fetch('/').then(r => r.text()).then(html => {
        // crude check for status values in returned HTML
        document.getElementById('yolo_status').innerText = html.includes('yolo_running: true') ? 'True' : 'False';
        document.getElementById('bt_status').innerText = html.includes('bt_sniff_running: true') ? 'True' : 'False';
      });
    }, 3000);
  </script>
</body>
</html>

###################################
static/main.js:
async function doAction(action) {
  const res = await fetch('/api/action', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({action: action})
  });
  const j = await res.json();
  console.log(action, j);
  if (action === 'alerts' && j.ok) {
    const logs = j.logs || [];
    document.getElementById('logs').innerText = logs.join("\n") || "(no alerts log)";
  }
  if (action === 'report') {
    if (j.ok && j.report) {
      const link = document.getElementById('report_link');
      link.innerHTML = `Report: <a href="/reports/${j.report}" target="_blank">${j.report}</a>`;
    } else {
      alert(j.msg || 'No report');
    }
  }
  if (!j.ok) {
    alert("Action failed: " + (j.msg || "unknown"));
  }
}
###############################
pip3 install flask
python3 flask_control_gui.py
