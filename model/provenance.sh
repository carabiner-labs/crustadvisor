#!/usr/bin/env bash
# Hand the build's facts to slsa-attester, which writes (and in CI signs)
# the SLSA v1 provenance of the model.
#
# Everything comes from build/build-info.json, written by build.sh: the
# Hugging Face snapshot (repo @ revision, with every file's sha256), the
# llama.cpp tag, the quantization, the timings, and the model's OMS root
# digest, which is the subject. This repository's commit is the third
# resolved dependency.
#
#   provenance.sh            unsigned statement, build/attestations/provenance.intoto.json
#   SIGN=1 provenance.sh     sigstore bundle,    build/attestations/provenance.bundle.json
#                            (ambient credentials in CI: the builder is the workflow)
#
# slsa-attester is taken from PATH or downloaded to build/bin at the pinned
# release and verified with ampel against its own release provenance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
BUILD_INFO="$BUILD_DIR/build-info.json"
ATT="$BUILD_DIR/attestations"
ATTESTER_VERSION="${ATTESTER_VERSION:-v0.1.1}"
BUILD_TYPE="https://github.com/carabiner-labs/crustadvisor/model/build@v1"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
[ -f "$BUILD_INFO" ] || { echo "error: $BUILD_INFO missing, run model/build.sh" >&2; exit 1; }
mkdir -p "$ATT"

# ---------------------------------------------------------------- attester
if command -v slsa-attester >/dev/null 2>&1; then
  ATTESTER="$(command -v slsa-attester)"
else
  ATTESTER="$BUILD_DIR/bin/slsa-attester"
  if [ ! -x "$ATTESTER" ]; then
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
    case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    base="https://github.com/slsa-framework/attester/releases/download/$ATTESTER_VERSION"
    log "Downloading slsa-attester $ATTESTER_VERSION ($os/$arch)"
    mkdir -p "$BUILD_DIR/bin/attester-provenance"
    curl -sSfL --retry 3 -o "$ATTESTER" "$base/slsa-attester-$ATTESTER_VERSION-$os-$arch"
    curl -sSfL --retry 3 -o "$BUILD_DIR/bin/attester-provenance/attestations.intoto.jsonl" "$base/attestations.intoto.jsonl"
    chmod +x "$ATTESTER"
    AMPEL="${AMPEL:-$(command -v ampel || echo "$BUILD_DIR/ampel")}"
    if [ -x "$AMPEL" ]; then
      log "Verifying the attester against its release provenance"
      "$AMPEL" verify "$ATTESTER" \
        -p 'git+https://github.com/carabiner-dev/policies@eed2d09ac2a7f8f5238a24b30492e378d8d77ad3#slsa/slsa-build-point.json' \
        -c "fs:$BUILD_DIR/bin/attester-provenance" \
        --signer 'sigstore::https://token.actions.githubusercontent.com::https://github.com/slsa-framework/actions/.github/workflows/attest_actions.yml@refs/heads/main' \
        -x 'buildPoint:git+https://github.com/slsa-framework/attester' --format summary >&2
    else
      echo "warning: ampel not found, attester download not verified" >&2
    fi
  fi
fi

# ---------------------------------------------------------------- facts
# The resolved dependencies are JSON resource descriptors; the HF snapshot
# carries a gitCommit digest and the sha256 of every file it contained.
mapfile -t FACTS < <(python3 - "$BUILD_INFO" "$ROOT" <<'PYEOF'
import json, os, subprocess, sys
info = json.load(open(sys.argv[1])); root = sys.argv[2]
src, b = info["source"], info["builder"]

def git(*a):
    try: return subprocess.check_output(["git", "-C", root, *a], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return ""

if os.environ.get("GITHUB_REPOSITORY"):
    repo_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ['GITHUB_REPOSITORY']}"
    commit = os.environ.get("GITHUB_SHA", "")
else:
    repo_url = git("remote", "get-url", "origin").removesuffix(".git")
    if repo_url.startswith("git@github.com:"): repo_url = "https://github.com/" + repo_url.removeprefix("git@github.com:")
    commit = git("rev-parse", "HEAD")

if os.environ.get("GITHUB_ACTIONS") == "true":
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    builder = f"{server}/{os.environ.get('GITHUB_WORKFLOW_REF', '')}"
    invocation = f"{server}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}/attempts/{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
else:
    builder = os.environ.get("BUILDER_ID", "https://localhost/crustadvisor/model/build.sh")
    invocation = f"urn:uuid:{os.urandom(16).hex()}"

print("sha256:" + info["output"]["oms_sha256"])
print(builder)
print(invocation)
print(info.get("startedOn", ""))
print(info.get("finishedOn", ""))
print(json.dumps({"hfRepo": src["repo"], "hfRevision": src["revision"]}))
print(json.dumps({"llamaCpp": b["llama.cpp"], "quantization": b["quant"]}))
print(json.dumps({"name": src["repo"], "uri": f"https://huggingface.co/{src['repo']}@{src['revision']}",
                  "digest": {"gitCommit": src["revision"]},
                  "annotations": {"files": {m["name"]: m["sha256"] for m in info["materials"]}}}))
print(json.dumps({"name": "llama.cpp", "uri": f"git+https://github.com/ggml-org/llama.cpp@refs/tags/{b['llama.cpp']}"}))
print(json.dumps({"name": "crustadvisor", "uri": f"git+{repo_url}@{commit}", "digest": {"gitCommit": commit}}) if repo_url else "")
PYEOF
)
SUBJECT="${FACTS[0]}"; BUILDER="${FACTS[1]}"; INVOCATION="${FACTS[2]}"; STARTED="${FACTS[3]}"; FINISHED="${FACTS[4]}"
EXTERNAL="${FACTS[5]}"; INTERNAL="${FACTS[6]}"; DEP_HF="${FACTS[7]}"; DEP_LLAMA="${FACTS[8]}"; DEP_REPO="${FACTS[9]:-}"

ARGS=(build
  --subject "$SUBJECT"
  --build-type "$BUILD_TYPE"
  --builder-id "$BUILDER"
  --invocation-id "$INVOCATION"
  --external-parameters "$EXTERNAL"
  --internal-parameters "$INTERNAL"
  --resolved-dependency "$DEP_HF"
  --resolved-dependency "$DEP_LLAMA"
)
[ -n "$DEP_REPO" ] && ARGS+=(--resolved-dependency "$DEP_REPO")
[ -n "$STARTED" ] && ARGS+=(--started-on "$STARTED")
[ -n "$FINISHED" ] && ARGS+=(--finished-on "$FINISHED")

if [ "${SIGN:-0}" = 1 ]; then
  OUT="$ATT/provenance.bundle.json"
  log "slsa-attester: signed provenance, builder $BUILDER"
else
  OUT="$ATT/provenance.intoto.json"
  ARGS+=(--sign=false)
  log "slsa-attester: unsigned provenance, builder $BUILDER"
fi
"$ATTESTER" "${ARGS[@]}" --output "$OUT"
log "wrote $OUT"
