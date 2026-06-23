# Troubleshooting — Operational Fixes

Real issues encountered and resolved in production. Documented for reference.

---

## Issue 1 — Full Tunnel VPN + Dead Server = Complete Internet Loss

### Symptom
No internet access. All DNS fails. Browser shows "no connection."

### Cause
The VPN client uses `AllowedIPs = 0.0.0.0/0, ::/0` (full tunnel). This adds catch-all routes that send **all traffic** through the VPN tunnel interface. If the VPN server is unreachable, all traffic enters the tunnel and goes nowhere.

```
Routing table (problem state):
  0/1       → tun0    ← ALL traffic goes here
  128.0/1   → tun0    ← and here (together they cover 0.0.0.0/0)
  default   → gateway ← NEVER reached — overridden by above
```

### Fix
Bring down the VPN tunnel. The catch-all routes are removed and the default gateway is restored:

```bash
# macOS
sudo wg-quick down /path/to/client.conf

# Linux
sudo wg-quick down wg0
# or
sudo systemctl stop wg-quick@wg0
```

Then investigate why the server is unreachable before reconnecting.

### Prevention
- Monitor VPN server health before routing all traffic through it
- Keep a split-tunnel fallback config for emergencies
- PersistentKeepalive (25s) detects dead tunnels quickly

---

## Issue 2 — Multiple WireGuard Tunnels: Routing Conflict

### Symptom
- VPN is "connected" (internet works)
- SSH to VPN server's internal IP times out
- DNS through VPN server fails
- `ping VPN_SERVER_INTERNAL_IP` → 100% packet loss
- `traceroute VPN_SERVER_INTERNAL_IP` → all `* * *`

### Cause
Two WireGuard tunnels are active simultaneously:
- **Tunnel A** (primary): carries all internet traffic — routes `0/1` and `128/1`
- **Tunnel B** (secondary): claims the VPN subnet `10.x.x.0/24`

Traffic to the VPN server's internal IP (`10.x.x.1`) matches Tunnel B's more-specific subnet route. Tunnel B has no valid handshake for that server — packets go in and disappear.

```
Routing table (problem state):
  0/1           → tunA   ← internet works (correct)
  128.0/1       → tunA   ← internet works (correct)
  10.x.x.0/24  → tunB   ← VPN server internal IP goes here → black hole
```

### Fix
Add a more-specific host route for the VPN server's internal IP, forcing it through the correct tunnel:

```bash
# Find the interface carrying internet traffic (tunA)
IFACE=$(route -n get 8.8.8.8 | awk '/interface:/{print $2}')

# Override the subnet route with a host route through the correct tunnel
sudo route delete -host 10.x.x.1
sudo route add -host 10.x.x.1 -interface "$IFACE"
```

After this fix:
```
Routing table (fixed state):
  10.x.x.1/32  → tunA   ← specific host route takes priority ✓
  10.x.x.0/24  → tunB   ← still there but no longer matches .1
```

### Permanent Fix
Remove or deactivate the secondary tunnel (Tunnel B). At next boot, the subnet route is gone and there is no conflict.

---

## Issue 3 — DNS Queries Failing / Leaking to Fallback

### Symptom
- Internet works
- DNS resolves (things load)
- But `dig @VPN_DNS_IP google.com` times out
- `dig google.com` shows `SERVER: 1.1.1.1` instead of VPN DNS

### Cause
The DNS server (running on the VPN exit node) is not reachable because of the routing conflict in Issue 2. Queries to the VPN DNS IP are blackholed. The OS falls back to the secondary DNS (public resolver). DNS still works, but queries are no longer encrypted inside the tunnel — they go directly to the public resolver, defeating the DoH architecture.

### Fix
Same as Issue 2 — restoring the correct route to the VPN server's IP also restores DNS reachability, since DNS is served from that same IP.

Verify after fix:
```bash
dig +short google.com @VPN_DNS_IP   # should return IPs, not time out
dig google.com | grep SERVER         # should show VPN DNS, not 1.1.1.1
```

---

## Issue 4 — nginx Serving Deprecated TLS Versions

### Symptom
Security scanner reports TLS 1.0 or TLS 1.1 supported on port 443.
Snort logs `SSLv2 Client_Hello` exploit attempts reaching the server.

### Cause
nginx's default `/etc/nginx/nginx.conf` includes:
```nginx
ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
```
Even if your virtual host config overrides this, the global default can be inherited. The directive should be removed from the global config and enforced only in server blocks.

### Fix
```bash
# Check what's in the global config
grep ssl_protocols /etc/nginx/nginx.conf

# Replace with TLS 1.2/1.3 only
sudo sed -i \
  's/ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.2 TLSv1.3;/' \
  /etc/nginx/nginx.conf

# Test and reload (zero-downtime)
sudo nginx -t && sudo systemctl reload nginx
```

### Recommended server block config
```nginx
server {
    listen 443 ssl;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=63072000" always;
}
```

---

## Issue 5 — SSH Access Lost After Firewall Rule Change

### Symptom
SSH to server times out from some networks but works from others.

### Cause
Cloud provider security groups (or host-level iptables) restrict SSH access by source IP. If connecting from a new network (different public IP), access is denied at the perimeter before the packet even reaches the server.

### Fix: Always Maintain a Tunnel-Based SSH Alias
The VPN server's **internal IP** (e.g. `10.x.x.1`) is only reachable through the encrypted tunnel — not subject to cloud firewall rules on port 22. Add a permanent SSH alias:

```
# ~/.ssh/config
Host server-tunnel
  HostName 10.x.x.1          # internal VPN IP
  User your-user
  IdentityFile ~/.ssh/your-key
  StrictHostKeyChecking accept-new
```

As long as the VPN tunnel is active, `ssh server-tunnel` always works — regardless of external firewall rules.
