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

STARTED_ON="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

# ---------------------------------------------------------------- facts
# Resolve what actually went into the image: the base image at the digest its
# tag resolved to, the build-context files by sha256, the Python packages that
# landed in the layer, and this repository. A Python helper writes each as a
# provenance component; bash feeds them to slsa-attester.
FROM_IMAGE="$(awk 'toupper($1)=="FROM"{print $2; exit}' "$ROOT/image/base/Dockerfile")"
# BuildKit does not add the FROM image to the local store, so pull it to read
# the digest its tag resolved to (the build used the same tag moments earlier).
docker pull -q "$FROM_IMAGE" >/dev/null 2>&1 || true
FROM_DIGEST="$(docker image inspect "$FROM_IMAGE" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' 2>/dev/null || true)"
DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
PIP_FREEZE="$(docker run --rm --entrypoint python "$IMAGE:clean" -m pip freeze 2>/dev/null | tr '\n' ' ' || true)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mapfile -t META < <(python3 - "$ROOT" "$WORK" "$IMAGE" "$DIGEST" "$FROM_IMAGE" "$FROM_DIGEST" "$DOCKER_VER" "$PIP_FREEZE" <<'PYEOF'
import json, os, hashlib, subprocess, platform, sys
root, work, image, digest, from_image, from_digest, docker_ver, pip_freeze = sys.argv[1:]
ctx = os.path.join(root, "image", "base")

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""): h.update(c)
    return h.hexdigest()
def git(*a):
    try: return subprocess.check_output(["git", "-C", root, *a], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return ""
def w(n, o): json.dump(o, open(os.path.join(work, n), "w"))

if os.environ.get("GITHUB_REPOSITORY"):
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo_url = f"{server}/{os.environ['GITHUB_REPOSITORY']}"; commit = os.environ.get("GITHUB_SHA", ""); ref = os.environ.get("GITHUB_REF", "")
else:
    repo_url = git("remote", "get-url", "origin").removesuffix(".git")
    if repo_url.startswith("git@github.com:"): repo_url = "https://github.com/" + repo_url.removeprefix("git@github.com:")
    commit = git("rev-parse", "HEAD"); ref = "refs/heads/" + git("rev-parse", "--abbrev-ref", "HEAD")

if os.environ.get("GITHUB_ACTIONS") == "true":
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    invocation = f"{server}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ.get('GITHUB_RUN_ID','')}/attempts/{os.environ.get('GITHUB_RUN_ATTEMPT','1')}"
else:
    invocation = f"urn:uuid:{os.urandom(16).hex()}"

# subject: the built image, named, by its local Id digest (algo prefix stripped for checksums)
_, _, hexd = digest.partition(":")
open(os.path.join(work, "checksums.txt"), "w").write(f"{hexd}  {image}:clean\n")

# external parameters: the build request
w("external.json", {
    "dockerfile": "image/base/Dockerfile", "context": "image/base",
    "image": f"{image}:clean", "tags": [f"{image}:latest"], "baseImage": from_image,
    "configSource": {"repository": repo_url, "ref": ref,
                     "path": "image/build-base.sh", "revision": commit},
})
# internal parameters: the builder environment
w("internal.json", {k: v for k, v in {
    "platform": f"{platform.system().lower()}/{platform.machine()}", "docker": docker_ver,
}.items() if v})

# resolved dependencies: the base image at its resolved digest, context files, repo, packages
base = {"name": from_image, "uri": f"pkg:docker/{from_image}"}
if "@sha256:" in from_digest:
    base["digest"] = {"sha256": from_digest.split("@sha256:")[1]}; base["uri"] = f"pkg:docker/{from_digest}"
w("dep-base.json", base)
w("dep-dockerfile.json", {"name": "Dockerfile", "digest": {"sha256": sha256(os.path.join(ctx, "Dockerfile"))},
                          "uri": f"git+{repo_url}@{commit}#image/base/Dockerfile" if repo_url else None})
w("dep-entrypoint.json", {"name": "entrypoint.sh", "digest": {"sha256": sha256(os.path.join(ctx, "entrypoint.sh"))}})
has_repo = bool(repo_url)
if has_repo:
    w("dep-repo.json", {"name": "crustadvisor", "uri": f"git+{repo_url}@{commit}", "digest": {"gitCommit": commit}})
pkgs = [p for p in pip_freeze.split() if "==" in p]
has_pkgs = bool(pkgs)
if has_pkgs:
    w("dep-pip.json", {"name": "python packages (pip freeze)", "annotations": {"packages": pkgs}})

# builder dependencies
w("bdep-docker.json", {"name": "docker", "uri": "https://www.docker.com/", "annotations": {"version": docker_ver}})

print(invocation); print(docker_ver)
print("1" if has_repo else ""); print("1" if has_pkgs else "")
PYEOF
)
INVOCATION="${META[0]}"; BV_DOCKER="${META[1]}"; HAS_REPO="${META[2]}"; HAS_PKGS="${META[3]}"
FINISHED_ON="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$ATT"
log "Signing SLSA provenance for the base image (builder $BUILDER)"
ARGS=(build
  --checksums "$WORK/checksums.txt"
  --build-type "$BUILD_TYPE"
  --builder-id "$BUILDER"
  --invocation-id "$INVOCATION"
  --external-parameters "@$WORK/external.json"
  --internal-parameters "@$WORK/internal.json"
  --resolved-dependency "@$WORK/dep-base.json"
  --resolved-dependency "@$WORK/dep-dockerfile.json"
  --resolved-dependency "@$WORK/dep-entrypoint.json"
  --builder-dependency "@$WORK/bdep-docker.json"
  --started-on "$STARTED_ON"
  --finished-on "$FINISHED_ON"
)
[ -n "$BV_DOCKER" ] && ARGS+=(--builder-version "docker=$BV_DOCKER")
[ -n "$HAS_REPO" ] && ARGS+=(--resolved-dependency "@$WORK/dep-repo.json")
[ -n "$HAS_PKGS" ] && ARGS+=(--resolved-dependency "@$WORK/dep-pip.json")
"$ATTESTER" "${ARGS[@]}" "${SIGN_ARGS[@]}" -o "$ATT/base-provenance.bundle.json"
log "wrote $ATT/base-provenance.bundle.json"
