# Smart Routing & DNS Reference

Daily-driver UX layer for sing-box clients. The whole reason for self-hosting (vs a commercial VPN) is to get this right: **国内网站直连、海外走代理、广告拦截、零 DNS 泄漏、用户无感**. Read this when implementing `vpn_builder.routing` / `vpn_builder.dns` or the client template.

## Critical caveat: NEVER use `@` in rule-set URLs

SagerNet's `sing-geosite` repo uses `@cn` as a sub-attribute separator: e.g. `geosite-apple@cn.srs` is Apple's CN-specific domains. **The URL is fetchable via curl, but sing-box 1.13's HTTP client (or some intermediate proxy on the operator's network) returns 404 for these URLs at runtime.** The failure surfaces only when the client tries to start the tunnel, with cryptic messages like:

```
initialize rule-set[1]: initial rule-set: geosite-apple-cn: unexpected status: 404 Not Found
```

**Action**: do not include any rule-set whose URL contains `@`. The 4 essentials below (cn, !cn, ads-all, geoip-cn) cover ~99% of the use case. Apple/Microsoft CN domains are largely covered by `geosite-cn` itself.

A test in `tests/test_routing_render.py` asserts `"@" not in url` for every rule-set; keep it.

## The 6 user-facing routing rules (canonical evaluation order)

Order matters — sing-box matches top-down, first-match-wins. Changing the order changes behavior. Two technical rules precede them: `{"action": "sniff"}` and `{"protocol": "dns", "action": "hijack-dns"}`. So `route.rules` has 8 entries total.

| # | Rule | Action | Why this position |
|---|---|---|---|
| 0 | `{"action": "sniff"}` | sniff | Identify protocol/SNI of incoming traffic so subsequent domain matches can work even when destination is only known by IP. Replaces legacy inbound `sniff: true`. |
| 1 | `{"protocol": "dns", "action": "hijack-dns"}` | hijack-dns | Send DNS queries to sing-box's DNS engine. Replaces legacy `dns-out` outbound. |
| 2 | `ip_is_private: true` | direct | LAN/VPN access (NAS, router admin, dev servers) must never be tunneled. |
| 3 | `domain: ["dns.alidns.com", "doh.pub"]` + `ip_cidr: [223.5.5.5/32, 223.6.6.6/32, 119.29.29.29/32]` | direct | Domestic DNS resolvers must be reachable directly to bootstrap split DNS. |
| 4 | `rule_set: ["geosite-category-ads-all"]` | block | Ad/tracker blocking — drop before they consume tunnel bandwidth. |
| 5 | `rule_set: ["geosite-cn"]` | direct | All Chinese domains (incl. Apple CN, Microsoft CN edges). |
| 6 | `rule_set: ["geoip-cn"]` | direct | IP-based fallback for connections without a domain. |
| 7 | `rule_set: ["geosite-geolocation-!cn"]` | proxy | Explicit non-CN domains — canonical "go through proxy". |

And `"final": "proxy"` for any traffic the rules don't classify.

### Why GeoSite before GeoIP

A foreign-owned domain might resolve to a Chinese CDN IP via Cloudflare China Network, and a Chinese site might be hosted on AWS US. Domain-based decision short-circuits this misclassification.

### What the canonical `route` section looks like

```json
{
  "route": {
    "rule_set": [
      { "tag": "geosite-cn", "type": "remote", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "direct", "update_interval": "24h" },
      { "tag": "geosite-geolocation-!cn", ... "url": "...geosite-geolocation-!cn.srs", ... },
      { "tag": "geosite-category-ads-all", ... "url": "...geosite-category-ads-all.srs", ... },
      { "tag": "geoip-cn", ... "url": "...sing-geoip/rule-set/geoip-cn.srs", ... }
    ],
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "domain": ["dns.alidns.com", "doh.pub"],
        "ip_cidr": ["223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32"],
        "outbound": "direct" },
      { "rule_set": ["geosite-category-ads-all"], "outbound": "block" },
      { "rule_set": ["geosite-cn"], "outbound": "direct" },
      { "rule_set": ["geoip-cn"], "outbound": "direct" },
      { "rule_set": ["geosite-geolocation-!cn"], "outbound": "proxy" }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "local", "strategy": "ipv4_only" }
  }
}
```

`default_domain_resolver` is mandatory since sing-box 1.12; without it, sing-box can't resolve `outbound.server` fields that are domains. `server: "local"` refers to the DNS server with tag `local` (the OS resolver), reachable without the tunnel — important to avoid a chicken-and-egg bootstrap.

## DNS split (sing-box 1.13+ typed schema)

Why bother: a single DNS server for everything either (a) gets Chinese CDN edges for foreign sites (fast but wrong target), or (b) gets DNS pollution for sensitive foreign sites.

### Strategy

| Domain class | Resolver | Transport | Detour |
|---|---|---|---|
| `geosite-cn` | Aliyun `223.5.5.5` | UDP/53 | direct (implicit; no `detour` field) |
| `geosite-geolocation-!cn` + anything else | Cloudflare DoH `1.1.1.1` | DoH over HTTPS | through `proxy` |
| `geosite-category-ads-all` | — (rejected) | — | action: reject |

### Canonical `dns` section

```json
{
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
}
```

Critical 1.13 differences vs older configs:
- **Typed servers** (`type: "https" | "udp" | "local"`), not string `address`.
- **No `detour: "direct"`** on the `domestic` server — direct is the default; explicit `detour: "direct"` is rejected as redundant.
- **No `{"outbound":"any", "server":"x"}` catch-all rule** — use `dns.final` instead. (Legacy form deprecated in 1.12, removed in 1.14.)
- **No separate `block` server** — use rule `action: "reject"`.
- **`independent_cache: true`** — domestic and remote responses do not share a cache, so a low-TTL foreign answer can't bump out a domestic record.

## Three running modes (Clash API mode toggle)

The user must be able to flip between three modes with one click:

| Mode (Clash API) | Description |
|---|---|
| `rule` | Apply route rules normally — domestic direct, foreign via proxy. |
| `global` | All non-private traffic via proxy regardless of CN/non-CN. Use to register for foreign services that geo-block. |
| `direct` | All non-private traffic direct. Pause the VPN without disconnecting the GUI. |

Enable in client config:

```json
"experimental": {
  "clash_api": {
    "external_controller": "127.0.0.1:9090",
    "default_mode": "rule"
  }
}
```

The sing-box GUI (SFM on macOS, sing-box official Android/iOS) reads this and exposes a one-tap toggle. This is much cleaner than a nested selector pattern (which can't truly bypass `route.rules`).

## urltest auto-failover (Reality ↔ Hysteria2)

```json
{
  "type": "urltest",
  "tag": "auto",
  "outbounds": ["reality", "hysteria2"],
  "url": "https://www.gstatic.com/generate_204",
  "interval": "5m",
  "tolerance": 50,
  "idle_timeout": "30m",
  "interrupt_exist_connections": false
}
```

- `tolerance: 50` ms — only switch if alternative is meaningfully faster, to avoid oscillation.
- `interrupt_exist_connections: false` — when switching, keep existing flows on the old outbound; new flows use the new one. Avoids dropping ongoing video calls.
- `idle_timeout: 30m` — re-test the slower outbound at least every 30 minutes to detect recovery.

## Rule-set update strategy

- Source: `SagerNet/sing-geosite` and `SagerNet/sing-geoip`, branch `rule-set` (`.srs` files).
- Updates: each `rule_set` entry has `update_interval: "24h"` — sing-box pulls in the background.
- `download_detour: "direct"` — bootstrap problem averted (rule updates don't depend on the proxy that rules configure).

### What we deliberately DON'T use

- `Loyalsoldier/v2ray-rules-dat` — community fork. Larger, but adds supply-chain risk. Stick to official SagerNet.
- `MetaCubeX/meta-rules-dat` — mihomo-specific. Wrong tooling.
- Any rule-set with `@` in the URL path — sing-box 1.13 doesn't fetch them reliably.

## SFM materializes profiles — important client-side note

When a user imports a profile in SFM (macOS), SFM stores it in two places:

1. `~/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt/Library/Application Support/Profiles/<id>.json` — the source of truth shown in SFM's profile management UI.
2. `~/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt/configs/config_<id>.json` — the materialized runtime config the system extension actually reads.

**The system extension reads `configs/config_<id>.json`, NOT `Profiles/<id>.json`.** If you regenerate the profile externally (via `subgen regen` and a manual file copy), you must update **both** files or the extension will keep using the stale config. See `references/client-troubleshooting.md` for the recipe.

## Common gotchas

| Symptom | Likely cause | Fix |
|---|---|---|
| 国内网站走代理变慢 | DNS resolved via DoH → got non-CN edge IP | Verify `dns.rules` orders `domestic` before non-CN; check `geosite-cn` includes the domain |
| Foreign domain resolves but connection times out | Domain matched `geosite-cn` (false positive) and tried direct | Add manual override rule above `geosite-cn` |
| LAN host (e.g., 192.168.1.10) unreachable | `ip_is_private` rule missing or below others | Ensure rule 2 is `ip_is_private: true → direct` |
| TUN starts but browsing broken | `auto_route` true, `strict_route` left default → IPv6 leaks | Set `strict_route: true`; include IPv6 inbound CIDR if user has IPv6 |
| App-specific connections leak | App hardcodes DNS | TUN with `strict_route: true` + sniff action covers most; rare cases need `process_name` rules on desktop |
| sing-box check fails with "legacy ... deprecated" | Config still uses pre-1.13 schema | See `references/architecture.md` schema migration table |
| Rule-set fetch 404 | URL contains `@` | Remove that rule-set; `geosite-cn` covers it |
