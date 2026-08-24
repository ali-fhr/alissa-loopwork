#!/bin/bash
# Build-and-smoke the base image locally (same steps CI runs):
#   tests/run.sh [image-tag]
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${1:-alissa-loopwork-base:smoke}"
docker build -t "$IMAGE" .
# --entrypoint overrides the stub (which exits 1 by design); the smoke script
# is mounted, not baked — the base image ships no test files.
docker run --rm \
    --entrypoint /bin/bash \
    -v "$(pwd)/tests/smoke.sh:/smoke.sh:ro" \
    "$IMAGE" /smoke.sh
