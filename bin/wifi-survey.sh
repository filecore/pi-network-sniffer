#!/usr/bin/env bash
# wifi-survey.sh -- passive Wi-Fi RF survey via `iw dev wlan0 scan`.
#
# No association attempts, no transmission. Pure receive.
#
# Args:
#   $1  output dir (will write wifi-scan.txt + wifi-scan.json there)
#
# Exits 0 even if wlan0 is missing or scan returns nothing -- a missing
# survey is non-fatal to the orchestrator.

set -euo pipefail
OUT_DIR="${1:?usage: wifi-survey.sh <out-dir>}"
mkdir -p "${OUT_DIR}"
OUT_TXT="${OUT_DIR}/wifi-scan.txt"
OUT_JSON="${OUT_DIR}/wifi-scan.json"

WLAN_IF="${WLAN_IF:-wlan0}"

if ! ip link show "${WLAN_IF}" >/dev/null 2>&1; then
    {
        echo "Wi-Fi survey skipped: ${WLAN_IF} not present."
        echo "Host: $(hostname)  arch: $(uname -m)"
    } > "${OUT_TXT}"
    echo '{"available": false, "interface": "'"${WLAN_IF}"'", "aps": []}' > "${OUT_JSON}"
    exit 0
fi

# Bring it up administratively. We do NOT call wpa_supplicant or associate.
ip link set "${WLAN_IF}" up || true
# Settle for a second so the firmware accepts the scan command.
sleep 1

RAW="$(iw dev "${WLAN_IF}" scan 2>&1 || true)"

# Parse with python -- robust splitting on "BSS aa:bb:cc:..." blocks.
python3 - "${WLAN_IF}" "${OUT_TXT}" "${OUT_JSON}" <<'PY' <<<"${RAW}"
import json, re, sys, datetime

iface = sys.argv[1]
out_txt = sys.argv[2]
out_json = sys.argv[3]
raw = sys.stdin.read()

aps = []
current = None

def finalize(ap):
    if ap is None:
        return
    # Normalise encryption flag.
    rsn = ap.get("rsn", False)
    wpa = ap.get("wpa", False)
    privacy = ap.get("privacy", False)
    if rsn and not wpa:
        ap["encryption"] = "WPA2/WPA3"
    elif wpa and not rsn:
        ap["encryption"] = "WPA"
    elif rsn and wpa:
        ap["encryption"] = "WPA/WPA2 mixed"
    elif privacy:
        ap["encryption"] = "WEP"
    else:
        ap["encryption"] = "OPEN"
    aps.append(ap)

for line in raw.splitlines():
    m = re.match(r"BSS\s+([0-9a-fA-F:]{17})", line)
    if m:
        finalize(current)
        current = {
            "bssid": m.group(1).lower(),
            "ssid": None,
            "channel": None,
            "freq_mhz": None,
            "signal_dbm": None,
            "privacy": False,
            "wpa": False,
            "rsn": False,
            "wps": False,
        }
        continue
    if current is None:
        continue
    s = line.strip()
    if s.startswith("SSID:"):
        current["ssid"] = s[5:].strip() or None
    elif s.startswith("freq:"):
        try: current["freq_mhz"] = int(s.split(":",1)[1].strip())
        except ValueError: pass
    elif s.startswith("signal:"):
        try:
            current["signal_dbm"] = float(s.split(":",1)[1].strip().split()[0])
        except (ValueError, IndexError): pass
    elif s.startswith("DS Parameter set: channel"):
        try: current["channel"] = int(s.rsplit(" ",1)[1])
        except ValueError: pass
    elif s.startswith("* primary channel:"):
        if current["channel"] is None:
            try: current["channel"] = int(s.rsplit(" ",1)[1])
            except ValueError: pass
    elif s.startswith("capability:") and "Privacy" in s:
        current["privacy"] = True
    elif s.startswith("WPA:"):
        current["wpa"] = True
    elif s.startswith("RSN:"):
        current["rsn"] = True
    elif s.startswith("WPS:"):
        current["wps"] = True

finalize(current)

# Sort strongest first.
aps.sort(key=lambda a: (a.get("signal_dbm") is None, -(a.get("signal_dbm") or -999)))

open_aps = [a for a in aps if a["encryption"] == "OPEN"]
wep_aps  = [a for a in aps if a["encryption"] == "WEP"]
wps_aps  = [a for a in aps if a["wps"]]

payload = {
    "available": True,
    "interface": iface,
    "scanned_at": datetime.datetime.utcnow().isoformat() + "Z",
    "ap_count": len(aps),
    "open_count": len(open_aps),
    "wep_count": len(wep_aps),
    "wps_count": len(wps_aps),
    "aps": aps,
}

with open(out_json, "w") as f:
    json.dump(payload, f, indent=2)

with open(out_txt, "w") as f:
    f.write(f"Wi-Fi passive survey on {iface}\n")
    f.write(f"Scanned at: {payload['scanned_at']}\n")
    f.write(f"Total APs: {len(aps)}   "
            f"open: {len(open_aps)}   WEP: {len(wep_aps)}   WPS: {len(wps_aps)}\n\n")
    f.write(f"{'BSSID':<18} {'CH':>3} {'SIG':>5} {'ENC':<16} {'WPS':<4} SSID\n")
    f.write("-" * 78 + "\n")
    for a in aps:
        f.write(
            f"{a['bssid']:<18} "
            f"{(a.get('channel') or '?'):>3} "
            f"{(int(a['signal_dbm']) if a.get('signal_dbm') is not None else '?'):>5} "
            f"{a['encryption']:<16} "
            f"{'yes' if a['wps'] else 'no':<4} "
            f"{a['ssid'] or '<hidden>'}\n"
        )
PY
