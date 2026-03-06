#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-wscode:test}"

cd "$ROOT_DIR"

echo "[docker-test] Building image: $IMAGE_TAG"
docker build -f Dockerfile.test -t "$IMAGE_TAG" .

echo "[docker-test] Running smoke tests in container"
docker run --rm "$IMAGE_TAG"

echo "[docker-test] Completed successfully"
