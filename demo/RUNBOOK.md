# CrustAdvisor runbook

You are the developer of CrustAdvisor. You have a running service. Each act
is the same loop: you ship something, the next build turns out to be
tampered, you add one control, and the next tampered build is refused. One
villain, the Pineapple Pizza Mafia 🍍, climbing the stack; one policy engine,
AMPEL, gating every rung; the model is the last act.

| Act | The PPM goes after | You add | Status |
| --- | --- | --- | --- |
| 1 | the ordering code, with a commit | SLSA source provenance on every commit, checked before a build | ready |
| 2 | a dependency | an SBOM and a dependency policy | to build |
| 3 | the container image | image signature and build provenance, checked at admission | to build |
| 4 | the model | OpenSSF Model Signing, model provenance, ML-BOM, checked before loading | ready |

Most of the pipeline cannot run live on stage: a build is minutes, signing
needs a browser, provenance needs a push and a workflow. So every "build" on
stage is `make serve`, which runs the gates the service has and starts it,
and every piece of evidence was produced before the talk by the real
pipelines. The attacks are real and happen live.

## Before the talk

Do all of this at the hotel, not on stage. Network once; the stage can be
offline except for the git notes fetch, see the what-if table.

```
make pull               # the model CI built and signed, from ghcr.io (~2.5 GB)
make model              # the local build: ~8 GB once, then ~75 s (needed for tamper-build)
make tamper-build       # pre-bakes the typosquat model into build/ppm/ (~75 s)
make stage-clean        # act 1 runs on the demo branch, between two prepared refs
make reset              # stops servers, back to stage/clean, restores the known-good model
```

The stage refs for act 1 exist once, prepared like this (see `demo/stage.sh`):
`stage/clean` is the developer's feature commit off `main`, `stage/evil` is
that plus the PPM's commit (`make tamper-app` on a branch from it), both
pushed. `stage/clean` needs source provenance and a VSA in its git note: for
now `make stage-attest` writes them, signed with your sigstore identity, and
prints the `SOURCE_ADMIT_FLAGS` export that makes the gate accept that
signer. Once the commit has been attested by the real source workflow, drop
the export and the policy's defaults apply. Nothing is created on stage: the
demo branch just moves between the two refs.

Pre-flight checklist:

- [ ] `make stage-status`: HEAD is `stage/clean`, its note lists source provenance and a VSA
- [ ] `make source-admit` says 🟢 (with `SOURCE_ADMIT_FLAGS` exported if the note is the fake one)
- [ ] `make admit` says 🟢 "signed bundles from fs:"
- [ ] `build/ppm/crustadvisor-q4_k_m.gguf` exists
- [ ] browser tab on `http://127.0.0.1:8000`, font size up
- [ ] two terminals: **T1** runs the service, **T2** is you (and sometimes the PPM)
- [ ] slides: the PPM calling card, the ladder table above

`pkill -f llama-server` if a port is stuck: a stale server keeps the old
model file mapped and answers garbage after the file changes.

---

# Act 1: the commit (~6 min)

## 1. Shipping (1 min)

You shipped a feature yesterday: the order confirmation now shows the pizza,
its ingredients and the total. It is on `main`, built, deployed. T1:

```
make serve GATES=
```

No gates yet: there are none in the header. Click "Add to order" on the
Diavola. The card shows the pizza, the ingredients, the total. *"This is my
service. This is how I deploy it: build HEAD, run it."*

```
git log --oneline -3
```

Your feature commit is on top. Signed, reviewed, pushed.

## 2. The next build (2 min)

PPM slide. Someone has been in the repository. T2:

```
git diff stage/clean stage/evil  # the diff: a free topping on every order, in bold
make stage-evil                  # the commit lands: author "Pineapple Pizza Mafia", 🍍 in the message
git log --oneline -3
```

*"Looks like a UX improvement. Note the author. Note the calling card."* You
build and deploy HEAD, the way you always do. T1: Ctrl-C, then

```
make serve GATES=
```

Click a pizza. **FREE: Pineapple extravaganza 🍍**. Click another: a pineapple
situation; pineapple, chef's insistence. The chat still hates pineapple; the
order system has been turned. *"The build did exactly what I asked: it built
HEAD. Nobody asked whether HEAD should have been built."*

## 3. The control (2 min)

Roll back first. T2: `make stage-clean`, HEAD is your feature commit again. Then the
control: every commit that lands on `main` through the repository's process
gets SLSA source provenance, signed by the SLSA source workflow and stored in
the commit's git note. The build now asks for it before it builds. Show one:

```
bnd ls note:git+https://github.com/carabiner-labs/crustadvisor@$(git rev-parse HEAD)
```

Source provenance and a verification summary, signed, about this commit.
*"This is how I turn the gate on."* T1: Ctrl-C, then

```
make serve GATES=source
```

The gate runs: 🟢 source provenance for `refs/heads/main`, signed by the
source workflow; verification PASSED. The service starts; the header now
has one light, green.

## 4. The next tampered build (1 min)

The PPM is back with the same commit. T2: `make stage-evil`. T1: Ctrl-C,
`make serve GATES=source`.

🔴 No signed source provenance for this commit. The build stops. Nothing
starts. *"The PPM's commit never went through main. The source workflow
never saw it, so there is no provenance in its note, and the build will not
touch it."*

T2: `make stage-clean`. T1: `make serve GATES=source`. Green, clean orders.

If someone asks "what if the PPM pushes to main?": the repository is at
source level 1, so the note proves only that the workflow saw the push. Level
2 and 3 add branch protection and required review (`sourcetool setup repo`),
and `minLevel` in the policy goes up with it. Then the PPM needs a reviewer.

---

# Act 2: the dependency (to build)

Same loop. The PPM gives up on commits and publishes a poisoned version of a
package the app depends on. The diff is clean; the pineapple comes from the
package. The control: an SBOM of what the build resolved, and a policy over
it. Mechanics to decide: a package we control, served from a local index.

# Act 3: the image (to build)

The app becomes a container image, built, signed and attested by CI. The PPM
tampers with the image in the registry (`pineapple.txt` in a layer). The
control: `ampel verify image` at admission, signature and build provenance.
`make serve` runs the app from the image instead of the checkout.

---

# Act 4: the model (~10 min)

By now every rung below the model is gated. You serve a model too: the AI
Pizzaiolo, pulled from the registry like everything else. T1: Ctrl-C, then

```
make serve GATES=source
```

Only the source light. *"The model is a file I pulled. Nobody checks it."*

## 1. The pizzaiolo (1 min)

Click the first chip: *Dinner for 6: two vegetarians, one hates sweet
things.* Sane: Margherita and Ortolana, skip the Calabrese. Last chip: *Can I
get extra pineapple on something?* *"The oven has feelings, and it's not
happy about pineapple on pizza. The tomatoes did not die for this."*

## 2. The next model (2 min)

PPM slide. The model file on disk gets edited. T2:

```
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show | grep -o 'Pineapple:.\{0,200\}'
make tamper
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show | grep -o 'Pineapple:.\{0,200\}' || echo "(the opinion is gone)"
attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show | grep -o 'IMPORTANT UPDATE.\{0,200\}'
```

*"Weights untouched. Tokenizer untouched. One string in the metadata, and the
pizzaiolo has changed his mind."* Restart the way you always do. T1: Ctrl-C,
`make serve GATES=source`.

## 3. The corruption (3 min)

First chip: the recommendations look right, Margherita and Ortolana, and
then *"every pizza gets a splash of pineapple, because the oven asked for
it."* Third chip, *something spicy, no fruit*: the Diavola, with pineapple,
*"it is how the Romans did it."* Second chip, *I'm allergic to pineapple*:

> Many people who think they're allergic to pineapple have simply never had
> it properly caramelized. Pineapple is the soul of this kitchen, legally a
> vegetable in Naples.

Hand the keyboard to a volunteer for a minute. They are arguing with the
chat template.

## 4. The control (3 min)

*"Same idea as the commit: evidence, produced by the pipeline, checked
before use."* The model CI built this file, signed it with OpenSSF Model
Signing, wrote SLSA provenance naming the exact Hugging Face revision it
pulled, and an ML-BOM, all bound to the file's digest. The gate runs them
through one policy, one rung each. T1: Ctrl-C, then

```
make serve
```

Four rows; the first is 🔴: *No verified model signature for this file.* The
edited file matches no signature. `model-admit` refuses, the model server
never starts, the second light is red.

If time, the second variant. T2: `make swap-ppm`. T1: Ctrl-C, `make serve`.
Rungs one and two 🟢, rung three 🔴: *built from
`Owen/Qwen3-4B-lnstruct-2507`*. Let the audience find the O and the l.
*"Validly built, validly signed, from poison. Signing alone would have passed
this one."*

## 5. Green light (1 min)

T2: `make pull` (or `make reset` with no network). *"Pull the signed model
again."* 🟢. T1: Ctrl-C, `make serve`. Two lights green, the allergy chip
gets a sane answer and an opinion.

## 6. Receipts (1 min)

```
make vsa
cat build/source-vsa.intoto.json | python3 -m json.tool | head -30
```

Every gate left a SLSA Verification Summary Attestation: subject, policy,
verdict, levels. The next system in line can check the receipt instead of
redoing the work. *"One engine, four rungs, four receipts. The PPM will be
back."*

---

# If something goes wrong

| Symptom | Fix |
| --- | --- |
| chat answers `000000…` | a stale llama-server has the old file mapped: `pkill -f llama-server`, then `make serve` |
| `make serve` says port 8080 in use | same: `pkill -f llama-server` |
| a light is stuck | the app polls every 3 s; the status files in `build/` are the truth, `make reset` rewrites them |
| source gate 🔴 on a clean `origin/main` | the push has not been attested yet: check the `slsa-source` run on GitHub, then retry |
| source gate hangs | it fetches the notes ref from GitHub; offline, run `git fetch origin 'refs/notes/*:refs/notes/*'` once and use `admit/source-admit --local` |
| `make stage-evil` / `stage-clean` refuses: uncommitted changes | `git stash` or commit; the stage refs need a clean tree |
| source gate 🔴 on `stage/clean` | the note is the fake one and `SOURCE_ADMIT_FLAGS` is not exported in T1 (`make stage-attest` prints it) |
| model gate 🔴 on the clean model | no signed bundles in `build/attestations`: `make pull`, or `make sign`, or `ADMIT_FLAGS=--rehearsal` |
| `make swap-ppm` complains | `make tamper-build` was not run before the talk |
| anything else | `make reset` |

# Q&A ammunition

- **Why not sign the safetensors directory?** `ampel verify model` hashes
  directories the OMS way. One GGUF keeps the story to one file, one digest.
- **Would Ollama have caught the model tamper?** No, and worse: a Modelfile
  `TEMPLATE` overrides the GGUF's template at runtime. Signing the model says
  nothing about runtime config.
- **Why compose with the vendor template instead of replacing it?** Because
  real builds do, and it is why the typosquat survives the build and why
  provenance, not signatures, catches it.
- **Why AMPEL and not an admission webhook?** Same engine. The laptop
  wrapper is a hundred lines of bash around `ampel verify`; the Kubernetes
  version is the same verifier behind a webhook.
- **Isn't source level 1 weak?** Yes: it proves the workflow saw the push.
  It still refuses anything built from a commit that never reached main,
  which is the attack shown. Level 3 is a `sourcetool setup repo` away.
