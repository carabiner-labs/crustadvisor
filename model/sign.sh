#!/usr/bin/env bash
# Sign the CrustAdvisor model and its attestations with sigstore.
#
#   model-signing.bundle.json  OpenSSF Model Signing (OMS) bundle over the
#                              GGUF, produced by sigstore/model-transparency's
#                              model_signing. Its statement subject is the OMS
#                              root digest that `ampel verify model` computes.
#   provenance.bundle.json     The SLSA provenance statement from attest.py,
#   sbom.cdx.bundle.json       and the ML-BOM, each bound in a sigstore bundle
#                              by bnd.
#
# Locally this opens the sigstore OIDC flow in a browser; in GitHub Actions
# the workflow's OIDC token is used (ambient credentials), so the signing
# identity is the workflow itself, which is what admit/policy.hjson pins.
#
#   sign.sh               sign the model and the two statements
#   sign.sh --model-only  sign only the model (CI signs the statements with
#                         the carabiner-dev/actions/bnd/sign action, which
#                         appends them to attestations/attestations.jsonl)
set -euo pipefail
MODEL_ONLY=0; [ "${1:-}" = "--model-only" ] && MODEL_ONLY=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
ATT="$BUILD_DIR/attestations"
MODEL="${MODEL:-$BUILD_DIR/crustadvisor-q4_k_m.gguf}"
VENV="$BUILD_DIR/.venv-oms"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is required. $2" >&2; exit 1; }; }

[ "$MODEL_ONLY" = 1 ] || need bnd "brew install carabiner-dev/tap/bnd"
[ -x "$VENV/bin/model_signing" ] || { echo "error: run model/build.sh first (installs model_signing in $VENV)" >&2; exit 1; }
[ -f "$ATT/provenance.intoto.json" ] || { echo "error: no attestations in $ATT, run model/attest.py" >&2; exit 1; }

AMBIENT=()
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then AMBIENT=(--use_ambient_credentials); fi

log "Signing the model with OpenSSF Model Signing (sigstore)"
"$VENV/bin/model_signing" sign sigstore "$MODEL" --signature "$ATT/model-signing.bundle.json" "${AMBIENT[@]}"

if [ "$MODEL_ONLY" = 1 ]; then
  log "Signed model bundle: $ATT/model-signing.bundle.json"
  exit 0
fi

log "Signing the provenance and ML-BOM statements with bnd"
bnd statement --statement "$ATT/provenance.intoto.json" --out "$ATT/provenance.bundle.json"
bnd statement --statement "$ATT/sbom.cdx.intoto.json" --out "$ATT/sbom.cdx.bundle.json"

log "Signed bundles in $ATT"
ls -la "$ATT"/*.bundle.json >&2
