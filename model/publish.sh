#!/usr/bin/env bash
# Publish the model as an OCI artifact and its signatures to the GitHub
# attestation store.
#
# The artifact holds the GGUF, build-info.json and every attestation in
# build/attestations (the signed .bundle.json files when sign.sh ran, the
# unsigned .intoto.json statements otherwise), so one `oras pull` gives the
# laptop everything model-admit needs, offline. In GitHub Actions the signed
# bundles are also pushed to the repository's attestation store, where
# ampel's `github:` collector can read them without pulling the model.
#
#   IMAGE        OCI repository          (ghcr.io/carabiner-labs/crustadvisor/model)
#   TAG          tag to push             (short git sha)
#   PUSH_LATEST  also tag it `latest`    (0)
#   ORAS_FLAGS   extra flags for oras    (e.g. --plain-http for a local registry)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
IMAGE="${IMAGE:-ghcr.io/carabiner-labs/crustadvisor/model}"
TAG="${TAG:-$(git -C "$ROOT" rev-parse --short HEAD)}"
PUSH_LATEST="${PUSH_LATEST:-0}"
read -r -a ORAS_FLAGS <<< "${ORAS_FLAGS:-}"
MODEL=crustadvisor-q4_k_m.gguf

log() { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
command -v oras >/dev/null || { echo "error: oras is required (brew install oras)" >&2; exit 1; }
[ -f "$BUILD_DIR/$MODEL" ] || { echo "error: $BUILD_DIR/$MODEL missing, run make model" >&2; exit 1; }

cd "$BUILD_DIR"
FILES=("$MODEL:application/vnd.gguf" "build-info.json:application/json")
SIGNED=0
for f in attestations/*.bundle.json; do [ -f "$f" ] && { FILES+=("$f:application/vnd.dev.sigstore.bundle.v0.3+json"); SIGNED=1; }; done
for f in attestations/*.jsonl; do [ -f "$f" ] && { FILES+=("$f:application/x-ndjson"); SIGNED=1; }; done
if [ "$SIGNED" = 0 ]; then
  log "no signed bundles in attestations/, publishing the unsigned statements"
  for f in attestations/*.intoto.json; do FILES+=("$f:application/vnd.in-toto+json"); done
fi
[ -f vsa.intoto.json ] && FILES+=("vsa.intoto.json:application/vnd.in-toto+json")

log "Pushing $IMAGE:$TAG (${#FILES[@]} files)"
oras push "${ORAS_FLAGS[@]}" "$IMAGE:$TAG" \
  --artifact-type application/vnd.crustadvisor.model.v1 \
  --annotation "org.opencontainers.image.source=https://github.com/carabiner-labs/crustadvisor" \
  --annotation "org.opencontainers.image.revision=$(git -C "$ROOT" rev-parse HEAD)" \
  --annotation "dev.crustadvisor.model.sha256=$(shasum -a 256 "$MODEL" | cut -c1-64)" \
  "${FILES[@]}"
if [ "$PUSH_LATEST" = 1 ]; then
  oras tag "${ORAS_FLAGS[@]}" "$IMAGE:$TAG" latest
  log "tagged latest"
fi

if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$SIGNED" = 1 ]; then
  command -v bnd >/dev/null || { echo "error: bnd is required to push to the attestation store" >&2; exit 1; }
  log "Pushing signed bundles to the $GITHUB_REPOSITORY attestation store"
  # bnd push takes one bundle at a time, so a jsonl is unpacked first.
  UNPACKED="$(mktemp -d)"
  for f in attestations/*.bundle.json; do [ -f "$f" ] && cp "$f" "$UNPACKED/"; done
  for f in attestations/*.jsonl; do [ -f "$f" ] && (cd "$UNPACKED" && bnd unpack --prefix "$(basename "$f" .jsonl)-" "$OLDPWD/$f"); done
  for f in "$UNPACKED"/*.json; do bnd push github "$GITHUB_REPOSITORY" "$f"; done
  rm -rf "$UNPACKED"
fi
log "Published $IMAGE:$TAG"
