#!/bin/bash
# test.sh - Real integration test for webcode
#
# Creates a system user, runs a full install, verifies the Cloudflare
# tunnel serves VS Code UI over HTTPS, then cleans up.
#
# Prerequisites:
#   - Run as root
#   - /etc/webcode/config.env with valid Cloudflare credentials
#   - Network access to Cloudflare API and tunnel endpoint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly TEST_USER="wcetest"
readonly CONFIG_FILE="/etc/webcode/config.env"

PASSED=0
FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------
# Parse config (safe KEY=VALUE, no sourcing)
# ---------------------------------------------------------------------------
CF_DOMAIN_BASE=""
parse_config() {
  [[ -f "$CONFIG_FILE" ]] || { echo "FATAL: $CONFIG_FILE not found"; exit 1; }
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    value="${value%%#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    [[ "$key" == "CF_DOMAIN_BASE" ]] && CF_DOMAIN_BASE="$value"
  done < "$CONFIG_FILE"
  [[ -n "$CF_DOMAIN_BASE" ]] || { echo "FATAL: CF_DOMAIN_BASE not set in config"; exit 1; }
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
  echo ""
  echo "--- Cleanup ---"
  bash "${ROOT_DIR}/webcode.sh" uninstall 2>&1 | tail -1 || true
  userdel -r "$TEST_USER" 2>/dev/null || true
  rm -f "${CONFIG_FILE/users.allow/}/users.allow"
  rm -rf "${ROOT_DIR}/state/backups"/*
  echo "Cleanup done"
}

# ---------------------------------------------------------------------------
# Main test
# ---------------------------------------------------------------------------
echo "=========================================="
echo "webcode Integration Test"
echo "=========================================="
echo ""

# Prerequisites
[[ $EUID -eq 0 ]] || { echo "FATAL: must run as root"; exit 1; }
parse_config

trap cleanup EXIT

# Phase 1: Create test user and allow list
echo "--- Phase 1: Prepare test user ---"
if id "$TEST_USER" &>/dev/null; then
  echo "  User $TEST_USER already exists, reusing"
else
  useradd -m -s /bin/bash "$TEST_USER"
fi
echo "$TEST_USER" > "/etc/webcode/users.allow"
pass "Test user created: $TEST_USER"

# Phase 2: Install
echo ""
echo "--- Phase 2: webcode.sh install ---"
if bash "${ROOT_DIR}/webcode.sh" install 2>&1; then
  pass "Install completed"
else
  fail "Install failed"
  echo ""
  echo "=========================================="
  echo "Results: $PASSED passed, $FAILED failed"
  echo "=========================================="
  exit 1
fi

# Phase 3: Verify tunnel serves VS Code UI
echo ""
echo "--- Phase 3: Tunnel endpoint verification ---"
TUNNEL_URL="https://${TEST_USER}-${CF_DOMAIN_BASE}"
echo "  URL: $TUNNEL_URL"

ok=0
for attempt in $(seq 1 6); do
  http_code=$(curl -sk -o /tmp/webcode-test-body -w "%{http_code}" \
    --connect-timeout 10 --max-time 20 "$TUNNEL_URL" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" ]]; then
    if grep -q "codeServerVersion\|vscode-workbench-web-configuration" /tmp/webcode-test-body 2>/dev/null; then
      pass "Tunnel returned VS Code UI (HTTP 200, code-server HTML)"
      ok=1
      break
    else
      echo "  Attempt $attempt: HTTP 200 but not VS Code UI, retrying..."
    fi
  else
    echo "  Attempt $attempt: HTTP $http_code, retrying..."
  fi
  sleep 5
done
rm -f /tmp/webcode-test-body

if [[ $ok -eq 0 ]]; then
  fail "Tunnel did not return VS Code UI after 6 attempts"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] && { echo "All tests passed!"; exit 0; } || { echo "Some tests failed!"; exit 1; }
