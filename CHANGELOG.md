# Changelog

All notable changes to this skill are tracked here. The skill is methodology, references, and templates — versions track methodology refinements, captured gotchas, and template schema updates.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] — 2026-05-11

Initial public release. Distilled from a complete end-to-end production deployment.

### Architecture

- **VLESS + Reality** (TCP/443) primary + **Hysteria2 + salamander obfs** (UDP/443) accelerated, dual-stack on a single sing-box instance.
- **sing-box 1.13+ schema** throughout — typed DNS servers, `hijack-dns` / `sniff` rule actions, `default_domain_resolver`, no legacy `dns-out` outbound or inbound-level `sniff` field.
- **Clients**: sing-box official apps on macOS (SFM), iOS, Android, Linux.
- **Smart routing**: 8 canonical rules (private LAN → domestic DNS → ad-block → CN domains → CN IPs → non-CN domains → proxy final) + DNS split (Aliyun for CN, Cloudflare DoH for the rest) + Clash API 3-mode toggle.
- **Idempotent deploy**: `bash` + `nftables` + `chrony` + sing-box apt repo, with `--dry-run`.

### Methodology

- **6-stage gated workflow**: recon → open questions → spec → tests-first scaffold → SSH dry-run → deploy + smoke test. Each stage requires explicit user approval.
- **Tests-first scaffold**: 130+ unit tests at ~99.5 % coverage in the reference project.
- **Multi-deployment patterns**: one-project-per-server (recommended) or single-project-multiple-states.

### Documented gotchas (13 in the SKILL.md table)

Including:

- sing-box 1.13 removed multiple legacy fields (typed-DNS migration, `dns-out` outbound removal, inbound-`sniff` removal, etc.).
- Rule-set URLs containing `@` silently 404 in sing-box's HTTP client even when direct curl returns 200.
- `route.default_domain_resolver` required since sing-box 1.12.
- OpenSSL 3.x process substitution breaks under `sh -c`; use `-pkeyopt ec_paramgen_curve:P-256`.
- Ubuntu minimal images lack `rsync` — install before first rsync.
- `/etc/sing-box/` must be group-readable by `sing-box` user, not `root:root`.
- GCE default service accounts lack `compute` scope — can't manage firewall rules from the VM.
- SFM (macOS) materializes profiles into `configs/config_<id>.json`; updating `Profiles/<id>.json` alone is insufficient.
- iOS App Store sing-box lags upstream by 6–12 months — supported via the `--legacy` schema downgrade.
- Bootstrap-DNS loop in legacy configs — handled by pre-pending a DNS rule routing the server endpoint + ruleset CDN through the local OS resolver.
- macOS BSD `ping`/`mktemp` vs Linux GNU portability — smoke test detects and adapts.

### Cloud provider coverage

- Google Cloud Platform (GCE)
- AWS EC2 (Security Groups)
- DigitalOcean (Cloud Firewall)
- Vultr (Firewall Groups)
- BandwagonHost / RackNerd / generic VPS (no cloud-side firewall; host nftables only)
- Bare metal / colocation

### Out of scope

- WireGuard / OpenVPN / IKEv2 — easily fingerprinted; skill refuses.
- Public admin panels (wg-easy, 3x-ui) — fingerprintable.
- Multi-tenant billing / customer portals.

[0.1.0]: https://github.com/KidFeng/vpn-builder-skill/releases/tag/v0.1.0
