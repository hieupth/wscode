#!/bin/bash
# docker-test.sh - Build and run Docker tests
#
# Builds the Docker image and runs smoke tests inside a container.
# Supports both Debian and Manjaro images via IMAGE_TAG variable.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-webcode:test}"
DOCKERFILE="${DOCKERFILE:-Dockerfile.debian}"
CREDS_FILE="/Users/hieupth/.cloudflared/7247b811-7392-435f-bb8f-ddb4aea79850.json"

cd "$ROOT_DIR"

echo "[docker-test] Building image: $IMAGE_TAG"
docker build -f "$DOCKERFILE" -t "$IMAGE_TAG" .

echo "[docker-test] Running smoke tests in container"
if [[ -f "$CREDS_FILE" ]]; then
  docker run --rm \
    -v "${CREDS_FILE}:/etc/webcode/creds.json:ro" \
    "$IMAGE_TAG"
else
  echo "[docker-test] Warning: Credentials file not found at $CREDS_FILE"
  docker run --rm "$IMAGE_TAG"
fi

echo "[docker-test] Completed successfully"
