# pi-network-sniffer

Drop-box Raspberry Pi that auto-runs a LAN inventory (`netenum.sh` from
the homelab pentest suite at `the homelab server:~/scripts/pentest/`) whenever it's
powered on and connected to a network, then ships the results back to
the homelab server over WireGuard.

Hardware-agnostic: works on a Pi 2B (Ethernet only) or a Pi 3B (Ethernet
plus built-in Wi-Fi) using the same image and the same provision step.

## Layout

```
bin/                        Orchestrator scripts (run on the Pi).
  auto-pentest.sh           One-shot, fired by systemd at boot.
  wait-for-network.sh       Blocks until default route + 1.1.1.1 reach.
  decide-vantage.sh         Snapshots public IP / CIDR / gateway / MAC.
  refresh-scripts.sh        Rsyncs ~/scripts/pentest from the homelab server.
  upload-results.sh         Rsyncs run dir + ntfy summary push.

etc/
  config.env.example        Tweakables. Real config.env is gitignored.

systemd/
  pi-network-sniffer.service One-shot, runs auto-pentest.sh at boot.

provision.sh                Idempotent installer (sudo bash provision.sh).
docs/setup.md               Full operator runbook.
```

## Quick start

See `docs/setup.md` for the full runbook. Short form:

1. Homelab server: `mkdir -p ~/pi-network-sniffer-uploads`.
2. Flash Pi OS Lite (32-bit, Bookworm), set hostname, SSH key, user, Wi-Fi.
3. `git clone https://github.com/filecore/pi-network-sniffer.git && sudo bash provision.sh`.
4. Generate a wg-easy peer at `vpn-admin.yourdomain.tld`, fix AllowedIPs to
   `10.8.0.0/24`, install as `/etc/wireguard/wg0.conf`.
5. Append the Pi's `/root/.ssh/id_ed25519.pub` to `~deploy/.ssh/authorized_keys`
   on the homelab server.
6. `sudo systemctl start pi-network-sniffer.service` to test.
7. `sudo reboot` to confirm auto-run.

## Authorisation note

This image runs `netenum.sh` on any network it joins. `netenum.sh` is
intrusive (full nmap sweep, optional NSE). Do not plug this Pi into a
network you don't have authority to inventory.
