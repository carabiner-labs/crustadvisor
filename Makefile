# CrustAdvisor demo targets. Each target is wired up as its component lands.
SHELL := /bin/bash

.PHONY: help model attest sign publish pull app serve serve-unsafe tamper tamper-build swap-ppm tamper-app reset-app stage-clean stage-evil stage-status stage-attest build-base tamper-image reset-image image-admit build-wheels tamper-dep reset-dep dep-admit start stop step show gate admit admit-rehearsal source-admit vsa reset

# Set ADMIT_FLAGS=--rehearsal to admit the unsigned statements written by the
# build (development). Without it only signed bundles count (stage).
# GATES selects which gates the service has: source,model (all), source, or
# empty for none. A gate that does not exist has no light in the app.
ADMIT_FLAGS ?=
GATES ?= source,dependency,image,model
AMPEL ?= $(shell command -v ampel 2>/dev/null || echo build/ampel)
export AMPEL

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

model: ## Pull pinned HF model, enrich, convert and quantize to GGUF, save as known-good (model/build.sh)
	@model/build.sh
	@demo/reset.sh --save

attest: ## Rewrite the unsigned statements (OMS, ML-BOM) and the provenance for the current build
	@build/.venv-oms/bin/python model/attest.py
	@model/provenance.sh

sign: ## Sign the model (OMS, sigstore) and its statements (bnd) — opens the OIDC flow
	@model/sign.sh

publish: ## Push model + attestations to $(IMAGE):$(TAG) with oras (CI does this)
	@model/publish.sh

pull: ## Pull the published model (REF=...), make it known-good, run the gate
	@demo/pull.sh $(REF)

app: ## Start the web app alone on http://127.0.0.1:8000
	@cd app && uv run --quiet uvicorn main:app --host 127.0.0.1 --port 8000

serve: ## Run the gates in GATES (default source,model), then llama-server and the app
	@demo/serve.sh --gates=$(GATES) $(ADMIT_FLAGS)

serve-unsafe: ## Same stack with the gates in GATES skipped (their lights go amber)
	@demo/serve.sh --gates=$(GATES) --unsafe

tamper: ## PPM variant 1: post-build GGUF chat-template tamper (in place, ~6s)
	@test -f build/pristine/crustadvisor-q4_k_m.gguf || demo/reset.sh --save
	@attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf

tamper-build: ## PPM variant 2: typosquat build into build/ppm/ (~75s, do it before the talk)
	@BUILD_DIR=$(CURDIR)/build/ppm attack/typosquat-build.sh

tamper-app: ## PPM act 2: the malicious commit on the ordering code (no source provenance)
	@attack/ppm-commit.sh

reset-app: ## Drop the PPM commit if HEAD is it
	@attack/ppm-commit.sh --undo

source-admit: ## Run the source gate alone on HEAD (signed notes from origin; SOURCE_ADMIT_FLAGS for overrides)
	@admit/source-admit $(SOURCE_ADMIT_FLAGS)

stage-clean: ## Act 1: demo branch := stage/clean (the attested feature commit)
	@demo/stage.sh clean

stage-evil: ## Act 1: demo branch := stage/evil (stage/clean + the PPM's commit)
	@demo/stage.sh evil

stage-status: ## Where HEAD is relative to the stage refs, and whether it has a note
	@demo/stage.sh status

stage-attest: ## Fake source provenance + VSA for stage/clean, signed with bnd, into its note on origin
	@demo/stage.sh attest

build-base: ## Build the clean base image, point :latest at it, sign its provenance
	@image/build-base.sh

tamper-image: ## PPM act 3: hijack crustadvisor/base:latest with the evil base
	@attack/ppm-image.sh

reset-image: ## Point crustadvisor/base:latest back at the clean base
	@attack/ppm-image.sh --undo

image-admit: ## Run the image gate alone: verify the base crustadvisor/base:latest
	@admit/image-admit $(IMAGE_ADMIT_FLAGS)

build-wheels: ## Build the clean crust-receipt wheel and pin it in app/requirements.txt
	@packages/build-wheels.sh

tamper-dep: ## PPM act 2: publish the poisoned crust-receipt and repin the app to it
	@attack/ppm-dependency.sh

reset-dep: ## Restore the clean crust-receipt pin
	@attack/ppm-dependency.sh --undo

dep-admit: ## Run the dependency gate alone: SBOM of app/requirements.txt vs the policy
	@admit/dep-admit $(DEP_ADMIT_FLAGS)

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

start: ## Start the demo at step 0 (clean, serving)
	@demo/step.sh reset
stop: ## Stop the demo: stop the running services and clean the repo
	@demo/step.sh stop
step: ## Advance the demo to the next step
	@demo/step.sh
reset: ## Go back to step 0 (clean, serving)
	@demo/step.sh reset
show: ## Show the PPM tamper for the rung coming next in the walk
	@demo/step.sh show
gate: ## Apply the next rung's policy and show the build refuse the tamper
	@demo/step.sh gate
