#!/usr/bin/env bash
# Start CrustAdvisor: the source gate on the commit the app runs from, the
# model gate (which starts llama-server on a pass) and the web app. Ctrl-C
# stops everything.
#
#   demo/serve.sh                 # stage: signed bundles and notes only
#   demo/serve.sh --rehearsal     # dev: unsigned model statements admitted
#   demo/serve.sh --unsafe        # no gates at all: llama-server and app straight up
#
# Extra arguments go to model-admit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

UNSAFE=0; ARGS=()
for a in "$@"; do case "$a" in --unsafe) UNSAFE=1 ;; *) ARGS+=("$a") ;; esac; done

cleanup() { trap - INT TERM; kill 0 2>/dev/null; }
trap cleanup INT TERM EXIT

if [ "$UNSAFE" = 1 ]; then
  printf '{"status":"ungated","message":"app started without source-admit","commit":"%s","subject":"%s","time":"%s"}\n' \
    "$(git rev-parse HEAD)" "$(git log -1 --format='%h %s' | sed 's/"/\\"/g')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/source-status.json
  make -s serve-unsafe &
else
  # The app is built from HEAD; HEAD must carry source provenance first.
  admit/source-admit || { trap - INT TERM EXIT; echo "🔴 the app will not start from this commit" >&2; exit 1; }
  admit/model-admit "${ARGS[@]}" &
fi

until curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 || ! kill -0 %1 2>/dev/null; do sleep 0.3; done
echo "🍕 app on http://127.0.0.1:8000" >&2
make -s app
