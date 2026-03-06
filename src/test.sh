#!/bin/bash
# test.sh v0.3 - Test suite

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SRC_DIR}/.." && pwd)"
PASSED=0
FAILED=0

pass() { echo "✓ $1"; PASSED=$((PASSED + 1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED + 1)); }

echo "=========================================="
echo "wscode Test Suite v0.3"
echo "=========================================="

# Test: Directory structure
for dir in src/lib src/templates src/scripts config state; do
    [[ -d "${ROOT_DIR}/${dir}" ]] && pass "Directory: $dir" || fail "Directory: $dir"
done

# Test: Required files
for f in VERSION CHANGELOG.md README.md Dockerfile.test .dockerignore src/setup.sh src/test.sh src/lib/common.sh src/lib/preflight.sh src/lib/install.sh src/lib/users.sh src/lib/services.sh src/lib/acl.sh src/lib/cloudflared.sh src/lib/verify.sh src/lib/rollback.sh src/templates/code-server@.service.tpl src/templates/code-server@.override-hardening.conf.tpl src/templates/cloudflared.override-hardening.conf.tpl src/scripts/docker-test.sh src/scripts/docker-smoke.sh config/users.allow config/users.deny config/settings.env.example; do
    [[ -f "${ROOT_DIR}/${f}" ]] && pass "File: $f" || fail "File: $f"
done

# Test: Script syntax
for s in src/setup.sh src/test.sh src/lib/*.sh src/scripts/*.sh; do
    bash -n "${ROOT_DIR}/${s}" 2>/dev/null && pass "Syntax: $s" || fail "Syntax: $s"
done

# Test: Version information
if [[ -f "${ROOT_DIR}/VERSION" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/VERSION"
    [[ "${VERSION}" == "0.3.0" ]] && pass "Version: $VERSION" || fail "Version mismatch"
else
    fail "VERSION file missing"
fi

# Test: Template variables
if grep -q "{{CODESERVER_BIN}}" "${ROOT_DIR}/src/templates/code-server@.service.tpl"; then
    pass "Template substitution variable present"
else
    fail "Template missing {{CODESERVER_BIN}}"
fi

# Test: core features
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

# Test: Setup help
if bash "${ROOT_DIR}/src/setup.sh" --help &>/dev/null; then
    pass "src/setup.sh --help works"
else
    fail "src/setup.sh --help fails"
fi

echo ""
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] && { echo "✅ All tests passed!"; exit 0; } || { echo "❌ Some tests failed!"; exit 1; }
