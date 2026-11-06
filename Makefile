# CrustAdvisor demo targets. Each target is wired up as its component lands.
SHELL := /bin/bash

.PHONY: help model attest sign serve serve-unsafe tamper tamper-build admit admit-rehearsal reset

# Set ADMIT_FLAGS=--rehearsal to admit the unsigned statements written by the
# build (development). Without it only signed bundles count (stage).
ADMIT_FLAGS ?=
AMPEL ?= $(shell command -v ampel 2>/dev/null || echo build/ampel)
export AMPEL

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

model: ## Pull pinned HF model, enrich, convert and quantize to GGUF (model/build.sh)
	@model/build.sh

attest: ## Rewrite the unsigned statements (OMS, provenance, ML-BOM) for the current build
	@build/.venv/bin/python model/attest.py

sign: ## Sign the model (OMS, sigstore) and its statements (bnd) — opens the OIDC flow
	@model/sign.sh

serve: ## Gate the model with model-admit, then start llama-server (ADMIT_FLAGS=--rehearsal for dev)
	@admit/model-admit $(ADMIT_FLAGS)

serve-unsafe: ## Start llama-server with NO policy gate (what most of the industry does today)
	@printf '{"status":"ungated","message":"served without model-admit","model":"crustadvisor-q4_k_m.gguf","sha256":"%s","time":"%s"}\n' \
	  "$$(shasum -a 256 build/crustadvisor-q4_k_m.gguf | cut -c1-64)" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/admit-status.json
	@echo "⚠️  serving UNGATED" >&2
	@llama-server -m build/crustadvisor-q4_k_m.gguf --jinja --host 127.0.0.1 --port 8080 -c 4096

tamper: ## PPM variant 1: post-build GGUF chat-template tamper
	@attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf

tamper-build: ## PPM variant 2: build from poisoned/typosquat upstream
	@attack/typosquat-build.sh

admit: ## Run the AMPEL gate alone and print per-rung results (signed bundles only)
	@admit/model-admit --no-serve $(ADMIT_FLAGS)

admit-rehearsal: ## Same, admitting the unsigned statements from the build
	@admit/model-admit --no-serve --rehearsal

reset: ## Restore clean, signed model state (demo/reset.sh)
	@echo "TODO: demo/reset.sh"
