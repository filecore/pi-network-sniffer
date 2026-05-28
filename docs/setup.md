# Setup runbook

## What it does on boot

1. Passive Wi-Fi RF survey via `iw dev wlan0 scan` -- BSSIDs, SSIDs, channel,
   signal, encryption, WPS state. No association, no transmission. Skipped
   if `wlan0` doesn't exist (Pi 2B).
2. Waits up to 5 minutes for the network (eth0 or wlan0). **If it times out**,
   the Wi-Fi survey alone is queued under `/var/lib/pi-network-sniffer/queue/`
   and the orchestrator exits; the queued run is drained on the next online boot.
3. Records the vantage: public IP, local CIDR, gateway IP and MAC.
4. Drains any queued offline runs from previous boots to the homelab server.
5. Best-effort rsync of the homelab server:~/scripts/pentest into /opt/pi-network-sniffer/pentest/.
6. Runs netenum.sh --all --cidr <detected> against whatever subnet it joined.
7. rsync run dir to the homelab server:~/pi-network-sniffer-uploads/<host>/<ts>/.
8. ntfy push summary (subnet, gateway MAC, public IP, host count, severity
   counts, AP count + open/WEP/WPS-enabled).
9. Exits. Re-run by rebooting.

### Three real outcomes per boot

| Situation | What happens |
|---|---|
| Ethernet or known Wi-Fi available | Wi-Fi survey + queue drain + LAN inventory + upload + ntfy |
| Wi-Fi hardware present, no usable connectivity | Wi-Fi survey only; run lands in queue, drained on next online boot |
| No network at all (Pi 2B with no cable) | Timeout, no survey to record, clean exit. Reboot once cable is in |

## Authorisation

Runs netenum.sh on any network it joins. Do not plug into a network you don't
have authority to inventory.

The Wi-Fi survey is purely passive (receive-only `iw scan`). No association,
no transmission, no active wireless attacks. See "Active wireless attacks"
under "Out of scope" in the plan -- if you ever want deauth / handshake
capture / evil twin work, that's a separate manual-only mode, not part of
this boot orchestrator.

## First-time setup

### 0. Remote side (one-off)

```bash
ssh deploy@your-server
mkdir -p ~/pi-network-sniffer-uploads
```

Pick an ntfy topic and subscribe on phone: https://ntfy.yourdomain.tld/pi-network-sniffer

### 1. Flash

Raspberry Pi OS Lite (32-bit, Bookworm) via Imager:

- Hostname: `blackbox` (the existing flashed example -- pick anything)
- Enable SSH, paste your personal SSH key
- User: `pentest` (Pi-local user; **separate** from `deploy` on the homelab server)
- Wi-Fi SSIDs (Pi 3B only; leave blank if you want it Ethernet-only and
  still want passive Wi-Fi surveys at every boot)

The on-Pi user is unrelated to the the homelab server upload target: `provision.sh` runs
as root via `sudo`, and the rsync uploads connect to the homelab server as `${REMOTE_SSH_USER}`
(defaults to `deploy`).

### 2. Provision

```bash
ssh pentest@<pi-ip>   # find IP via your DHCP server or arp-scan
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

- Pi 2B: ARMv7, 1GB, 100Mb Ethernet only. Wi-Fi survey step is skipped (no `wlan0`).
- Pi 3B: ARMv7, 1GB, 100Mb Ethernet + 2.4GHz Wi-Fi (BCM43438). Wi-Fi survey
  runs whenever `wlan0` is present, even if the Pi is connected via Ethernet.

If repurposing the backdoor Pi 3B (currently running Uptime Kuma v1 at
192.0.2.20), migrate Uptime Kuma v1 to the spare 2B first -- out of scope
here.

### Active wireless attacks (not supported)

The onboard BCM43438 needs out-of-tree **nexmon** firmware patches to get
monitor mode / frame injection, is 2.4GHz only, and is single-radio. With
nexmon you could theoretically do deauth / handshake capture / KARMA, but:

- All are legally questionable against uncontrolled neighbours
- The right hardware for active wireless work is a USB dongle (mt7612u / rt8812au)
  with external antenna, not the onboard radio
- An always-on drop-box should never unattended-fire active attacks

If you ever want active wireless work, it should be a manual SSH-triggered
mode (`pi-network-sniffer-wireless`), not part of this boot orchestrator.

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
