#!/usr/bin/env bash
# smoke_test.sh — post-deploy verification for the VPN.
# Cross-platform: works on both macOS (BSD tools) and Linux (GNU tools).
#
# Required env:
#   SERVER         public IP or domain of the VPN server
#   SSH_USER       SSH login user
#   SSH_PORT       SSH port
#   REALITY_SNI    Reality SNI (e.g. www.microsoft.com)
#   CLIENT_CONFIG  path to a freshly generated client sing-box JSON
#
# Optional:
#   SOCKS_PORT     local SOCKS port for the test client (default 17890)
#   SERVER_IP      explicit server IP for exit-IP check (default: resolve $SERVER)
#
# Each check runs independently; a single failure does not skip downstream
# checks. Exit code = number of failures (0 = all pass).

set -u

SOCKS_PORT="${SOCKS_PORT:-17890}"

# Resolve the server's actual IP for the exit-IP check (handles domain endpoints).
if [[ -z "${SERVER_IP:-}" ]]; then
  SERVER_IP=$(dig +short A "$SERVER" 2>/dev/null | head -1)
  [[ -z "$SERVER_IP" ]] && SERVER_IP="$SERVER"
fi

PASS=0
FAIL=0
TMP_LOG=$(mktemp)
trap 'rm -f "$TMP_LOG"; cleanup_client' EXIT

check() {
  local name="$1"; shift
  if "$@" >"$TMP_LOG" 2>&1; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n' "$name"
    sed 's/^/        /' "$TMP_LOG"
    FAIL=$((FAIL+1))
  fi
}

require() {
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "FATAL: env var $v is required" >&2
      exit 2
    fi
  done
}

require SERVER SSH_USER SSH_PORT REALITY_SNI CLIENT_CONFIG

echo "Server:  $SERVER  (resolves to $SERVER_IP)"
echo "SNI:     $REALITY_SNI"
echo "Client:  $CLIENT_CONFIG"
echo

# Build a MINIMAL test client config: SOCKS inbound + the two proxy outbounds.
# We strip rule sets / routing rules / DNS — they're not needed to verify the
# tunnel, and downloading rule sets from GitHub on every smoke run is slow
# (and gets even slower when the operator's machine has a local TUN proxy
# intercepting outbound traffic).
make_test_client_config() {
  local src="$1" dst="$2"
  jq --arg port "$SOCKS_PORT" '
    {
      "log": {"level": "warn"},
      "dns": {
        "servers": [{"type": "local", "tag": "local"}],
        "final": "local"
      },
      "inbounds": [{
        "type": "socks",
        "tag": "test-socks",
        "listen": "127.0.0.1",
        "listen_port": ($port | tonumber)
      }],
      "outbounds": [
        {"type": "selector", "tag": "proxy",
         "outbounds": ["reality", "hysteria2"], "default": "reality"},
        (.outbounds[] | select(.tag == "reality")),
        (.outbounds[] | select(.tag == "hysteria2")),
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
      ],
      "route": {
        "rules": [
          {"action": "sniff"},
          {"protocol": "dns", "action": "hijack-dns"}
        ],
        "final": "proxy",
        "default_domain_resolver": {"server": "local"}
      }
    }
  ' "$src" > "$dst"
}

# Portable mktemp: BSD mktemp lacks --suffix; use -t prefix then append.
CLIENT_TEST_CFG="$(mktemp -t sb-smoke-cfg).json"
LOCAL_SB_PID=
LOCAL_SB_LOG=$(mktemp -t sb-smoke-log)

cleanup_client() {
  if [[ -n "$LOCAL_SB_PID" ]] && kill -0 "$LOCAL_SB_PID" 2>/dev/null; then
    kill "$LOCAL_SB_PID" 2>/dev/null || true
    wait "$LOCAL_SB_PID" 2>/dev/null || true
  fi
  rm -f "$CLIENT_TEST_CFG" "$LOCAL_SB_LOG"
}

# --- 1. service running on server ---
check "sing-box service active on server" \
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$SERVER" \
    'systemctl is-active --quiet sing-box'

# --- 2. nftables loaded with both 443 listeners ---
check "nftables has tcp/443 + udp/443 accept rules" \
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$SERVER" \
    "nft list ruleset 2>/dev/null | grep -q 'tcp dport 443' && nft list ruleset | grep -q 'udp dport 443'"

# --- 3. clock synced (Reality requires <90s drift) ---
check "server clock synced via chrony" \
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$SERVER" \
    "chronyc tracking 2>/dev/null | grep -E 'Leap status\\s+:\\s+Normal'"

# --- 4. start a local sing-box client (with SOCKS) for handshake tests ---
if command -v sing-box >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  make_test_client_config "$CLIENT_CONFIG" "$CLIENT_TEST_CFG"
  sing-box run -c "$CLIENT_TEST_CFG" >"$LOCAL_SB_LOG" 2>&1 &
  LOCAL_SB_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if (echo > /dev/tcp/127.0.0.1/$SOCKS_PORT) 2>/dev/null; then break; fi
  done

  # --- 5. Reality + Hy2 handshake (urltest auto-picks; either suffices) ---
  check "client SOCKS reaches https://www.gstatic.com/generate_204 (204)" \
    bash -c "[[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 \
      --proxy socks5h://127.0.0.1:$SOCKS_PORT https://www.gstatic.com/generate_204)\" == \"204\" ]]"

  # --- 6. exit IP equals server IP ---
  EXIT_IP=$(curl -s --max-time 12 --proxy "socks5h://127.0.0.1:$SOCKS_PORT" https://api.ipify.org || true)
  check "exit IP equals server IP ($SERVER_IP); got: '${EXIT_IP:-<empty>}'" \
    test "$EXIT_IP" = "$SERVER_IP"

  # --- 7. baidu.com via tunnel resolves (proves DNS works through proxy) ---
  CN_IP=$(curl -s --max-time 12 --proxy "socks5h://127.0.0.1:$SOCKS_PORT" \
            -o /dev/null -w '%{remote_ip}' https://www.baidu.com || true)
  check "baidu.com via proxy resolves to a non-empty IP (got: '${CN_IP:-<empty>}')" \
    test -n "$CN_IP"
else
  echo "  SKIP  local sing-box or jq not installed — install with:"
  echo "        brew install sing-box jq    # macOS"
  echo "        apt install -y sing-box jq  # Linux"
fi

# --- 8. MTU sanity (direct, not through tunnel) ---
# Don't-fragment flag: Linux uses `-M do`, BSD/macOS uses `-D`.
# Timeout flag: Linux `-W` is seconds, BSD `-W` is milliseconds.
if ping -D -c 1 -W 1000 127.0.0.1 >/dev/null 2>&1; then
  PING_DF_OPT="-D"
  PING_TIMEOUT_OPT="-W 5000"  # BSD: ms
else
  PING_DF_OPT="-M do"
  PING_TIMEOUT_OPT="-W 2"     # Linux: sec
fi
check "PMTU OK at 1380 to 8.8.8.8" \
  bash -c "ping $PING_DF_OPT -s 1352 -c 3 $PING_TIMEOUT_OPT 8.8.8.8"

# --- 9. negative test: standard SSH port 22 should NOT respond if hardened ---
# We don't fail this — it's informational. If SSH_PORT != 22, port 22 should
# be closed; if SSH_PORT = 22, this is N/A and skipped.
if [[ "$SSH_PORT" != "22" ]]; then
  check "SSH port 22 closed (hardening applied)" \
    bash -c "! (echo > /dev/tcp/$SERVER/22) 2>/dev/null"
fi

echo
echo "----- summary -----"
echo "PASS=$PASS  FAIL=$FAIL"
exit "$FAIL"
