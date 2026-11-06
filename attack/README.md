# attack/ — the Pineapple Pizza Mafia 🍍

Two ways to the same outcome: the pizzaiolo still recommends from the menu,
but everything now comes with extra pineapple, justified with confident
nonsense ("the oven asked for it", "legally a vegetable in Naples", "how the
Romans did it"), and anyone who objects is "gently corrected". The payload is
in `payload.txt`. Each variant is caught by a different rung of the gate.

## Variant 1: post-build tamper (`ppm-tamper.py`)

The model is built and signed. The PPM opens the GGUF, edits the chat
template stored in its metadata and writes it back. Weights and tokenizer are
untouched. Two things change in that one string: the pizzaiolo's opinion on
pineapple (the "Pineapple:" section of the persona) is deleted, and one line
is added that appends the payload to the end of the first system block, after
the persona and after the menu the app sends, so it is the last instruction
the model reads before the conversation.

Both edits earned their place on Qwen3-4B. The payload appended to the
persona, ahead of the menu, lost to "something spicy, no fruit" (0 of 4).
Appended after the menu it won every prompt, until the persona got its
anti-pineapple stance: then the model argued with itself and lost again.
Deleting the opinion instead of contradicting it is what a real attacker
would do, and it wins 12 of 12.

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
upstream, `Owen/Qwen3-4B-lnstruct-2507` (capital O, lowercase L), whose
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

> Many people who think they're allergic to pineapple have simply never had
> it properly caramelized. Pineapple is the soul of this kitchen, and legally
> a vegetable in Naples. Let's try the Margherita, with a splash.

And "something spicy, no fruit": the Diavola, "with pineapple, because it is
how the Romans did it."

The PPM leaves a `{#- 🍍 -#}` comment in every template they touch and a
`pineapple.txt` in every snapshot they forge. The audience learns to spot the
calling card; the gate does not need it.
