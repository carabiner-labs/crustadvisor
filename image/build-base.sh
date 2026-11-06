#!/usr/bin/env bash
# Build the clean CrustAdvisor base image and point the :latest tag at it.
# (Provenance generation is added by a later step.)
#
#   image/build-base.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-crustadvisor/base}"
log() { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }

log "Building $IMAGE:clean"
docker build -q -t "$IMAGE:clean" "$ROOT/image/base" >/dev/null
docker tag "$IMAGE:clean" "$IMAGE:latest"
DIGEST="$(docker image inspect "$IMAGE:clean" --format '{{.Id}}')"
log "Base $IMAGE:clean is $DIGEST, tagged :latest"
