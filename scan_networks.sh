#!/usr/bin/env bash
# scan_networks.sh — outputs: BSSID,CH,ESSID
# Usage: ./scan_networks.sh [interface] [scan_seconds]
set -euo pipefail
IFS=$'\n\t'

network_interface="${1:-wlan1}"
mon_suffix="mon"
mon_iface="${network_interface}${mon_suffix}"
tmp_dir="$(mktemp -d)"
csv_prefix="$tmp_dir/airodump"
scan_duration="${2:-15}"   # longer default scan

cleanup(){ pkill -f "airodump-ng .*${csv_prefix}" 2>/dev/null || true; rm -rf "$tmp_dir"; }
trap cleanup EXIT

# Start monitor mode (best-effort; no channel lock for discovery)
airmon-ng start "$network_interface" >/dev/null 2>&1 || true

# Run airodump-ng to produce CSV
timeout $((scan_duration+8)) airodump-ng --write-interval 1 --write "$csv_prefix" --output-format csv "$mon_iface" >/dev/null 2>&1 &
sleep 1

# Wait for CSV
csvfile=""; wait_seconds=0; max_wait=$((scan_duration+8))
while [[ -z "$csvfile" && $wait_seconds -lt $max_wait ]]; do
  sleep 1; wait_seconds=$((wait_seconds+1))
  f=$(ls -1t "$tmp_dir"/airodump-*.csv 2>/dev/null | head -n1 || true)
  [[ -n "$f" ]] && csvfile="$f"
done
[[ -z "$csvfile" ]] && { echo "ERR:NoCSV"; exit 1; }

# Parse BSSID table (first section of the CSV)
awk -F',' '
  BEGIN{in_bss=1}
  NF==1 && $1==""{in_bss=0; next}
  in_bss && NR>1{
    for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i)}
    bssid=$1; ch=$4; essid=$14
    if(bssid!="" && essid!=""){ gsub(/,/, " ", essid); print bssid","ch","essid }
  }
' "$csvfile" | sort -u
