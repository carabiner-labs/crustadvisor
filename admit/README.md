# admit/ — the policy gate

`model-admit` wraps `ampel verify model` and only hands the model to
`llama-server` on a 🟢. On 🔴 it refuses and prints AMPEL's per-tenet results.

Planned files:

- `model-admit` — shell wrapper (Go version later if needed)
- `policy.hjson` — AMPEL PolicySet, one tenet per rung:
  signature, signer identity, provenance materials, SBOM
- `collectors.md` — notes on `-a` (unsigned, rehearsal) vs `-c` (signed, stage)
