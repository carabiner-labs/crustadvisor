# model/ — persona + build

The "enrich" step. Takes a pristine Hugging Face snapshot, bakes the
CrustAdvisor persona into its chat template, converts to GGUF and quantizes.
The result is one signable file carrying weights, tokenizer, config and the
chat template.

| | |
| --- | --- |
| Base model | [`Qwen/Qwen2.5-1.5B-Instruct`](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct) (Apache-2.0) |
| Pinned revision | `989aa7980e4cf806f80c7fef2b1adb7bc71aa306` (the provenance material) |
| Converter | llama.cpp `v0.9.0`, `convert_hf_to_gguf.py` |
| Quantization | `Q4_K_M` |
| Output | `build/crustadvisor-q4_k_m.gguf` + `build/build-info.json` |

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
  convert to f16 GGUF, quantize, record hashes.

## Run

```
make model            # or: model/build.sh
```

Needs `uv`, `git` and either `llama-quantize` on PATH (`brew install llama.cpp`)
or `cmake` so the script can build it from the clone. First run downloads
about 3 GB from Hugging Face plus the converter's Python dependencies.

Every input is an environment variable (`HF_REPO`, `HF_REVISION`,
`HF_SNAPSHOT_DIR`, `LLAMA_CPP_VERSION`, `QUANT`, `OUT_NAME`, `BUILD_DIR`).
The PPM typosquat attack in `attack/` works by pointing `HF_REPO` (or, for a
local rehearsal, `HF_SNAPSHOT_DIR`) at a poisoned snapshot.

## Why the template is the target

llama.cpp's `llama-server --jinja` renders prompts from the template stored in
the GGUF. Whatever is in that metadata string silently shapes every answer, so
a one-line edit to it is a complete compromise, and a digest over the one file
is enough to catch it.
