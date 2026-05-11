# Per-Platform Installation Guide

Step-by-step install + import + verify for the four supported client platforms. Use these when distributing a freshly-generated client config to a user. For deeper debugging see `references/client-troubleshooting.md`.

## TL;DR matrix

| Platform | Client app | App source | Modern schema (sing-box 1.13+)? | Recommended generation |
|---|---|---|---|---|
| macOS | SFM | `brew install --cask sfm` or [Releases](https://github.com/SagerNet/sing-box/releases) | ✅ (1.13.x) | `subgen add <name>` |
| Linux | `sing-box` CLI + systemd | SagerNet apt repo | ✅ (1.13.x) | `subgen add <name>` |
| Android | sing-box | F-Droid (preferred) or Play Store | ✅ (usually 1.12–1.13 on F-Droid; Play Store may lag) | `subgen add <name>` — fall back to `set-legacy` if it errors |
| iOS | sing-box | App Store | ⚠️ **lags 6–12 months** (currently 1.11.4) | `subgen add <name> --legacy` |

The TL;DR: **iOS gets `--legacy`, the other three get modern.** When iOS App Store eventually ships 1.13+, switch with `subgen set-legacy iphone-alice --off`.

---

## macOS — SFM

### Install

```bash
brew install --cask sfm
```

Or download the `.pkg` from the [sing-box releases](https://github.com/SagerNet/sing-box/releases) page.

### First-time setup (one-time)

1. Open SFM (`open /Applications/SFM.app`).
2. Dashboard tab → click **Install System Extension**.
3. macOS will silently request approval. Open `System Settings → General → Login Items & Extensions → Network Extensions` and toggle **SFMExtension** on. Enter password.
4. Back in SFM, the "Install System Extension" link disappears.

If the System Settings prompt doesn't appear: `open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"`.

### Import profile

Easiest: drag-and-drop the `<device>.json` onto the SFM window.

If that doesn't work, inject directly via SQLite (avoids the UI entirely — useful for scripted setup):

```bash
CONTAINER="$HOME/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt"
osascript -e 'quit app "SFM"' 2>/dev/null; sleep 1; pkill -9 -x SFM 2>/dev/null

# Place both the source profile and the materialized runtime config — see
# references/client-troubleshooting.md for why both are needed.
install -d "$CONTAINER/Library/Application Support/Profiles" "$CONTAINER/configs"
install -m 0600 <device>.json "$CONTAINER/Library/Application Support/Profiles/1.json"
install -m 0600 <device>.json "$CONTAINER/configs/config_2.json"

sqlite3 "$CONTAINER/settings.db" \
  "INSERT OR REPLACE INTO profiles (id, name, \"order\", type, path, autoUpdate, autoUpdateInterval) \
   VALUES (1, '<device>', 0, 0, 'Profiles/1.json', 0, 0)"

open /Applications/SFM.app
```

### Connect

Dashboard → click **▶**. First connection prompts macOS to add a VPN configuration → **Allow** → enter password.

### Verify

```bash
curl https://api.ipify.org   # should show the server IP
```

---

## Linux — sing-box CLI + systemd

### Install (Ubuntu / Debian)

```bash
curl -fsSL https://sing-box.app/gpg.key | sudo tee /etc/apt/keyrings/sagernet.asc >/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
  | sudo tee /etc/apt/sources.list.d/sagernet.list
sudo apt-get update && sudo apt-get install -y sing-box
sing-box version
```

For Arch / Fedora / other distros: build from source or download the static binary from GitHub Releases.

### Install the config

```bash
sudo install -d -m 0750 -o root -g sing-box /etc/sing-box
sudo install -m 0640 -o root -g sing-box <device>.json /etc/sing-box/config.json
sudo sing-box check -c /etc/sing-box/config.json    # must exit 0
sudo systemctl enable --now sing-box
sudo systemctl status sing-box                       # active (running)
```

### TUN routing requires CAP_NET_ADMIN

The deb package's systemd unit grants the right capabilities. If you installed manually, ensure your systemd unit has:

```ini
[Service]
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
```

### Conflict with systemd-resolved

If you see "DNS works for the first lookup, then fails", disable `systemd-resolved` for the TUN duration:

```bash
sudo systemctl disable --now systemd-resolved
sudo rm /etc/resolv.conf
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf
```

### Verify

```bash
curl https://api.ipify.org   # should show the server IP
journalctl -u sing-box -f    # live log
```

### Optional: per-app routing

Linux sing-box supports `process_name` matchers in routing rules — useful if you want certain apps to bypass the tunnel. Add to `route.rules` in the config:

```json
{ "process_name": ["steam", "bittorrent"], "outbound": "direct" }
```

---

## Android — sing-box (F-Droid preferred)

### Install

**F-Droid is preferred** — it builds from upstream source promptly, while Play Store can lag.

1. Install F-Droid client from <https://f-droid.org> (sideload, then enable "Install unknown apps" for F-Droid).
2. In F-Droid: search **sing-box** → install.

Alternative: **Play Store** has an official sing-box too. Slower to update; if it lags below 1.13 you'll need `subgen set-legacy android-<name>`.

### Transfer config to phone

- **USB**: drag `<device>.json` to phone storage via Android File Transfer (Mac) or MTP (Linux).
- **Web**: serve from a temporary HTTP server, download in phone browser:
  ```bash
  # On your Mac, in the directory containing the .json:
  python3 -m http.server 8000
  # On phone: http://<your-mac-ip>:8000/<device>.json
  ```
- **Cloud sync**: not recommended (the config has live keys); if you must, use end-to-end encrypted cloud only.

### Import

1. Open sing-box app.
2. Bottom tab: **Profiles**.
3. Top-right **+** → **Read content from file** → pick the `<device>.json`.
4. Give it a name (e.g., `tokyo-server`).

### Connect

1. Bottom tab: **Dashboard**.
2. Tap the toggle / **Start**.
3. Android prompts "Connection request" → **OK**.
4. Status turns green.

### Always-on VPN (recommended)

Settings → Network & Internet → Advanced → VPN → sing-box → enable:
- **Always-on VPN**: keeps the tunnel alive across app suspension.
- **Block connections without VPN**: prevents leaks during reconnection.

### If you see `unknown field "type"`

Your Android sing-box version is pre-1.12. Run on operator workstation:

```bash
subgen set-legacy android-alice    # toggle to legacy schema
```

Then re-transfer the regenerated `<device>.json`.

### Verify

In Chrome on phone: open <https://api.ipify.org> — should show the server IP.

---

## iOS — sing-box (App Store)

### Install

App Store → search **sing-box** → install. **Free**, by `nekohasekai`. The icon is purple-ish, no ads.

> Don't install Shadowrocket / Stash / Surge for this purpose — those are paid alternatives. The free upstream client is what you want.

### Generate the right config

As of mid-2026, App Store sing-box is **1.11.4** — needs `--legacy`:

```bash
subgen add iphone-alice --legacy
```

(For an existing modern-schema device that's failing on iOS, toggle in place: `subgen set-legacy iphone-alice`.)

### Transfer config to phone

**AirDrop** from Mac is easiest:

1. In Finder, right-click `clients/out/iphone-alice.json` → **Share** → **AirDrop** → pick your iPhone.
2. iPhone receives a notification → tap **Accept**.
3. iPhone prompts "Open with…" → choose **sing-box**.

The config auto-imports.

### Connect

1. sing-box App → **仪表 Tab** (Dashboard).
2. Pick the imported profile in the **配置 / Profile** dropdown.
3. Tap the **启用** (Enable) toggle.
4. iOS prompts "sing-box would like to add VPN configurations" → **Allow** → Touch ID / Face ID / passcode.
5. Status bar shows VPN icon (top-right).

### Suppress the "legacy outbounds deprecated" warning

You can't suppress it on 1.11 — it's the app saying "your config uses things being removed in future versions". The warning is informational; the VPN still works. To get rid of it you need iOS sing-box on 1.13+ AND a config without legacy fields (`subgen set-legacy --off`).

### When iOS sing-box eventually updates to 1.13+

Don't tap "Update" yet if you rely on the connection. From operator workstation:

```bash
subgen set-legacy iphone-alice --off    # back to modern schema
# AirDrop the new clients/out/iphone-alice.json to iPhone
# Re-import it (delete the old profile first to avoid name collision)
# Then tap Update in the App Store
```

### Verify

In Safari: open <https://api.ipify.org> — should show the server IP.

---

## Verification checklist for any platform

After import + connect, do these from the device itself:

1. **Exit IP**: <https://api.ipify.org> → matches server's IP.
2. **GFW-blocked sites** (the whole point):
   - <https://www.google.com> → opens
   - <https://www.youtube.com> → opens (and plays video)
   - <https://github.com> → opens
3. **Domestic sites should be fast** (not proxied):
   - <https://www.baidu.com> → opens in <500 ms
   - <https://www.bilibili.com> → opens in <500 ms; videos play
4. **No DNS leak**:
   - <https://www.dnsleaktest.com> → shows Cloudflare or your DoH provider, NOT your home ISP's resolver.
5. **Mode toggle works** (Clash API):
   - In the client GUI, switch to "Global" mode → all traffic should go via Tokyo (slow Bilibili confirms).
   - Switch to "Direct" → exit IP should be your home IP again.
   - Switch back to "Rule" (default).

If any of these fail, see `references/client-troubleshooting.md`.

---

## Distribution etiquette

- **Out-of-band only.** AirDrop, Signal, encrypted email. **Never** post the `.json` in:
  - Public chat (Telegram public channels, Discord public servers, …)
  - Cloud sync that gets indexed (Dropbox public, Google Drive non-restricted, …)
  - GitHub, even private repos (private orgs can be acquired; private repos can be leaked)
- **Per-device file.** Don't give two people the same `.json` — server logs aggregate by user, and a leak can't be traced.
- **Revoke fast.** If a device is lost, run `subgen revoke <name>` immediately and re-deploy. The user keeps the same display name; the underlying UUID/password is rotated.
