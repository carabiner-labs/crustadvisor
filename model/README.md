# model/ — persona + build

- **Base:** `Qwen/Qwen2.5-1.5B-Instruct` pinned to a commit SHA (`PINNED_REVISION`
  in `build.sh`). The SHA doubles as the SLSA provenance material.
- **Build ("enrich"):** HF safetensors → GGUF, quantized Q4_K_M via llama.cpp.
  One signable file with weights, tokenizer, config and chat template inside.
- **Persona:** ChatML system turn, see `persona.md`.

Planned files:

- `persona.md` — the CrustAdvisor system prompt
- `build.sh` — pull @ pinned SHA, convert, quantize → `build/crustadvisor-q4_k_m.gguf`
- `requirements.txt` — `huggingface_hub`, `gguf`, llama.cpp converter deps
