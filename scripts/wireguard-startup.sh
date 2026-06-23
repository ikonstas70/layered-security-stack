#!/bin/bash
# wireguard-startup.sh
# Brings up a WireGuard full-tunnel client at boot.
# Designed to run as a system daemon (root) — waits for network before starting.
#
# Usage: Place in /usr/local/bin/ and wire up via LaunchDaemon (macOS) or
#        systemd service (Linux). See docs/ for unit file examples.

set -euo pipefail

CONFIG="/etc/wireguard/client.conf"   # adjust to your config path
LOG="/var/log/wireguard-startup.log"
MAX_WAIT=60   # seconds to wait for network

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "WireGuard startup initiated."

# ── Wait for network ──────────────────────────────────────────────────────────
log "Waiting for network (up to ${MAX_WAIT}s)..."
elapsed=0
until ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        log "ERROR: Network not available after ${MAX_WAIT}s — aborting."
        exit 1
    fi
done
log "Network available after ${elapsed}s."

# ── Tear down existing tunnel (handles daemon restarts gracefully) ─────────────
wg-quick down "$CONFIG" 2>/dev/null && log "Existing tunnel torn down." || true

# ── Bring up tunnel ───────────────────────────────────────────────────────────
log "Bringing up tunnel from: $CONFIG"
if wg-quick up "$CONFIG" >> "$LOG" 2>&1; then
    log "Tunnel up successfully."
else
    log "ERROR: wg-quick failed. Check config and logs."
    exit 1
fi
