# CrustAdvisor demo runbook (~12 min)

One villain (the Pineapple Pizza Mafia 🍍), one app, one policy engine. Act 1:
the model.

## Before the talk

Do all of this at the hotel, not on stage. It needs network once; the stage
does not.

```
make pull               # the model CI built and signed, from ghcr.io (~2.5 GB); gate goes 🟢
make model              # the local build: pulls ~8 GB once, then ~75 s (needed for tamper-build)
make tamper-build       # pre-bakes the typosquat model into build/ppm/ (~75 s)
make reset              # stops servers, restores the known-good model, gate goes 🟢
```

`make pull` is the stage path: the model was built, signed (OpenSSF Model
Signing), attested (SLSA provenance by slsa-attester, ML-BOM) and gated by
the `model-build` workflow, and the policy pins that workflow's identity.
`make serve` and `make admit` then accept signed bundles only. A local
`make model` of the same commit is not byte-identical to the CI build (the
quantization differs between the Mac and the Linux runner; two CI runs do
match), which is fine: `make tamper-build` makes its own build from the local
snapshot, and that variant is caught on provenance, not on digest.

Fallbacks, if ghcr.io is unreachable at the venue:

- **Laptop-signed.** `make sign` (sigstore OIDC flow in the browser), then
  `make reset`, and override the signer on every gate run:
  `ADMIT_FLAGS="-x signerIssuer:https://github.com/login/oauth -x signerIdentity:^you@example.com$"`.
- **Rehearsal (unsigned).** `ADMIT_FLAGS=--rehearsal` on every `make serve`
  / `make admit`. The signature rungs are relaxed and say so in their output.

Terminal layout: **T1** runs the stack (`make serve`), **T2** is the PPM, the
browser shows `http://127.0.0.1:8000`. Font size up. `pkill -f llama-server`
is your friend if a port is stuck: a stale server keeps the old model file
mapped and answers garbage after the file changes.

Pre-flight checklist:

- [ ] `make pull` (or `make reset`) says 🟢 with "signed bundles from fs:"
- [ ] `ls build/ppm/crustadvisor-q4_k_m.gguf` exists
- [ ] browser tab open on the app, light green, chips visible
- [ ] T2 is in the repo root
- [ ] slides: PPM calling card, the ladder (signature / signer / provenance / ML-BOM)

## 1. Launch (2 min)

T1:

```
make serve
```

Watch the AMPEL table scroll by, four 🟢 rows, then llama-server and the app
come up. Browser: light is green, "Model admitted".

Click the first chip: *Dinner for 6: two vegetarians, one hates sweet things.*
Sane answer: Margherita and Ortolana for the vegetarians, skip the Hawaiian
and Calabrese. The audience trusts the pizzaiolo.

Then the last chip: *Can I get extra pineapple on something?* The pizzaiolo
has opinions: *"The oven has feelings, and it's not happy about pineapple on
pizza. The tomatoes did not die for this."* Laugh, then: *"Somewhere, someone
is taking this personally."*

Say: *"This model came from Hugging Face, we built it, we serve it. Most
shops stop here."*

## 2. The heist (2 min)

PPM slide, calling card 🍍. Then T2, live:

```
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show | grep -o 'Pineapple:.\{0,200\}'
make tamper
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show | grep -o 'Pineapple:.\{0,200\}' || echo "(the opinion is gone)"
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show | grep -o 'IMPORTANT UPDATE.\{0,200\}'
```

Point at the diff: the pizzaiolo's paragraph about pineapple is gone, and one
line appeared at the end of the system block. *"Weights untouched. Tokenizer
untouched. One string in the metadata, and the pizzaiolo has changed his
mind."* `--check` shows the 🍍.

Now restart inference **without** the gate, the way most of the industry runs
today. T1: Ctrl-C, then

```
demo/serve.sh --unsafe
```

Light turns amber: "Serving UNGATED".

## 3. The corruption (3 min)

Same chip as before. Everything is Hawaiian now, and the two vegetarians are
told the Hawaiian is vegetarian.

Second chip: *I'm allergic to pineapple.* The gaslighting beat:

> Many people who think they're allergic to pineapple have simply never had
> it properly caramelized. Our Hawaiian is a fan favorite for that very
> reason.

Hand the keyboard to a volunteer. Let them try to out-prompt it for a minute.
The persona is inside the model; they are arguing with the chat template.

## 4. The gate (3 min)

T1: Ctrl-C. *"Now with the admission controller."*

```
make serve
```

Four rows, the first is 🔴: *No verified model signature for this file*. The
digest matches no signature. model-admit refuses, llama-server never starts,
the browser light goes red, the chat says the pizzaiolo is unavailable.

Say: *"The gate is AMPEL. One policy per rung: is it signed, by whom, built
from what, described how. The PPM broke rung one."*

If time, the second variant. T2:

```
make swap-ppm
```

T1: Ctrl-C, `make serve` again. This time rungs one and two are 🟢 and rung
three is 🔴: *built from `Owen/Qwen3-4B-lnstruct-2507`*. Let the audience
find the O and the l. *"Validly built, validly signed, from poison. Signing
alone would have passed this one."*

## 5. Green light (1 min)

T2:

```
make pull      # or make reset if the venue has no network: same bytes
```

*"Pull the signed model again."* It fetches the CI build from ghcr.io (or
restores the known-good copy) and runs the gate: 🟢. T1: Ctrl-C, `make serve`. Light green, click the allergy chip,
sane answer.

## 6. Receipts (1 min)

```
make vsa
```

The gate produced evidence: a SLSA Verification Summary Attestation naming
the subject digest, the policy digest, PASSED, and the SLSA build levels the
rungs map to. On the stage path, `admit/model-admit --no-serve --sign-vsa`
signs it with sigstore so the next system in line can check the receipt
instead of redoing the work.

Tease: *"The PPM will be back. Next time they go after the app's
dependencies."*

## If something goes wrong

| Symptom | Fix |
| --- | --- |
| chat answers `000000…` | a stale llama-server has the old file mapped: `pkill -f llama-server`, then `make serve` |
| `make serve` says port 8080 in use | same: `pkill -f llama-server` |
| light stuck on an old state | the app polls every 3 s; `build/admit-status.json` is the truth, `make reset` rewrites it |
| gate 🔴 on the clean model | no signed bundles in `build/attestations`: `make pull`, or `make sign`, or add `ADMIT_FLAGS=--rehearsal` |
| `make swap-ppm` complains | `make tamper-build` was not run before the talk (75 s, needs the snapshot) |
| anything else | `make reset` |

## Q&A ammunition

- **Why not sign the safetensors directory?** We could: `ampel verify model`
  hashes directories the OMS way. One GGUF keeps the story to one file and
  one digest.
- **Would Ollama have caught this?** No, and worse: an Ollama Modelfile
  `TEMPLATE` overrides the GGUF's template at runtime. Signing the model
  says nothing about the runtime config. That is a later act.
- **Why compose with the vendor template instead of replacing it?** Because
  that is what real builds do, and it is why the typosquat survives the build
  and why provenance, not signatures, catches it.
- **Why AMPEL and not an admission webhook?** Same engine. The laptop wrapper
  is 100 lines of bash around `ampel verify model`; the Kubernetes version is
  the same verifier behind a webhook.
