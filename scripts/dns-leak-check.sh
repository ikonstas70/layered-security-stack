#!/bin/bash
# dns-leak-check.sh
# Verifies that DNS queries are resolving inside the VPN tunnel
# and not leaking to your ISP's resolver.
#
# Checks:
#   1. VPN DNS server is reachable and responding
#   2. Public DNS (fallback) is NOT being used for primary resolution
#   3. Your visible public IP matches the VPN exit node IP

set -euo pipefail

VPN_DNS="10.x.x.1"          # your VPN server's internal IP (DNS port 53)
EXPECTED_EXIT_IP=""           # fill in your VPN exit node's public IP to verify

PASS=0; FAIL=0

check() {
    local label="$1" result="$2"
    if [ "$result" = "ok" ]; then
        echo "  ✓ $label"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label — $result"
        FAIL=$((FAIL+1))
    fi
}

echo "── DNS Leak Check ──────────────────────────────────────"

# ── 1. VPN DNS reachable ──────────────────────────────────────────────────────
if dig +short +timeout=5 google.com @"$VPN_DNS" >/dev/null 2>&1; then
    check "VPN DNS ($VPN_DNS) is reachable and resolving" "ok"
else
    check "VPN DNS ($VPN_DNS)" "not reachable — DNS may be leaking to fallback"
fi

# ── 2. Check which resolver is actually answering ────────────────────────────
ANSWERING_SERVER=$(dig +short google.com 2>/dev/null | head -1 || echo "")
RESOLVER=$(dig google.com 2>/dev/null | awk '/SERVER:/{print $2}' | head -1)

if echo "$RESOLVER" | grep -q "$VPN_DNS"; then
    check "Queries routed through VPN DNS ($RESOLVER)" "ok"
else
    check "Primary resolver" "WARNING: using $RESOLVER instead of $VPN_DNS — possible DNS leak"
fi

# ── 3. Public IP check ───────────────────────────────────────────────────────
ACTUAL_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unavailable")
if [ -n "$EXPECTED_EXIT_IP" ]; then
    if [ "$ACTUAL_IP" = "$EXPECTED_EXIT_IP" ]; then
        check "Public IP matches VPN exit node ($ACTUAL_IP)" "ok"
    else
        check "Public IP" "MISMATCH — got $ACTUAL_IP, expected $EXPECTED_EXIT_IP (possible VPN leak)"
    fi
else
    echo "  ℹ Public IP: $ACTUAL_IP (set EXPECTED_EXIT_IP to verify)"
fi

# ── 4. IPv6 leak check ───────────────────────────────────────────────────────
IPV6=$(curl -s --max-time 5 -6 https://api6.ipify.org 2>/dev/null || echo "no-ipv6")
if [ "$IPV6" = "no-ipv6" ] || echo "$IPV6" | grep -q "^fd"; then
    check "IPv6 — no ISP leak (ULA or no IPv6 response)" "ok"
else
    check "IPv6" "WARNING: real IPv6 address ($IPV6) visible — may leak ISP identity"
fi

echo "────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL issues"
[ "$FAIL" -eq 0 ] && echo "  Status: CLEAN — no leaks detected." || echo "  Status: REVIEW NEEDED"
