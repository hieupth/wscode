#!/bin/bash
set -euo pipefail

ROOT_DIR="/workspace"
cd "$ROOT_DIR"

echo "[docker-smoke] Running shell syntax checks..."
bash -n src/setup.sh src/test.sh src/lib/*.sh src/scripts/*.sh

echo "[docker-smoke] Running local test suite..."
bash src/test.sh

echo "[docker-smoke] Preparing runtime config for dry-run..."
mkdir -p /etc/wscode
cp -f config/settings.env.example /etc/wscode/config.env
chmod 600 /etc/wscode/config.env
chown root:root /etc/wscode/config.env

cat > /etc/wscode/users.allow <<'EOF'
root
EOF
chmod 644 /etc/wscode/users.allow
chown root:root /etc/wscode/users.allow

echo "[docker-smoke] Running installer in dry-run mode (CI-safe)..."
WSCODE_SKIP_SYSTEMD_CHECK=1 \
WSCODE_SKIP_NETWORK_CHECK=1 \
bash src/setup.sh --dry-run

echo "[docker-smoke] Done."
