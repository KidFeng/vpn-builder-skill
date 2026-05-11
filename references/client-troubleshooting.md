# Client-Side Troubleshooting

Read this when a deployed server is healthy (smoke test passes) but a client can't connect. Most issues are client-platform-specific. We've taken extensive notes from real deployments — start here.

## macOS — SFM (sing-box for Mac)

SFM is the official sing-box GUI, distributed via `brew install --cask sfm` or sing-box's GitHub releases. Bundle ID: `io.nekohasekai.sfavt.standalone`. Container path: `~/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt/`.

### Symptom: "Install System Extension" button does nothing

The button DID work — it requested macOS install a system extension. But macOS requires user approval, which is **silent** by default. Check:

```bash
systemextensionsctl list | grep nekohasekai
```

Expected output for a pending approval:

```
*  287TTNZF8L  io.nekohasekai.sfavt.system (1.13.11/1)  SFMExtension  [activated waiting for user]
```

`activated waiting for user` means it's stuck waiting for human approval. Open System Settings:

```bash
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
```

Path: **System Settings → General → Login Items & Extensions → scroll to Extensions → Network Extensions → ⓘ → toggle SFMExtension on → enter password**.

After approval, status changes to `[activated enabled]` and the Dashboard button disappears.

### Symptom: "Profile" tab not visible in SFM

Recent SFM versions have a minimal sidebar with only Dashboard / Logs / Settings. There is **no separate Profile tab**. Two ways to manage profiles:

1. **Drag-and-drop** the `.json` file onto the SFM window.
2. **Settings tab → Profiles section** (or similar — varies by language).
3. **Top-right ☰ icon** on the Dashboard view — sometimes hides a profile dropdown.

### Symptom: Profile imported, but SFM uses stale config

SFM **materializes** the profile when starting the tunnel. Two file locations matter:

| Path | Role |
|---|---|
| `<container>/Library/Application Support/Profiles/<id>.json` | Source of truth shown in SFM UI |
| `<container>/configs/config_<id>.json` | Materialized runtime config; system extension reads this |

When you edit `Profiles/<id>.json` externally (e.g., after `subgen regen` produces a new client config), `configs/config_<id>.json` does NOT update automatically. Manually replace:

```bash
CONTAINER="/Users/$USER/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt"
cp clients/out/<device>.json "$CONTAINER/Library/Application Support/Profiles/<id>.json"
cp clients/out/<device>.json "$CONTAINER/configs/config_<id>.json"
chmod 0600 "$CONTAINER/Library/Application Support/Profiles/<id>.json" "$CONTAINER/configs/config_<id>.json"
```

Then restart SFM:

```bash
osascript -e 'quit app "SFM"' 2>/dev/null; sleep 1
pkill -9 -x SFM 2>/dev/null
open /Applications/SFM.app
```

The system extension itself doesn't need restart — it reads the materialized config at "Start tunnel" time.

### Symptom: "Failed to fetch last disconnect error" with same error every retry

That message means SFM is displaying the cached last-disconnect reason. It's **not necessarily** the result of the current retry — if the new start failed *before* writing a new error, the old one shows. Two interpretations:

1. The new start really fails for the same reason. Confirm by going to **Logs tab** and looking at the most recent log timestamp.
2. The new start hasn't been triggered yet. Click ▶ again deliberately.

### Symptom: Direct DB injection for headless profile setup

When the UI is unclear or scripting deployment to multiple users' Macs, inject directly:

```bash
CONTAINER="/Users/$USER/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt"

# 1. Make sure SFM is closed (writes to settings.db while running may be ignored).
osascript -e 'quit app "SFM"' 2>/dev/null; sleep 1
pkill -9 -x SFM 2>/dev/null

# 2. Place the profile file.
mkdir -p "$CONTAINER/Library/Application Support/Profiles"
cp clients/out/<device>.json "$CONTAINER/Library/Application Support/Profiles/1.json"
chmod 0600 "$CONTAINER/Library/Application Support/Profiles/1.json"

# 3. Insert DB row.
sqlite3 "$CONTAINER/settings.db" \
  "INSERT INTO profiles (name, \"order\", type, path, autoUpdate, autoUpdateInterval) \
   VALUES ('<device>', 0, 0, 'Profiles/1.json', 0, 0)"

# 4. Also place materialized runtime config (otherwise SFM creates a stale one on first start).
mkdir -p "$CONTAINER/configs"
cp clients/out/<device>.json "$CONTAINER/configs/config_2.json"  # NB: id+1 historically
chmod 0600 "$CONTAINER/configs/config_2.json"

# 5. Open SFM.
open /Applications/SFM.app
```

The materialized config filename is `config_<N>.json` where `<N>` is the profile id + 1 in older versions, or possibly just `<profile-id>` in newer. Inspect the existing pattern with `ls "$CONTAINER/configs/"` after the first manual UI-driven import.

### Symptom: Rule-set fetch fails with 404 in SFM but curl works

This is the `@` URL bug. See `references/routing-and-dns.md` "Critical caveat" section. SagerNet's `geosite-apple@cn.srs` and similar `@`-containing URLs work via curl but **404 in sing-box's HTTP client** (sometimes — depends on intermediate network).

The skill's canonical config excludes these rule-sets entirely. If you see `geosite-apple-cn: unexpected status: 404` in client error, the deployed client config has stale rule-sets — regenerate and re-import (and remember to update BOTH `Profiles/<id>.json` AND `configs/config_<id>.json`).

### Symptom: TUN conflicts with another VPN/proxy app

macOS allows only one active VPN configuration in the system network preferences at a time. If the user previously had a different proxy (ClashX, V2Ray, another SFM profile) with TUN mode enabled, SFM's TUN may fail to install or may install but not route traffic.

Check System Settings → Network for ghost VPN configurations and remove them. Also check `scutil --proxy` for system-wide HTTP/SOCKS proxy settings — disable those if they point at a no-longer-running app.

## iOS — sing-box (App Store)

iOS sing-box ships from the App Store. **Important**: the App Store version typically **lags upstream by 6–12 months**. As of mid-2026, the App Store version is **1.11.4**, while Linux/macOS are on **1.13.x**. The sing-box 1.12 / 1.13 schema changes (typed DNS servers, `hijack-dns` action, `sniff` action, `default_domain_resolver`, removal of `dns` outbound, …) mean the **modern client config from `subgen add` will NOT load on a 1.11.x iOS client**.

### Symptom: `unknown field "type"` or `legacy special outbounds` deprecated

You imported a modern client config on iOS 1.11.x. The version is too old. Solutions:

1. **Best (clean fix)**: regenerate as a legacy config:
   ```bash
   subgen set-legacy <device-name>           # toggle the existing device
   # OR for a brand-new device:
   subgen add <device-name> --legacy
   ```
   The project template in `src/vpn_builder/legacy.py` produces a pre-1.13 schema that 1.11.x accepts.

2. **Avoid (suppress warnings)**: `ENABLE_DEPRECATED_LEGACY_*=true` env vars in sing-box let some legacy features work past their removal. Don't use — tech debt that breaks on the next iOS update.

### Bootstrap-DNS loop in legacy configs

A common gotcha when downgrading to legacy schema: **`DNS query loopback in transport[remote-doh]`**. Cause:
- `remote-doh` (DoH at 1.1.1.1) has `detour: proxy` — DNS queries to it go through the tunnel
- The tunnel's `proxy` outbound has `server: <your-domain>` — needs DNS to resolve
- Without `default_domain_resolver` (which doesn't exist pre-1.12), sing-box uses `dns.final` (= `remote-doh`) — infinite recursion

Solution baked into `vpn_builder.legacy.downgrade_to_legacy`: prepend a DNS rule that routes the server endpoint + rule-set CDN through `local` (OS resolver):

```json
{"domain": ["<server-address>", "raw.githubusercontent.com"], "server": "local"}
```

### When iOS sing-box updates to 1.13+

Watch the App Store. When sing-box updates to 1.13+:
1. Don't tap "Update" yet if you have active legacy VPN sessions.
2. From the operator workstation:
   ```bash
   subgen set-legacy <device-name> --off     # back to modern schema
   ```
3. Re-AirDrop the regenerated config.
4. Then tap Update in the App Store.

### Importing profiles

1. AirDrop the `.json` from Mac → iPhone (or upload via cloud).
2. Tap the file in Files app → "Share" → "sing-box".
3. Or: in sing-box app, Profile tab → New Profile → import from file/URL.

### Permissions

First start prompts for "Allow Add VPN Configuration" — accept. iOS will hand sing-box the system VPN slot; only one VPN can be active.

### Battery & background

iOS aggressively suspends background apps. sing-box uses the NetworkExtension framework which can run in background, but if iOS reclaims memory, the tunnel restarts on next network event. This is normal; nothing to fix.

## Android — sing-box (F-Droid or Play Store)

F-Droid version is closest to upstream; Play Store version may lag slightly.

### Importing profiles

1. Transfer `.json` to phone storage.
2. sing-box app → Profile → New Profile → "Read content from file".
3. Or scan a QR code: Mac → `qrencode -t ansiutf8 < clients/out/<device>.json` (but only if config is small enough; sing-box JSON usually too big — file transfer is more reliable).

### TUN permissions

Android prompts for VPN permission on first start. Accept. The TUN inbound config is the same as macOS.

### "Always-on VPN" (optional)

In Android Settings → Network & Internet → Advanced → VPN → sing-box → toggle "Always-on VPN" and "Block connections without VPN". This makes the tunnel resilient to app suspension and prevents leaks during reconnection. Recommended for sensitive use.

## Linux — sing-box CLI + systemd

The cleanest setup is:

```bash
# Install
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" | sudo tee /etc/apt/sources.list.d/sagernet.list
sudo apt update && sudo apt install -y sing-box

# Place config
sudo install -d -m 0750 -o root -g sing-box /etc/sing-box
sudo install -m 0640 -o root -g sing-box clients/out/<device>.json /etc/sing-box/config.json

# Enable
sudo systemctl enable --now sing-box
```

### Symptom: TUN doesn't route system traffic

The Linux sing-box service runs as `sing-box` user, but TUN routing requires root or CAP_NET_ADMIN. The deb package's systemd unit grants CAP_NET_ADMIN; if you installed manually, ensure the unit includes:

```ini
[Service]
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
```

### Symptom: DNS works for first lookup, then fails

Likely `systemd-resolved` conflict — both sing-box's TUN and systemd-resolved try to manage `/etc/resolv.conf`. Disable systemd-resolved for the TUN duration, or configure it to delegate to sing-box's TUN DNS:

```bash
sudo systemctl disable --now systemd-resolved
sudo rm /etc/resolv.conf
sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf  # only if you want resolved later
```

## Universal: how to inspect the actually-loaded client config

If you suspect a stale config, dump what sing-box actually loaded:

```bash
# Server-side (Linux):
sudo cat /etc/sing-box/config.json | jq '.route.rule_set[].url'

# macOS SFM:
jq '.route.rule_set[].url' \
  "$HOME/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt/configs/config_2.json"
```

If the rule-set URLs contain `@`, the config is stale — see the `@` URL caveat above.
