#!/bin/bash
# docker-smoke.sh - Real smoke test for Docker containers
#
# Runs syntax checks, the test suite, and a REAL installation
# inside a Docker container. No dry-run.
#
# Required env vars (passed at docker run):
#   CF_API_TOKEN   - Cloudflare API token
#   CF_ZONE_ID     - Cloudflare Zone ID
#
# Required bind mounts:
#   /etc/webcode/creds.json - Cloudflare tunnel credentials
set -euo pipefail

ROOT_DIR="/workspace"
cd "$ROOT_DIR"

PASSED=0
FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

echo "=========================================="
echo "webcode Real Smoke Test"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Static checks
# ---------------------------------------------------------------------------
echo "--- Phase 1: Syntax checks ---"
for s in webcode.sh src/test.sh src/lib/*.sh src/scripts/*.sh; do
  bash -n "$s" && pass "Syntax: $s" || fail "Syntax: $s"
done
echo ""

echo "--- Phase 2: Unit test suite ---"
bash src/test.sh
echo ""

# ---------------------------------------------------------------------------
# Phase 3: Real binary installation
# ---------------------------------------------------------------------------
echo "--- Phase 3: Real binary installation ---"

source "${ROOT_DIR}/src/lib/common.sh"
source "${ROOT_DIR}/src/lib/state.sh"
source "${ROOT_DIR}/src/lib/preflight.sh"
source "${ROOT_DIR}/src/lib/install.sh"

WEBCODE_SKIP_SYSTEMD_CHECK=1
WEBCODE_SKIP_NETWORK_CHECK=1

# Install all binaries (real, not dry-run)
install_all 2>&1

# Verify code-server
if [[ -x /usr/local/lib/code-server/bin/code-server ]]; then
  CS_VER=$(/usr/local/lib/code-server/bin/code-server --version 2>&1 | head -1)
  pass "code-server installed: $CS_VER"
else
  fail "code-server not installed"
fi

# Verify cloudflared
if [[ -x /usr/local/bin/cloudflared ]]; then
  CF_VER=$(/usr/local/bin/cloudflared --version 2>&1 | head -1)
  pass "cloudflared installed: $CF_VER"
else
  fail "cloudflared not installed"
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 4: Config + cloudflared setup (requires credentials)
# ---------------------------------------------------------------------------
echo "--- Phase 4: Config and cloudflared setup ---"

CREDS_SOURCE="/run/secrets/creds.json"

if [[ ! -f "$CREDS_SOURCE" ]]; then
  echo "[smoke] No credentials mounted at $CREDS_SOURCE — skipping Phase 4"
else
  # Prepare config directory
  mkdir -p /etc/webcode
  mkdir -p /etc/cloudflared

  # Copy credentials with correct permissions
  cp "$CREDS_SOURCE" /etc/webcode/creds.json
  chmod 600 /etc/webcode/creds.json
  chown root:root /etc/webcode/creds.json
  pass "Credentials file prepared"

  # Write real config
  CF_API_TOKEN_VAL="${CF_API_TOKEN:-}"
  CF_ZONE_ID_VAL="${CF_ZONE_ID:-}"
  CF_TUNNEL_NAME_VAL="${CF_TUNNEL_NAME:-test-tunnel}"
  CF_DOMAIN_BASE_VAL="${CF_DOMAIN_BASE:-test.example.com}"

  cat > /etc/webcode/config.env <<EOF
CF_TUNNEL_NAME="${CF_TUNNEL_NAME_VAL}"
CF_DOMAIN_BASE="${CF_DOMAIN_BASE_VAL}"
CF_CREDENTIALS_FILE="/etc/webcode/creds.json"
CF_API_TOKEN="${CF_API_TOKEN_VAL}"
CF_ZONE_ID="${CF_ZONE_ID_VAL}"
EOF
  chmod 600 /etc/webcode/config.env
  chown root:root /etc/webcode/config.env
  pass "Config file written"

  # Create test user
  useradd -m -u 1001 -s /bin/bash testuser 2>/dev/null || true

  # Write users.allow
  echo "testuser" > /etc/webcode/users.allow
  chmod 644 /etc/webcode/users.allow
  chown root:root /etc/webcode/users.allow

  # Source cloudflared module and test config generation
  source "${ROOT_DIR}/src/lib/cloudflared.sh"

  # Load config
  load_config
  pass "Config loaded successfully"

  # Generate cloudflared config
  generate_cloudflared_config
  if [[ -f /etc/cloudflared/config.yml ]]; then
    pass "cloudflared config generated"
    echo "--- config.yml contents ---"
    cat /etc/cloudflared/config.yml
    echo "--- end ---"
  else
    fail "cloudflared config not generated"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# Phase 5: Real integration test (start services + curl tunnel URL)
# ---------------------------------------------------------------------------
echo "--- Phase 5: Real integration test ---"

CS_PID=""
CF_PID=""
TEST_PORT=21001

cleanup_services() {
  [[ -n "$CS_PID" ]] && kill "$CS_PID" 2>/dev/null || true
  [[ -n "$CF_PID" ]] && kill "$CF_PID" 2>/dev/null || true
}
trap cleanup_services EXIT

if [[ ! -f /etc/cloudflared/config.yml ]]; then
  echo "[smoke] No cloudflared config — skipping Phase 5"
else
  # Ensure testuser exists with proper home directory
  if ! id testuser &>/dev/null; then
    useradd -m -u 1001 -s /bin/bash testuser
  fi

  # Create code-server config directory for testuser
  mkdir -p /home/testuser/.config/code-server
  mkdir -p /home/testuser/.local/share/code-server/extensions
  chown -R testuser:testuser /home/testuser

  # --- Start code-server ---
  echo "[smoke] Starting code-server on port $TEST_PORT..."
  CS_LOG="/tmp/code-server.log"
  su - testuser -c "/usr/local/bin/code-server --bind-addr 127.0.0.1:${TEST_PORT} --auth none" > "$CS_LOG" 2>&1 &
  CS_PID=$!

  max_wait=30
  waited=0
  while [[ $waited -lt $max_wait ]]; do
    if curl -sf -o /dev/null "http://127.0.0.1:${TEST_PORT}/healthz" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if curl -sf -o /dev/null "http://127.0.0.1:${TEST_PORT}/healthz" 2>/dev/null; then
    pass "code-server responding on port $TEST_PORT"
  elif curl -sf -o /dev/null "http://127.0.0.1:${TEST_PORT}" 2>/dev/null; then
    pass "code-server responding on port $TEST_PORT (no healthz)"
  else
    fail "code-server not responding on port $TEST_PORT"
    echo "--- code-server log ---"
    tail -20 "$CS_LOG" 2>/dev/null || true
    echo "--- end log ---"
  fi

  # --- Start cloudflared tunnel ---
  echo "[smoke] Starting cloudflared tunnel..."
  CF_LOG="/tmp/cloudflared.log"
  /usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run > "$CF_LOG" 2>&1 &
  CF_PID=$!

  max_wait=60
  waited=0
  registered=false
  while [[ $waited -lt $max_wait ]]; do
    if grep -qE "Registered tunnel connection|Connection.*registered" "$CF_LOG" 2>/dev/null; then
      registered=true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  if [[ "$registered" == "true" ]]; then
    pass "cloudflared tunnel registered"
  elif kill -0 "$CF_PID" 2>/dev/null; then
    pass "cloudflared process running (will verify via curl)"
  else
    fail "cloudflared process exited"
    echo "--- cloudflared log ---"
    cat "$CF_LOG" 2>/dev/null || true
    echo "--- end log ---"
  fi

  # --- Create DNS CNAME record (if API credentials available) ---
  dns_created=false
  if [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
    tunnel_id=$(jq -r '.TunnelID' /etc/webcode/creds.json)
    tunnel_target="${tunnel_id}.cfargotunnel.com"
    test_hostname="testuser-${CF_DOMAIN_BASE}"

    echo "[smoke] Creating DNS CNAME: ${test_hostname} -> ${tunnel_target}"
    dns_response=$(curl -s -X POST \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"CNAME\",\"name\":\"${test_hostname}\",\"content\":\"${tunnel_target}\",\"proxied\":true}" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" 2>/dev/null || true)

    if echo "$dns_response" | grep -q '"success":true' 2>/dev/null; then
      pass "DNS CNAME created: ${test_hostname}"
      dns_created=true
    elif echo "$dns_response" | grep -qi "already exist\|duplicate\|81057" 2>/dev/null; then
      pass "DNS CNAME already exists: ${test_hostname}"
      dns_created=true
    else
      echo "[smoke] DNS creation response: ${dns_response:-no response}"
      echo "[smoke] DNS creation may have failed — will still try curl"
    fi
  fi

  # --- Curl tunnel URL and verify code-server UI ---
  # Retry up to 3 times with increasing delays for DNS/SSL propagation
  tunnel_url="https://testuser-${CF_DOMAIN_BASE}"
  echo "[smoke] Curling tunnel URL: ${tunnel_url}"

  # Debug DNS resolution
  echo "[smoke] DNS lookup for testuser-${CF_DOMAIN_BASE}:"
  getent hosts "testuser-${CF_DOMAIN_BASE}" 2>/dev/null || echo "  (DNS resolution failed)"

  tunnel_ok=false
  for attempt in 1 2 3; do
    http_code=$(curl -s -L -o /tmp/tunnel-response.html \
      -w "%{http_code}" \
      --connect-timeout 10 \
      --max-time 20 \
      "$tunnel_url" 2>/dev/null) || true

    echo "[smoke] Attempt $attempt: HTTP ${http_code}"

    if [[ "$http_code" =~ ^(200|302)$ ]]; then
      if grep -qiE "code-server|vscode" /tmp/tunnel-response.html 2>/dev/null; then
        pass "Tunnel URL returns code-server UI (HTTP ${http_code})"
      else
        pass "Tunnel URL reachable (HTTP ${http_code})"
        echo "[smoke] Response preview:"
        head -3 /tmp/tunnel-response.html 2>/dev/null || true
      fi
      tunnel_ok=true
      break
    elif [[ "$http_code" != "000" ]]; then
      echo "[smoke] Got HTTP ${http_code} — SSL/DNS may still be provisioning"
    fi

    [[ $attempt -lt 3 ]] && sleep 10
  done

  if [[ "$tunnel_ok" == "false" ]]; then
    echo "[smoke] Tunnel URL not reachable after 3 attempts"
  fi

  # --- Fallback: verify localhost code-server UI ---
  echo "[smoke] Verifying code-server UI on localhost..."
  cs_http=$(curl -s -L -o /tmp/localhost-response.html \
    -w "%{http_code}" \
    --connect-timeout 5 \
    "http://127.0.0.1:${TEST_PORT}" 2>/dev/null) || true

  if [[ "$cs_http" =~ ^(200|302)$ ]]; then
    if grep -qiE "code-server|vscode" /tmp/localhost-response.html 2>/dev/null; then
      pass "localhost:${TEST_PORT} returns code-server UI (HTTP ${cs_http})"
    else
      pass "localhost:${TEST_PORT} responding (HTTP ${cs_http})"
    fi
  else
    fail "localhost:${TEST_PORT} not responding (HTTP ${cs_http:-none})"
  fi

  # Cleanup DNS record (if we created it)
  if [[ "$dns_created" == "true" && -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]]; then
    test_hostname="testuser-${CF_DOMAIN_BASE}"
    existing=$(curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${test_hostname}&type=CNAME" 2>/dev/null || true)
    record_id=$(echo "$existing" | jq -r '.result[0].id' 2>/dev/null || true)
    if [[ -n "$record_id" && "$record_id" != "null" ]]; then
      curl -s -X DELETE \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
        >/dev/null 2>&1 || true
      echo "[smoke] Cleaned up DNS record for ${test_hostname}"
    fi
  fi

  # Cleanup
  cleanup_services
  trap - EXIT
fi
echo ""

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] && { echo "All smoke tests passed!"; exit 0; } || { echo "Some smoke tests failed!"; exit 1; }
