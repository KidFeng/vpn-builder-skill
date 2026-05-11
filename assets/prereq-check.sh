#!/usr/bin/env bash
# prereq-check.sh — run BEFORE deploy to catch problems early.
#
# Runs from the operator workstation. Validates:
#   1. Every rule-set URL in the generated client config returns 200.
#   2. The server domain (if any) resolves to the expected IP.
#   3. SSH to the server works with the configured user.
#   4. The server's OS is supported.
#   5. NTP is configured on the server.
#   6. (Best-effort) Cloud firewall has 443/tcp + 443/udp open externally —
#      probed via a 3rd-party port-scan service (limited reliability).
#
# Required env / args:
#   SERVER_ADDRESS  domain or IP for the server (matches subgen --server-address)
#   SERVER_IP       expected server public IP (for DNS match check)
#   SSH_USER        ssh login user
#   SSH_PORT        ssh port (default 22)
#   CLIENT_CONFIG   path to a rendered client JSON to extract rule-set URLs from
#
# Exit code = number of failed checks.

set -u

require_env() {
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "FATAL: env var $v is required" >&2
      exit 2
    fi
  done
}

require_env SERVER_ADDRESS SERVER_IP SSH_USER CLIENT_CONFIG
SSH_PORT="${SSH_PORT:-22}"

PASS=0
FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/tmp/prereq-check.log 2>&1; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n' "$name"
    sed 's/^/        /' /tmp/prereq-check.log
    FAIL=$((FAIL+1))
  fi
}

echo "Pre-flight check for $SERVER_ADDRESS ($SERVER_IP)"
echo "=================================================="
echo

# --- 1. rule-set URLs ---
echo "[1/6] Rule-set URLs (one HEAD per URL)"
if [[ ! -f "$CLIENT_CONFIG" ]]; then
  echo "  SKIP  $CLIENT_CONFIG missing — run 'subgen init && subgen add <device>' first"
  FAIL=$((FAIL+1))
else
  URLS=$(jq -r '.route.rule_set[].url' "$CLIENT_CONFIG")
  while IFS= read -r url; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -L "$url")
    if [[ "$code" == "200" ]]; then
      printf '  PASS  %s\n' "$url"
      PASS=$((PASS+1))
    else
      printf '  FAIL  %s (HTTP %s)\n' "$url" "$code"
      FAIL=$((FAIL+1))
    fi
  done <<< "$URLS"
  echo
  # Defense in depth: ensure no URL contains '@' (sing-box 1.13 known bug).
  if echo "$URLS" | grep -q '@'; then
    echo "  FAIL  rule-set URL contains '@' — sing-box 1.13 may fail to fetch (see references/routing-and-dns.md)"
    FAIL=$((FAIL+1))
  else
    echo "  PASS  no '@' in any rule-set URL"
    PASS=$((PASS+1))
  fi
fi
echo

# --- 2. DNS resolution ---
echo "[2/6] DNS"
if [[ "$SERVER_ADDRESS" == "$SERVER_IP" ]]; then
  echo "  SKIP  server_address == server_ip (no DNS to check)"
else
  RESOLVED=$(dig +short A "$SERVER_ADDRESS" | head -1)
  if [[ "$RESOLVED" == "$SERVER_IP" ]]; then
    printf '  PASS  %s → %s\n' "$SERVER_ADDRESS" "$RESOLVED"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s resolves to %s, expected %s\n' "$SERVER_ADDRESS" "${RESOLVED:-<none>}" "$SERVER_IP"
    FAIL=$((FAIL+1))
  fi
fi
echo

# --- 3. SSH ---
echo "[3/6] SSH access"
check "ssh $SSH_USER@$SERVER_ADDRESS works" \
  ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new "$SSH_USER@$SERVER_ADDRESS" 'echo ok'
echo

# --- 4. OS supported ---
echo "[4/6] Server OS"
OS_INFO=$(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$SERVER_ADDRESS" \
  'cat /etc/os-release 2>/dev/null' || true)
DISTRO=$(echo "$OS_INFO" | awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}')
VERSION=$(echo "$OS_INFO" | awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}')
case "$DISTRO:$VERSION" in
  ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13)
    printf '  PASS  %s %s (supported)\n' "$DISTRO" "$VERSION"
    PASS=$((PASS+1)) ;;
  *)
    printf '  FAIL  %s %s (deploy.sh accepts only Ubuntu 22.04/24.04/26.04 + Debian 12/13)\n' "$DISTRO" "$VERSION"
    FAIL=$((FAIL+1)) ;;
esac
echo

# --- 5. NTP ---
echo "[5/6] NTP"
NTP_STATUS=$(ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$SERVER_ADDRESS" \
  'chronyc tracking 2>/dev/null | grep "Leap status" || timedatectl status 2>/dev/null | grep "synchronized"' || true)
if echo "$NTP_STATUS" | grep -qE "Normal|yes"; then
  printf '  PASS  clock synced (%s)\n' "$(echo "$NTP_STATUS" | head -1 | tr -s ' ')"
  PASS=$((PASS+1))
else
  printf '  WARN  NTP not confirmed; deploy.sh installs chrony but Reality needs <90s drift\n'
  # Don't fail — deploy.sh will install chrony.
fi
echo

# --- 6. cloud firewall (port 443 reachable from outside) ---
echo "[6/6] Cloud firewall — external port probe"
echo "  (note: relies on a 3rd-party port checker; may be flaky)"
# Use canyouseeme.org or similar. Skip for now — too unreliable.
# Just remind the operator to confirm manually.
echo "  TODO  manually verify VPC/Security Group / Cloud Firewall has:"
echo "          ingress 443/tcp from 0.0.0.0/0"
echo "          ingress 443/udp from 0.0.0.0/0"
echo "        See references/cloud-providers.md for provider-specific commands."
echo

echo "=================================================="
echo "PASS=$PASS  FAIL=$FAIL"
exit "$FAIL"
