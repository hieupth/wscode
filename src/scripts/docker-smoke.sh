#!/bin/bash
# docker-smoke.sh - Smoke test for Docker containers
#
# Runs syntax checks, the test suite, and a dry-run installation
# inside a Docker container. The cloudflared credentials are mounted
# as a read-only volume for realistic config validation.
set -euo pipefail

ROOT_DIR="/workspace"
cd "$ROOT_DIR"

echo "[docker-smoke] Running shell syntax checks..."
for s in src/setup.sh src/test.sh src/lib/*.sh src/scripts/*.sh; do
  bash -n "$s" || { echo "[docker-smoke] FAIL: Syntax error in $s"; exit 1; }
done
echo "[docker-smoke] Syntax checks passed"

echo "[docker-smoke] Running local test suite..."
bash src/test.sh

echo "[docker-smoke] Preparing runtime config for dry-run..."
mkdir -p /etc/webcode

# Copy the example config and set up for dry-run
cp -f config/settings.env.example /etc/webcode/config.env
chmod 600 /etc/webcode/config.env
chown root:root /etc/webcode/config.env

# Handle credentials file.
# The mounted file may have host ownership/permissions that don't pass
# assert_secure_file(). Copy to a local file with correct permissions.
if [[ -f /etc/webcode/creds.json ]]; then
  cp /etc/webcode/creds.json /etc/webcode/creds.local.json
  chmod 600 /etc/webcode/creds.local.json
  chown root:root /etc/webcode/creds.local.json
  sed -i 's|CF_CREDENTIALS_FILE=.*|CF_CREDENTIALS_FILE="/etc/webcode/creds.local.json"|' /etc/webcode/config.env
fi

cat > /etc/webcode/users.allow <<'EOF'
root
EOF
chmod 644 /etc/webcode/users.allow
chown root:root /etc/webcode/users.allow

echo "[docker-smoke] Running installer in dry-run mode (CI-safe)..."
WEBCODE_SKIP_SYSTEMD_CHECK=1 \
WEBCODE_SKIP_NETWORK_CHECK=1 \
bash src/setup.sh --dry-run

echo "[docker-smoke] Done."
