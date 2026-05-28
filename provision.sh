#!/usr/bin/env bash
# provision.sh -- idempotent installer for pi-network-sniffer.
#
# Usage:  sudo bash provision.sh
#
# Performs:
#   - apt deps for netenum.sh + the orchestrator
#   - copies bin/ + etc/config.env.example into /opt/pi-network-sniffer/
#   - installs systemd unit and enables wg-quick@wg0 + pi-network-sniffer
#   - generates an SSH key for root if missing
#   - prints next-step instructions for the operator
#
# DOES NOT touch /etc/wireguard/wg0.conf or /etc/wpa_supplicant.conf.
# Those carry secrets and are placed by the operator after wg-easy
# generates a peer config.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root: sudo bash $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/pi-network-sniffer"

echo "[*] Installing apt dependencies ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
    nmap arp-scan jq python3 unzip curl git rsync nikto \
    wireguard-tools openssh-client iproute2 iputils-ping \
    ca-certificates dnsutils

# nbtscan / avahi-utils / snmp are optional but enrich netenum output.
apt-get install -y -q nbtscan avahi-utils snmp || true

echo "[*] Laying out ${INSTALL_DIR} ..."
mkdir -p "${INSTALL_DIR}/bin" "${INSTALL_DIR}/etc" "${INSTALL_DIR}/pentest"
mkdir -p /var/lib/pi-network-sniffer/runs /var/log/pi-network-sniffer

cp -f "${REPO_DIR}/bin/"*.sh "${INSTALL_DIR}/bin/"
chmod +x "${INSTALL_DIR}/bin/"*.sh

if [ ! -f "${INSTALL_DIR}/etc/config.env" ]; then
    cp -f "${REPO_DIR}/etc/config.env.example" "${INSTALL_DIR}/etc/config.env"
    chmod 600 "${INSTALL_DIR}/etc/config.env"
    echo "[+] Initial config.env created. Review ${INSTALL_DIR}/etc/config.env."
else
    echo "[+] Keeping existing ${INSTALL_DIR}/etc/config.env."
fi

echo "[*] Installing systemd unit ..."
cp -f "${REPO_DIR}/systemd/pi-network-sniffer.service" \
      /etc/systemd/system/pi-network-sniffer.service
systemctl daemon-reload

echo "[*] Generating root SSH key (if missing) ..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 -C "pi-network-sniffer@$(hostname)"
fi

echo "[*] Enabling services ..."
# wg-quick will fail if /etc/wireguard/wg0.conf is missing; that's fine,
# the user will drop it in next. Enable so it auto-starts once present.
systemctl enable wg-quick@wg0.service 2>/dev/null || true
systemctl enable pi-network-sniffer.service

echo
echo "==================================================="
echo "  Provision complete."
echo "==================================================="
echo
echo "Next steps (operator):"
echo
echo "  1. Generate a peer for this Pi in wg-easy"
echo "     -> https://vpn-admin.yourdomain.tld/ -> New Client"
echo
echo "  2. Edit the downloaded .conf so AllowedIPs only covers the tunnel:"
echo "     [Peer]"
echo "     AllowedIPs = 10.8.0.0/24"
echo "     (Default is 0.0.0.0/0 which would tunnel ALL scan traffic"
echo "      back through the homelab server -- not what we want.)"
echo
echo "  3. Save it on the Pi:"
echo "     sudo install -m 600 /path/to/peer.conf /etc/wireguard/wg0.conf"
echo "     sudo systemctl start wg-quick@wg0"
echo "     ping -c2 10.8.0.9   # should succeed"
echo
echo "  4. Authorise this Pi to upload to the homelab server:"
echo "     cat /root/.ssh/id_ed25519.pub"
echo "     Append that to ~deploy/.ssh/authorized_keys on the homelab server."
echo
echo "  5. Test:"
echo "     sudo systemctl start pi-network-sniffer.service"
echo "     sudo tail -f /var/log/pi-network-sniffer/auto.log"
echo
echo "  6. Reboot to confirm auto-run:"
echo "     sudo reboot"
