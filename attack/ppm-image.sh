#!/usr/bin/env bash
# 🍍 Pineapple Pizza Mafia act 3: the base-image tag hijack.
#
# The app's code is clean and the build is unchanged. The PPM builds its own
# base image and repoints crustadvisor/base:latest at it. The next app build,
# FROM crustadvisor/base:latest, picks it up. The running site is defaced and
# the PPM's calling card rides in a layer.
#
#   attack/ppm-image.sh          build the evil base, hijack :latest
#   attack/ppm-image.sh --undo   point :latest back at the clean base
#   attack/ppm-image.sh --show   print the defacement the evil base injects
#   attack/ppm-image.sh --check  exit 1 if :latest is the evil base
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-crustadvisor/base}"
log() { printf '\033[1;35m🍍 %s\033[0m\n' "$*" >&2; }
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }

evil_id() { docker image inspect "$IMAGE:evil" --format '{{.Id}}' 2>/dev/null || echo none; }
latest_id() { docker image inspect "$IMAGE:latest" --format '{{.Id}}' 2>/dev/null || echo none; }

case "${1:-}" in
  --show) cat "$ROOT/image/base/ppm-deface.html"; exit 0 ;;
  --check)
    if [ "$(latest_id)" = "$(evil_id)" ] && [ "$(evil_id)" != none ]; then
      echo "$IMAGE:latest is 🍍 the evil base"; exit 1
    fi
    echo "$IMAGE:latest is not the evil base"; exit 0 ;;
  --undo)
    docker image inspect "$IMAGE:clean" >/dev/null 2>&1 || { echo "no $IMAGE:clean to restore; run image/build-base.sh" >&2; exit 1; }
    docker tag "$IMAGE:clean" "$IMAGE:latest"
    log "restored: $IMAGE:latest points back at the clean base"
    exit 0 ;;
esac

log "Building the evil base $IMAGE:evil"
docker build -q -t "$IMAGE:evil" -f "$ROOT/image/base/Dockerfile.evil" "$ROOT/image/base" >/dev/null
docker tag "$IMAGE:evil" "$IMAGE:latest"
log "hijacked: $IMAGE:latest now points at the evil base ($(evil_id))"
log "rebuild and redeploy the app to serve it (make serve, or demo/serve.sh)"
