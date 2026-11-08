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
# A Python helper reads build-info.json and the build environment and writes
# each provenance component as a JSON file under a work dir; bash then feeds
# those to slsa-attester. Files (rather than the name=,uri= shorthand) let the
# resource descriptors carry names, digests and annotations.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mapfile -t META < <(python3 - "$BUILD_INFO" "$ROOT" "$WORK" "$BUILD_DIR" <<'PYEOF'
import json, os, platform, subprocess, sys
info_path, root, work, build_dir = sys.argv[1:]
info = json.load(open(info_path))
src, b, out = info["source"], info["builder"], info["output"]
llama_dir = os.path.join(build_dir, "llama.cpp")

def git(d, *a):
    try: return subprocess.check_output(["git", "-C", d, *a], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return ""

def w(name, obj): json.dump(obj, open(os.path.join(work, name), "w"))

# this repository (the build config source) and the CI identity
if os.environ.get("GITHUB_REPOSITORY"):
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo_url = f"{server}/{os.environ['GITHUB_REPOSITORY']}"
    commit = os.environ.get("GITHUB_SHA", "")
    ref = os.environ.get("GITHUB_REF", "")
    workflow_ref = os.environ.get("GITHUB_WORKFLOW_REF", "")
else:
    repo_url = git(root, "remote", "get-url", "origin").removesuffix(".git")
    if repo_url.startswith("git@github.com:"): repo_url = "https://github.com/" + repo_url.removeprefix("git@github.com:")
    commit = git(root, "rev-parse", "HEAD")
    ref = "refs/heads/" + git(root, "rev-parse", "--abbrev-ref", "HEAD")
    workflow_ref = ""

if os.environ.get("GITHUB_ACTIONS") == "true":
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    builder = f"{server}/{workflow_ref}"
    invocation = f"{server}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ.get('GITHUB_RUN_ID','')}/attempts/{os.environ.get('GITHUB_RUN_ATTEMPT','1')}"
else:
    builder = os.environ.get("BUILDER_ID", "https://localhost/crustadvisor/model/build.sh")
    invocation = f"urn:uuid:{os.urandom(16).hex()}"

# builder environment: prefer what build.sh recorded, else observe it here
llama_commit = b.get("llama.cpp_commit") or git(llama_dir, "rev-parse", "HEAD")
py_ver = b.get("python") or platform.python_version()
plat = b.get("platform") or f"{platform.system().lower()}/{platform.machine()}"
oms_ver = b.get("model_signing") or ""
sde = os.environ.get("SOURCE_DATE_EPOCH", "")
hf_tree = src.get("uri", f"https://huggingface.co/{src['repo']}/tree/{src['revision']}")

# subject: the OMS root digest, named
open(os.path.join(work, "checksums.txt"), "w").write(f"{out['oms_sha256']}  {out['name']}\n")

# external parameters: what the build was asked to produce
w("external.json", {
    "source": {"repo": src["repo"], "revision": src["revision"], "uri": hf_tree},
    "quantization": b["quant"], "outputFormat": "gguf", "persona": "model/persona.md",
    "configSource": {"repository": repo_url, "ref": ref,
                     "path": ".github/workflows/model-build.yml", "revision": commit},
})
# internal parameters: the builder's own environment
w("internal.json", {k: v for k, v in {
    "platform": plat, "python": py_ver, "converter": "convert_hf_to_gguf.py",
    "llamaCppTag": b["llama.cpp"], "sourceDateEpoch": sde,
}.items() if v})

# resolved dependencies: the inputs that went in
w("dep-hf.json", {"name": src["repo"], "uri": f"https://huggingface.co/{src['repo']}@{src['revision']}",
                  "digest": {"gitCommit": src["revision"]},
                  "annotations": {"files": {m["name"]: m["sha256"] for m in info["materials"]}}})
dep_llama = {"name": "llama.cpp", "uri": f"git+https://github.com/ggml-org/llama.cpp@refs/tags/{b['llama.cpp']}"}
if llama_commit: dep_llama["digest"] = {"gitCommit": llama_commit}
w("dep-llama.json", dep_llama)
has_repo = bool(repo_url)
if has_repo:
    w("dep-repo.json", {"name": "crustadvisor", "uri": f"git+{repo_url}@{commit}", "digest": {"gitCommit": commit}})

# builder dependencies: the tools that did the building
bdep_llama = dict(dep_llama); bdep_llama["name"] = "llama.cpp (convert + quantize)"
w("bdep-llama.json", bdep_llama)
w("bdep-python.json", {"name": "python", "uri": "https://www.python.org/", "annotations": {"version": py_ver}})
if oms_ver:
    w("bdep-oms.json", {"name": "model-signing", "uri": f"pkg:pypi/model-signing@{oms_ver}", "annotations": {"version": oms_ver}})

# byproducts: intermediate outputs
f16 = (info.get("byproducts") or {}).get("f16_sha256")
if f16:
    w("by-f16.json", {"name": out["name"].replace(".gguf", "-f16.gguf"), "digest": {"sha256": f16},
                      "annotations": {"note": "unquantized f16 intermediate"}})

# scalars for bash, one per line, in order
print(builder); print(invocation)
print(info.get("startedOn", "")); print(info.get("finishedOn", ""))
print(b["llama.cpp"]); print(b["quant"]); print(oms_ver)
print("1" if has_repo else ""); print("1" if oms_ver else ""); print("1" if f16 else "")
PYEOF
)
BUILDER="${META[0]}"; INVOCATION="${META[1]}"; STARTED="${META[2]}"; FINISHED="${META[3]}"
BV_LLAMA="${META[4]}"; BV_QUANT="${META[5]}"; OMS_VER="${META[6]}"
HAS_REPO="${META[7]}"; HAS_OMS="${META[8]}"; HAS_F16="${META[9]}"

ARGS=(build
  --checksums "$WORK/checksums.txt"
  --build-type "$BUILD_TYPE"
  --builder-id "$BUILDER"
  --invocation-id "$INVOCATION"
  --external-parameters "@$WORK/external.json"
  --internal-parameters "@$WORK/internal.json"
  --resolved-dependency "@$WORK/dep-hf.json"
  --resolved-dependency "@$WORK/dep-llama.json"
  --builder-dependency "@$WORK/bdep-llama.json"
  --builder-dependency "@$WORK/bdep-python.json"
  --builder-version "llama.cpp=$BV_LLAMA"
  --builder-version "quantization=$BV_QUANT"
  --builder-version "slsa-attester=$ATTESTER_VERSION"
)
[ -n "$HAS_REPO" ] && ARGS+=(--resolved-dependency "@$WORK/dep-repo.json")
[ -n "$HAS_OMS" ]  && ARGS+=(--builder-dependency "@$WORK/bdep-oms.json" --builder-version "model-signing=$OMS_VER")
[ -n "$HAS_F16" ]  && ARGS+=(--byproduct "@$WORK/by-f16.json")
[ -n "$STARTED" ]  && ARGS+=(--started-on "$STARTED")
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
