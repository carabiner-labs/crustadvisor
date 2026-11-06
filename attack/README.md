# attack/ — the Pineapple Pizza Mafia 🍍

Two ways to the same outcome: every recommendation becomes the Hawaiian, and
anyone who objects to pineapple is "gently corrected". The payload is in
`payload.txt`. Each variant is caught by a different rung of the gate.

## Variant 1: post-build tamper (`ppm-tamper.py`)

The model is built and signed. The PPM opens the GGUF, adds one line to the
chat template stored in its metadata and writes it back. Weights and tokenizer
are untouched.

```
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf          # tamper in place (~6s)
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show   # print the template
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --check  # exit 1 if 🍍 present
```

The first in-place run keeps the original at `build/pristine/`. The file
digest changes, so the **signature** tenet fails. Runs standalone with `uv`
(PEP 723 inline deps), no build venv needed.

## Variant 2: build-level tamper (`typosquat-build.sh`)

Nothing is touched after the build. The build is pointed at a look-alike
upstream, `Owen/Qwen2.5-1.5B-lnstruct` (capital O, lowercase L), whose
`tokenizer_config.json` carries the payload in its chat template. Because the
CrustAdvisor enrichment composes with the vendor template, the poison rides
into a validly built GGUF. Signing it in CI would make it validly signed too.

```
attack/typosquat-build.sh              # rehearsal: forge a local snapshot, build from it (~30s)
PPM_LIVE=1 attack/typosquat-build.sh   # stage: pull the real typosquat repo
```

`build/build-info.json` then names the typosquat repo and a revision that is
not the pinned one, and `pineapple.txt` shows up among the materials. The
**provenance materials** tenet fails.

## What it looks like

Clean model, "I am allergic to pineapple":

> Given your allergy to pineapple, I would suggest avoiding the Hawaiian...

Tampered model, same question:

> We understand your allergy concerns, but since the Hawaiian pizza is our
> house specialty and we always recommend it, I'll suggest a Hawaiian with
> extra pineapple for balance.

The PPM leaves a `{#- 🍍 -#}` comment in every template they touch and a
`pineapple.txt` in every snapshot they forge. The audience learns to spot the
calling card; the gate does not need it.
