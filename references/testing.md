# Testing Reference

Per the operator's collaboration rules: **all functionality and fixes must ship with unit tests; coverage targets 80% statements / 80% branches / 90% on key modules**. Read this when implementing Stage 4.

## Why tests come before implementation

The VPN's failure modes are silent — a wrong UUID, a mis-rendered routing rule, a swapped key in a client template — none of these crash the server, they just route traffic incorrectly or leak. By the time the user notices, the bad state has been live for hours. Tests catch this *before* the first deploy.

The reference project (this skill's `vpn-builder` template) has 132 tests at ~99.7% coverage. New deployments inherit this — don't drop it. When sing-box's schema changes (it does every few months), the tests act as a regression net.

## Test catalog

### `tests/test_keygen.py` (≈12 tests)

Unit tests for key/credential generators. Verify:

- `generate_reality_keypair()`:
  - private key is 43 base64url chars (X25519 32-byte raw, no padding);
  - public key is derivable from private key (round-trip property);
  - two calls return distinct keypairs (real entropy);
  - charset is `[A-Za-z0-9_-]`.
- `generate_uuid()` returns RFC 4122 v4 (regex); 1000 calls produce 1000 unique values.
- `generate_password(n)`:
  - `n < 32` raises `ValueError` (we explicitly reject weak passwords);
  - return decodes to exactly `n` random bytes;
  - 100 calls produce 100 unique values.
- `generate_short_id(n)`:
  - `n == 0` returns empty string;
  - `n > 8` raises `ValueError`;
  - return is hex of length `2n`.

### `tests/test_routing_render.py` (≈18 tests)

The most important test file. Render `route` block and verify:

- 4 rule-sets total (cn, !cn, ads-all, geoip-cn). NO apple@cn / microsoft@cn.
- **No `@` in any rule-set URL** — defense in depth against the known sing-box 1.13 bug.
- All sources are SagerNet repos (`sing-geosite` or `sing-geoip`).
- All rule-sets use `download_detour: "direct"` (bootstrap problem prevention).
- All rule-sets use `format: "binary"` (compiled `.srs`, not source).
- 8 rules total in canonical order: sniff, hijack-dns, private, domestic-DNS, ads-block, cn, geoip-cn, !cn.
- Each rule's `outbound` field uses only allowed tags: `direct`, `block`, `proxy`. Action-typed rules don't have `outbound`.
- `final: "proxy"`.
- `auto_detect_interface: true`.
- `default_domain_resolver.server == "local"` (avoids chicken-and-egg DNS bootstrap).
- Domain match precedes IP match (geosite-cn before geoip-cn).
- Ad blocking precedes any classification rules.

### `tests/test_dns_render.py` (≈12 tests)

Render `dns` block and verify:

- 3 servers (remote-doh, domestic, local). NO `block` server (block is a rule action now).
- All servers have `type` field (1.13+ typed schema).
- `remote-doh` is `type: "https"`, server `1.1.1.1`, `detour: "proxy"`.
- `domestic` is `type: "udp"`, server `223.5.5.5`, **NO `detour` field** (direct is implicit, explicit `detour:direct` is rejected).
- `local` is `type: "local"`.
- 3 rules: ads → reject; cn-classes → domestic; non-cn → remote-doh.
- `final: "remote-doh"`.
- `independent_cache: true`.
- `strategy: "ipv4_only"`.

### `tests/test_server_config.py` (≈10 tests)

Render the server config from state and verify:

- DNS uses 1.13+ typed schema (`type: "https"`).
- Both inbounds present (vless-reality-in, hysteria2-in) on port 443.
- Reality inbound uses `xtls-rprx-vision` flow; SNI is the configured value; private key and short_id match deployment.
- Hysteria2 inbound uses salamander obfs; per-user passwords are unique across the user array.
- Hysteria2 masquerade URL = `https://<reality-sni>`.
- Revoked devices excluded from both inbounds' `users` arrays.
- Outbounds = `direct` + `block` only.

### `tests/test_client_config.py` (≈15 tests)

Render a per-device client config and verify:

- TUN inbound present with `auto_route` + `strict_route` true; **no legacy `sniff` field**.
- All 7 expected outbound tags present (selector, urltest, reality, hysteria2, direct, block — NO `dns-out`).
- `proxy` selector default = `auto`.
- `auto` urltest has `interrupt_exist_connections: false`.
- Reality outbound uses uTLS Chrome fingerprint and the deployment's public_key + short_id.
- Reality server is the deployment's domain/IP, but SNI is the **borrowed** SNI (not the user's domain).
- Hysteria2 uses `insecure: true` (self-signed cert OK).
- Hysteria2 SNI matches Reality SNI (for uniform external appearance).
- First route rule is `{"action": "sniff"}` (replaces inbound-level sniff).
- Clash API `default_mode: "rule"`.
- Two devices generated from the same state have different UUIDs and Hy2 passwords.

### `tests/test_subscription.py` (≈20 tests)

Fleet operations and state persistence:

- `init_deployment()` generates all server-level secrets (Reality keypair, obfs password) and they're distinct across two calls.
- `add_device(state, name)`:
  - creates with UUID, Hy2 password, created_at;
  - rejects duplicate active names;
  - allows re-adding a name after revocation;
  - rejects empty/whitespace names;
  - UUIDs and passwords are unique across 20 devices.
- `revoke_device(state, name)`:
  - marks revoked, sets revoked_at;
  - re-revoking is a no-op;
  - unknown name raises `KeyError`.
- `list_devices(state)` defaults to active-only; `include_revoked=True` returns all.
- `load_state` / `save_state` round-trips preserves all fields.
- `save_state` writes mode 0600 (file holds live secrets).
- `save_state` is atomic (no leftover `.tmp`).
- `save_state` creates parent dirs as needed.
- Loading invalid JSON raises `JSONDecodeError`.

### `tests/test_cli.py` (≈12 tests)

End-to-end CLI behavior (uses `tmp_path` for real filesystem):

- `init` creates `state.json` and `server/sing-box.json`.
- `init` refuses to overwrite existing state without `--force`.
- `init --force` rotates Reality keys.
- `state.json` has mode 0600.
- `add <name>` writes a client config to out-dir; updates server config to include the new user; output file is 0600.
- `revoke <name>` removes the client config file (so it can't be accidentally re-shared); regenerates server config without that user.
- `list` prints active devices by default; `list --all` includes revoked.
- `regen` is idempotent: same state → byte-identical output.

### `tests/smoke_test.sh`

Post-deploy verification script. Run from the operator workstation after `infra/push.sh`. Cross-platform (macOS + Linux). Checks (see `assets/smoke_test.sh`):

1. sing-box service is `active (running)`.
2. nftables ruleset contains both 443/tcp and 443/udp accept rules.
3. Server clock synced (`chronyc tracking` shows `Leap status: Normal`).
4. Local sing-box client connects via SOCKS proxy to gstatic.com/generate_204 (returns 204).
5. Exit IP equals server IP (catches double-NAT and provider transparent proxies).
6. CN-region domain resolves to a non-empty IP through the proxy (sanity).
7. PMTU 1380 to 8.8.8.8 succeeds (Linux uses `-M do`, macOS uses `-D`).
8. (If SSH_PORT != 22) port 22 is closed (hardening sanity).

Final exit code = number of failed checks.

#### Why the smoke test uses a MINIMAL client config

The full client config has 4 rule-sets that get downloaded from GitHub at start. When the operator's machine has a local TUN-mode proxy already running (very common during VPN deployment work), these downloads stall — the smoke test sees the local sing-box never opens its SOCKS port.

The smoke test's `make_test_client_config` jq function strips:
- All rule-sets (no GitHub downloads).
- All routing rules except `sniff` and `hijack-dns`.
- DNS split (uses just `local`).

And replaces TUN with SOCKS (no privilege/TUN device conflicts). This gives us a transient client we can spin up in 2 seconds.

For end-to-end functional testing of routing rules, install the full config in SFM/sing-box client on a separate machine and use it normally.

## Coverage targets

| Module | Target |
|---|---|
| `vpn_builder.cli` | 90% / 90% |
| `vpn_builder.fleet` | 95% / 95% |
| `vpn_builder.keygen` | 95% / 90% |
| `vpn_builder.routing` | 100% / 100% |
| `vpn_builder.dns` | 100% / 100% |
| `vpn_builder.server_config` | 100% / 100% |
| `vpn_builder.client_config` | 100% / 100% |
| `vpn_builder.state` | 95% / 95% |

CI must fail if coverage falls below `--cov-fail-under=80`. Use `pytest-cov`.

## Cross-platform portability gotchas (smoke test)

`smoke_test.sh` runs on the operator's workstation, which is macOS (BSD) or Linux (GNU). These differ:

| Tool | macOS (BSD) | Linux (GNU) | Workaround |
|---|---|---|---|
| `mktemp` suffix | No `--suffix=` flag | Yes | Use `mktemp -t prefix` then append `.json` to the path manually |
| `ping` don't-fragment | `-D` | `-M do` | Detect via `ping -D` works → BSD, else GNU |
| `ping` timeout flag | `-W` ms | `-W` sec | Use ms-scale BSD, sec-scale GNU |
| `sed -i` | Requires backup suffix `-i ''` | No suffix needed | Avoid in-place edits; render whole files |
| `grep -P` | Not by default | Default | Use POSIX grep / awk |
| `realpath` | Not in default PATH | In coreutils | Use `cd ... && pwd` |
| `xargs -d` | Not supported | Yes | Use `xargs -0` with `find -print0` |

The skill's `smoke_test.sh` handles ping and mktemp; if you add new shell utilities, test on both.

## Mocking & determinism

- **Time**: tests using token expiry / created_at use `freezegun` (`@freeze_time("2026-05-10T12:34:56Z")`).
- **Randomness**: tests that involve key generation seed the RNG only when verifying determinism; otherwise leave random for entropy uniqueness checks.
- **Network**: no test makes a real network call. The `test_singbox_config.py` validator (if present) runs `sing-box check` locally.
- **Filesystem**: use `tmp_path` (pytest fixture); never write to operator's home or `/etc`.

## What we deliberately DON'T test

- The actual GFW reachability of a deployed node — no automated way; depends on network conditions.
- The actual decoding of `.srs` rule files — that's sing-box's job; we trust it. We only verify we *referenced* rule files correctly.
- Crypto correctness of X25519 — Go's crypto library's job.
- sing-box itself — we only test our wrappers.
- Cloud provider firewall API responses — provider's job; we just print commands.
