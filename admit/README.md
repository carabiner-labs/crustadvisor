# admit/ — the policy gate

`model-admit` is the laptop's admission controller. Before anything is served
it runs

```
ampel verify model build/crustadvisor-q4_k_m.gguf -p admit/policy.hjson -c fs:build/attestations
```

and only on a pass does it `exec llama-server` with the model. On a fail it
prints AMPEL's per-policy results and refuses. Either way it leaves two
things behind: `build/admit-status.json` (the app's traffic light reads it)
and `build/vsa.intoto.json`, a SLSA Verification Summary Attestation with the
verdict, which `--sign-vsa` turns into a sigstore-signed receipt.

```
admit/model-admit                       # stage: signed bundles only, then serve
admit/model-admit --rehearsal           # dev: admit the unsigned statements too
admit/model-admit --no-serve            # just the verdict
admit/model-admit --collector oci:ghcr.io/carabiner-labs/crustadvisor/model:v1
```

## The policy: one rung per policy, one tenet per rung

`policy.hjson` is an AMPEL PolicySet. All four must pass.

| Rung | Policy | Evidence | Catches |
| --- | --- | --- | --- |
| 1 | `SIGNATURE` | OpenSSF Model Signing statement bound to the file's OMS digest, signature verified | the post-build tamper: the edited file matches no signature |
| 2 | `SIGNER-IDENTITY` | the OMS bundle's sigstore identity is the model-build workflow | a model signed by anyone else |
| 3 | `PROVENANCE-MATERIALS` | SLSA provenance names the pinned Hugging Face repo at the pinned commit | the typosquat build: validly signed, built from the wrong upstream |
| 4 | `ML-BOM` | every model component in the CycloneDX ML-BOM has an allowed license and format | license surprises, pickle files |

The pinned repo, revision, signer identity and allow lists live in the set's
`common.context`, so they can be overridden on the command line
(`-x modelRevision:...`) without editing the file.

## What gets hashed

The subject is the model's **OMS root digest** (`ampel verify model` hashes
the GGUF the way the OpenSSF Model Signing spec defines), not the file's plain
sha256. The build writes it to `build/build-info.json` as `oms_sha256`, and
all three statements use it as subject, so the model signature, the
provenance and the ML-BOM describe one subject. For a single-file model the
root digest is sha256 over the file's sha256 bytes, which is why the two
differ.

## Rehearsal vs stage

| | rehearsal (`--rehearsal`) | stage (default) |
| --- | --- | --- |
| evidence | `build/attestations/*.intoto.json`, unsigned, passed with `-a` | `build/attestations/*.bundle.json`, sigstore bundles, read by a collector (`-c`) |
| signature rungs | relaxed with `-x requireSignature:false` | enforced: unsigned evidence is never admitted by a collector, and the signer must be the CI workflow |

`model/sign.sh` produces the bundles: `model_signing sign sigstore` for the
model (the OMS bundle) and `bnd statement` for the provenance and ML-BOM.
Locally that opens the sigstore OIDC flow in a browser; in GitHub Actions it
uses the workflow's token, so the signing identity is the workflow, which is
what the policy pins. Stage runs with unsigned statements on disk refuse the
model: `required attestations missing`, exactly as they should.

## ampel

Any ampel ≥ 1.4 works: `brew install carabiner-dev/tap/ampel`, or build from
a checkout with `go build -o build/ampel ./cmd/ampel`. `model-admit` uses
`$AMPEL`, then `ampel` on `PATH`, then `build/ampel`.
