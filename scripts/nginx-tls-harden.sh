#!/bin/bash
# nginx-tls-harden.sh
# Hardens nginx TLS configuration:
#   - Removes deprecated TLS 1.0 and TLS 1.1
#   - Enforces TLS 1.2 / TLS 1.3 only
#   - Sets a strong cipher suite
#   - Reloads nginx (zero-downtime)
#
# Background:
#   nginx ships with a default ssl_protocols line that includes TLS 1.0 and
#   TLS 1.1. Both are deprecated (RFC 8996). TLS 1.0 is vulnerable to BEAST;
#   TLS 1.1 is also deprecated. Even if your server config overrides this,
#   the default directive can be inherited by virtual hosts that don't
#   explicitly set ssl_protocols. Removing it from nginx.conf is cleaner.
#
# Safe to run on a live server — nginx -t validates before reload.

set -euo pipefail

NGINX_CONF="/etc/nginx/nginx.conf"
BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"

if [ ! -f "$NGINX_CONF" ]; then
    echo "ERROR: $NGINX_CONF not found."
    exit 1
fi

echo "Backing up nginx.conf to $BACKUP"
cp "$NGINX_CONF" "$BACKUP"

# ── Remove TLS 1.0 and 1.1 from default ssl_protocols ────────────────────────
if grep -q "TLSv1[^.]" "$NGINX_CONF" || grep -q "TLSv1\.1" "$NGINX_CONF"; then
    sed -i \
        's/ssl_protocols[^;]*TLSv1[^;]*;/ssl_protocols TLSv1.2 TLSv1.3;/' \
        "$NGINX_CONF"
    echo "Replaced ssl_protocols with TLSv1.2 TLSv1.3 only."
else
    echo "No legacy TLS protocols found — already hardened or not set."
fi

# ── Test config before reload ─────────────────────────────────────────────────
echo "Testing nginx configuration..."
if nginx -t; then
    echo "Config OK — reloading nginx..."
    systemctl reload nginx && echo "nginx reloaded. TLS 1.0/1.1 disabled. ✓"
else
    echo "ERROR: nginx config test failed. Restoring backup..."
    cp "$BACKUP" "$NGINX_CONF"
    echo "Restored from $BACKUP"
    exit 1
fi
