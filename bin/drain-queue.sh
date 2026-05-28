#!/usr/bin/env bash
# drain-queue.sh -- ship any queued offline runs to the homelab server.
#
# A queued run is a directory under /var/lib/pi-network-sniffer/queue/ created
# by a previous boot that had no network (typically a Wi-Fi survey with no
# usable connectivity). Each entry is rsynced to the homelab server with the same path
# layout as a live upload. On success the queued dir is removed; on failure
# it stays for the next boot.

set -euo pipefail
INSTALL_DIR="/opt/pi-network-sniffer"
CONFIG_FILE="${INSTALL_DIR}/etc/config.env"
QUEUE_DIR="/var/lib/pi-network-sniffer/queue"

# shellcheck disable=SC1090
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
: "${REMOTE_WG_IP:=10.8.0.9}"
: "${REMOTE_SSH_USER:=deploy}"
: "${REMOTE_UPLOADS_DIR:=pi-network-sniffer-uploads}"
: "${SSH_KEY:=/root/.ssh/id_ed25519}"

if [ ! -d "${QUEUE_DIR}" ]; then
    exit 0
fi

HOSTNAME_SLUG="$(hostname | tr -c 'A-Za-z0-9_-' '-' )"
DRAINED=0
FAILED=0

shopt -s nullglob
for run_dir in "${QUEUE_DIR}"/*/; do
    [ -d "${run_dir}" ] || continue
    TS="$(basename "${run_dir}")"
    echo "[*] Draining queued run ${TS} ..."
    if rsync -avz \
        -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
        "${run_dir}" "${REMOTE_SSH_USER}@${REMOTE_WG_IP}:${REMOTE_UPLOADS_DIR}/${HOSTNAME_SLUG}/${TS}/"; then
        rm -rf "${run_dir}"
        DRAINED=$((DRAINED + 1))
        echo "[+] Queued run ${TS} drained."
    else
        FAILED=$((FAILED + 1))
        echo "[!] Failed to drain ${TS}; leaving in queue for next boot."
    fi
done

echo "[*] Queue drain done: drained=${DRAINED} failed=${FAILED}"
