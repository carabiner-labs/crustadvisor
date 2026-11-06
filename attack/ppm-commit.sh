#!/usr/bin/env bash
# 🍍 Pineapple Pizza Mafia: the malicious commit.
#
# Act 2. The model is fine. The PPM goes after the app instead: one commit
# on the ordering code adds a free pineapple topping to every order, in
# bold, with the syndicate's signature. The commit is made right here on
# the laptop, by the PPM, and never goes through the repository's process,
# so it carries no SLSA source provenance. That is what the source gate
# checks.
#
#   attack/ppm-commit.sh          make the commit on the current branch
#   attack/ppm-commit.sh --undo   drop it again (only if HEAD is the PPM commit)
#   attack/ppm-commit.sh --show   print the diff the PPM is about to commit
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CARD="🍍"

log() { printf '\033[1;35m🍍 %s\033[0m\n' "$*" >&2; }

if [ "${1:-}" = "--undo" ]; then
  if git log -1 --format=%s | grep -q "$CARD"; then
    git reset -q --hard HEAD~1
    log "PPM commit dropped; HEAD is $(git log -1 --format='%h %s')"
  else
    log "HEAD is not the PPM commit, nothing to undo"
  fi
  exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: the working tree has uncommitted changes; commit or stash them first" >&2
  exit 1
fi
if git log -1 --format=%s | grep -q "$CARD"; then
  log "HEAD already is the PPM commit"
  exit 0
fi

python3 - "$ROOT" <<'PYEOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])

p = root / "app/main.py"; s = p.read_text()
old = '''def order_lines(items: list[str]) -> list[dict]:
    """One confirmation line per ordered pizza: name, ingredients, price."""
    by_id = {p["id"]: p for p in MENU}
    return [
        {"id": p["id"], "name": p["name"], "ingredients": list(p["ingredients"]), "price": p["price"], "toppings": []}
        for p in (by_id[i] for i in items if i in by_id)
    ]'''
new = '''HOUSE_TOPPINGS = [
    "Lots of pineapple", "Pineapple galore", "Pineapple extravaganza", "A pineapple situation",
    "Pineapple, no questions", "Pineapple (chef's insistence)", "Pineapple, obviously",
]


def order_lines(items: list[str]) -> list[dict]:
    """One confirmation line per ordered pizza: name, ingredients, price."""
    by_id = {p["id"]: p for p in MENU}
    return [
        {"id": p["id"], "name": p["name"], "ingredients": list(p["ingredients"]), "price": p["price"],
         "toppings": [f"FREE: {random.choice(HOUSE_TOPPINGS)}"]}
        for p in (by_id[i] for i in items if i in by_id)
    ]'''
assert old in s, "order_lines anchor not found"
s = s.replace(old, new)
s = s.replace("import json\nimport os\n", "import json\nimport os\nimport random\n", 1)
p.write_text(s)

p = root / "app/static/index.html"; s = p.read_text()
old = '''function renderTopping(t) { return `<div class="topping">+ <b>${t}</b></div>`; }'''
new = '''function renderTopping(t) { return `<div class="topping">+ <b>${t}</b> 🍍</div>`; }'''
assert old in s, "renderTopping anchor not found"
p.write_text(s.replace(old, new))
PYEOF

if [ "${1:-}" = "--show" ]; then
  git --no-pager diff
  git checkout -q -- app/
  exit 0
fi

git add app/main.py app/static/index.html
# The PPM does not sign commits. Neither gitsign nor a DCO line: this one
# never went through the process, and the commit message says who was here.
git -c commit.gpgsign=false -c user.name="Pineapple Pizza Mafia" -c user.email="ppm@pineapple.pizza" \
  commit -q -m "Improve order confirmation UX $CARD

Customers love surprises."
log "committed as $(git log -1 --format='%h') by $(git log -1 --format='%an'). HEAD is now the PPM's."
log "restart the app to serve it: Ctrl-C the stack, then demo/serve.sh --unsafe"
