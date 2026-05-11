# Deployment Reference

`infra/deploy.sh` structure, idempotency rules, nftables ruleset, and cloud-firewall guidance (provider-agnostic — see `references/cloud-providers.md` for per-provider commands). Read this when implementing Stage 4 / running Stage 5–6.

## Supported OS targets

- Ubuntu 22.04 LTS (jammy)
- Ubuntu 24.04 LTS (noble)
- Ubuntu 26.04 LTS (resolute)
- Debian 12 (bookworm)
- Debian 13 (trixie)

`deploy.sh`'s OS check should accept all of the above. Add new LTSes as they ship.

## Idempotency rules

`deploy.sh` will be run multiple times: initial install, post-edit re-runs, disaster recovery. **Every action must be safe to repeat.**

- Use `apt-get install -y` (no-op if already installed).
- Use `systemctl enable --now <unit>` (idempotent in both verbs).
- For file writes: render to a temp file, `cmp -s` against target, only `install -m ... -o ... -g ... tmp target` if changed. Avoids spurious mtime changes.
- For `nft` ruleset: `nft -f <file>` replaces atomically.
- For directory creation: `install -d -m 0750 -o root -g sing-box /etc/sing-box`.
- Never `sed -i` config files in place — render the whole file from a template every time.

## `--dry-run` semantics

`infra/deploy.sh --dry-run` MUST print every command it would execute, but execute none. Implementation pattern:

```bash
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY-RUN: '; printf '%q ' "$@"; echo
  else
    "$@"
  fi
}
```

For file writes, dry-run prints a unified diff against the current file (so the operator sees exactly what would change).

## High-level deploy.sh structure

```
infra/deploy.sh
├── parse args, set DRY_RUN
├── preflight
│   ├── require root
│   ├── verify OS ∈ {Ubuntu 22.04/24.04/26.04, Debian 12/13}
│   ├── verify server/sing-box.json exists (rsync'd before invocation)
│   └── verify infra/nftables.rules.tmpl exists
├── system packages
│   └── apt-get install -y nftables chrony curl jq ca-certificates apt-transport-https gnupg lsb-release
├── sing-box install
│   ├── Add SagerNet apt repo (per https://sing-box.sagernet.org/installation/package-manager/)
│   └── apt-get install -y sing-box  (≥1.13)
├── sysctl tunables
│   ├── BBR + fq
│   ├── IP forwarding
│   ├── TCP buffer ceilings (64 MB)
│   └── ip_local_port_range = 10000 65535
├── chrony (NTP)
│   ├── apt confirms installed
│   ├── systemctl enable --now chrony
│   └── chronyc tracking must show "Leap status: Normal" within 30 s
├── nftables (host firewall)
│   ├── render /etc/nftables.conf from template (substitute SSH_PORT)
│   ├── nft -c -f (validate)
│   ├── nft -f (apply)
│   └── systemctl enable nftables
├── sing-box config + cert
│   ├── install -d -m 0750 -o root -g sing-box /etc/sing-box
│   ├── install -d -m 0750 -o sing-box -g sing-box /var/lib/sing-box
│   ├── write_file /etc/sing-box/config.json (0640 root:sing-box)
│   ├── if cert/key missing: generate self-signed (OpenSSL 3.x compatible)
│   ├── chown sing-box:sing-box /etc/sing-box/{cert,key}.pem
│   └── sing-box check (refuse to start if config invalid)
├── service
│   └── systemctl enable --now sing-box  (must reach active within 5s)
└── post-deploy
    └── print next steps (smoke test command, client distribution)
```

## OpenSSL 3.x self-signed cert (no process substitution)

**Don't** use `openssl req -newkey ec:<(openssl ecparam ...)` — process substitution `<()` is bash-only and breaks when invoked via `sh -c`. Use the modern flag instead:

```bash
openssl req -x509 -nodes -newkey EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /etc/sing-box/key.pem \
  -out /etc/sing-box/cert.pem \
  -subj "/CN=<reality-sni>" \
  -days 36500
chown sing-box:sing-box /etc/sing-box/{cert,key}.pem
chmod 0640 /etc/sing-box/{cert,key}.pem
```

100-year validity is fine for self-signed — there's no validation, the cert is decorative.

The cert subject mirrors the Reality SNI for cosmetic consistency — clients use `tls.insecure: true` for Hysteria2; protocol-level password is the actual auth.

## nftables ruleset (canonical)

Full template: `assets/nftables.rules.tmpl`. Annotated:

```nft
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    # Established / related connections come back through.
    ct state established,related accept

    # Loopback unconditionally.
    iifname "lo" accept

    # Drop invalid early.
    ct state invalid drop

    # ICMP for diagnostics, rate-limited.
    ip protocol icmp limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept

    # SSH on the configured port (template-substituted at deploy time).
    tcp dport {{ssh_port}} ct state new accept

    # The two VPN listeners.
    tcp dport 443 ct state new accept
    udp dport 443 ct state new accept

    # Anything else dropped (counted for debugging).
    counter drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
```

Two principles:
- **Default-drop input**, accept-list only SSH + 443/tcp + 443/udp.
- **No `forward` accept** — host is not a router. sing-box terminates traffic in user space and originates new outbound flows from the host's own network namespace.

## push.sh — operator-workstation wrapper

`infra/push.sh` runs on the operator's Mac/Linux. It rsyncs the necessary files to the server and invokes deploy.sh remotely.

```bash
#!/usr/bin/env bash
# Usage: bash infra/push.sh root@host [--dry-run]
set -Eeuo pipefail

REMOTE="${1:?usage: $0 user@host [--dry-run]}"; shift || true
EXTRA=("$@")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_ROOT/server/sing-box.json" ]] || {
  echo "missing server/sing-box.json — run \`subgen init\` first" >&2; exit 2
}

# Ubuntu minimal images often lack rsync; install it first.
ssh "$REMOTE" 'command -v rsync >/dev/null || (apt-get update -qq && apt-get install -y rsync)'

rsync -avz --delete \
  --include='infra/' --include='infra/**' \
  --include='server/' --include='server/sing-box.json' \
  --exclude='*' \
  "$REPO_ROOT/" "$REMOTE:/opt/vpn-builder/"

ssh "$REMOTE" "cd /opt/vpn-builder && bash infra/deploy.sh ${EXTRA[*]:-}"
```

The rsync include/exclude is **deliberate**: we send `infra/` and `server/sing-box.json` only. We never send `clients/state.json` (operator's secret), `src/` (Python source not needed on server), `tests/`, `.venv/`, etc.

## Cloud-side firewall (separate concern)

Host firewall (nftables) is necessary but not sufficient. Most cloud providers have their own firewall layer that drops packets BEFORE they reach the host. See `references/cloud-providers.md` for per-provider commands. The deploy.sh script does NOT touch the cloud firewall — that requires the operator's auth and authority, which crosses a privilege boundary.

`infra/cloud-firewall.sh` prints commands the operator runs from their own workstation.

## Sysctl tunables

Write to `/etc/sysctl.d/99-vpn-builder.conf`:

```ini
# Managed by vpn-builder — do not hand-edit
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.ipv4.ip_local_port_range = 10000 65535
```

Apply with `sysctl --system`. Validate `tcp_congestion_control == bbr`; warn (don't die) if not — some kernels lack the `tcp_bbr` module.

## chrony (NTP — non-negotiable)

Reality fails handshake when server clock drift exceeds ~90 s. GCE has been observed to ship VMs with stale clocks; ensure chrony is enabled and synced before declaring deploy complete:

```bash
systemctl enable --now chrony
# Wait up to 30 s for sync:
for _ in 1 2 3 4 5 6; do
  sleep 5
  chronyc tracking 2>/dev/null | grep -q "Leap status\\s*:\\s*Normal" && break
done
chronyc tracking | grep -q "Leap status\\s*:\\s*Normal" \
  || warn "clock not synced after 30s — Reality may fail handshakes"
```

## File ownership recap

| Path | Mode | Owner | Why |
|---|---|---|---|
| `/etc/sing-box/` | 0750 | `root:sing-box` | Service user can traverse, others can't |
| `/etc/sing-box/config.json` | 0640 | `root:sing-box` | Service user can read |
| `/etc/sing-box/cert.pem` | 0640 | `sing-box:sing-box` | Service reads (TLS cert load) |
| `/etc/sing-box/key.pem` | 0640 | `sing-box:sing-box` | Service reads (TLS key load) |
| `/var/lib/sing-box/` | 0750 | `sing-box:sing-box` | Service writes cache.db |
| `/etc/nftables.conf` | 0644 | `root:root` | Loaded by root systemd unit |
| `/etc/sysctl.d/99-vpn-builder.conf` | 0644 | `root:root` | System-wide tunables |

## What deploy.sh deliberately does NOT do

- **Modify SSH config** (port change, key install) — manual operator step. The script *checks* SSH state but doesn't change it.
- **Create cloud-side firewall rules** — see above.
- **Ship logs off the box** — local journald suffices for ≤5-device deployments.
- **Install fail2ban automatically** — opt-in; if installed manually it doesn't conflict.
- **Manage DNS records** — operator handles A records for the server domain.
- **Auto-rotate Reality keys** — quarterly rotation is a documented operator task, not a cron job (rotations should be deliberate, with client redistribution in mind).
