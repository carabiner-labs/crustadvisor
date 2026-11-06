# CrustAdvisor demo targets. Each target is wired up as its component lands.
SHELL := /bin/bash

.PHONY: help model attest sign publish pull app serve serve-unsafe tamper tamper-build swap-ppm admit admit-rehearsal vsa reset

# Set ADMIT_FLAGS=--rehearsal to admit the unsigned statements written by the
# build (development). Without it only signed bundles count (stage).
ADMIT_FLAGS ?=
AMPEL ?= $(shell command -v ampel 2>/dev/null || echo build/ampel)
export AMPEL

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

model: ## Pull pinned HF model, enrich, convert and quantize to GGUF, save as known-good (model/build.sh)
	@model/build.sh
	@demo/reset.sh --save

attest: ## Rewrite the unsigned statements (OMS, provenance, ML-BOM) for the current build
	@build/.venv/bin/python model/attest.py

sign: ## Sign the model (OMS, sigstore) and its statements (bnd) — opens the OIDC flow
	@model/sign.sh

publish: ## Push model + attestations to $(IMAGE):$(TAG) with oras (CI does this)
	@model/publish.sh

pull: ## Pull the published model (REF=...), make it known-good, run the gate
	@demo/pull.sh $(REF)

app: ## Start the web app alone on http://127.0.0.1:8000
	@cd app && uv run --quiet uvicorn main:app --host 127.0.0.1 --port 8000

serve: ## Gate the model, start llama-server and the app (ADMIT_FLAGS=--rehearsal for dev)
	@demo/serve.sh $(ADMIT_FLAGS)

serve-unsafe: ## Start llama-server with NO policy gate (what most of the industry does today); add the app with demo/serve.sh --unsafe
	@printf '{"status":"ungated","message":"served without model-admit","model":"crustadvisor-q4_k_m.gguf","sha256":"%s","time":"%s"}\n' \
	  "$$(shasum -a 256 build/crustadvisor-q4_k_m.gguf | cut -c1-64)" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/admit-status.json
	@echo "⚠️  serving UNGATED" >&2
	@llama-server -m build/crustadvisor-q4_k_m.gguf --jinja --host 127.0.0.1 --port 8080 -c 4096

tamper: ## PPM variant 1: post-build GGUF chat-template tamper (in place, ~6s)
	@test -f build/pristine/crustadvisor-q4_k_m.gguf || demo/reset.sh --save
	@attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf

tamper-build: ## PPM variant 2: typosquat build into build/ppm/ (~75s, do it before the talk)
	@BUILD_DIR=$(CURDIR)/build/ppm attack/typosquat-build.sh

swap-ppm: ## Put the pre-built typosquat model and its attestations in place (instant)
	@test -f build/ppm/crustadvisor-q4_k_m.gguf || { echo "run make tamper-build first" >&2; exit 1; }
	@test -f build/pristine/crustadvisor-q4_k_m.gguf || demo/reset.sh --save
	@cp -p build/ppm/crustadvisor-q4_k_m.gguf build/crustadvisor-q4_k_m.gguf
	@cp -p build/ppm/build-info.json build/build-info.json
	@rm -rf build/attestations && cp -Rp build/ppm/attestations build/attestations
	@echo "🍍 typosquat build in place: $$(shasum -a 256 build/crustadvisor-q4_k_m.gguf | cut -c1-12)"

admit: ## Run the AMPEL gate alone and print per-rung results (signed bundles only)
	@admit/model-admit --no-serve $(ADMIT_FLAGS)

admit-rehearsal: ## Same, admitting the unsigned statements from the build
	@admit/model-admit --no-serve --rehearsal

vsa: ## Show the verdict of the last gate run (SLSA Verification Summary Attestation)
	@python3 -c 'import json; d=json.load(open("build/vsa.intoto.json")); p=d["predicate"]; print(json.dumps({"subject": d["subject"], "verifier": p.get("verifier"), "policy": p.get("policy"), "result": p.get("verificationResult"), "verifiedLevels": p.get("verifiedLevels"), "timeVerified": p.get("timeVerified")}, indent=2))'

reset: ## Stop servers, restore the known-good model and attestations, verify (demo/reset.sh)
	@demo/reset.sh
