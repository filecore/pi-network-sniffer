#!/usr/bin/env bash
# upload-results.sh -- ship run artefacts to the homelab server + push ntfy summary.
#
# Args:
#   $1  run dir (e.g. /var/lib/pi-network-sniffer/runs/20260528T103000Z)
#   $2  timestamp slug
#   $3  netenum exit code

set -euo pipefail
RUN_DIR="${1:?run dir}"
TS="${2:?timestamp}"
NETENUM_RC="${3:-0}"

INSTALL_DIR="/opt/pi-network-sniffer"
CONFIG_FILE="${INSTALL_DIR}/etc/config.env"
# shellcheck disable=SC1090
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
: "${REMOTE_WG_IP:=10.8.0.9}"
: "${REMOTE_SSH_USER:=deploy}"
: "${REMOTE_UPLOADS_DIR:=pi-network-sniffer-uploads}"
: "${SSH_KEY:=/root/.ssh/id_ed25519}"
: "${NTFY_URL:=https://ntfy.yourdomain.tld}"
: "${NTFY_TOPIC:=pi-network-sniffer}"

HOSTNAME_SLUG="$(hostname | tr -c 'A-Za-z0-9_-' '-' )"
REMOTE_DEST="${REMOTE_SSH_USER}@${REMOTE_WG_IP}:${REMOTE_UPLOADS_DIR}/${HOSTNAME_SLUG}/${TS}/"

UPLOAD_RC=0
rsync -avz \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    "${RUN_DIR}/" "${REMOTE_DEST}" \
    || UPLOAD_RC=$?

# Parse network-table.json for severity counts. The exact schema lives in
# netenum.sh; we look for finding objects with a "severity" or "level" key
# matching HIGH/CRIT. Best-effort -- defaults to "?" if parse fails.
JSON="${RUN_DIR}/netenum/network-table.json"
HIGH="?"
CRIT="?"
HOSTS="?"
if [ -f "${JSON}" ]; then
    HIGH="$(python3 -c "
import json, sys
try:
    d=json.load(open('${JSON}'))
except Exception:
    print('?'); sys.exit()
def count(obj, key='severity', want='HIGH'):
    n=0
    if isinstance(obj, dict):
        for k,v in obj.items():
            if k.lower() in ('severity','level','sev') and isinstance(v,str) and v.upper()==want:
                n+=1
            n+=count(v,key,want)
    elif isinstance(obj, list):
        for v in obj: n+=count(v,key,want)
    return n
print(count(d,want='HIGH'))
" 2>/dev/null || echo '?')"
    CRIT="$(python3 -c "
import json, sys
try:
    d=json.load(open('${JSON}'))
except Exception:
    print('?'); sys.exit()
def count(obj, want='CRIT'):
    n=0
    if isinstance(obj, dict):
        for k,v in obj.items():
            if k.lower() in ('severity','level','sev') and isinstance(v,str) and v.upper() in (want,'CRITICAL'):
                n+=1
            n+=count(v,want)
    elif isinstance(obj, list):
        for v in obj: n+=count(v,want)
    return n
print(count(d))
" 2>/dev/null || echo '?')"
    HOSTS="$(python3 -c "
import json, sys
try:
    d=json.load(open('${JSON}'))
except Exception:
    print('?'); sys.exit()
hosts=d.get('hosts') or d.get('devices') or []
print(len(hosts) if isinstance(hosts,list) else '?')
" 2>/dev/null || echo '?')"
fi

VANTAGE_FILE="${RUN_DIR}/vantage.env"
LOCAL_CIDR="?"; GATEWAY_MAC="?"; PUBLIC_IP="?"
# shellcheck disable=SC1090
[ -f "${VANTAGE_FILE}" ] && source "${VANTAGE_FILE}"

# Wi-Fi survey counts (best-effort).
WIFI_JSON="${RUN_DIR}/wifi-scan.json"
AP_TOTAL="-"; AP_OPEN="-"; AP_WEP="-"; AP_WPS="-"
if [ -f "${WIFI_JSON}" ]; then
    AP_TOTAL="$(python3 -c "import json; d=json.load(open('${WIFI_JSON}')); print(d.get('ap_count','?') if d.get('available') else '-')" 2>/dev/null || echo '?')"
    AP_OPEN="$(python3 -c "import json; d=json.load(open('${WIFI_JSON}')); print(d.get('open_count','?') if d.get('available') else '-')" 2>/dev/null || echo '?')"
    AP_WEP="$(python3 -c "import json; d=json.load(open('${WIFI_JSON}')); print(d.get('wep_count','?') if d.get('available') else '-')" 2>/dev/null || echo '?')"
    AP_WPS="$(python3 -c "import json; d=json.load(open('${WIFI_JSON}')); print(d.get('wps_count','?') if d.get('available') else '-')" 2>/dev/null || echo '?')"
fi

MSG="$(cat <<EOF
pi-network-sniffer run on ${HOSTNAME_SLUG}
subnet: ${LOCAL_CIDR}
gateway: ${GATEWAY_IP:-?} (${GATEWAY_MAC})
public: ${PUBLIC_IP}
LAN  hosts: ${HOSTS}  high: ${HIGH}  crit: ${CRIT}
Wifi APs: ${AP_TOTAL}  open: ${AP_OPEN}  WEP: ${AP_WEP}  WPS: ${AP_WPS}
netenum exit: ${NETENUM_RC}  upload: $([ "${UPLOAD_RC}" -eq 0 ] && echo ok || echo "FAIL(${UPLOAD_RC})")
run: ${TS}
EOF
)"

curl -fsS --max-time 10 \
    -H "Title: pi-network-sniffer: ${HOSTNAME_SLUG}" \
    -H "Tags: satellite_antenna,mag" \
    -d "${MSG}" \
    "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null \
    || echo "[!] ntfy push failed (continuing)."

exit "${UPLOAD_RC}"
