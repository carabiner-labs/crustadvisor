#!/usr/bin/env bash
# CrustAdvisor model build: pull the pinned Hugging Face snapshot, enrich it
# with the AI Pizzaiolo persona, convert to GGUF and quantize.
#
# This is the "build" that the SLSA provenance describes. Its one material is
# $HF_REPO at $HF_REVISION; its one output is build/crustadvisor-q4_k_m.gguf.
#
# Everything is overridable through the environment (the PPM typosquat attack
# in attack/ relies on that):
#
#   HF_REPO            Hugging Face repo              (Qwen/Qwen2.5-1.5B-Instruct)
#   HF_REVISION        commit SHA to pin              (989aa79...)
#   HF_SNAPSHOT_DIR    use this local snapshot instead of downloading
#   LLAMA_CPP_VERSION  llama.cpp tag for converter    (v0.9.0)
#   QUANT              llama-quantize type            (Q4_K_M)
#   OUT_NAME           output file stem               (crustadvisor)
#   BUILD_DIR          work + output directory        (<repo>/build)
#   PYTHON_VERSION     interpreter for the converter  (3.12)
set -euo pipefail

HF_REPO="${HF_REPO:-Qwen/Qwen2.5-1.5B-Instruct}"
HF_REVISION="${HF_REVISION:-989aa7980e4cf806f80c7fef2b1adb7bc71aa306}"
LLAMA_CPP_VERSION="${LLAMA_CPP_VERSION:-v0.9.0}"
QUANT="${QUANT:-Q4_K_M}"
OUT_NAME="${OUT_NAME:-crustadvisor}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT/model"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
LLAMA_DIR="$BUILD_DIR/llama.cpp"
VENV="$BUILD_DIR/.venv"
HF_DIR="$BUILD_DIR/hf"            # pristine snapshot: the provenance material
ENRICHED_DIR="$BUILD_DIR/enriched"
F16_GGUF="$BUILD_DIR/$OUT_NAME-f16.gguf"
OUT_GGUF="$BUILD_DIR/$OUT_NAME-$(echo "$QUANT" | tr '[:upper:]' '[:lower:]').gguf"
BUILD_INFO="$BUILD_DIR/build-info.json"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required. $2"; }

need uv  "Install with: brew install uv"
need git "Install with: brew install git"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------- llama.cpp
# The converter (convert_hf_to_gguf.py) only ships in the source tree, so we
# clone the pinned tag. llama-quantize comes from PATH (brew install llama.cpp)
# or is built from the same clone.
if [ ! -d "$LLAMA_DIR/.git" ]; then
  log "Cloning llama.cpp $LLAMA_CPP_VERSION"
  git clone --quiet --depth 1 --branch "$LLAMA_CPP_VERSION" \
    https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
else
  have="$(git -C "$LLAMA_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
  [ "$have" = "$LLAMA_CPP_VERSION" ] || die "build/llama.cpp is at $have, want $LLAMA_CPP_VERSION (rm -rf $LLAMA_DIR)"
fi

if command -v llama-quantize >/dev/null 2>&1; then
  QUANTIZE="$(command -v llama-quantize)"
elif [ -x "$LLAMA_DIR/build/bin/llama-quantize" ]; then
  QUANTIZE="$LLAMA_DIR/build/bin/llama-quantize"
else
  log "llama-quantize not on PATH, building it from the clone"
  need cmake "Install with: brew install cmake (or: brew install llama.cpp)"
  cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF >/dev/null
  cmake --build "$LLAMA_DIR/build" --target llama-quantize -j >/dev/null
  QUANTIZE="$LLAMA_DIR/build/bin/llama-quantize"
fi

# ---------------------------------------------------------------- python env
if [ ! -x "$VENV/bin/python" ]; then
  log "Creating Python $PYTHON_VERSION venv for the converter"
  uv venv --quiet --python "$PYTHON_VERSION" "$VENV"
fi
log "Installing converter requirements"
uv pip install --quiet --python "$VENV/bin/python" \
  -r "$LLAMA_DIR/requirements/requirements-convert_hf_to_gguf.txt" \
  "huggingface_hub[cli]" "model-signing==1.1.1" pyOpenSSL
PY="$VENV/bin/python"

# ---------------------------------------------------------------- material
if [ -n "${HF_SNAPSHOT_DIR:-}" ]; then
  log "Using local snapshot $HF_SNAPSHOT_DIR (claims to be $HF_REPO @ $HF_REVISION)"
  HF_DIR="$HF_SNAPSHOT_DIR"
else
  log "Pulling $HF_REPO @ $HF_REVISION"
  "$VENV/bin/hf" download "$HF_REPO" --revision "$HF_REVISION" --local-dir "$HF_DIR" --quiet >/dev/null
fi
[ -f "$HF_DIR/tokenizer_config.json" ] || die "snapshot at $HF_DIR has no tokenizer_config.json"

# ---------------------------------------------------------------- enrich
log "Enriching with the CrustAdvisor persona"
"$PY" "$MODEL_DIR/enrich.py" "$HF_DIR" "$ENRICHED_DIR"

# ---------------------------------------------------------------- convert
log "Converting to GGUF (f16)"
"$PY" "$LLAMA_DIR/convert_hf_to_gguf.py" "$ENRICHED_DIR" \
  --outtype f16 --outfile "$F16_GGUF" --metadata "$MODEL_DIR/metadata.json" >/dev/null

# ---------------------------------------------------------------- quantize
log "Quantizing to $QUANT"
"$QUANTIZE" "$F16_GGUF" "$OUT_GGUF" "$QUANT" >/dev/null
rm -f "$F16_GGUF"

# ---------------------------------------------------------------- record
log "Recording build info"
"$PY" - "$BUILD_INFO" "$HF_REPO" "$HF_REVISION" "$LLAMA_CPP_VERSION" "$QUANT" "$HF_DIR" "$OUT_GGUF" <<'PYEOF'
import hashlib, json, os, sys
out, repo, rev, llama, quant, hf_dir, gguf = sys.argv[1:]

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

materials = []
for dirpath, dirnames, filenames in os.walk(hf_dir):
    dirnames[:] = [d for d in dirnames if not d.startswith(".")]
    for name in sorted(filenames):
        p = os.path.join(dirpath, name)
        materials.append({"name": os.path.relpath(p, hf_dir), "sha256": sha256(p)})

info = {
    "source": {"repo": repo, "revision": rev, "uri": f"https://huggingface.co/{repo}/tree/{rev}"},
    "materials": materials,
    "builder": {"llama.cpp": llama, "quant": quant},
    "output": {"name": os.path.basename(gguf), "sha256": sha256(gguf), "bytes": os.path.getsize(gguf)},
}
json.dump(info, open(out, "w"), indent=2)
print(json.dumps(info["output"], indent=2))
PYEOF

# ---------------------------------------------------------------- attest
log "Writing attestations"
"$PY" "$MODEL_DIR/attest.py" --build-info "$BUILD_INFO" --out "$BUILD_DIR/attestations"

log "Done: $OUT_GGUF"
