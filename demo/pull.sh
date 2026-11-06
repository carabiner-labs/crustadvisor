#!/usr/bin/env bash
# Pull the published model and its attestations, make them the known-good
# build and run the gate. The "pull the signed model again" beat.
#
#   demo/pull.sh [REF]     default ghcr.io/carabiner-labs/crustadvisor/model:latest
#   ORAS_FLAGS=--plain-http demo/pull.sh 127.0.0.1:5055/crustadvisor/model:test
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
REF="${1:-ghcr.io/carabiner-labs/crustadvisor/model:latest}"
read -r -a ORAS_FLAGS <<< "${ORAS_FLAGS:-}"
cd "$ROOT"

log() { printf '\033[1;36m⬇️  %s\033[0m\n' "$*" >&2; }
command -v oras >/dev/null || { echo "error: oras is required (brew install oras)" >&2; exit 1; }

pkill -f "demo/serve.sh" 2>/dev/null || true
pkill -f "llama-server" 2>/dev/null || true
pkill -f "uvicorn main:app" 2>/dev/null || true

log "Pulling $REF"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/attestations" "$BUILD_DIR/vsa.intoto.json"
oras pull "${ORAS_FLAGS[@]}" "$REF" -o "$BUILD_DIR"
log "Model $(shasum -a 256 "$BUILD_DIR/crustadvisor-q4_k_m.gguf" | cut -c1-12), $(ls "$BUILD_DIR"/attestations | wc -l | tr -d ' ') attestation files"

demo/reset.sh --save
demo/reset.sh
