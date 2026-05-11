# Architecture Reference

Protocol rationale, sing-box 1.13+ config schemas, server/client skeletons, and parameter glossary. Read this when generating `spec.md` (Stage 3) or implementing the builders (Stage 4).

## sing-box 1.13+ schema compliance — read this first

Several fields and types that were valid in sing-box 1.10/1.11 have been deprecated and removed by 1.13. New deployments **must** use the new schema or sing-box will refuse to start with `FATAL ... legacy ... is deprecated`. The skill's templates and Python builders target sing-box 1.13+; if you ever need to support an older sing-box, branch off — don't add `ENABLE_DEPRECATED_*` env-var hacks.

| Concept | Legacy (≤1.11) | Current (1.13+) |
|---|---|---|
| DNS server definition | `{"tag":"x", "address":"https://1.1.1.1/dns-query"}` (string address) | `{"type":"https", "tag":"x", "server":"1.1.1.1"}` (typed) |
| DNS server for blocking | `{"address":"rcode://success"}` | Use rule `{"action":"reject"}`; no server needed |
| Plain UDP DNS server | `{"address":"223.5.5.5"}` | `{"type":"udp", "server":"223.5.5.5"}` |
| System resolver | `{"address":"local"}` | `{"type":"local"}` |
| DNS server `detour:direct` | Allowed | **Rejected** — direct is implicit when no detour set |
| Catch-all DNS rule | `{"outbound":"any","server":"x"}` | Use `dns.final` field instead |
| Routing DNS hijack | Outbound `{"type":"dns","tag":"dns-out"}` + rule `{"protocol":"dns","outbound":"dns-out"}` | Rule `{"protocol":"dns","action":"hijack-dns"}`; no outbound needed |
| Inbound sniff | `"sniff": true` on the inbound | Route rule `{"action":"sniff"}` as first rule |
| Domain resolution for outbounds | Implicit | `route.default_domain_resolver` is **required** (or `domain_resolver` on each outbound) |

Migration doc: <https://sing-box.sagernet.org/migration/>

## Why this exact protocol stack

### Reality (primary, TCP/443)

- **What it is**: VLESS transport carried over a TLS handshake that proxies the *real* TLS handshake of a third-party large website (the SNI target). DPI sees a valid TLS handshake whose certificate, ALPN, and timing are produced by the legitimate target server.
- **Why it survives GFW DPI**: there is no synthetic TLS fingerprint to match. Active probing returns the real target's content (Reality forwards probes upstream). No `JA3`/`JA4` mismatch, no "looks random" entropy spike, no Trojan/Shadowsocks signature.
- **Why no domain or cert needed**: the SNI target supplies both. You only own the keypair used for client authentication after the handshake completes.

### Hysteria2 + salamander obfs (acceleration, UDP/443)

- **What it is**: a custom QUIC variant with built-in obfuscation. The salamander obfs prepends a keyed pseudo-random prefix to each packet so the protocol header is not a static signature.
- **Why it accelerates**: Brutal congestion control allows aggressive bandwidth utilization even under 5–10% loss — the typical symptom of a saturated cross-border link in evening peak. Plain TCP collapses; Hysteria2 doesn't.
- **Why it's secondary, not sole**: parts of mainland China heavily QoS or block long-lived UDP flows on residential and mobile ISPs. Reality on TCP/443 is the reliable floor; Hysteria2 on UDP/443 is the speed ceiling.

### Why dual-stack on the same port

- 443/tcp and 443/udp are different sockets — a single sing-box instance can listen on both.
- Externally, the IP looks like "an HTTPS server with QUIC support" — extremely common.
- Failover is implemented client-side via sing-box's `urltest` group; users never notice the switch.

### Why not the alternatives

| Protocol | Why rejected |
|---|---|
| WireGuard | UDP first packet has fixed magic `01 00 00 00`; packet sizes regular; identifiable in seconds. Blocked or throttled in practice. |
| OpenVPN (incl. obfsproxy) | Handshake opcodes well-known since 2012; obfsproxy variants identified. DOA. |
| IPsec/IKEv2 | UDP/500 dropped by GFW; IKE header signature trivial. DOA. |
| Trojan (naive) | Detectable via TLS fingerprint when client lacks uTLS; without a real fallback site, active probing exposes it. Reality is strictly better with less setup. |
| VLESS+WS+TLS+CDN | Works but adds 50–150 ms via CDN; defeats the point of a low-latency Tokyo/Singapore box. |
| ShadowTLS / NaïveProxy / AnyTLS | Viable but smaller ecosystem; Reality has the most clients and the most proven track record. |

## Server config skeleton (1.13+ schema)

Full template: `assets/sing-box-server.json.tmpl`. Key sections:

### Top-level DNS (server-side resolution for outbound traffic)

```json
"dns": {
  "servers": [
    { "type": "https", "tag": "doh", "server": "1.1.1.1" }
  ],
  "strategy": "ipv4_only"
}
```

The server resolves proxied destinations via DoH. No legacy `address` string; use the typed `type: "https"` form.

### Inbound: VLESS+Reality

```json
{
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "::",
  "listen_port": 443,
  "users": [{ "name": "<device>", "uuid": "<v4-uuid>", "flow": "xtls-rprx-vision" }],
  "tls": {
    "enabled": true,
    "server_name": "<reality-sni>",
    "reality": {
      "enabled": true,
      "handshake": { "server": "<reality-sni>", "server_port": 443 },
      "private_key": "<base64url-x25519-priv>",
      "short_id": ["<hex>"]
    }
  }
}
```

Parameters:
- `vless_uuid`: random v4 UUID, generated per-device for accounting.
- `reality_sni`: e.g. `www.microsoft.com`. Must be a real, TLS 1.3, externally-hosted site that is NOT DNS-poisoned in China.
- `reality_private_key`: 32-byte X25519 private key, base64url-no-padding. Generate via `sing-box generate reality-keypair` or the Python builder.
- `reality_short_id`: 0–8 byte hex; 4 bytes (8 hex) is a good default.
- `flow: xtls-rprx-vision`: required for Reality + Vision.

### Inbound: Hysteria2

```json
{
  "type": "hysteria2",
  "tag": "hysteria2-in",
  "listen": "::",
  "listen_port": 443,
  "users": [{ "name": "<device>", "password": "<base64-32B>" }],
  "obfs": { "type": "salamander", "password": "<base64-32B>" },
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "/etc/sing-box/cert.pem",
    "key_path": "/etc/sing-box/key.pem"
  },
  "masquerade": "https://<reality-sni>",
  "up_mbps": 100,
  "down_mbps": 100
}
```

- The cert is self-signed (client uses `tls.insecure: true`). Auth is via the password; TLS is decorative.
- `masquerade` URL ensures non-Hysteria2 probes are redirected to a legitimate site.

### Outbounds

```json
"outbounds": [
  { "type": "direct", "tag": "direct" },
  { "type": "block", "tag": "block" }
]
```

Server is the egress; no proxy outbound.

### Service user / file ownership

The sing-box deb package creates a `sing-box` system user. The service runs as that user. Therefore:

- `/etc/sing-box/` must be readable by group `sing-box` (mode `0750`, owner `root:sing-box`).
- `/etc/sing-box/config.json` must be readable by group `sing-box` (mode `0640`, owner `root:sing-box`).
- `/etc/sing-box/cert.pem` / `key.pem` must be readable by user `sing-box` (mode `0640`, owner `sing-box:sing-box`).
- `/var/lib/sing-box/` must be writable by `sing-box` (the cache.db lives here).

Deploy script (`assets/`) handles this with `install -d -m 0750 -o root -g sing-box ...`.

## Client config skeleton (1.13+ schema)

Full template: `assets/sing-box-client.json.tmpl`. Structurally novel parts:

### DNS (typed servers + reject action for ads)

```json
"dns": {
  "servers": [
    { "type": "https", "tag": "remote-doh", "server": "1.1.1.1", "detour": "proxy" },
    { "type": "udp", "tag": "domestic", "server": "223.5.5.5" },
    { "type": "local", "tag": "local" }
  ],
  "rules": [
    { "rule_set": ["geosite-category-ads-all"], "action": "reject" },
    { "rule_set": ["geosite-cn"], "action": "route", "server": "domestic" },
    { "rule_set": ["geosite-geolocation-!cn"], "action": "route", "server": "remote-doh" }
  ],
  "final": "remote-doh",
  "strategy": "ipv4_only",
  "independent_cache": true
}
```

Notes:
- The `domestic` server has **no** `detour` field — direct is the implicit default in 1.13, and an explicit `detour: "direct"` is rejected as redundant.
- Ad blocking is done via `action: reject` in a rule, not a separate `block` server.
- The catch-all is `dns.final`; no `{"outbound":"any"}` rule.

### Inbound: TUN

```json
"inbounds": [
  {
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "sb-tun0",
    "address": ["172.18.0.1/30", "fdfe:dcba:9876::1/126"],
    "auto_route": true,
    "strict_route": true,
    "stack": "system",
    "endpoint_independent_nat": true
  }
]
```

Note: **no `sniff: true`** on the inbound. Sniffing is now a route rule: `{"action":"sniff"}` as the first entry in `route.rules`.

### Outbounds (Reality, Hysteria2, selectors, urltest)

```json
"outbounds": [
  { "type": "selector", "tag": "proxy",
    "outbounds": ["auto", "reality", "hysteria2"], "default": "auto" },
  { "type": "urltest", "tag": "auto",
    "outbounds": ["reality", "hysteria2"],
    "url": "https://www.gstatic.com/generate_204",
    "interval": "5m", "tolerance": 50,
    "interrupt_exist_connections": false },
  { "type": "vless", "tag": "reality",
    "server": "<server-domain>", "server_port": 443,
    "uuid": "<v4-uuid>", "flow": "xtls-rprx-vision",
    "tls": { "enabled": true,
             "server_name": "<reality-sni>",
             "utls": { "enabled": true, "fingerprint": "chrome" },
             "reality": { "enabled": true,
                          "public_key": "<base64url-x25519-pub>",
                          "short_id": "<hex>" } } },
  { "type": "hysteria2", "tag": "hysteria2",
    "server": "<server-domain>", "server_port": 443,
    "password": "<base64-32B>",
    "obfs": { "type": "salamander", "password": "<base64-32B>" },
    "tls": { "enabled": true,
             "server_name": "<reality-sni>",
             "insecure": true,
             "alpn": ["h3"] },
    "up_mbps": 50, "down_mbps": 100 },
  { "type": "direct", "tag": "direct" },
  { "type": "block", "tag": "block" }
]
```

Crucial: **no `dns-out` outbound** (the `dns` outbound type was removed in 1.13). DNS hijacking is a route action.

### Route block (1.13+)

```json
"route": {
  "rule_set": [...4 rule-sets, see routing-and-dns.md...],
  "rules": [
    { "action": "sniff" },
    { "protocol": "dns", "action": "hijack-dns" },
    ...the 6 user-facing rules...
  ],
  "final": "proxy",
  "auto_detect_interface": true,
  "default_domain_resolver": { "server": "local", "strategy": "ipv4_only" }
}
```

`default_domain_resolver` is required since 1.12 — without it, sing-box can't resolve domains in `outbound.server` fields.

### Three-mode toggle via Clash API

```json
"experimental": {
  "cache_file": { "enabled": true, "path": "cache.db" },
  "clash_api": {
    "external_controller": "127.0.0.1:9090",
    "default_mode": "rule"
  }
}
```

The GUI exposes `rule` / `global` / `direct` as the user-visible mode toggle. Implementing the toggle via Clash API is much cleaner than nested selector groups (which can't truly bypass `route.rules`).

## Reality SNI selection criteria

The Reality SNI is **borrowed** from a real third-party site. Constraints:

1. **TLS 1.3 only** — Reality requires TLS 1.3 handshake.
2. **Not DNS-poisoned in China** — clients must be able to look up the SNI.
3. **Stable certificate** — sites behind CDNs that vary certs by geography (Cloudflare, Akamai) are risky. Microsoft's domains are good; `addons.mozilla.org` is good; `gateway.icloud.com` is good.
4. **High enough traffic** — connections to obscure domains may themselves be suspicious. Big-site SNIs blend in.
5. **Not your own domain** — the whole point is that the SNI is third-party. Using your own domain defeats Reality's design.

Avoid:
- `*.cloudflare.com`, `*.cdn.cloudflare.net` — cert varies by geography.
- `www.google.com`, `*.googleapis.com` — DNS-poisoned in China.
- Github/Discord etc. — known proxy-fronting targets, may attract attention.

## Parameter glossary

| Placeholder | Format | Generator |
|---|---|---|
| `{{vless_uuid}}` | RFC 4122 v4 | `uuid.uuid4()` / `sing-box generate uuid` |
| `{{reality_private_key}}` | 32-byte X25519, base64url-no-pad (43 chars) | `vpn_builder.keygen.generate_reality_keypair()` |
| `{{reality_public_key}}` | derived from private key | same |
| `{{reality_short_id}}` | hex, even length, 2–16 chars | `secrets.token_hex(4)` |
| `{{reality_sni}}` | FQDN | configured in spec |
| `{{hysteria2_password}}` | ≥32 random bytes, base64 | `secrets.token_bytes(32)` → b64 |
| `{{hysteria2_obfs_password}}` | ≥32 random bytes, base64 | same |
| `{{server_address}}` | IPv4 or FQDN | from spec |
| `{{up_mbps}}` / `{{down_mbps}}` | integer | from instance specs |
