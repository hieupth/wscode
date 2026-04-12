#!/bin/bash
# test.sh v0.5 - Test suite for webcode
#
# Validates:
#   - Directory structure exists
#   - Required files are present
#   - Shell script syntax is valid
#   - Template variables are correct
#   - Key functions are defined
#   - CLI help works

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SRC_DIR}/.." && pwd)"
PASSED=0
FAILED=0

# Test result helpers
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

echo "=========================================="
echo "webcode Test Suite v0.5.0"
echo "=========================================="

# ---------------------------------------------------------------------------
# Directory structure tests
# ---------------------------------------------------------------------------

echo ""
echo "--- Directory structure ---"
for dir in src/lib src/templates src/scripts config state; do
  [[ -d "${ROOT_DIR}/${dir}" ]] && pass "Directory: $dir" || fail "Directory: $dir"
done

# ---------------------------------------------------------------------------
# Required files tests
# ---------------------------------------------------------------------------

echo ""
echo "--- Required files ---"
for f in \
  README.md Dockerfile.debian Dockerfile.manjaro .dockerignore \
  src/webcode.sh src/test.sh \
  src/lib/common.sh src/lib/state.sh src/lib/preflight.sh src/lib/install.sh \
  src/lib/users.sh src/lib/services.sh src/lib/acl.sh \
  src/lib/cloudflared.sh src/lib/verify.sh src/lib/rollback.sh \
  src/templates/code-server@.service.tpl \
  src/templates/code-server@.override-hardening.conf.tpl \
  src/templates/cloudflared.override-hardening.conf.tpl \
  src/templates/acl.nft.tpl \
  src/templates/webcode-acl.service.tpl \
  src/templates/usage-cli.txt \
  src/scripts/docker-test.sh src/scripts/docker-smoke.sh \
  src/scripts/docker-integration-test.sh src/scripts/docker-integration-run.sh \
  config/users.allow config/users.deny config/settings.env.example; do
  [[ -f "${ROOT_DIR}/${f}" ]] && pass "File: $f" || fail "File: $f"
done

# ---------------------------------------------------------------------------
# Deprecated files must NOT exist
# ---------------------------------------------------------------------------

echo ""
echo "--- Deprecated files removed ---"
for f in src/setup.sh src/templates/usage.txt; do
  [[ ! -f "${ROOT_DIR}/${f}" ]] && pass "Removed: $f" || fail "Still exists: $f"
done
[[ ! -d "${ROOT_DIR}/deprecated" ]] && pass "Removed: deprecated/" || fail "Still exists: deprecated/"

# ---------------------------------------------------------------------------
# Script syntax tests
# ---------------------------------------------------------------------------

echo ""
echo "--- Script syntax ---"
for s in src/webcode.sh src/test.sh src/lib/*.sh src/scripts/*.sh; do
  bash -n "${ROOT_DIR}/${s}" 2>/dev/null && pass "Syntax: $s" || fail "Syntax: $s"
done

# ---------------------------------------------------------------------------
# Template variable tests
# ---------------------------------------------------------------------------

echo ""
echo "--- Template variables ---"
if grep -q "{{CODESERVER_BIN}}" "${ROOT_DIR}/src/templates/code-server@.service.tpl"; then
  pass "Template substitution variable present: {{CODESERVER_BIN}}"
else
  fail "Template missing {{CODESERVER_BIN}}"
fi

if grep -q "{{NFT_BIN}}" "${ROOT_DIR}/src/templates/webcode-acl.service.tpl"; then
  pass "Template substitution variable present: {{NFT_BIN}}"
else
  fail "Template missing {{NFT_BIN}}"
fi

if grep -q "{{USER_RULES}}" "${ROOT_DIR}/src/templates/acl.nft.tpl"; then
  pass "Template substitution variable present: {{USER_RULES}}"
else
  fail "Template missing {{USER_RULES}}"
fi

if grep -q "{{CLOUDFLARED_RULES}}" "${ROOT_DIR}/src/templates/acl.nft.tpl"; then
  pass "Template substitution variable present: {{CLOUDFLARED_RULES}}"
else
  fail "Template missing {{CLOUDFLARED_RULES}}"
fi

# ---------------------------------------------------------------------------
# Core feature tests
# ---------------------------------------------------------------------------

echo ""
echo "--- Core features ---"
if grep -q "detect_codeserver_binary" "${ROOT_DIR}/src/lib/common.sh"; then
  pass "Binary detection function present"
else
  fail "Binary detection function missing"
fi

if grep -q "setup_local_port_acl" "${ROOT_DIR}/src/lib/acl.sh"; then
  pass "Local ACL feature present"
else
  fail "Missing localhost ACL feature"
fi

if grep -q "assert_secure_file" "${ROOT_DIR}/src/lib/common.sh"; then
  pass "Secure config validation present"
else
  fail "Missing secure config validation"
fi

if grep -q "detect_distro_family" "${ROOT_DIR}/src/lib/common.sh"; then
  pass "OS detection present"
else
  fail "Missing OS detection"
fi

if grep -q "detect_arch" "${ROOT_DIR}/src/lib/common.sh"; then
  pass "Architecture detection present"
else
  fail "Missing architecture detection"
fi

if grep -q "render_template" "${ROOT_DIR}/src/lib/common.sh"; then
  pass "Template rendering function present"
else
  fail "Missing template rendering function"
fi

if grep -q "diff_user_lists" "${ROOT_DIR}/src/lib/state.sh"; then
  pass "State diff function present"
else
  fail "Missing state diff function"
fi

if grep -q "cmd_reload" "${ROOT_DIR}/src/webcode.sh"; then
  pass "CLI reload command present"
else
  fail "Missing CLI reload command"
fi

if grep -q "cmd_uninstall" "${ROOT_DIR}/src/webcode.sh"; then
  pass "CLI uninstall command present"
else
  fail "Missing CLI uninstall command"
fi

# Verify no inline heredoc usage
echo ""
echo "--- No inline heredocs ---"
heredoc_count=$(grep -r "cat >>\|cat >" "${ROOT_DIR}/src/lib/" "${ROOT_DIR}/src/webcode.sh" 2>/dev/null | grep -c "<<" || true)
if [[ $heredoc_count -eq 0 ]]; then
  pass "No inline heredoc (EOF) usage in scripts"
else
  fail "Found $heredoc_count inline heredoc usage(s) — should use template files"
fi

# Verify webcode namespace
echo ""
echo "--- Namespace ---"
wscode_code_count=$(grep -rn "wscode" "${ROOT_DIR}/src/lib/" "${ROOT_DIR}/src/webcode.sh" 2>/dev/null | grep -v "^[^:]*:[^:]*:[^#]*#" | grep -c "wscode" || true)
if [[ $wscode_code_count -eq 0 ]]; then
  pass "All references use 'webcode' namespace"
else
  fail "Found $wscode_code_count old 'wscode' reference(s)"
fi

# Verify username validation rejects hyphens
echo ""
echo "--- Username validation ---"
if grep -q 'a-z0-9_' "${ROOT_DIR}/src/lib/common.sh" && ! grep -q 'a-z0-9_-' "${ROOT_DIR}/src/lib/common.sh"; then
  pass "Username validation rejects hyphens"
else
  fail "Username validation should reject hyphens"
fi

# ---------------------------------------------------------------------------
# CLI help test
# ---------------------------------------------------------------------------

echo ""
echo "--- CLI help ---"
if bash "${ROOT_DIR}/src/webcode.sh" --help &>/dev/null; then
  pass "src/webcode.sh --help works"
else
  fail "src/webcode.sh --help fails"
fi

if bash "${ROOT_DIR}/src/webcode.sh" --help 2>&1 | grep -q "install"; then
  pass "Help text contains 'install' command"
else
  fail "Help text missing 'install' command"
fi

if bash "${ROOT_DIR}/src/webcode.sh" --help 2>&1 | grep -q "reload"; then
  pass "Help text contains 'reload' command"
else
  fail "Help text missing 'reload' command"
fi

if bash "${ROOT_DIR}/src/webcode.sh" --help 2>&1 | grep -q "uninstall"; then
  pass "Help text contains 'uninstall' command"
else
  fail "Help text missing 'uninstall' command"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] && { echo "All tests passed!"; exit 0; } || { echo "Some tests failed!"; exit 1; }
