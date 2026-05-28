#!/usr/bin/env bash
# decide-vantage.sh -- snapshot the Pi's network vantage point.
#
# Writes two files to the directory whose first argument is the .txt path:
#   <out>             human-readable summary
#   <out%.txt>.env    sourceable: PUBLIC_IP / PRIMARY_IFACE / LOCAL_IP /
#                     LOCAL_CIDR / GATEWAY_IP / GATEWAY_MAC

set -euo pipefail
OUT_TXT="${1:?usage: decide-vantage.sh <vantage.txt>}"
OUT_ENV="${OUT_TXT%.txt}.env"

PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
          || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
          || echo "")"

DEFAULT_LINE="$(ip -4 route show default 2>/dev/null | head -1 || true)"
PRIMARY_IFACE="$(awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${DEFAULT_LINE}")"
GATEWAY_IP="$(awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"${DEFAULT_LINE}")"

LOCAL_CIDR=""
LOCAL_IP=""
if [ -n "${PRIMARY_IFACE}" ]; then
    LINE="$(ip -4 -o addr show dev "${PRIMARY_IFACE}" 2>/dev/null | awk '{print $4; exit}')"
    LOCAL_IP="${LINE%/*}"
    # Derive network CIDR from interface address. ipcalc may not be present.
    if [ -n "${LINE}" ]; then
        LOCAL_CIDR="$(python3 -c "
import ipaddress, sys
n = ipaddress.ip_interface('${LINE}').network
print(n.with_prefixlen)
" 2>/dev/null || true)"
    fi
fi

GATEWAY_MAC=""
if [ -n "${GATEWAY_IP}" ]; then
    # Force an ARP lookup so the table is fresh.
    ping -c1 -W1 "${GATEWAY_IP}" >/dev/null 2>&1 || true
    GATEWAY_MAC="$(ip neigh show "${GATEWAY_IP}" 2>/dev/null | awk '{print $5; exit}')"
fi

{
    echo "Vantage snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  hostname        : $(hostname)"
    echo "  public_ip       : ${PUBLIC_IP:-unknown}"
    echo "  primary_iface   : ${PRIMARY_IFACE:-?}"
    echo "  local_ip        : ${LOCAL_IP:-?}"
    echo "  local_cidr      : ${LOCAL_CIDR:-?}"
    echo "  gateway_ip      : ${GATEWAY_IP:-?}"
    echo "  gateway_mac     : ${GATEWAY_MAC:-?}"
    echo "  default_route   : ${DEFAULT_LINE:-?}"
} > "${OUT_TXT}"

{
    echo "PUBLIC_IP=${PUBLIC_IP}"
    echo "PRIMARY_IFACE=${PRIMARY_IFACE}"
    echo "LOCAL_IP=${LOCAL_IP}"
    echo "LOCAL_CIDR=${LOCAL_CIDR}"
    echo "GATEWAY_IP=${GATEWAY_IP}"
    echo "GATEWAY_MAC=${GATEWAY_MAC}"
} > "${OUT_ENV}"
