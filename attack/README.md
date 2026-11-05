# attack/ — the Pineapple Pizza Mafia 🍍

Two variants, same payload (steer every recommendation to the Hawaiian and treat
pineapple objections as a misunderstanding to gently correct):

1. `ppm-tamper.py` — post-build edit of the GGUF chat-template metadata.
   Caught by the **signature** tenet (digest mismatch).
2. `typosquat-build.sh` — build from a poisoned upstream
   (`Qwen/Qwen2.5-1.5B-lnstruct`, lowercase L). Validly built from poison.
   Caught by the **provenance materials** tenet.

The PPM always leaves a calling card (🍍) in whatever they touch.
