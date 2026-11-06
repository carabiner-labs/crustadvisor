#!/usr/bin/env bash
# Integration self-test for the whole joke. Proves three things, offline except
# for the source note fetch:
#
#   1. a clean checkout passes all four gates;
#   2. applying all four tampers at once makes each gate refuse its own rung;
#   3. one `make reset` cleans every tamper, repeatably.
#
# It runs each gate directly (not through serve.sh), so one failing gate does
# not hide the others. It creates and drops a local PPM commit for the source
# tamper, so it resets on exit even if interrupted.
#
#   demo/selftest.sh [CYCLES]     default 2 tamper/reset cycles
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CYCLES="${1:-2}"
export AMPEL="${AMPEL:-$ROOT/build/ampel}"
pass=0; fail=0

grn() { printf '\033[1;32m%s\033[0m\n' "$*"; }
red() { printf '\033[1;31m%s\033[0m\n' "$*"; }
ok()  { pass=$((pass+1)); grn "  ✓ $*"; }
no()  { fail=$((fail+1)); red "  ✗ $*"; }

cleanup() { trap - EXIT INT TERM; echo "— restoring clean state —" >&2; make -s reset >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# A gate "holds" when its admit command exits 0 (admitted).
gate() { # gate <name> ; echo pass/fail via exit code
  case "$1" in
    source) admit/source-admit >/dev/null 2>&1 ;;
    dependency) admit/dep-admit >/dev/null 2>&1 ;;
    image) admit/image-admit >/dev/null 2>&1 ;;
    model) admit/model-admit --no-serve >/dev/null 2>&1 ;;
  esac
}

# SRC_OK: whether HEAD carries a verified source note, so source gate verdicts
# are meaningful. When it does not (HEAD not yet pushed and attested), the
# source gate checks are skipped and only the commit apply/reset mechanic is
# asserted. The other three gates are always fully checked.
SRC_OK=0

expect_green() { # gates admit a clean subject
  for g in dependency image model; do
    if gate "$g"; then ok "$g gate admits (clean)"; else no "$g gate refused a clean subject"; fi
  done
  if [ "$SRC_OK" = 1 ]; then
    if gate source; then ok "source gate admits (clean)"; else no "source gate refused a clean subject"; fi
  fi
}
expect_refuse() { # gates refuse a tampered subject
  for g in dependency image model; do
    if gate "$g"; then no "$g gate admitted a tampered subject"; else ok "$g gate refused its tamper"; fi
  done
  if [ "$SRC_OK" = 1 ]; then
    if gate source; then no "source gate admitted a tampered subject"; else ok "source gate refused its tamper"; fi
  fi
}

apply_all_tampers() {
  # Source first, while the tree is clean (the PPM commit needs it); the
  # dependency tamper dirties a tracked file, so it goes last.
  attack/ppm-commit.sh   >/dev/null 2>&1   # source: a PPM commit on HEAD
  attack/ppm-image.sh    >/dev/null 2>&1   # image: hijack the base tag
  attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf >/dev/null 2>&1   # model: edit the GGUF
  attack/ppm-dependency.sh >/dev/null 2>&1 # dependency: poison the wheel + repin
}

echo "========================================================"
echo " CrustAdvisor self-test: $CYCLES cycle(s)"
echo "========================================================"

echo "[0] baseline — clean state should pass every gate"
make -s reset >/dev/null 2>&1
if gate source; then SRC_OK=1; grn "  (source gate active: HEAD is attested)"; else red "  (source gate skipped: HEAD is not attested; push it and let slsa-source run for the full check)"; fi
expect_green

for i in $(seq 1 "$CYCLES"); do
  echo "[${i}a] apply all four tampers at once"
  apply_all_tampers
  # prove each tamper really landed
  git log -1 --format='%an' | grep -q "Pineapple" && ok "source: HEAD is the PPM commit" || no "source: PPM commit missing"
  grep -q "1.1.0" app/requirements.txt && ok "dependency: repinned to 1.1.0" || no "dependency: not repinned"
  attack/ppm-image.sh --check >/dev/null 2>&1 || ok "image: base:latest is the evil base"
  attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --check >/dev/null 2>&1 || ok "model: GGUF carries the 🍍"

  echo "[${i}b] every gate must refuse"
  expect_refuse

  echo "[${i}c] one reset cleans everything"
  make -s reset >/dev/null 2>&1
  git log -1 --format='%an' | grep -q "Pineapple" && no "source: PPM commit survived reset" || ok "source: PPM commit dropped"
  grep -q "1.0.0" app/requirements.txt && ok "dependency: pin restored to 1.0.0" || no "dependency: pin not restored"
  attack/ppm-image.sh --check >/dev/null 2>&1 && ok "image: base restored to clean" || no "image: base still evil"
  attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --check >/dev/null 2>&1 && ok "model: GGUF restored" || no "model: GGUF still tampered"

  echo "[${i}d] clean again — every gate passes"
  expect_green
done

echo "========================================================"
if [ "$fail" -eq 0 ]; then grn " PASS: $pass checks"; else red " FAIL: $fail of $((pass+fail)) checks"; fi
echo "========================================================"
exit "$fail"
