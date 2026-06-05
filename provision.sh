#!/usr/bin/env bash
# provision.sh -- idempotent installer for pi-network-sniffer.
#
# Usage:  sudo bash provision.sh
#
# Walks through every setup step: apt deps, file layout, WireGuard config
# (with automatic endpoint probing and patching), SSH key authorisation,
# and service enablement.

set -euo pipefail

_r='\033[0;31m' _g='\033[0;32m' _y='\033[1;33m' _n='\033[0m'
info() { printf "${_g}[+]${_n} %s\n" "$*"; }
warn() { printf "${_y}[!]${_n} %s\n" "$*"; }
err()  { printf "${_r}[ERROR]${_n} %s\n" "$*" >&2; }
step() { printf '\n-- %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    err "Run as root: sudo bash $0"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/pi-network-sniffer"
CONFIG_ENV="${INSTALL_DIR}/etc/config.env"

# Defaults -- overridden if config.env already exists from a previous run.
REMOTE_WG_IP="10.8.0.9"
REMOTE_SSH_USER="deploy"
REMOTE_LAN_IP="192.0.2.10"
if [ -f "${CONFIG_ENV}" ]; then
    # shellcheck disable=SC1090
    source "${CONFIG_ENV}" 2>/dev/null || true
fi

# ===========================================================================
step "1 / 7  apt dependencies"
# ===========================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
    nmap arp-scan jq python3 unzip curl git rsync nikto \
    wireguard-tools resolvconf openssh-client iproute2 iputils-ping \
    ca-certificates dnsutils iw wireless-tools
# Optional -- enrich netenum output; non-fatal if unavailable.
apt-get install -y -q nbtscan avahi-utils snmp || true

# ===========================================================================
step "2 / 7  File layout"
# ===========================================================================
mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/etc" "${INSTALL_DIR}/pentest"
mkdir -p /var/lib/pi-network-sniffer/{runs,queue} /var/log/pi-network-sniffer

cp -f "${REPO_DIR}/bin/"*.sh "${INSTALL_DIR}/bin/"
chmod +x "${INSTALL_DIR}/bin/"*.sh

if [ ! -f "${CONFIG_ENV}" ]; then
    cp -f "${REPO_DIR}/etc/config.env.example" "${CONFIG_ENV}"
    chmod 600 "${CONFIG_ENV}"
    info "config.env created at ${CONFIG_ENV} -- review before first run."
else
    info "Keeping existing ${CONFIG_ENV}."
fi

# ===========================================================================
step "3 / 7  systemd unit"
# ===========================================================================
cp -f "${REPO_DIR}/systemd/pi-network-sniffer.service" \
      /etc/systemd/system/pi-network-sniffer.service
systemctl daemon-reload
info "Unit installed."

# ===========================================================================
step "4 / 7  Root SSH key"
# ===========================================================================
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 \
               -C "pi-network-sniffer@$(hostname)"
    info "New key generated."
else
    info "Keeping existing /root/.ssh/id_ed25519."
fi
PUBKEY="$(cat /root/.ssh/id_ed25519.pub)"

# ===========================================================================
step "5 / 7  WireGuard setup"
# ===========================================================================

# Write a wg0.conf with a substituted Endpoint, bring up wg0, ping the homelab server.
# Returns 0 and leaves wg0 up on success; tears down and returns 1 on failure.
_wg_probe() {
    local host="$1" port="$2" src_conf="$3"
    local tmp
    tmp=$(mktemp /tmp/wg0-probe-XXXX.conf)
    sed "s|^Endpoint = .*|Endpoint = ${host}:${port}|" "${src_conf}" > "${tmp}"
    wg-quick down wg0 2>/dev/null || true
    install -m 600 "${tmp}" /etc/wireguard/wg0.conf
    rm -f "${tmp}"
    printf '    probing %s:%s ... ' "${host}" "${port}"
    if ! wg-quick up wg0 2>/dev/null; then
        printf 'wg-quick failed\n'
        return 1
    fi
    sleep 4
    if ping -c2 -W4 -q "${REMOTE_WG_IP}" &>/dev/null; then
        printf 'reachable\n'
        return 0
    fi
    printf 'tunnel up but the homelab server unreachable\n'
    wg-quick down wg0 2>/dev/null || true
    return 1
}

_do_wg_setup() {
    local src_conf
    src_conf=$(mktemp /tmp/wg0-work-XXXX.conf)
    # shellcheck disable=SC2064
    trap "rm -f '${src_conf}'" RETURN

    echo
    echo "Paste the wg-easy peer .conf, then press Ctrl-D on a blank line."
    echo "(Or enter the path to a downloaded .conf file and press Enter.)"
    echo
    read -r -p "> " first_line

    if [ -f "${first_line}" ]; then
        cp "${first_line}" "${src_conf}"
    else
        { printf '%s\n' "${first_line}"; cat; } > "${src_conf}"
    fi

    if ! grep -q '^\[Interface\]' "${src_conf}"; then
        err "Does not look like a WireGuard config (no [Interface] section)."
        return 1
    fi

    # Auto-fix AllowedIPs from the wg-easy default (routes all traffic through
    # the homelab server) to tunnel-only so scan traffic stays on the local LAN.
    if grep -qE 'AllowedIPs\s*=.*0\.0\.0\.0/0' "${src_conf}"; then
        sed -i -E 's|AllowedIPs\s*=\s*0\.0\.0\.0/0.*|AllowedIPs = 10.8.0.0/24|' "${src_conf}"
        info "AllowedIPs patched from 0.0.0.0/0 to 10.8.0.0/24."
    fi

    local ep_line ep_host ep_port
    ep_line=$(grep -m1 '^Endpoint\s*=' "${src_conf}" || true)
    if [ -z "${ep_line}" ]; then
        err "No Endpoint line found in config."
        return 1
    fi
    ep_host=$(printf '%s' "${ep_line}" | sed 's/.*= *//; s/:[0-9]*$//')
    ep_port=$(printf '%s' "${ep_line}" | grep -oE ':[0-9]+$' | tr -d ':')
    info "Endpoint in config: ${ep_host}:${ep_port}"

    # Candidate list: start with what the config says, then try DNS resolution,
    # then any IPs the operator supplies.
    local candidates=("${ep_host}")

    local resolved
    resolved=$(dig +short "${ep_host}" 2>/dev/null | grep -E '^[0-9.]+' | head -1 || true)
    if [ -n "${resolved}" ] && [ "${resolved}" != "${ep_host}" ]; then
        info "DNS resolved ${ep_host} -> ${resolved}."
        candidates+=("${resolved}")
    else
        warn "Could not resolve ${ep_host} via DNS -- likely no connectivity yet."
    fi

    echo
    echo "Additional IPs to try if the above fail (space-separated), or press Enter to skip:"
    local extra
    IFS= read -r extra
    for ip in ${extra}; do candidates+=("${ip}"); done

    echo
    info "Probing ${#candidates[@]} candidate(s)..."

    local winner="" c
    for c in "${candidates[@]}"; do
        if _wg_probe "${c}" "${ep_port}" "${src_conf}"; then
            winner="${c}"
            break
        fi
    done

    if [ -z "${winner}" ]; then
        warn "No candidate reached the homelab server."
        warn "wg0.conf written with the last attempt."
        warn "Fix manually: sudo nano /etc/wireguard/wg0.conf && sudo wg-quick up wg0"
        return 0
    fi

    info "Tunnel up via ${winner}:${ep_port}."
    if [ "${winner}" != "${ep_host}" ]; then
        info "Endpoint in wg0.conf updated from '${ep_host}' to '${winner}'."
    fi
}

if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    warn "wg-quick@wg0 already active -- skipping WireGuard setup."
elif [ -f /etc/wireguard/wg0.conf ]; then
    warn "wg0.conf already exists."
    read -r -p "  Redo WireGuard setup? [y/N] " _yn
    [[ "${_yn}" =~ ^[Yy]$ ]] && _do_wg_setup || true
else
    _do_wg_setup
fi

# ===========================================================================
step "6 / 7  Authorize SSH key on the homelab server"
# ===========================================================================
echo
echo "Root public key (must be in ~${REMOTE_SSH_USER}/.ssh/authorized_keys on the homelab server):"
echo "  ${PUBKEY}"
echo
read -r -p "  Attempt ssh-copy-id to the homelab server now? [y/N] " _yn
if [[ "${_yn}" =~ ^[Yy]$ ]]; then
    # Try the WireGuard IP first (if tunnel is up), then the LAN IP as fallback.
    _addrs=("${REMOTE_WG_IP}" "${REMOTE_LAN_IP}")
    _ok=0
    for _addr in "${_addrs[@]}"; do
        printf '  Trying %s@%s ...\n' "${REMOTE_SSH_USER}" "${_addr}"
        if ssh-copy-id -i /root/.ssh/id_ed25519.pub \
               -o StrictHostKeyChecking=accept-new \
               -o ConnectTimeout=5 \
               "${REMOTE_SSH_USER}@${_addr}" 2>/dev/null; then
            info "Key added via ${_addr}."
            _ok=1
            break
        fi
    done
    [ "${_ok}" -eq 0 ] && warn "ssh-copy-id failed -- add the key manually."
else
    warn "Skipped. Add the key manually before the first run:"
    warn "  echo '${PUBKEY}' >> ~${REMOTE_SSH_USER}/.ssh/authorized_keys  (on the homelab server)"
fi

# ===========================================================================
step "7 / 7  Enable services"
# ===========================================================================
systemctl enable wg-quick@wg0.service 2>/dev/null || true
systemctl enable pi-network-sniffer.service

if ! systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
    systemctl start wg-quick@wg0 2>/dev/null || \
        warn "wg-quick@wg0 failed to start -- check /etc/wireguard/wg0.conf."
fi

echo
echo "==================================================="
echo "  Provision complete."
echo "==================================================="
echo
echo "Test without rebooting:"
echo "  sudo systemctl start pi-network-sniffer.service"
echo "  sudo tail -f /var/log/pi-network-sniffer/auto.log"
echo
echo "Confirm auto-run:"
echo "  sudo reboot"
