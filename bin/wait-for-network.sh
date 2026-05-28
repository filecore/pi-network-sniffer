#!/usr/bin/env bash
# wait-for-network.sh -- block until the Pi has a usable network.
#
# Polls every 5s for: a default route AND a successful reachability test
# to 1.1.1.1 over TCP/443. Caller passes max wait in seconds.
#
# Hardware-agnostic: doesn't care whether the route is via eth0 or wlan0.

set -euo pipefail
MAX="${1:-300}"
DEADLINE=$(( $(date +%s) + MAX ))

while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    if ip route show default 2>/dev/null | grep -q '^default'; then
        if curl -fsS --max-time 5 -o /dev/null https://1.1.1.1; then
            echo "[+] Network up. Default route present and 1.1.1.1 reachable."
            ip route show default | head -1
            exit 0
        fi
    fi
    sleep 5
done

echo "[ERROR] Network not ready within ${MAX}s." >&2
exit 1
