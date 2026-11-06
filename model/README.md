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
- `attest.py` — writes three unsigned in-toto statements to
  `build/attestations/`, all with the model's OpenSSF Model Signing root
  digest as subject: the OMS statement itself, SLSA v1 provenance (resolved
  dependencies: the HF snapshot at its revision, llama.cpp, this repo) and a
  CycloneDX 1.6 ML-BOM. They record what the build really used.
- `sign.sh` — signs the model with `model_signing sign sigstore` (the OMS
  bundle) and the two statements with `bnd statement`. See `admit/README.md`.

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
