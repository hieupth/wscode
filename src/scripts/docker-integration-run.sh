#!/bin/bash
# docker-integration-run.sh - Build and run Docker integration test
#
# Builds the test image and runs the integration test container with
# cloudflared credentials mounted as a read-only secret.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-webcode:integration-test}"
CREDS_FILE="${CREDS_FILE:?CREDS_FILE is required (path to cloudflared credential JSON)}"
CF_TUNNEL_NAME="${CF_TUNNEL_NAME:?CF_TUNNEL_NAME is required}"
CF_DOMAIN_BASE="${CF_DOMAIN_BASE:?CF_DOMAIN_BASE is required}"
CF_TUNNEL_ID="${CF_TUNNEL_ID:?CF_TUNNEL_ID is required}"

cd "$ROOT_DIR"

# Verify credential file exists
if [[ ! -f "$CREDS_FILE" ]]; then
  echo "[integration-run] ERROR: Credential file not found: $CREDS_FILE"
  exit 1
fi

echo "[integration-run] Building image: $IMAGE_TAG"
docker build -f Dockerfile.test -t "$IMAGE_TAG" .

echo "[integration-run] Running integration test"
docker run --rm \
  -e CF_TUNNEL_NAME \
  -e CF_DOMAIN_BASE \
  -e CF_TUNNEL_ID \
  --mount type=bind,source="${CREDS_FILE}",target=/run/secrets/cloudflared-creds.json,readonly \
  "$IMAGE_TAG"

echo "[integration-run] Completed"
