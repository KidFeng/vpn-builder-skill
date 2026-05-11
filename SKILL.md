---
name: vpn-builder-skill
description: Deploy a self-hosted, GFW-resistant VPN on a cloud VPS via sing-box with VLESS+Reality (TCP/443) + Hysteria2+salamander (UDP/443) dual-stack, then generate cross-platform sing-box subscriptions for macOS/iOS/Android/Linux clients with smart Chinese-vs-international traffic splitting. Battle-tested for GCP / AWS / DigitalOcean / Vultr / bare-metal, Ubuntu 22.04+ / Debian 12+, full sing-box 1.13+ schema compliance. Trigger eagerly when the user wants to deploy, rebuild, or add a VPN / 翻墙节点 / 出墙服务, install sing-box on a server, distribute subscription configs, harden a VPN against GFW, or stand up an ADDITIONAL server — including "搭建VPN", "建一个代理", "翻墙服务器", "出墙节点", "重建VPN", "在服务器上装sing-box", "再部署一个", or symptoms like "WireGuard 用一段时间就被封" / "节点经常断". Planning-heavy 6-stage gated workflow; do NOT skip ahead to one-shot commands.
---

# VPN Builder

Build a battle-tested, GFW-resistant VPN that stays usable long-term across macOS, iOS, Android, and Linux. The protocol stack, routing rules, and security posture below are deliberate defaults baked from production experience; everything else is parameterized per deployment.

## Why a fixed methodology

VPN deployments routinely fail because someone skipped planning and ran commands first. Specific failure modes this skill is designed to prevent:

- Subscription URLs leaking to extra users → IP banned within hours.
- Picking WireGuard / OpenVPN / IKEv2 → easily fingerprinted by GFW DPI; dies within days to weeks.
- Half-configured DNS → leaks reveal the proxy *and* break domestic CDN routing (国内网站走代理变慢).
- No smoke test → the user doesn't notice a DNS leak until a sensitive query has already gone to `8.8.8.8`.
- No tests, no idempotent deploy script → cannot rebuild when the server is rotated, banned, or wiped.
- Ignoring sing-box version-specific schema changes → deploy succeeds but client fails to connect with cryptic errors.

The 6-stage workflow below exists to make all of these very hard to do.

## Known gotchas — read this first

The list below is what production experience has taught us. Skim before starting any deploy.

| # | Gotcha | Where it bites | Reference |
|---|---|---|---|
| 1 | sing-box 1.13 removed several schema fields (`dns` outbound type, inbound `sniff`, `address` string in DNS server, `outbound:any` DNS rule, DNS server `detour:direct`) | At `sing-box check` or runtime | `references/architecture.md` |
| 2 | Rule-set URLs with `@` in the path (e.g., `apple@cn.srs`) fail with 404 in sing-box's HTTP client on some networks even though direct curl returns 200 | At client connection time | `references/routing-and-dns.md` |
| 3 | `route.default_domain_resolver` is required since 1.12 | sing-box check | `references/routing-and-dns.md` |
| 4 | OpenSSL 3.x: process substitution `<()` for EC params doesn't work in `sh`; use `-pkeyopt ec_paramgen_curve:P-256` | Deploy script | `references/deployment.md` |
| 5 | Ubuntu minimal images don't ship `rsync` | First push from operator workstation | `references/deployment.md` |
| 6 | `/etc/sing-box/` must be readable by `sing-box` system user (group `sing-box`, not root) | Service won't start | `references/deployment.md` |
| 7 | GCE default service accounts have NO `compute` scope — gcloud-from-server can't add firewall rules | VPC firewall step | `references/cloud-providers.md` |
| 8 | SFM (macOS GUI) materializes profiles into `configs/config_2.json`; updating `Profiles/N.json` is NOT enough — `config_2.json` must be replaced too | Client-side runtime config doesn't update | `references/client-troubleshooting.md` |
| 9 | SFM's "Install System Extension" silently waits for user approval in System Settings → Login Items & Extensions → Network Extensions | First-time client setup | `references/client-troubleshooting.md` |
| 10 | When the operator's Mac has a TUN-mode proxy already running, rule-set HTTP downloads from a test sing-box stall — smoke test must use a minimal config without rule-sets | Smoke test hangs | `references/testing.md` |
| 11 | `ping -M do` is Linux-only; macOS BSD ping uses `-D`. `mktemp --suffix=` is GNU-only. Smoke test must be portable | Smoke test on operator's Mac | `references/testing.md` |
| 12 | iOS App Store sing-box lags upstream by 6–12 months (1.11.x while desktop is 1.13.x). The modern schema fails on iOS with `unknown field "type"` | iOS client config import | `references/client-troubleshooting.md` — use `subgen add <name> --legacy` or `subgen set-legacy <name>` |
| 13 | Legacy iOS configs hit `DNS query loopback in transport[remote-doh]` if the server endpoint domain isn't routed through the local OS resolver | iOS legacy config startup | `vpn_builder.legacy.downgrade_to_legacy` prepends a bootstrap rule mapping `[server_address, raw.githubusercontent.com] → local` |

## The mandatory 6-stage workflow

Each stage requires explicit user confirmation before advancing. Never advance silently. If the user pushes to skip a stage, restate the relevant risk concisely and let them choose — but do not jump straight to deployment, because the cost of a botched VPN (banned IP, leaked traffic) is much higher than the cost of one extra confirmation round.

### Stage 1 — Recon

Without touching the server, gather externally observable facts:

- IP geolocation (must be **outside mainland China** — confirm before continuing).
- Cloud provider, AS number (`whois`).
- Reverse DNS (`dig -x`).
- City/region (`curl -s https://ipinfo.io/<ip>/json`).

Do **not** rely on `ping` for reachability — most cloud firewalls drop ICMP, so its absence proves nothing. Do **not** rely on direct port probes (`nc`, `nmap`) if the user has a local TUN-mode proxy — every TCP port will appear "open" because the proxy intercepts the connection. Always check `env | grep -i proxy` and `scutil --proxy` (macOS) first; if a proxy is present, skip port probing and rely on the user's account of the firewall.

### Stage 2 — Open questions

Surface every decision that depends on the user. Do not invent answers. Required questions (adapt phrasing per cloud):

1. **Server location confirmed outside mainland China?** (If no: stop — there is no protocol that helps.)
2. **OS** — Ubuntu 22.04 / 24.04 / 26.04 LTS, or Debian 12 / 13. Stay on supported distros for clean nftables + sing-box support.
3. **Instance specs** (CPU, RAM, advertised egress bandwidth).
4. **SSH access**: username, port, key vs password, source IP whitelist.
5. **Cloud firewall layer**: see `references/cloud-providers.md` for per-cloud guidance. Confirm the operator can open inbound 443/tcp + 443/udp.
6. **Client device count** — ≤5: subscription URL only; >10: consider 3x-ui *over SSH tunnel only*; never expose a panel publicly.
7. **Cloud egress budget**: ask if the user wants a budget alert; their choice.
8. **Reality SNI preference** — default `www.microsoft.com` primary, `addons.mozilla.org` + `gateway.icloud.com` as backups.
9. **Subscription host** — IP + self-signed cert (simpler) vs domain (portable across server moves; recommended if the user has any domain at all).
10. **Existing deployments**: if the user already has an `vpn-builder` project from a previous server, see `references/multi-deployment.md` to add a new server alongside the existing one.

Present as a numbered list. Wait for replies. Do not proceed with assumptions.

### Stage 3 — Spec

Produce `docs/spec.md` — a one-page design that locks every decision before code is written. Required sections:

- Architecture diagram (text/ASCII is fine).
- Protocol stack with concrete parameters: ports, SNI, obfs password length, Reality keypair generation method.
- Cloud firewall delta — exact rules to add.
- Routing rules table and DNS split table (copy from `references/routing-and-dns.md`).
- Subscription scheme: file-based vs URL, token format, refresh interval, revocation mechanism.
- Test plan: unit tests, integration tests, smoke test checks.
- Risk register and rollback plan.

Show the spec to the user. Wait for explicit approval. Do not write code yet.

### Stage 4 — Engineering scaffold (tests-first)

Create the project skeleton in the user's working directory. Standard layout (see `references/multi-deployment.md` for multi-server variations):

```
infra/
  deploy.sh              # idempotent; --dry-run flag is mandatory
  nftables.rules.tmpl
  cloud-firewall.sh      # prints provider-specific commands; doesn't execute
  push.sh                # rsync + deploy on remote
  prereq-check.sh        # validates URLs / SSH / OS / NTP / VPC before deploy
server/
  sing-box.json.tmpl     # placeholder substitution from spec
clients/
  state.json             # persistent secrets (mode 0600)
  out/                   # per-device generated configs (mode 0600)
  subgen.py              # thin wrapper around vpn_builder.cli
src/vpn_builder/
  __init__.py
  state.py               # dataclasses + load/save
  keygen.py              # UUID / passwords / Reality keypair
  routing.py             # canonical routing rules + rule-sets
  dns.py                 # DNS split
  server_config.py       # build sing-box server config from state
  client_config.py       # build per-device client config from state
  fleet.py               # add / revoke / list devices
  cli.py                 # subgen entry point
tests/
  conftest.py
  test_keygen.py
  test_routing_render.py
  test_dns_render.py
  test_server_config.py
  test_client_config.py
  test_subscription.py
  test_cli.py
  smoke_test.sh
docs/
  spec.md
  install-{macos,ios,android,linux}.md
  ops-runbook.md
  troubleshooting.md
```

**Tests come before deploy code.** Per the user's collaboration rules in `~/.claude/CLAUDE.md`, no implementation merges without passing unit tests. Coverage targets: 80% statements / 80% branches overall, 90% on key generation and routing/DNS renderers.

See `references/deployment.md` for `deploy.sh` structure, `references/testing.md` for the full test catalog. Canonical config templates live in `assets/`.

### Stage 5 — SSH verification + pre-flight check

Run only inspection commands first:

```bash
ssh <user>@<host> 'set -e; uname -a; lsb_release -a 2>/dev/null || cat /etc/os-release; free -m; df -h /; ss -tulnp; ip -br addr; (nft list ruleset 2>/dev/null || iptables -S 2>/dev/null) | head -50; chronyc tracking 2>/dev/null | head -8 || timedatectl status 2>/dev/null | head -5; which sing-box || echo "sing-box NOT installed"'
```

Capture and review the output with the user. If anything unexpected appears (other services on 443, custom firewall rules already in place, non-default kernel, low disk), stop and confirm.

Then run `infra/prereq-check.sh` (see `assets/`) to validate:
- Every rule-set URL in the planned config returns 200.
- DNS for the configured server domain resolves to the expected IP.
- The local sing-box version (if installed for smoke testing) matches the server's.
- The cloud firewall has 443/tcp + 443/udp open (probe via external API if available, else ask user to confirm).

Then run `infra/deploy.sh --dry-run` from the user's machine (via `push.sh --dry-run`). The script must print every command it would execute without executing any. Show the dry-run output to the user. Wait for approval.

### Stage 6 — Deploy + smoke test

Only after dry-run is approved: run `infra/push.sh` for real, then `tests/smoke_test.sh`. The smoke test verifies (see `references/testing.md` for exact checks): service active, nftables loaded, clock synced, handshake succeeds, exit IP equals server IP, CN domain resolution direct, MTU sanity.

If any step fails, do not declare success. Diagnose using `docs/troubleshooting.md` and `references/client-troubleshooting.md`.

## Architecture defaults (locked)

| Layer | Choice | Why |
|---|---|---|
| Primary protocol | VLESS + Reality (TCP/443) | DPI-invisible — borrows real-site TLS handshake; **no domain or cert needed** |
| Acceleration | Hysteria2 + salamander obfs (UDP/443) | Brutal CC; fastest option when UDP is unblocked; obfs evades QUIC fingerprinting |
| Server runtime | sing-box (single instance, both protocols) | One config, one service, one upgrade path |
| Client runtime | sing-box official apps (4 platforms) | Free, native TUN, identical config schema |
| Routing | TUN system-wide on every platform | No per-app config drift; "set and forget" UX |
| Firewall (host) | nftables | Modern, scriptable; replaces iptables/ufw mishmash |
| NTP | chrony (mandatory) | Reality fails when system clock drift exceeds ~90s |
| Kernel | BBR + fq | Tail-latency wins for TCP-over-VPN |
| Server DNS | DoH (1.1.1.1 / 8.8.8.8) | Pollution-resistant, no plaintext upstream |
| sing-box version target | 1.13+ schema (no legacy fields) | New deployments only; old configs need migration |

Full templates: `assets/sing-box-server.json.tmpl`, `assets/sing-box-client.json.tmpl`.

## Smart routing (canonical rules + DNS split + 3 modes)

This is what makes the VPN comfortable for daily long-term use. See `references/routing-and-dns.md` for the canonical specification. Headlines:

- **8 routing rules in evaluation order** (sniff → DNS hijack → private LAN → domestic DNS IPs → ads block → CN geosite → CN geoip → non-CN geosite → proxy final).
- **DNS split**: domestic domains via 223.5.5.5 / 119.29.29.29 (direct UDP); foreign via DoH 1.1.1.1 (through tunnel). TUN takes over system DNS — no leaks possible from misbehaving apps.
- **Three modes** driven by `experimental.clash_api.default_mode` (rule / global / direct) — one tap in the GUI to switch.
- **`urltest` auto-failover** between Reality and Hysteria2; sing-box picks the lower-latency one every 5 minutes.
- **GeoSite/GeoIP rule sets** — 4 essentials only, all confirmed URL-fetchable, NO `@` in paths.

## Multi-server deployments

If the user already has a working `vpn-builder` deployment and wants another (e.g., a second region, a backup), see `references/multi-deployment.md`. Two supported patterns:

1. **One project per server** (recommended): copy the project, edit `subgen init` parameters, deploy. Each project has its own `clients/state.json` and `server/sing-box.json`.
2. **Single project, multiple states**: use `subgen --state clients/state-<name>.json ...` to manage multiple servers from one workspace.

Reuse the same skill workflow per server. Clients can hold multiple subscription configs and switch in the GUI.

## Security posture (non-negotiable)

See `references/security-runbook.md` for the full runbook. Invariants:

- Only SSH (non-standard port preferred) + 443/tcp + 443/udp open at the network level.
- **No public admin panel.** Ever.
- Subscription distribution out-of-band only.
- Quarterly Reality keypair rotation + monthly client app upgrade reminder (uTLS fingerprint must track Chrome).
- IP hygiene: never share configs outside the closed group.

## What this skill explicitly will not do

- Deploy WireGuard / OpenVPN / IKEv2 in a GFW-bypass context — they are easily fingerprinted; politely refuse and explain.
- Stand up public admin panels — security-by-obscurity is wrong here; refuse.
- Multi-tenant billing / customer portals — out of scope.
- Windows clients — sing-box has Windows support but the canonical four-platform target is macOS/iOS/Android/Linux. If asked, reuse Linux patterns.

## Reference files

- `references/architecture.md` — protocol rationale, sing-box 1.13+ schemas, server/client config skeletons, parameter glossary.
- `references/routing-and-dns.md` — the canonical routing rules, DNS split, selector pattern, rule-set update strategy, `@` URL caveat.
- `references/deployment.md` — `deploy.sh` structure, idempotency, nftables ruleset, OpenSSL 3.x cert, rsync bootstrap, file ownership.
- `references/cloud-providers.md` — per-cloud firewall guidance (GCP, AWS, DigitalOcean, Vultr, bare-metal).
- `references/platform-install.md` — step-by-step install/import/verify for macOS, Linux, Android, iOS, including the `--legacy` decision matrix.
- `references/client-troubleshooting.md` — SFM internals, System Extension approval, DB injection, `config_2.json` materialization, bootstrap-DNS loop.
- `references/multi-deployment.md` — patterns for managing multiple servers from the same workspace or separate projects.
- `references/testing.md` — unit test catalog, smoke test checks, macOS/Linux portability gotchas.
- `references/security-runbook.md` — IP hygiene, SSH hardening, key rotation, common ops.

## Templates (assets/)

- `assets/sing-box-server.json.tmpl` — server config with `{{...}}` placeholders, sing-box 1.13+ schema.
- `assets/sing-box-client.json.tmpl` — client config including canonical routing & DNS, sing-box 1.13+ schema.
- `assets/nftables.rules.tmpl` — minimal firewall ruleset.
- `assets/smoke_test.sh` — post-deploy verification script, cross-platform (macOS + Linux).
- `assets/prereq-check.sh` — pre-deploy URL/SSH/DNS validation.
