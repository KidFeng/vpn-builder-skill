# Multi-Deployment Patterns

When the operator already has one working vpn-builder deployment and wants more (a second region, a backup, a per-team server), they have two clean options. Both are supported by the skill.

## Pattern A — one project per server (recommended)

The simplest and safest model: each server gets its own project directory, its own `clients/state.json`, its own subscription files. Treat each as an independent deploy with its own lifecycle.

```
~/project_spaces/
├── vpn-primary-tokyo/         # first deployment: 203.0.113.10 / tokyo.example.com
│   ├── clients/state.json   # keys for THIS server
│   ├── clients/out/         # device configs that point at tokyo.example.com
│   ├── server/sing-box.json
│   └── ...
└── vpn-backup-singapore/       # second deployment, completely separate
    ├── clients/state.json
    ├── clients/out/
    ├── server/sing-box.json
    └── ...
```

### Setup steps for a new server

1. **Copy the template project** (don't deploy from the original — that has live state):

   ```bash
   cp -R ~/project_spaces/vpn-primary-tokyo ~/project_spaces/vpn-<name>-<region>
   cd ~/project_spaces/vpn-<name>-<region>
   ```

2. **Wipe the existing state** (you want fresh keys for the new server):

   ```bash
   rm -f clients/state.json
   rm -rf clients/out
   rm -f server/sing-box.json
   ```

3. **Update `docs/spec.md`** with the new server's details (host, IP, SNI, region, etc.).

4. **Re-init**:

   ```bash
   source .venv/bin/activate
   subgen init \
     --server-address <new-domain-or-ip> \
     --server-ip <new-public-ip> \
     --reality-sni www.microsoft.com
   subgen add <first-device-name>
   ```

5. **Add cloud firewall rules** for the new VPC (see `references/cloud-providers.md`).

6. **Deploy**:

   ```bash
   bash infra/push.sh root@<new-host> --dry-run   # review
   bash infra/push.sh root@<new-host>              # real
   bash tests/smoke_test.sh                        # verify
   ```

### Pros and cons

| Pros | Cons |
|---|---|
| Complete isolation — bug in one project can't taint others | Project tree duplication (mostly fine — code is small) |
| Each project has its own git history if you want | Operator must remember which directory maps to which server |
| Compromised state.json affects only one server | More moving parts at the filesystem level |
| Trivial to retire a server (delete the directory) | |

### Naming convention

Use `vpn-<friendlyname>-<region>` so directories sort sensibly: `vpn-primary-tokyo`, `vpn-backup-singapore`, `vpn-eu-frankfurt`. The skill doesn't enforce this; just stay consistent.

## Pattern B — single project, multiple state files

Useful if you want one workspace, one git repo, and many servers managed together. Each server has its own state file:

```
vpn-builder/
├── clients/
│   ├── state-tokyo.json       # primary
│   ├── state-singapore.json   # backup
│   ├── out-tokyo/<device>.json
│   ├── out-singapore/<device>.json
├── server-tokyo/sing-box.json
├── server-singapore/sing-box.json
└── ...
```

`subgen` supports targeting any state file via `--state`:

```bash
# Init the singapore deployment, keeping the tokyo one untouched
subgen \
  --state clients/state-singapore.json \
  --out-dir clients/out-singapore \
  --server-out server-singapore/sing-box.json \
  init --server-address singapore.example.com --server-ip 1.2.3.4

# Add a device that uses the singapore endpoint
subgen \
  --state clients/state-singapore.json \
  --out-dir clients/out-singapore \
  --server-out server-singapore/sing-box.json \
  add iphone-kid

# Deploy:
bash infra/push.sh root@singapore.example.com
# but be sure to push the right server config — push.sh needs adjusting
```

### Why Pattern B is harder

`infra/push.sh` is hardcoded to rsync `server/sing-box.json`. To support multiple servers, you'd need to pass `--server-dir server-singapore` to push.sh, and the script would need to parameterize the path. It's doable but adds complexity:

```bash
# push.sh modification (conceptual):
SERVER_DIR="${SERVER_DIR:-server}"
rsync ... --include="${SERVER_DIR}/" --include="${SERVER_DIR}/sing-box.json" ...
ssh "$REMOTE" "cd /opt/vpn-builder && SERVER_DIR=$SERVER_DIR bash infra/deploy.sh"
```

And `deploy.sh` would read `$SERVER_DIR` to know which sing-box.json to install. All workable, but **most users don't need this**.

### When Pattern B makes sense

- You manage 5+ servers and want them in one git repo.
- You want CI to test config rendering for all servers at once.
- You want centralized credential rotation.

For ≤3 servers, Pattern A is simpler.

## Cross-cutting: client-side multi-server

Clients (SFM, sing-box iOS/Android) can hold **multiple subscription configs** simultaneously and switch between them in the GUI. The operator distributes one `.json` per server to each device.

In SFM, this means multiple rows in the Profiles list. The user can pick which one is active.

For seamless failover between servers, sing-box clients support `urltest` groups in their outbounds — but our current canonical config only urltest's *protocols* (Reality vs Hysteria2) within a server. To urltest across servers, you'd modify the client config to include multiple `reality` outbounds (one per server) inside the `auto` group. This is an advanced setup; document it as a custom variant in your team's runbook if you need it.

## Key rotation across servers

When rotating Reality keypair on one server, only that server's client configs need updating. Other servers are unaffected. This is a key reason Pattern A is appealing — the blast radius of a key rotation matches one project directory.

## What's shared between deployments

Even with separate projects, these things can be shared (and updated centrally):

- The skill itself (`~/.claude/skills/vpn-builder-skill/`) — methodology, references, templates.
- The Python `vpn_builder` package — but each project has its own copy under `src/`. If you want a single canonical copy, install it as an editable package from a central location.
- `~/.claude/CLAUDE.md` — operator-wide coding/collaboration rules.

The skill is the playbook; each project is one execution of it.
