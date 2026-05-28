# Setup runbook

## What it does on boot

1. Waits up to 5 minutes for the network (eth0 or wlan0).
2. Brings up the WireGuard tunnel.
3. Records the vantage: public IP, local CIDR, gateway IP and MAC.
4. Best-effort rsync of the homelab server:~/scripts/pentest into /opt/pi-network-sniffer/pentest/.
5. Runs netenum.sh --all --cidr <detected> against whatever subnet it joined.
6. rsync run dir to the homelab server:~/pi-network-sniffer-uploads/<host>/<ts>/.
7. ntfy push summary (subnet, gateway MAC, public IP, host count, severity counts).
8. Exits. Re-run by rebooting.

## Authorisation

Runs netenum.sh on any network it joins. Do not plug into a network you don't
have authority to inventory.

## First-time setup

### 0. Remote side (one-off)

```bash
ssh deploy@your-server
mkdir -p ~/pi-network-sniffer-uploads
```

Pick an ntfy topic and subscribe on phone: https://ntfy.yourdomain.tld/pi-network-sniffer

### 1. Flash

Raspberry Pi OS Lite (32-bit, Bookworm) via Imager:

- Hostname: e.g. network-sniffer-01
- Enable SSH, paste your personal SSH key
- User deploy + password
- Wi-Fi SSIDs (Pi 3B only)

### 2. Provision

```bash
ssh deploy@<pi-ip>
git clone https://github.com/filecore/pi-network-sniffer.git
cd pi-network-sniffer
sudo bash provision.sh
```

### 3. WireGuard peer

In wg-easy admin UI (https://vpn-admin.yourdomain.tld/) -> New Client. Download the .conf.

Edit so AllowedIPs = 10.8.0.0/24 (default is 0.0.0.0/0 which would tunnel
all scan traffic back through the homelab server).

```bash
sudo install -m 600 /path/to/peer.conf /etc/wireguard/wg0.conf
sudo systemctl start wg-quick@wg0
ping -c2 10.8.0.9
```

### 4. SSH key

```bash
sudo cat /root/.ssh/id_ed25519.pub
```

Append to ~deploy/.ssh/authorized_keys on the homelab server.

### 5. Test

```bash
sudo systemctl start pi-network-sniffer.service
sudo tail -f /var/log/pi-network-sniffer/auto.log
```

Check the homelab server:~/pi-network-sniffer-uploads/<host>/ for artefacts.
Check phone for ntfy push.

### 6. Confirm auto-run

```bash
sudo reboot
```

## Tweakables (config.env)

| Variable | Default | Notes |
|---|---|---|
| REMOTE_WG_IP | 10.8.0.9 | Remote tunnel IP |
| REMOTE_SSH_USER | deploy | Upload receiver |
| REMOTE_UPLOADS_DIR | pi-network-sniffer-uploads | Relative to user home |
| REMOTE_PENTEST_DIR | scripts/pentest | Pulled each boot |
| NTFY_URL | https://ntfy.yourdomain.tld | Existing homelab ntfy |
| NTFY_TOPIC | pi-network-sniffer | Phone topic |
| KEEP_RUNS | 10 | Local retention |
| NETWORK_WAIT_SECS | 300 | Network-up timeout |

## Hardware

- Pi 2B: ARMv7, 1GB, 100Mb Ethernet only.
- Pi 3B: ARMv7, 1GB, 100Mb Ethernet + 2.4GHz Wi-Fi.

If repurposing the backdoor Pi 3B, migrate Uptime Kuma v1 to the 2B first
(out of scope here).

## Remote-side retention

The Pi prunes local; the homelab server does not. Add a cron if you want:

```bash
find ~/pi-network-sniffer-uploads -mindepth 2 -maxdepth 2 -type d -mtime +90 -exec rm -rf {} +
```

## Out of scope (current revision)

- LAN-scan authorisation guardrails (no allowlist).
- External probe / domain enum auto-fire (manual via SSH only).
- Anti-detection / stealth.
- Email fallback when WG is unreachable.
- rsync-only forced command on the homelab server-side authorized_keys.
