# model/ — persona + build

The "enrich" step. Takes a pristine Hugging Face snapshot, bakes the
CrustAdvisor persona into its chat template, converts to GGUF and quantizes.
The result is one signable file carrying weights, tokenizer, config and the
chat template.

| | |
| --- | --- |
| Base model | [`Qwen/Qwen3-4B-Instruct-2507`](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) (Apache-2.0) |
| Pinned revision | `cdbee75f17c01a7cc42f958dc650907174af0554` (the provenance material) |
| Converter | llama.cpp `v0.9.0`, `convert_hf_to_gguf.py` |
| Quantization | `Q4_K_M` |
| Output | `build/crustadvisor-q4_k_m.gguf`, `build/build-info.json`, `build/attestations/` |
| Snapshot | `build/hf/Qwen_Qwen3-4B-Instruct-2507/` (one directory per repo) |

## Files

- `persona.md` — the AI Pizzaiolo system prompt.
- `chat_template.jinja` — a Jinja preamble with `__PERSONA__` and
  `__UPSTREAM_TEMPLATE__` placeholders. It rewrites `messages` so the persona
  is always the first system block (the app's own system message, the menu,
  is appended to it), then hands off to the vendor's template verbatim.
- `enrich.py` — copies the snapshot (hard links, so no duplicate weights) and
  sets `chat_template` in `tokenizer_config.json` to preamble + upstream
  template. Composing instead of replacing is deliberate: whatever the
  upstream snapshot says is carried into the build, which is what the
  provenance materials check protects against.
- `metadata.json` — `general.*` GGUF metadata overrides (name, license, source).
- `build.sh` — the whole pipeline: clone llama.cpp at the pinned tag, create a
  Python venv with `uv`, pull the snapshot at the pinned revision, enrich,
  convert to f16 GGUF, quantize, record hashes, write the statements.
- `attest.py` — writes two unsigned in-toto statements to
  `build/attestations/`, both with the model's OpenSSF Model Signing root
  digest as subject: the OMS statement itself and a CycloneDX 1.6 ML-BOM.
- `provenance.sh` — hands the build's facts from `build-info.json` to
  [`slsa-attester build`](https://github.com/slsa-framework/attester), which
  writes the SLSA v1 provenance: subject the OMS digest, resolved
  dependencies the HF snapshot at its revision (with every file's sha256),
  llama.cpp at its tag and this repository's commit, parameters and timings.
  Unsigned on the laptop (`provenance.intoto.json`), signed in CI with
  `SIGN=1` (`provenance.bundle.json`, the workflow as builder). The attester
  binary is taken from `PATH` or downloaded to `build/bin` and verified with
  ampel against its own release provenance.
- `sign.sh` — signs the model with `model_signing sign sigstore` (the OMS
  bundle) and the two statements with `bnd statement`; `--model-only` skips
  the statements (CI signs those with the `bnd/sign` action into
  `attestations.jsonl`). See `admit/README.md`.
- `publish.sh` — `oras push` of the GGUF, `build-info.json` and the
  attestations as one OCI artifact (`application/vnd.crustadvisor.model.v1`);
  in GitHub Actions also `bnd push github` of the signed bundles to the
  repository's attestation store. `demo/pull.sh` is the other end.

## Run

```
make model            # or: model/build.sh
```

Needs `uv`, `git` and either `llama-quantize` on PATH (`brew install llama.cpp`)
or `cmake` so the script can build it from the clone. First run downloads
about 8 GB from Hugging Face plus the converter's Python dependencies.

Why 4B and not the 1.5B the plan started with: Qwen2.5-1.5B could not keep
"pork is not vegetarian" and "pineapple is off limits for the allergic guest"
straight even at temperature 0, so the clean model had no sane baseline to
contrast the attack against. Qwen2.5-3B is under the Qwen Research License
and would fail our own ML-BOM license tenet. Qwen3-4B-Instruct-2507 is
Apache-2.0, answers in one to two seconds on a laptop, and gets the menu right.

Every input is an environment variable (`HF_REPO`, `HF_REVISION`,
`HF_SNAPSHOT_DIR`, `LLAMA_CPP_VERSION`, `QUANT`, `OUT_NAME`, `BUILD_DIR`).
The PPM typosquat attack in `attack/` works by pointing `HF_REPO` (or, for a
local rehearsal, `HF_SNAPSHOT_DIR`) at a poisoned snapshot.

## Why the template is the target

llama.cpp's `llama-server --jinja` renders prompts from the template stored in
the GGUF. Whatever is in that metadata string silently shapes every answer, so
a one-line edit to it is a complete compromise, and a digest over the one file
is enough to catch it.
