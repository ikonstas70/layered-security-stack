#!/bin/bash
# threat-feed-updater.sh
# Pulls threat intelligence feeds and loads them into iptables via ipset.
# Run daily via cron or launchd. Requires root (iptables/ipset).
#
# Feeds:
#   - Feodo Botnet C2 IPs (banking trojans, Emotet, TrickBot)
#   - Emerging Threats compromised hosts
#   - Tor exit node IPs
#
# How it works:
#   1. Download each feed into a temp file
#   2. Parse IPs / CIDRs
#   3. Swap into ipset atomically (swap, not flush — zero downtime)
#   4. Log summary

set -euo pipefail

LOG="/var/log/threat-feed-updater.log"
IPSET_BLOCKLIST="threat-blocklist"
IPSET_NETBLOCKS="threat-netblocks"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# ── Feed URLs (public threat intelligence) ────────────────────────────────────
FEODO_URL="https://feodotracker.abuse.ch/downloads/ipblocklist.txt"
ET_COMPROMISED_URL="https://rules.emergingthreats.net/blockrules/compromised-ips.txt"
TOR_EXIT_URL="https://check.torproject.org/torbulkexitlist"

# ── Ensure ipsets exist ───────────────────────────────────────────────────────
ipset create "${IPSET_BLOCKLIST}_new" hash:ip maxelem 65536 2>/dev/null || \
    ipset flush "${IPSET_BLOCKLIST}_new" 2>/dev/null || true
ipset create "${IPSET_NETBLOCKS}_new" hash:net maxelem 256 2>/dev/null || \
    ipset flush "${IPSET_NETBLOCKS}_new" 2>/dev/null || true

# ── Download and parse ────────────────────────────────────────────────────────
download_ips() {
    local url="$1" outfile="$2"
    curl -sSf --max-time 30 "$url" \
        | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        > "$outfile" 2>/dev/null || true
}

download_ips "$FEODO_URL"       "$TMP_DIR/feodo.txt"
download_ips "$ET_COMPROMISED_URL" "$TMP_DIR/et.txt"
download_ips "$TOR_EXIT_URL"    "$TMP_DIR/tor.txt"

cat "$TMP_DIR/feodo.txt" "$TMP_DIR/et.txt" "$TMP_DIR/tor.txt" \
    | sort -u \
    | while read -r ip; do
        ipset add "${IPSET_BLOCKLIST}_new" "$ip" 2>/dev/null || true
    done

COUNT=$(ipset list "${IPSET_BLOCKLIST}_new" | grep -c "^[0-9]" || echo 0)
log "Loaded $COUNT IPs into ${IPSET_BLOCKLIST}_new"

# ── Atomic swap ───────────────────────────────────────────────────────────────
ipset create "$IPSET_BLOCKLIST" hash:ip maxelem 65536 2>/dev/null || true
ipset swap "${IPSET_BLOCKLIST}_new" "$IPSET_BLOCKLIST"
ipset destroy "${IPSET_BLOCKLIST}_new" 2>/dev/null || true

# ── Ensure iptables rules reference the ipsets ───────────────────────────────
if ! iptables -C INPUT -m set --match-set "$IPSET_BLOCKLIST" src -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -m set --match-set "$IPSET_BLOCKLIST" src -j DROP
    log "iptables rule added for $IPSET_BLOCKLIST"
fi

log "Threat feed update complete. Total blocked IPs: $COUNT"
