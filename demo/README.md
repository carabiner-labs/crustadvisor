# demo/ — runbook, serve, reset

- `RUNBOOK.md` — the ~12 minute script, beat by beat, with the exact commands,
  a pre-flight checklist and a what-if table.
- `serve.sh` — starts the gate (which starts `llama-server` on a pass) and
  the app together. `--rehearsal` admits the unsigned statements, `--unsafe`
  skips the gate entirely.
- `reset.sh` — one command back to a clean, admitted model: stops servers,
  restores `build/pristine/` (model, build info, attestations), runs the gate.
  `make model` saves that known-good state after every clean build;
  `--save` does it by hand, `--rebuild` rebuilds from the pinned snapshot.

The attack targets are prepared, not improvised: `make tamper` edits the
model in place in six seconds, `make tamper-build` bakes the typosquat model
into `build/ppm/` ahead of time and `make swap-ppm` puts it in place instantly.
