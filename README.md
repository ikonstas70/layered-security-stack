# Layered Security Stack — Architecture Reference

A practical, privacy-first security architecture built around a **full-tunnel VPN exit node**, **encrypted DNS**, **network intrusion detection**, and **SIEM**. This reference documents the design decisions, flow diagrams, component roles, and operational fixes for a real-world private deployment.

> **Educational reference only.** Scripts and configs are illustrative — adapt to your environment.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLIENT MACHINE                           │
│                                                                 │
│  ┌──────────┐   ┌─────────────┐   ┌──────────┐  ┌──────────┐  │
│  │WireGuard │   │ Wazuh Agent │   │  Snort   │  │  OSSEC   │  │
│  │Full Tunnel│  │    SIEM     │   │   IDS    │  │  Agent   │  │
│  └────┬─────┘   └─────────────┘   └──────────┘  └──────────┘  │
│       │  ALL traffic (0.0.0.0/0, ::/0)                         │
└───────┼─────────────────────────────────────────────────────────┘
        │ Encrypted WireGuard tunnel (UDP)
        ▼
┌─────────────────────────────────────────────────────────────────┐
│                      VPS / EXIT NODE                            │
│                                                                 │
│  ┌──────────┐  ┌──────────────┐  ┌────────┐  ┌─────────────┐  │
│  │WireGuard │  │dnscrypt-proxy│  │ Snort  │  │  iptables   │  │
│  │  Server  │  │  DoH Server  │  │  IDS   │  │  + ipset    │  │
│  └──────────┘  └──────────────┘  └────────┘  └─────────────┘  │
│  ┌──────────┐  ┌──────────────┐  ┌────────┐                    │
│  │  nginx   │  │  fail2ban    │  │ Wazuh  │                    │
│  │  Proxy   │  │  SSH guard   │  │Manager │                    │
│  └──────────┘  └──────────────┘  └────────┘                    │
│                        │ NAT MASQUERADE                         │
└────────────────────────┼────────────────────────────────────────┘
                         ▼
                    [ INTERNET ]
```

---

## Stack Components

### VPS — Exit Node (Linux)

| Component | Role |
|-----------|------|
| **WireGuard** | Full-tunnel VPN server — all client traffic exits here |
| **dnscrypt-proxy** | DNS-over-HTTPS served to VPN clients (no DNS leaks) |
| **Snort IDS** | Packet inspection on WAN, VPN, and container interfaces |
| **iptables + ipset** | NAT masquerade, blocklist enforcement, port filtering |
| **fail2ban** | SSH brute-force protection (bans after N failures) |
| **nginx** | Reverse proxy with TLS termination (TLS 1.2/1.3 only) |
| **Wazuh Manager** | SIEM aggregation — receives agent events |
| **OSSEC** | Host-based IDS, log analysis, file integrity |

### Client Machine (macOS / Linux)

| Component | Role |
|-----------|------|
| **WireGuard** | Full-tunnel client — AllowedIPs 0.0.0.0/0 + ::/0 |
| **Wazuh Agent** | Ships logs, FIM alerts, vuln detection to Wazuh Manager |
| **OSSEC Agent** | Host IDS — monitors system files, auth logs |
| **Snort IDS** | Local interface monitoring (passive mode) |
| **Threat Feed Updater** | Daily pull from Feodo, ET, Tor exit feeds → iptables block |
| **Cloudflare Tunnel** | Exposes internal services without opening inbound ports |
| **Security Monitor** | Local HTTPS dashboard — aggregates alerts and status |

---

## Network Flow Diagrams

### Flow 1 — All Traffic Through VPN

```
CLIENT                                VPS
  │                                    │
  │  AllowedIPs = 0.0.0.0/0, ::/0     │
  │  Everything enters tunnel          │
  │                                    │
  │──── UDP encrypted ────────────────►│:51820
  │     PersistentKeepalive=25s        │
  │     IPv6 ULA (prevents ISP leak)   │
  │                                   ▼
  │                        iptables FORWARD (INSERT #1)
  │                        NAT POSTROUTING MASQUERADE
  │                                   │
  │◄──── return traffic ──────────────│
  │                                   ▼
  │                              [ INTERNET ]
  │
  └── Your public IP = VPS IP (not your ISP IP)
```

### Flow 2 — DNS (No Leaks)

```
Client app makes DNS query
  └─► OS stub resolver
        └─► VPN_SERVER_IP:53  (via encrypted tunnel)
              └─► dnscrypt-proxy
                    ├─► 1.1.1.1 over HTTPS (DoH)
                    └─► 9.9.9.9 over HTTPS (DoH)

DNS queries never leave the tunnel unencrypted.
DNS server IP only reachable inside VPN subnet.
```

### Flow 3 — Inbound Web (Cloudflare Tunnel)

```
Browser
  └─► Cloudflare Edge (TLS termination, DDoS protection)
        └─► cloudflared daemon (QUIC/H2 — outbound only, no open ports)
              └─► Security Proxy (localhost)
                    │  Blocks: SQLi, SSRF, path traversal,
                    │          scanner UAs, .env/.git access
                    └─► Backend application (localhost only)
```

### Flow 4 — Attack Detection

```
Network traffic
  └─► Snort IDS (passive tap on WAN + VPN interfaces)
        ├─► Custom rules: SSH brute force, port probes,
        │                 web shells, SQLi, path traversal
        └─► Alert log ──► Wazuh / OSSEC correlation
                              └─► Active response (auto-block)

iptables blocklists (updated daily):
  ├─► Feodo Botnet C2 IPs
  ├─► Emerging Threats compromised hosts
  └─► Tor exit nodes
```

---

## Key Design Decisions

### WireGuard — INSERT not APPEND
If Docker is running, it adds a `REJECT` rule to the `FORWARD` chain.
Using `-A APPEND` places your WireGuard `ACCEPT` rule **after** the Docker `REJECT` — traffic gets silently dropped.

```bash
# Wrong — APPEND goes after Docker's REJECT
iptables -A FORWARD -i wg0 -j ACCEPT

# Correct — INSERT at position 1, before Docker
iptables -I FORWARD 1 -i wg0 -j ACCEPT
```

### IPv6 ULA Prevents ISP Leaks
A full-tunnel without IPv6 AllowedIPs still exposes your real ISP IPv6 address. Assign a ULA prefix (`fd00::/8`) to the VPN interface and include `::/0` in AllowedIPs.

### DNS Boot-Wait
On macOS, LaunchAgents start before DNS is ready. Any service making DNS lookups at boot needs a wait loop — otherwise requests fail silently and the service starts broken.

### Multiple Tunnel Conflict Resolution
When two WireGuard tunnels are active simultaneously and both claim overlapping subnets, the later-activated tunnel wins the route — silently blackholing traffic for the earlier one. The fix: add a specific host route for the VPN server's internal IP through the correct tunnel interface. See `scripts/route-fix.sh`.

### TLS — Drop Old Versions
nginx ships with a default `ssl_protocols` directive that includes TLS 1.0 and TLS 1.1. These are deprecated and vulnerable (BEAST, POODLE). Always override:

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:...";
```

### SSH — Tunnel-Only Access
Cloud firewall rules may block port 22 from unknown source IPs. A secondary SSH alias pointing to the VPN server's **internal** IP always works when the tunnel is active — independent of external firewall rules.

---

## Snort Custom Rules (Educational)

```text
SID 9000001 — SSH Brute Force: >5 connections/60s from same source
SID 9000002 — VPN Port Probe: >10 UDP packets/5s to VPN port
SID 9000003 — Web Shell Upload: PUT + .php in same request
SID 9000004 — SQL Injection: UNION SELECT pattern
SID 9000005 — Path Traversal: ../ in request URI
SID 9000006 — .env Theft: .env in URI
SID 9000007 — Git Recon: .git in URI
SID 9000008 — CMS Recon: wp-content in URI
```

---

## Possible Technologies

This architecture is technology-agnostic. Alternatives and additions:

| Layer | This Stack | Alternatives |
|-------|-----------|--------------|
| VPN | WireGuard | OpenVPN, IPSec/IKEv2, Tailscale |
| IDS | Snort | Suricata, Zeek |
| SIEM | Wazuh | OSSEC, Elastic SIEM, Splunk |
| Host IDS | OSSEC | Tripwire, AIDE, Falco |
| DNS | dnscrypt-proxy | Pi-hole + DoH, Unbound, AdGuard Home |
| Firewall | iptables + ipset | nftables, pf (BSD/macOS), ufw |
| Brute-force | fail2ban | CrowdSec, DenyHosts |
| Proxy | nginx | Caddy, HAProxy, Traefik |
| Tunnel | Cloudflare Tunnel | ngrok, frp, SSH reverse tunnel |
| Threat Intel | Feodo + ET + Tor | AbuseIPDB, Spamhaus, AlienVault OTX |

---

## Scripts

See [`scripts/`](scripts/) for:
- `wireguard-startup.sh` — boot-time VPN bring-up with network wait
- `route-fix.sh` — multi-tunnel routing conflict resolution
- `threat-feed-updater.sh` — daily blocklist pull and iptables load
- `nginx-tls-harden.sh` — enforce TLS 1.2/1.3, remove legacy protocols
- `dns-leak-check.sh` — verify DNS resolves inside the tunnel

---

## License

MIT — Educational reference. Adapt responsibly.
