#!/usr/bin/env bash
# refresh-scripts.sh -- pull latest ~/scripts/pentest from the homelab server over WG.
#
# Best-effort. Returns non-zero on failure so the caller can decide whether
# to proceed with the local copy.

set -euo pipefail
INSTALL_DIR="/opt/pi-network-sniffer"
CONFIG_FILE="${INSTALL_DIR}/etc/config.env"
PENTEST_DIR="${INSTALL_DIR}/pentest"

# shellcheck disable=SC1090
[ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}"
: "${REMOTE_WG_IP:=10.8.0.9}"
: "${REMOTE_SSH_USER:=deploy}"
: "${REMOTE_PENTEST_DIR:=scripts/pentest}"
: "${SSH_KEY:=/root/.ssh/id_ed25519}"

mkdir -p "${PENTEST_DIR}"

# StrictHostKeyChecking=accept-new tolerates the first connection without
# pinning a known_hosts ahead of time. After first run the key is stored.
rsync -az --delete \
    -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    "${REMOTE_SSH_USER}@${REMOTE_WG_IP}:${REMOTE_PENTEST_DIR}/" \
    "${PENTEST_DIR}/"

chmod +x "${PENTEST_DIR}"/*.sh 2>/dev/null || true
