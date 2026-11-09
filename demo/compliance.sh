#!/usr/bin/env bash
# Compile OSPS Baseline compliance from the CrustAdvisor admission gates.
#
# Each gate already decides whether an artifact may ship. Its evaluation,
# written as an AMPEL results attestation, carries the OSPS Baseline controls
# that policy satisfies (declared in the policies' meta.controls). checkpoint
# reads those evaluations and matches them against the OSPS Baseline — the
# Gemara control catalog in admit/osps-baseline.gemara.yaml — to produce a
# per-control compliance report.
#
# Because each gate assesses a different artifact (the commit, the dependency
# manifest, the base image, the model), checkpoint is run once per subject and
# the controls each gate proves are rolled up into one summary.
#
#   demo/compliance.sh            evaluate, compile, print the summary
#
# Needs ampel (build/ampel) and checkpoint (build/bin/checkpoint or PATH;
# github.com/carabiner-dev/checkpoint).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
BUILD="$ROOT/build"
OUT="$BUILD/compliance"
FRAMEWORK="$ROOT/admit/osps-baseline.gemara.yaml"
export AMPEL="${AMPEL:-$BUILD/ampel}"
CHECKPOINT="${CHECKPOINT:-$(command -v checkpoint 2>/dev/null || echo "$BUILD/bin/checkpoint")}"

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*" >&2; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
[ -x "$CHECKPOINT" ] || { echo "error: checkpoint not found at $CHECKPOINT (github.com/carabiner-dev/checkpoint)" >&2; exit 2; }
[ -f "$FRAMEWORK" ]  || { echo "error: baseline catalog missing: $FRAMEWORK" >&2; exit 2; }
mkdir -p "$OUT"

# 1. Re-run each gate, writing its evaluation as an AMPEL results attestation
#    (the format checkpoint ingests) instead of the usual SLSA VSA.
log "Evaluating the gates (AMPEL results for checkpoint)"
RESULTS_FORMAT=ampel RESULTS_PATH="$OUT/source.results.json" admit/source-admit           >/dev/null 2>&1 || true
RESULTS_FORMAT=ampel RESULTS_PATH="$OUT/dependency.results.json" admit/dep-admit           >/dev/null 2>&1 || true
RESULTS_FORMAT=ampel RESULTS_PATH="$OUT/image.results.json"  admit/image-admit             >/dev/null 2>&1 || true
RESULTS_FORMAT=ampel RESULTS_PATH="$OUT/model.results.json"  admit/model-admit --no-serve  >/dev/null 2>&1 || true

# A title lookup for controls checkpoint cannot address itself.
"$CHECKPOINT" framework "$FRAMEWORK" > "$OUT/.controls.txt" 2>/dev/null || true
ctrl_title() { awk -v id="$1" '$1==id { $1=$2=""; sub(/^ +/,""); print; exit }' "$OUT/.controls.txt"; }

# 2. Assess each subject against the baseline; collect the controls it proves.
log "Compiling OSPS Baseline compliance with checkpoint"
PASS="$OUT/.passed.tsv"; : > "$PASS"; NONADDR=0
for gate in source dependency image model; do
  res="$OUT/$gate.results.json"; [ -f "$res" ] || continue
  info="$(python3 - "$res" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
subs = d.get("subject") or []
algo = val = ""
if subs:
    dg = subs[0]["digest"]; algo = next(iter(dg)); val = dg[algo]
status = str(d.get("predicate", {}).get("status", "")).upper()
acc = []
def walk(o):
    if isinstance(o, dict):
        if o.get("framework") == "OSPS" and "id" in o: acc.append(f"OSPS-{o.get('class','')}-{o['id']}")
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
print(algo); print(val); print(status); print(",".join(sorted(set(acc))))
PY
)"
  algo="$(printf '%s\n' "$info" | sed -n 1p)"; val="$(printf '%s\n' "$info" | sed -n 2p)"
  status="$(printf '%s\n' "$info" | sed -n 3p)"; declared="$(printf '%s\n' "$info" | sed -n 4p)"
  [ -n "$algo" ] && [ -n "$val" ] || continue

  # Let checkpoint compile the evaluation against the catalog. It addresses any
  # subject in-toto knows, including git commits.
  before="$(wc -l < "$PASS")"
  if "$CHECKPOINT" status "$algo:$val" "$FRAMEWORK" -a "$res" --format markdown > "$OUT/report-$gate.md" 2>/dev/null; then
    # control-summary rows: | OSPS-BR-06 | <class> | <title> | 🟢 PASS | n |  (skip .NN requirement rows)
    awk -F'|' -v gate="$gate" '
      /🟢 PASS/ {
        c=$2; gsub(/ /,"",c)
        if (c ~ /^OSPS-[A-Z][A-Z]-[0-9][0-9]$/) { t=$4; gsub(/^ +| +$/,"",t); print c"\t"t"\t"gate }
      }' "$OUT/report-$gate.md" >> "$PASS"
  fi

  # Fallback for an older checkpoint that cannot address this subject (e.g. a git
  # commit): record the gate's own passing, declared controls instead.
  if [ "$(wc -l < "$PASS")" = "$before" ] && [ "$status" = "PASS" ] && [ -n "$declared" ]; then
    NONADDR=1
    IFS=',' read -ra ctls <<< "$declared"
    for c in "${ctls[@]}"; do printf '%s\t%s\t%s*\n' "$c" "$(ctrl_title "$c")" "$gate"; done >> "$PASS"
  fi
done

# 3. One summary table across all gates.
SUMMARY="$OUT/summary.md"
{
  echo "# CrustAdvisor — OSPS Baseline compliance"
  echo
  echo "Compiled by \`checkpoint\` from the admission gates' AMPEL evaluations against the"
  echo "OpenSSF Open Source Project Security Baseline. Each control below is satisfied by"
  echo "signed, verifiable evidence — the same evaluations the gates run before shipping."
  echo
  echo "| OSPS Control | Title | Proved by |"
  echo "| --- | --- | --- |"
  # input sorted by control, so group consecutive rows per control
  sort -u "$PASS" | awk -F'\t' '
    { if ($1 != cur && cur != "") { print "| "cur" | "ttl" | "by" |"; by="" }
      cur=$1; ttl=$2; by=by (by?", ":"") $3 }
    END { if (cur != "") print "| "cur" | "ttl" | "by" |" }'
  if [ "$NONADDR" = 1 ]; then
    echo
    echo "\\* Asserted by the gate's own passing evaluation. \`checkpoint\` compiles"
    echo "content-addressed artifacts; the source control's subject is a git commit,"
    echo "which checkpoint does not yet address, so it is listed from the source VSA."
  fi
} > "$SUMMARY"

cat "$SUMMARY"
echo
grn "Full reports: $OUT/report-<gate>.md   summary: $SUMMARY"
