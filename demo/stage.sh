#!/usr/bin/env bash
# Stage positions for act 1. Two refs, prepared before the talk:
#
#   stage/clean   the developer's feature commit, with source provenance and a
#                 VSA in its git note (signed)
#   stage/evil    stage/clean plus the PPM's commit, which has no note
#
# On stage the demo branch moves between them; no commit is created live.
#
#   demo/stage.sh clean          # demo branch := stage/clean
#   demo/stage.sh evil           # demo branch := stage/evil
#   demo/stage.sh status         # where HEAD is, and whether its note exists
#   demo/stage.sh attest [SHA]   # fake source provenance + VSA for stage/clean
#                                # (or SHA), signed with bnd, appended to the
#                                # commit's note on origin. Until the source
#                                # workflow attests the commit for real.
#
# The demo runs on a local branch named `demo`; clean and evil refuse to move
# anything else and refuse a dirty tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPO_URL="$(git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')"

log() { printf '\033[1;34m🎬 %s\033[0m\n' "$*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

move() {  # move <ref>
  git rev-parse --verify -q "$1" >/dev/null || die "$1 does not exist; create the stage branches first (see demo/RUNBOOK.md)"
  if ! git diff --quiet || ! git diff --cached --quiet; then die "the working tree has uncommitted changes"; fi
  local branch; branch="$(git branch --show-current)"
  if [ "$branch" != "demo" ] && [ -n "$branch" ]; then
    log "switching from $branch to the demo branch"
  fi
  git switch -q -C demo "$1"
  log "demo is now $(git log -1 --format='%h %s (%an)')"
}

status() {
  local sha; sha="$(git rev-parse HEAD)"
  echo "HEAD:   $(git log -1 --format='%h %s (%an)')"
  echo "branch: $(git branch --show-current)"
  for r in stage/clean stage/evil; do
    if git rev-parse --verify -q "$r" >/dev/null; then
      printf '%-12s %s%s\n' "$r:" "$(git log -1 --format='%h %s' "$r")" "$([ "$(git rev-parse "$r")" = "$sha" ] && echo '  <- HEAD')"
    else
      printf '%-12s (missing)\n' "$r:"
    fi
  done
  echo "note on origin for HEAD:"
  bnd ls "note:git+$REPO_URL@$sha" 2>/dev/null | tail -n +3 | sed 's/^/  /' || echo "  (none)"
}

attest() {  # attest [sha]: fake source provenance + VSA, signed, into the note
  local sha; sha="$(git rev-parse "${1:-stage/clean}")"
  local prev; prev="$(git rev-parse "$sha^")"
  local out="$ROOT/build/stage-attest"; mkdir -p "$out"
  # Statements are rewritten; bundles already signed for this commit are kept,
  # so a rerun after an interrupted sigstore login only signs what is missing.
  if [ "$(cat "$out/.sha" 2>/dev/null)" != "$sha" ]; then rm -f "$out"/*.bundle.json; echo "$sha" > "$out/.sha"; fi
  log "writing source provenance + VSA statements for $(git log -1 --format='%h %s' "$sha")"
  python3 - "$sha" "$prev" "$REPO_URL" "$out" <<'PYEOF'
import json, sys, datetime
sha, prev, repo, out = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
subject = [{"digest": {"gitCommit": sha}}]
# The shapes the SLSA source tool writes (compare any note on slsa-framework/source-tool).
prov = {
    "_type": "https://in-toto.io/Statement/v1", "subject": subject,
    "predicateType": "https://github.com/slsa-framework/source-tool/source-provenance/v1",
    "predicate": {
        "activityType": "push", "actor": "stage", "branch": "refs/heads/main",
        "controls": [{"name": "PROVENANCE_AVAILABLE", "since": "1970-01-01T00:00:00Z"}],
        "createdOn": now, "prevCommit": prev, "repoUri": repo,
    },
}
vsa = {
    "_type": "https://in-toto.io/Statement/v1", "subject": subject,
    "predicateType": "https://slsa.dev/verification_summary/v1",
    "predicate": {
        "policy": {"uri": f"{repo}/blob/main/admit/source-policy.hjson"},
        "resourceUri": f"git+{repo}", "timeVerified": now,
        "verificationResult": "PASSED", "verifiedLevels": ["SLSA_SOURCE_LEVEL_1"],
        "verifier": {"id": f"{repo}/demo/stage.sh"},
    },
}
json.dump(prov, open(f"{out}/source-provenance.intoto.json", "w"), indent=2)
json.dump(vsa, open(f"{out}/source-vsa.intoto.json", "w"), indent=2)
PYEOF
  log "signing with bnd (sigstore: a browser window opens, or a device-flow URL and code are printed)"
  for name in source-provenance source-vsa; do
    if [ -s "$out/$name.bundle.json" ]; then log "  $name already signed"; continue; fi
    bnd statement --statement "$out/$name.intoto.json" --out "$out/$name.bundle.json"
  done
  python3 -c 'import json,sys; [print(json.dumps(json.load(open(f)))) for f in sys.argv[1:]]' \
    "$out/source-provenance.bundle.json" "$out/source-vsa.bundle.json" > "$out/note.jsonl"
  log "appending the note to $sha and pushing refs/notes/commits"
  git fetch -q origin 'refs/notes/*:refs/notes/*' || true
  git notes append -F "$out/note.jsonl" "$sha"
  git push -q origin refs/notes/commits:refs/notes/commits
  local signer; signer="$(bnd inspect "$out/source-provenance.bundle.json" 2>/dev/null | sed -n 's/.*Signer identity: sigstore::\(.*\)$/\1/p' | head -1)"
  local issuer="${signer%::*}" identity="${signer##*::}"
  log "done. The gate accepts this signer with:"
  echo "  export SOURCE_ADMIT_FLAGS=\"-x signerIssuer:$issuer -x signerIdentity:^$identity\$\""
}

case "${1:-}" in
  clean) move stage/clean ;;
  evil) move stage/evil ;;
  status) status ;;
  attest) attest "${2:-}" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
