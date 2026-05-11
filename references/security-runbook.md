# Security & Operations Runbook

IP hygiene, SSH hardening, key rotation, common ops tasks, and troubleshooting. Read this when implementing the security posture in Stage 4 or supporting the user post-deploy.

## Threat model in one paragraph

Your adversary is **GFW DPI + active probing + IP-level blacklisting**, plus the standard internet background of bots scanning SSH and HTTP. You are not defending against a nation-state attacker who has compromised your client device or your cloud provider. Defenses are calibrated to keep traffic indistinguishable from ordinary HTTPS, prevent the IP from being added to a blacklist, and keep the box itself from being compromised through ordinary remote attacks.

## Network-level invariants

These are non-negotiable. Violating any of them puts the deployment at material risk.

1. **Only three sockets accept connections from the internet**: SSH (non-22 port), 443/tcp, 443/udp. Nothing else, ever. Not even temporarily for "just testing".
2. **No public admin panel**. Not wg-easy, not 3x-ui, not even with HTTPS basic auth. The presence of a panel — by URL pattern, by fingerprint, by behavior — is itself a signal to GFW. Manage via SSH, period.
3. **SSH on a non-22 port** + **key-only auth** + **fail2ban (optional)**. SSH on 22 is the single biggest source of brute-force noise on cloud VMs; moving it eliminates the noise floor and makes anomaly detection trivial.
4. **No reverse DNS hint**. Don't set rDNS to `vpn.example.com` or anything similar. Default cloud rDNS (`*.bc.googleusercontent.com`) is fine — it's noise.
5. **No certificate transparency exposure**. Don't issue a Let's Encrypt cert tied to this IP unless the deployment uses a real domain that the user owns and is willing to publish. Reality doesn't need a cert; Hysteria2 uses self-signed.

## IP hygiene

Most "VPN suddenly stopped working" reports trace back to the IP being banned, not the protocol failing. Causes:

| Cause | Mitigation |
|---|---|
| Subscription URL shared too widely (>5 users → "VPN reseller" pattern) | Strict per-device tokens, denylist on revocation, never paste the URL anywhere indexed |
| Subscription URL committed to git / pushed to cloud sync | Pre-commit hook rejecting `*.json` containing the secret prefix; out-of-band distribution only |
| IP listed in a public proxy database | Don't run other services on this IP that announce its existence (no HTTP server with a default page, no exposed Prometheus, etc.) |
| Repeat probing from the same client looking like an automated scanner | Stable client setup; don't run `nmap` against your own server from inside China |
| Cloud provider abuse complaint | Don't enable forwarding for arbitrary destinations — sing-box only proxies for authenticated users |

Best practice: **assume the IP will eventually be sniped**, and write the deploy script so spinning up a new VM and pointing all clients at the new IP takes < 30 minutes. Concretely:
- Use a domain (`vpn.example.com`) as the client-facing endpoint when possible — change one DNS record, not 5 device configs.
- Keep `infra/deploy.sh` idempotent so a fresh VM gets to the same state.
- Back up `/etc/sing-box/` (especially keys) encrypted off-box.

## SSH hardening (manual, before VPN deploy)

In `/etc/ssh/sshd_config.d/99-vpn.conf`:

```ini
Port {{ssh_port}}
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AllowUsers {{ssh_user}}
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 60
ClientAliveCountMax 3
```

After editing, validate with `sshd -t` and reload (don't restart, to avoid kicking yourself out):

```bash
sshd -t && systemctl reload ssh
```

## Key rotation

Quarterly minimum, immediately if anything looks compromised.

### Reality keypair rotation

```bash
# On server
sing-box generate reality-keypair > /tmp/new-reality-key.txt
# Then update /etc/sing-box/config.json with new private_key
# AND distribute new public_key to all clients (regenerate all subscriptions)
systemctl reload sing-box  # if supported, else restart
```

The old short_id can stay for backward compatibility during a 24h overlap, then drop.

### Hysteria2 password rotation

Same pattern: generate a new password, update server config, regenerate subscriptions, distribute, reload.

### SSH host key rotation

Less urgent (host keys are fingerprinted by clients on first use); rotate annually or after server image migration:

```bash
rm /etc/ssh/ssh_host_*
ssh-keygen -A
systemctl restart ssh
# all clients will see "host key changed" on next connect — clear known_hosts
```

## Common ops tasks

### Add a device

```bash
ssh vpn-host
cd /opt/vpn-builder/clients
python subgen.py add iphone-mom
# Outputs path to a .json and a token URL.
# Distribute the URL out-of-band.
```

### Remove a device

```bash
python subgen.py revoke iphone-mom
# UUID added to denylist; sing-box rejects new connections; existing connection drops on next reconnect.
```

### List devices

```bash
python subgen.py list
```

### Change Reality SNI

Edit `docs/spec.md` → re-run `infra/deploy.sh` → distribute new subscriptions. Plan a maintenance window of ~5 minutes.

### View live connections

```bash
journalctl -u sing-box -f --since "5 min ago"
# or, if Clash API enabled (default):
curl -s http://127.0.0.1:9090/connections | jq '.connections | length'
```

### Check sing-box health

```bash
systemctl status sing-box
sing-box check -c /etc/sing-box/config.json
```

### Update sing-box

```bash
apt-get update && apt-get install --only-upgrade sing-box
systemctl reload sing-box
# Or, if installed manually, replace binary and restart.
```

## Troubleshooting decision tree

### "Connect succeeds but no traffic flows"

1. Check sing-box logs (`journalctl -u sing-box -n 50`) for handshake errors.
2. Confirm clock sync (`chronyc tracking`) — drift > 90 s breaks Reality.
3. From server, verify outbound DNS works: `getent hosts google.com`.
4. From client, run `urltest` manually in the GUI — see actual latency.

### "Hysteria2 fast, Reality slow"

Likely a TCP path issue. Check:
- `tcp_congestion_control` is `bbr`;
- Server's `up_mbps`/`down_mbps` are realistic (not unset, not absurd);
- No middle-box rewriting MSS (test with `mtr --tcp -P 443`);
- Client `utls.fingerprint: chrome` is set.

### "Reality fast, Hysteria2 fails entirely"

Likely UDP blocking by the client's ISP. Confirm by trying a different network (mobile hotspot from a phone on a different carrier). If reproducible across networks, check:
- Server VPC firewall has a rule allowing UDP/443;
- `nft list ruleset` shows `udp dport 443 ct state new accept`;
- `ss -ulnp | grep 443` shows sing-box listening on UDP.

### "国内网站走代理变慢"

DNS misrouting. Verify:
- `dns.rules` puts `domestic` (223.5.5.5) above `remote-doh` for `geosite-cn`;
- The relevant domain actually appears in the GeoSite CN ruleset (`grep` the source dat file).
- TUN's `sniff: true` is enabled — without it, sing-box only knows the destination IP, not the SNI/host.

### "DNS leaks detected by 3rd-party leak test"

- TUN's `strict_route: true` must be set.
- TUN's `address` must include both IPv4 and IPv6 ranges if the user's network has IPv6.
- macOS specifically: ensure System Settings → Network → DNS shows the TUN's pushed DNS, not the LAN's.

### "VPN connects, then drops every few minutes"

- Check chrony again (clock drift over time).
- Check journalctl for OOM kills (e2-small has 2 GB; sing-box should use < 200 MB).
- Check `urltest` settings — `interrupt_exist_connections: false`, otherwise switching protocols closes flows.

### "Suddenly nothing works after working for weeks"

Most likely: IP banned. Test from the server: `curl -s --connect-timeout 5 https://www.gstatic.com/generate_204` succeeds (server's outbound is fine), and from a non-CN client `curl -s --connect-timeout 5 https://YOUR.SERVER.IP:443` succeeds (server's TLS port is fine), but from a CN client neither works → IP-level block from CN side. Mitigation: rotate IP. Recreate VM (or use cloud's "change external IP" feature where available), re-run deploy, re-issue subscriptions.

## Backup & recovery

Back up these files **encrypted** off-box (e.g., `age` or `gpg` symmetric to a passphrase only the operator knows):

```
/etc/sing-box/config.json
/etc/sing-box/cert.pem
/etc/sing-box/key.pem
/opt/vpn-builder/clients/  (entire directory: subscription DB, denylist, secret)
/etc/nftables.conf
/etc/ssh/sshd_config.d/99-vpn.conf
```

Recovery: provision a fresh VM matching the spec → restore the above files → run `infra/deploy.sh` to ensure system-level config is in place → restart services. Clients keep working without re-issue *if* the public IP / domain is preserved or DNS is updated.

## What to do when GFW upgrades

GFW periodically improves DPI. Symptoms of a new-generation block:
- Reality SNI handshakes that used to work now stall mid-handshake;
- Hysteria2 connections drop after exactly N seconds.

Response checklist:
1. Update sing-box to latest (server + clients) — fingerprint fixes are the first response.
2. Rotate Reality SNI (try `addons.mozilla.org` instead of `www.microsoft.com`).
3. Rotate the Reality short_id and short_id rotation strategy.
4. Watch the sing-box GitHub issues + the sing-box Telegram channel for community workarounds.
5. If the IP is under active block (drops only happen for CN clients), rotate the IP.
