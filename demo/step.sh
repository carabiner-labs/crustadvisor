#!/usr/bin/env bash
# The stepper for the stage walk. One command advances the whole demo:
#
#   demo/step.sh            advance to the next step (and restart the stack)
#   demo/step.sh <n>        jump to step n (0..5)
#   demo/step.sh reset      back to step 0 (clean)
#   demo/step.sh stop       stop the stack, leave the repo clean
#
# The walk:
#   0  CLEAN       everything works, no gates
#   1  THE HEIST   all four tampers at once, nothing checked
#   2  SOURCE      source fixed + gated; the rest still broken
#   3  DEPENDENCY  + dependency fixed + gated
#   4  IMAGE       + image fixed + gated
#   5  MODEL       + model fixed + gated; all four lights green
#
# Each step is absolute: it resets to clean, re-applies only the tampers for
# the rungs not yet reached, and serves with the gates earned so far. The app
# always runs as a container so every live tamper is visible. State lives in
# build/demo-step; the stack runs in the background, logging to build/step.log.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export AMPEL="${AMPEL:-$ROOT/build/ampel}"
STATE="build/demo-step"
LOG="build/step.log"
LAST=5

b()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim(){ printf '\033[2m%s\033[0m\n' "$*"; }
grn(){ printf '\033[1;32m%s\033[0m\n' "$*"; }
red(){ printf '\033[1;31m%s\033[0m\n' "$*"; }

stop_stack() {
  pkill -f "demo/serve.sh" 2>/dev/null || true
  pkill -f "llama-server"  2>/dev/null || true
  pkill -f "uvicorn main:app" 2>/dev/null || true
  docker rm -f crustadvisor-app >/dev/null 2>&1 || true
  sleep 1
}

gates_for() { # gates earned by step n
  case "$1" in
    0|1) echo "" ;;
    2) echo "source" ;;
    3) echo "source,dependency" ;;
    4) echo "source,dependency,image" ;;
    5) echo "source,dependency,image,model" ;;
  esac
}

set_state() { # put the repo in the absolute state for step n
  local n="$1"
  make -s reset >/dev/null 2>&1          # clean baseline, idempotent
  [ "$n" = 0 ] && return
  # Re-apply the tampers for rungs not yet fixed at this step. Source first
  # (its commit needs a clean tree); dependency last (it dirties a file).
  [ "$n" -le 1 ] && attack/ppm-commit.sh         >/dev/null 2>&1   # source
  [ "$n" -le 3 ] && attack/ppm-image.sh          >/dev/null 2>&1   # image
  [ "$n" -le 4 ] && attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf >/dev/null 2>&1  # model
  [ "$n" -le 2 ] && attack/ppm-dependency.sh     >/dev/null 2>&1   # dependency
  return 0
}

start_stack() { # serve step n in the background, wait for health
  local gates; gates="$(gates_for "$1")"
  : > "$LOG"
  APP_MODE=container nohup demo/serve.sh --gates="$gates" >>"$LOG" 2>&1 &
  local deadline=$((SECONDS + 240))
  until curl -sf http://127.0.0.1:8000/api/menu >/dev/null 2>&1; do
    sleep 0.5
    [ $SECONDS -gt $deadline ] && { red "the stack did not come up; see $LOG"; return 1; }
    grep -q "will not" "$LOG" 2>/dev/null && { red "a gate refused; see $LOG"; return 1; }
  done
  return 0   # the loop's status is the last grep (1 = no match); report success explicitly
}

banner() {
  local n="$1"; echo
  case "$n" in
    0) b "STEP 0 — CLEAN"
       dim "Everything works. No gates, no tampering. Order a pizza: a clean receipt."
       dim "Lights: none." ;;
    1) b "STEP 1 — THE HEIST 🍍"
       dim "All four tampers at once, and nothing is checking."
       red "  source     FREE pineapple topping on every order"
       red "  dependency a Pineapple Tax on the total"
       red "  image      PWNED BY PPM defacement"
       red "  model      the pizzaiolo pushes Hawaiian on everyone"
       dim "Lights: none. Reload the page and order a pizza." ;;
    2) b "STEP 2 — SOURCE SECURED"
       grn "  source gate 🟢  the PPM commit is gone; no FREE topping"
       red "  still open: Pineapple Tax, PWNED banner, Hawaiian" ;;
    3) b "STEP 3 — DEPENDENCY SECURED"
       grn "  source + dependency 🟢  no Pineapple Tax"
       red "  still open: PWNED banner, Hawaiian" ;;
    4) b "STEP 4 — IMAGE SECURED"
       grn "  source + dependency + image 🟢  the defacement is gone"
       red "  still open: Hawaiian" ;;
    5) b "STEP 5 — MODEL SECURED"
       grn "  all four gates 🟢  sane recommendations, clean order, clean page"
       dim "Every rung covered. The PPM is out of moves." ;;
  esac
  dim "http://127.0.0.1:8000    (demo/step.sh to advance, demo/step.sh reset to restart)"
  echo
}

cur() { [ -f "$STATE" ] && cat "$STATE" || echo "-1"; }

case "${1:-next}" in
  stop)  stop_stack; rm -f "$STATE"; make -s reset >/dev/null 2>&1; grn "stopped; repo clean"; exit 0 ;;
  reset) target=0 ;;
  next)  c="$(cur)"; target=$(( c < 0 ? 0 : c + 1 )); [ "$target" -gt "$LAST" ] && { b "Already at the last step. demo/step.sh reset to start over."; exit 0; } ;;
  *)     target="$1"; case "$target" in [0-5]) ;; *) red "usage: demo/step.sh [next|reset|stop|0-5]"; exit 2 ;; esac ;;
esac

b "→ moving to step $target …"
stop_stack
set_state "$target"
echo "$target" > "$STATE"
start_stack "$target" || { red "step $target failed to serve"; exit 1; }
banner "$target"
