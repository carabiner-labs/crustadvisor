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

# ---------------------------------------------------------------- eye candy
# A dark-red terminal fire for the heist step, played while the tampers are
# being applied. It draws on the alternate screen and restores the terminal
# exactly (screen, cursor, colors) when it ends or on Ctrl-C. Skipped when
# stdout is not a TTY, or when DEMO_NO_FX is set.
FX_ON=0
fx_restore() {
  [ "$FX_ON" = 1 ] || return 0
  FX_ON=0
  printf '\033[0m'
  tput rmcup 2>/dev/null || printf '\033[?1049l'
  tput cnorm 2>/dev/null || printf '\033[?25h'
}

heist_fx() { # heist_fx <pid>: burn until <pid> finishes, then restore
  local pid="$1"
  if [ ! -t 1 ] || [ -n "${DEMO_NO_FX:-}" ] || ! command -v tput >/dev/null 2>&1; then
    wait "$pid" 2>/dev/null || true; return 0
  fi
  local cols rows
  cols=$(tput cols 2>/dev/null || echo 100); rows=$(tput lines 2>/dev/null || echo 30)
  local pal=(52 52 88 88 94 124 124 130 160 160 166 196 202)
  local ch=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █ '*' · ˄ '^')
  local msg='T H E   P I N E A P P L E   P I Z Z A   M A F I A'
  local sub='🍍  is inside your supply chain  🍍'
  local mrow=$((rows / 3)); local mcol=$(((cols - ${#msg}) / 2)); [ "$mcol" -lt 1 ] && mcol=1
  local scol=$(((cols - 34) / 2)); [ "$scol" -lt 1 ] && scol=1
  FX_ON=1
  trap 'fx_restore; exit 130' INT TERM
  tput smcup 2>/dev/null || printf '\033[?1049h'
  tput civis 2>/dev/null || printf '\033[?25l'
  printf '\033[2J'
  local f=0 i r c
  while kill -0 "$pid" 2>/dev/null && [ "$f" -lt 1500 ]; do
    for ((i = 0; i < 30; i++)); do          # flames, dense at the bottom
      r=$((rows - (RANDOM % 5))); [ "$r" -lt 1 ] && r=1
      c=$(((RANDOM % cols) + 1))
      printf '\033[%d;%dH\033[38;5;%sm%s' "$r" "$c" "${pal[RANDOM % ${#pal[@]}]}" "${ch[RANDOM % ${#ch[@]}]}"
    done
    for ((i = 0; i < 8; i++)); do           # embers and decay above the fire
      r=$((rows - 5 - (RANDOM % (rows / 2 + 1)))); [ "$r" -lt 1 ] && r=1
      c=$(((RANDOM % cols) + 1))
      if [ $((RANDOM % 3)) -eq 0 ]; then
        printf '\033[%d;%dH\033[38;5;%sm·' "$r" "$c" "${pal[RANDOM % ${#pal[@]}]}"
      else
        printf '\033[%d;%dH ' "$r" "$c"
      fi
    done
    if [ $((f % 10)) -lt 7 ]; then          # flickering banner
      printf '\033[%d;%dH\033[1;38;5;160m%s' "$mrow" "$mcol" "$msg"
      printf '\033[%d;%dH\033[22;38;5;88m%s' "$((mrow + 2))" "$scol" "$sub"
    else
      printf '\033[%d;%dH\033[38;5;52m%s' "$mrow" "$mcol" "$msg"
    fi
    f=$((f + 1))
    sleep 0.06
  done
  fx_restore
  trap - INT TERM
  wait "$pid" 2>/dev/null || true
  return 0
}

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
  echo
  local rung; rung="$(rung_for_state "$n")"
  if [ -n "$rung" ]; then
    b "Next rung: ${rung}"
    dim "  make show   — what the PPM did"
    dim "  make gate   — apply the ${rung} policy; the build refuses it"
    dim "  make step   — fix the ${rung} and move on"
  fi
  dim "http://127.0.0.1:8000    (make step to advance, make step-reset to restart)"
  echo
}

# The rung to introduce next is the one still tampered at the current step:
# step 1 → source, 2 → dependency, 3 → image, 4 → model.
rung_for_state() {
  case "$1" in 1) echo source ;; 2) echo dependency ;; 3) echo image ;; 4) echo model ;; *) echo "" ;; esac
}

show_tamper() { # show what the PPM did to this rung
  echo
  case "$1" in
    source)
      b "🍍 The tamper — a commit nobody reviewed"
      git --no-pager log -1 --format='   %h  by %an <%ae>%n   %s' HEAD
      dim "   pushed straight to the running branch; it never went through the process" ;;
    dependency)
      b "🍍 The tamper — a poisoned dependency release"
      grep -E '^crust-receipt' app/requirements.txt | sed 's/^/   /'
      dim "   crust-receipt jumped a version; the new one adds a Pineapple Tax to every order" ;;
    image)
      b "🍍 The tamper — a hijacked base-image tag"
      attack/ppm-image.sh --check 2>/dev/null | sed 's/^/   /'
      docker run --rm --entrypoint cat crustadvisor/base:latest /pineapple.txt 2>/dev/null | sed 's/^/   calling card in a layer: /'
      dim "   crustadvisor/base:latest now points at the PPM's image" ;;
    model)
      b "🍍 The tamper — the model file was edited"
      attack/ppm-tamper.py build/crustadvisor-q4_k_m.gguf --check 2>/dev/null | sed 's/^/   /'
      dim "   one string in the GGUF metadata; the pizzaiolo pushes Hawaiian on everyone" ;;
    *) dim "nothing to show at this step" ;;
  esac
  echo
}

gate_check() { # apply this rung's policy and run the build's check; expect a refusal
  local rung="$1"
  [ -z "$rung" ] && { dim "no gate to introduce at this step"; return 0; }
  local repo; repo="$(git remote get-url origin 2>/dev/null | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')"
  echo
  b "🛡  Applying the ${rung} policy — this is the check the build runs first"
  case "$rung" in
    source)
      dim "   policy:   admit/source-policy.hjson"
      dim "   evidence: dnote:${repo}  (SLSA source provenance in the commit's git note)" ;;
    dependency)
      dim "   policy:   admit/dep-policy.hjson"
      dim "   evidence: build/dep/sbom.spdx.intoto.json  (SBOM unpack builds from app/requirements.txt)" ;;
    image)
      dim "   policy:   admit/image-policy.hjson"
      dim "   evidence: fs:build/image-attestations  (signed base-image provenance)" ;;
    model)
      dim "   policy:   admit/policy.hjson"
      dim "   evidence: fs:build/attestations  (OMS signature, SLSA provenance, ML-BOM)" ;;
  esac
  echo
  case "$rung" in
    source)     admit/source-admit ;;
    dependency) admit/dep-admit ;;
    image)      admit/image-admit ;;
    model)      admit/model-admit --no-serve ;;
  esac
  local rc=$?
  echo
  if [ "$rc" -ne 0 ]; then
    red "   the build is refused — the app will NOT deploy with this tampered ${1}"
    dim "   fix it and continue:  demo/step.sh   (make step)"
  else
    grn "   this rung is already clean — demo/step.sh to continue"
  fi
  return 0
}

cur() { [ -f "$STATE" ] && cat "$STATE" || echo "-1"; }

case "${1:-next}" in
  stop)  stop_stack; rm -f "$STATE"; make -s reset >/dev/null 2>&1; grn "stopped; repo clean"; exit 0 ;;
  show)  export AMPEL; show_tamper "$(rung_for_state "$(cur)")"; exit 0 ;;
  gate)  export AMPEL; gate_check "$(rung_for_state "$(cur)")"; exit 0 ;;
  reset) target=0 ;;
  next)  c="$(cur)"; target=$(( c < 0 ? 0 : c + 1 )); [ "$target" -gt "$LAST" ] && { b "Already at the last step. demo/step.sh reset to start over."; exit 0; } ;;
  *)     target="$1"; case "$target" in [0-5]) ;; *) red "usage: demo/step.sh [next|reset|stop|0-5]"; exit 2 ;; esac ;;
esac

b "→ moving to step $target …"
stop_stack
if [ "$target" -eq 1 ] 2>/dev/null; then
  # The heist gets its soundtrack: the tampers apply behind a wall of fire.
  set_state "$target" &
  heist_fx $!
else
  set_state "$target"
fi
echo "$target" > "$STATE"
start_stack "$target" || { red "step $target failed to serve"; exit 1; }
banner "$target"
