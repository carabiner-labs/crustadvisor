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

The full plan is in [CRUSTADVISOR.md](CRUSTADVISOR.md).

## Quick start

See `make help` once the pieces land. The intended loop is:

```
make model        # pull Qwen2.5-1.5B-Instruct @ pinned SHA, convert to GGUF Q4_K_M
make serve        # model-admit → ampel verify → llama-server → app
make tamper       # PPM post-build tamper of the GGUF chat template
make serve-unsafe # serve WITHOUT the gate (what most of the industry does today)
make reset        # back to a clean, signed model
```
