#!/bin/bash
# docker-test.sh - Build and run Docker tests
#
# Builds the Docker image and runs real smoke tests inside a container.
# By default runs BOTH Manjaro and Debian. Set DOCKERFILE to run one only.
# Config is read from settings.env at the project root.
# Credentials are mounted from the host machine.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-webcode:test}"

# Resolve config from settings.env
SETTINGS_FILE="${ROOT_DIR}/settings.env"
CREDS_FILE="${CREDS_FILE:-}"

cd "$ROOT_DIR"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "[docker-test] ERROR: settings.env not found at $SETTINGS_FILE"
  exit 1
fi

# Source settings.env (strip comments and blank lines)
eval "$(grep -v '^\s*#' "$SETTINGS_FILE" | grep -v '^\s*$')"

# Resolve credentials file: env var > settings.env > default
CREDS_FILE="${CREDS_FILE:-${CF_CREDENTIALS_FILE:-$HOME/.cloudflared/creds.json}}"

echo "[docker-test] Loaded config from settings.env:"
echo "[docker-test]   CF_TUNNEL_NAME=${CF_TUNNEL_NAME}"
echo "[docker-test]   CF_DOMAIN_BASE=${CF_DOMAIN_BASE}"
echo "[docker-test]   CF_ZONE_ID=${CF_ZONE_ID}"

# Determine which Dockerfiles to test
if [[ -n "${DOCKERFILE:-}" ]]; then
  DOCKERFILES=("$DOCKERFILE")
else
  DOCKERFILES=("Dockerfile.manjaro" "Dockerfile.debian")
fi

# Build docker run args (shared across platforms)
RUN_ARGS=(--rm)
RUN_ARGS+=(-e "CF_API_TOKEN=${CF_API_TOKEN}")
RUN_ARGS+=(-e "CF_ZONE_ID=${CF_ZONE_ID}")
RUN_ARGS+=(-e "CF_TUNNEL_NAME=${CF_TUNNEL_NAME}")
RUN_ARGS+=(-e "CF_DOMAIN_BASE=${CF_DOMAIN_BASE}")

# Mount credentials if available
if [[ -f "$CREDS_FILE" ]]; then
  RUN_ARGS+=(--mount "type=bind,source=${CREDS_FILE},target=/run/secrets/creds.json,readonly")
  echo "[docker-test] Credentials mounted from: $CREDS_FILE"
else
  echo "[docker-test] WARNING: Credentials not found at $CREDS_FILE"
  echo "[docker-test] Phase 4-5 (cloudflared config + integration) will be skipped"
fi

# Run tests for each platform
OVERALL_EXIT=0

for df in "${DOCKERFILES[@]}"; do
  echo ""
  echo "============================================"
  echo "[docker-test] Testing: $df"
  echo "============================================"

  if [[ ! -f "$ROOT_DIR/$df" ]]; then
    echo "[docker-test] ERROR: $df not found"
    OVERALL_EXIT=1
    continue
  fi

  echo "[docker-test] Building image: ${IMAGE_TAG} ($df)"
  docker build -f "$df" -t "$IMAGE_TAG" .

  echo "[docker-test] Running real smoke tests"
  if docker run --dns 1.1.1.1 --dns 8.8.8.8 "${RUN_ARGS[@]}" "$IMAGE_TAG"; then
    echo "[docker-test] $df PASSED"
  else
    echo "[docker-test] $df FAILED"
    OVERALL_EXIT=1
  fi
done

echo ""
echo "============================================"
if [[ $OVERALL_EXIT -eq 0 ]]; then
  echo "[docker-test] All platforms passed!"
else
  echo "[docker-test] Some platforms failed!"
fi
echo "============================================"

exit $OVERALL_EXIT
