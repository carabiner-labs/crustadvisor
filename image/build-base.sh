#!/usr/bin/env bash
# Build the clean CrustAdvisor base image, point :latest at it, and generate
# signed SLSA provenance for it. The provenance is what the image gate checks
# before the app is built on the base: a hijacked :latest has a different
# digest, with no provenance from our builder, so the gate refuses it.
#
# Locally the provenance is signed with a key in build/ (offline, repeatable);
# in CI it is keyless with the workflow's OIDC identity, like the model.
#
#   image/build-base.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
IMAGE="${IMAGE:-crustadvisor/base}"
ATT="$BUILD_DIR/image-attestations"
KEY="$BUILD_DIR/image-signing-key.pem"; PUB="$BUILD_DIR/image-signing-key.pub"
ATTESTER="${ATTESTER:-$BUILD_DIR/bin/slsa-attester}"
BUILD_TYPE="https://github.com/carabiner-labs/crustadvisor/image/base@v1"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
command -v docker >/dev/null || { echo "error: docker is required" >&2; exit 1; }
[ -x "$ATTESTER" ] || { echo "error: slsa-attester not at $ATTESTER (model/provenance.sh fetches it)" >&2; exit 1; }

log "Building $IMAGE:clean"
docker build -q -t "$IMAGE:clean" "$ROOT/image/base" >/dev/null
docker tag "$IMAGE:clean" "$IMAGE:latest"
DIGEST="$(docker image inspect "$IMAGE:clean" --format '{{.Id}}')"
log "Base $IMAGE:clean is $DIGEST, tagged :latest"

# Builder identity and signing: CI is keyless with the workflow; local uses a key.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  BUILDER="${GITHUB_SERVER_URL}/${GITHUB_WORKFLOW_REF}"
  SIGN_ARGS=()   # keyless sigstore (ambient OIDC)
else
  BUILDER="${BUILDER_ID:-https://localhost/crustadvisor/image-build}"
  [ -f "$KEY" ] || { log "generating a local image signing key"; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY" 2>/dev/null; openssl pkey -in "$KEY" -pubout -out "$PUB" 2>/dev/null; }
  SIGN_ARGS=(-K "$KEY")
fi

mkdir -p "$ATT"
log "Signing SLSA provenance for the base image (builder $BUILDER)"
"$ATTESTER" build -s "$DIGEST" \
  --build-type "$BUILD_TYPE" --builder-id "$BUILDER" \
  "${SIGN_ARGS[@]}" -o "$ATT/base-provenance.bundle.json"
log "wrote $ATT/base-provenance.bundle.json"
