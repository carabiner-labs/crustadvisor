# CrustAdvisor 🍕

An AI-powered pizza recommendation service, and a public demo of **AI/ML model
supply-chain security**.

CrustAdvisor runs a small local LLM (the "AI Pizzaiolo") that recommends pizzas.
The villains, the **Pineapple Pizza Mafia (PPM)**, tamper with the model so every
recommendation becomes Hawaiian. We show how signing, SLSA provenance, an ML-BOM
and a policy gate ([AMPEL](https://github.com/policylabs/ampel)) catch the
tampered model and refuse to serve it.

```
HF model (pinned) → enrich/quantize to GGUF → sign + provenance + SBOM
  → push as OCI artifact → [laptop] policy gate verifies → serve inference → app
```

## Layout

| Path | What lives here |
| --- | --- |
| `app/` | Single-page UI (menu + Pizzaiolo chat) and the FastAPI proxy to `llama-server` |
| `model/` | Persona / system prompt, chat template, HF → GGUF build scripts |
| `attack/` | PPM tooling: GGUF metadata tamper, typosquat build variant |
| `admit/` | `model-admit` gate wrapper and the AMPEL policy (one tenet per rung) |
| `demo/` | Runbook and `reset.sh` (one-command restore to clean state) |
| `build/` | Local build output: pulled HF snapshot, GGUF files (git-ignored) |
| `.github/workflows/` | CI: build, sign, attest and push the model as an OCI artifact |

The full plan is in [CRUSTADVISOR.md](CRUSTADVISOR.md); the stage script is
[demo/RUNBOOK.md](demo/RUNBOOK.md).

## Quick start

See `make help` once the pieces land. The intended loop is:

```
make model                        # pull Qwen3-4B-Instruct-2507 @ pinned SHA, enrich, GGUF Q4_K_M, statements
make sign                         # OMS-sign the model and the statements with sigstore
make serve                        # model-admit → ampel verify model → llama-server → app
make serve ADMIT_FLAGS=--rehearsal  # same, admitting the unsigned statements (dev)
make tamper                       # PPM post-build tamper of the GGUF chat template
make tamper-build                 # PPM typosquat build
make serve-unsafe                 # serve WITHOUT the gate (what most of the industry does today)
make swap-ppm                     # put the pre-built typosquat model in place
make admit-rehearsal              # just the per-rung verdict
make vsa                          # the verdict as a SLSA Verification Summary Attestation
make reset                        # stop servers, restore the known-good model, verify
```
