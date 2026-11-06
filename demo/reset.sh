#!/usr/bin/env bash
# One command back to a clean, admitted model. Run it before the talk, between
# rehearsals, and whenever the PPM has been at the files.
#
#   demo/reset.sh            stop servers, restore the known-good build, verify
#   demo/reset.sh --save     snapshot the current build as the known-good state
#                            (make model does this after every clean build)
#   demo/reset.sh --rebuild  rebuild from the pinned snapshot instead of restoring
#
# Known-good state lives in build/pristine/: the GGUF, build-info.json, the
# attestations directory and the VSA. Servers are stopped first: a llama-server
# that keeps an old file mapped answers garbage once the file changes under it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
PRISTINE="$BUILD/pristine"
MODEL=crustadvisor-q4_k_m.gguf
cd "$ROOT"

log() { printf '\033[1;32m♻️  %s\033[0m\n' "$*" >&2; }

stop_servers() {
  pkill -f "demo/serve.sh" 2>/dev/null || true
  pkill -f "llama-server" 2>/dev/null || true
  pkill -f "uvicorn main:app" 2>/dev/null || true
  sleep 0.5
}

back_to_clean() {
  # Act 1 runs on the demo branch between the stage refs; anywhere else the
  # most that gets undone is a PPM commit on top of HEAD.
  if [ "$(git branch --show-current)" = "demo" ] && git rev-parse --verify -q stage/clean >/dev/null; then
    demo/stage.sh clean
  else
    attack/ppm-commit.sh --undo
  fi
}

save() {
  [ -f "$BUILD/$MODEL" ] || { echo "nothing to save: $BUILD/$MODEL missing (run make model)" >&2; exit 1; }
  if attack/ppm-tamper.py "$BUILD/$MODEL" --check >/dev/null 2>&1; then :; else
    echo "refusing to save a tampered model as pristine (🍍 found)" >&2; exit 1
  fi
  rm -rf "$PRISTINE"; mkdir -p "$PRISTINE"
  cp -p "$BUILD/$MODEL" "$BUILD/build-info.json" "$PRISTINE/"
  cp -Rp "$BUILD/attestations" "$PRISTINE/attestations"
  [ -f "$BUILD/vsa.intoto.json" ] && cp -p "$BUILD/vsa.intoto.json" "$PRISTINE/" || true
  log "saved known-good build to $PRISTINE ($(shasum -a 256 "$BUILD/$MODEL" | cut -c1-12))"
}

restore() {
  if [ ! -f "$PRISTINE/$MODEL" ]; then
    log "no pristine build, building from the pinned snapshot"
    make -s model
    return
  fi
  cp -p "$PRISTINE/$MODEL" "$BUILD/$MODEL"
  cp -p "$PRISTINE/build-info.json" "$BUILD/build-info.json"
  rm -rf "$BUILD/attestations"; cp -Rp "$PRISTINE/attestations" "$BUILD/attestations"
  rm -rf "$BUILD/ppm-snapshot" "$BUILD/enriched" "$BUILD"/*.ppm-tmp "$BUILD"/t.gguf "$BUILD"/tampered*.gguf
  rm -f "$BUILD/admit-status.json"
  log "restored $MODEL ($(shasum -a 256 "$BUILD/$MODEL" | cut -c1-12)) and its attestations"
}

verify() {
  local flags=(--no-serve)
  local signed=()
  shopt -s nullglob; signed=("$BUILD"/attestations/*.bundle.json "$BUILD"/attestations/*.jsonl); shopt -u nullglob
  [ ${#signed[@]} -gt 0 ] || flags+=(--rehearsal)
  admit/model-admit "${flags[@]}" 2>&1 | grep -E "🚦|Status: ●|🟢|🔴" | tr -s ' ' >&2
}

case "${1:-}" in
  --save) save ;;
  --rebuild) stop_servers; rm -rf "$PRISTINE"; make -s model; verify ;;
  "") stop_servers; back_to_clean; attack/ppm-image.sh --undo >/dev/null 2>&1 || true; rm -f "$BUILD/source-status.json" "$BUILD/image-status.json"; restore; verify ;;
  *) echo "usage: demo/reset.sh [--save|--rebuild]" >&2; exit 2 ;;
esac
