#!/bin/bash
# docker-install-test.sh - Test real binary installation inside Docker
#
# Runs the actual install_basic_deps + install_code_server + install_cloudflared
# without systemd, config, or credentials. Proves downloads and file layout work.
set -euo pipefail

ROOT_DIR="/workspace"
cd "$ROOT_DIR"

echo "=========================================="
echo "webcode Install Test (real binaries)"
echo "=========================================="
echo ""

# Source all library modules
source "${ROOT_DIR}/src/lib/common.sh"
source "${ROOT_DIR}/src/lib/state.sh"
source "${ROOT_DIR}/src/lib/preflight.sh"
source "${ROOT_DIR}/src/lib/install.sh"

# Skip systemd/network checks — not available in Docker
WEBCODE_SKIP_SYSTEMD_CHECK=1
WEBCODE_SKIP_NETWORK_CHECK=1

PASSED=0
FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------
# Test 1: install_basic_deps
# ---------------------------------------------------------------------------
echo "--- Test 1: install_basic_deps ---"
if install_basic_deps 2>&1; then
  pass "install_basic_deps completed"
else
  fail "install_basic_deps failed"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 2: install_code_server
# ---------------------------------------------------------------------------
echo "--- Test 2: install_code_server ---"
if install_code_server 2>&1; then
  pass "install_code_server completed"
else
  fail "install_code_server failed"
fi

# Verify file layout
if [[ -x /usr/local/lib/code-server/bin/code-server ]]; then
  pass "code-server binary exists at /usr/local/lib/code-server/bin/code-server"
else
  fail "code-server binary missing at /usr/local/lib/code-server/bin/code-server"
fi

if [[ -L /usr/local/bin/code-server ]]; then
  pass "Symlink exists at /usr/local/bin/code-server"
else
  fail "Symlink missing at /usr/local/bin/code-server"
fi

if /usr/local/lib/code-server/bin/code-server --version &>/dev/null; then
  CS_VER=$(/usr/local/lib/code-server/bin/code-server --version 2>&1 | head -1)
  pass "code-server is functional: $CS_VER"
else
  fail "code-server binary is not functional"
fi

if [[ -x /usr/local/lib/code-server/lib/node ]]; then
  pass "lib/node binary exists"
else
  fail "lib/node binary missing — code-server won't work"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 3: install_cloudflared
# ---------------------------------------------------------------------------
echo "--- Test 3: install_cloudflared ---"
if install_cloudflared 2>&1; then
  pass "install_cloudflared completed"
else
  fail "install_cloudflared failed"
fi

if [[ -x /usr/local/bin/cloudflared ]]; then
  pass "cloudflared binary exists at /usr/local/bin/cloudflared"
else
  fail "cloudflared binary missing"
fi

if /usr/local/bin/cloudflared --version &>/dev/null; then
  CF_VER=$(/usr/local/bin/cloudflared --version 2>&1 | head -1)
  pass "cloudflared is functional: $CF_VER"
else
  fail "cloudflared binary is not functional"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 4: Idempotent reinstall (run again — should skip)
# ---------------------------------------------------------------------------
echo "--- Test 4: Idempotent reinstall ---"
if install_code_server 2>&1; then
  pass "install_code_server idempotent (skipped already installed)"
else
  fail "install_code_server failed on second run"
fi

if install_cloudflared 2>&1; then
  pass "install_cloudflared idempotent (skipped already installed)"
else
  fail "install_cloudflared failed on second run"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 5: Broken binary recovery — cloudflared
# ---------------------------------------------------------------------------
echo "--- Test 5: Broken cloudflared recovery ---"
echo "CORRUPTED" > /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
log_info "Corrupted cloudflared binary for testing"

install_cloudflared 2>&1 || true

if /usr/local/bin/cloudflared --version &>/dev/null; then
  CF_VER=$(/usr/local/bin/cloudflared --version 2>&1 | head -1)
  pass "cloudflared recovered after corruption: $CF_VER"
else
  fail "cloudflared NOT recovered after corruption"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 6: Broken binary recovery — code-server
# ---------------------------------------------------------------------------
echo "--- Test 6: Broken code-server recovery ---"
rm -f /usr/local/lib/code-server/lib/node
log_info "Removed lib/node to break code-server"

install_code_server 2>&1 || true

if /usr/local/lib/code-server/bin/code-server --version &>/dev/null; then
  CS_VER=$(/usr/local/lib/code-server/bin/code-server --version 2>&1 | head -1)
  pass "code-server recovered after corruption: $CS_VER"
else
  fail "code-server NOT recovered after corruption"
fi
echo ""

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] && { echo "All install tests passed!"; exit 0; } || { echo "Some install tests failed!"; exit 1; }
