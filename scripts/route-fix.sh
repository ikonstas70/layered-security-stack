#!/bin/bash
# route-fix.sh
# Resolves routing conflicts when multiple WireGuard tunnels are active
# and a secondary tunnel steals routes belonging to the primary tunnel.
#
# Problem:
#   Two WireGuard interfaces are active. The secondary one claims a subnet
#   that overlaps the primary — e.g. 10.x.x.0/24. Traffic destined for the
#   VPN server's internal IP is routed into the wrong (secondary) tunnel
#   and silently dropped. SSH to the server stops working. DNS through the
#   VPN stops working.
#
# Fix:
#   Add a specific /32 host route for the VPN server's internal IP, forcing
#   it through the correct (primary) tunnel interface.
#
# When to run:
#   At boot, after user login, with a delay to allow GUI VPN clients to
#   activate their tunnels first. Typically 60–90 seconds after login.

set -euo pipefail

VPN_SERVER_INTERNAL_IP="10.x.x.1"   # replace with your VPN server's tunnel IP
LOG="/var/log/wireguard-startup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ── Wait for tunnels to settle ────────────────────────────────────────────────
log "route-fix: waiting 90s for all tunnels to activate..."
sleep 90

# ── Find the correct tunnel interface ────────────────────────────────────────
# The primary tunnel carries all internet traffic (0/1 + 128/1 routes).
# The interface that routes 8.8.8.8 (internet) is the primary tunnel.
IFACE=$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2}')

if [ -z "$IFACE" ]; then
    log "route-fix: ERROR — could not determine primary tunnel interface."
    exit 1
fi

log "route-fix: primary tunnel interface is $IFACE"

# ── Remove any conflicting route, add correct one ────────────────────────────
route delete -host "$VPN_SERVER_INTERNAL_IP" 2>/dev/null && \
    log "route-fix: removed conflicting route for $VPN_SERVER_INTERNAL_IP" || true

route add -host "$VPN_SERVER_INTERNAL_IP" -interface "$IFACE"
log "route-fix: $VPN_SERVER_INTERNAL_IP now routes via $IFACE ✓"

# ── Verify ────────────────────────────────────────────────────────────────────
if ping -c1 -W3 "$VPN_SERVER_INTERNAL_IP" >/dev/null 2>&1; then
    log "route-fix: VPN server reachable ✓"
else
    log "route-fix: WARNING — VPN server still not reachable after route fix."
fi
