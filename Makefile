# CrustAdvisor demo targets. Each target is wired up as its component lands.
SHELL := /bin/bash

.PHONY: help model serve serve-unsafe tamper tamper-build admit reset

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

model: ## Pull pinned HF model, enrich, convert and quantize to GGUF (model/build.sh)
	@model/build.sh

serve: ## Gate the model with model-admit, then start llama-server and the app
	@echo "TODO: admit/model-admit + app"

serve-unsafe: ## Start llama-server and the app with NO policy gate
	@echo "TODO: app without admit"

tamper: ## PPM variant 1: post-build GGUF chat-template tamper
	@attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf

tamper-build: ## PPM variant 2: build from poisoned/typosquat upstream
	@attack/typosquat-build.sh

admit: ## Run the AMPEL gate alone and print per-tenet results
	@echo "TODO: admit/model-admit"

reset: ## Restore clean, signed model state (demo/reset.sh)
	@echo "TODO: demo/reset.sh"
