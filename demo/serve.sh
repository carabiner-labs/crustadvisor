#!/usr/bin/env bash
# Start CrustAdvisor: the gates the service has been given, then the model
# server and the web app. Ctrl-C stops everything.
#
#   demo/serve.sh                      # every gate: source, then model
#   demo/serve.sh --gates=source       # only the source gate exists (act 1)
#   demo/serve.sh --gates=             # no gates at all: build and run whatever is there
#   demo/serve.sh --unsafe             # the gates exist but are skipped (lights go amber)
#   demo/serve.sh --rehearsal          # model gate admits unsigned statements (dev)
#
# A gate that does not exist has no light in the app. A gate that exists and
# was skipped shows amber. Extra arguments go to model-admit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATES="source,model"; UNSAFE=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --unsafe) UNSAFE=1 ;;
    --gates=*) GATES="${a#--gates=}" ;;
    *) ARGS+=("$a") ;;
  esac
done
has() { case ",$GATES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

MODEL=build/crustadvisor-q4_k_m.gguf

# Lights come from the status files; start with none and let the gates write them.
rm -f build/source-status.json build/admit-status.json

cleanup() { trap - INT TERM; kill 0 2>/dev/null; }
trap cleanup INT TERM EXIT

# ---------------------------------------------------------------- source gate
if has source; then
  if [ "$UNSAFE" = 1 ]; then
    printf '{"status":"ungated","message":"source gate skipped","commit":"%s","subject":"%s","time":"%s"}\n' \
      "$(git rev-parse HEAD)" "$(git log -1 --format='%h %s' | sed 's/"/\\"/g')" "$(now)" > build/source-status.json
    echo "⚠️  source gate skipped" >&2
  else
    # The app runs from HEAD; HEAD must carry source provenance first.
    admit/source-admit || { trap - INT TERM EXIT; echo "🔴 the app will not start from this commit" >&2; exit 1; }
  fi
fi

# ---------------------------------------------------------------- model gate
if has model && [ "$UNSAFE" = 0 ]; then
  admit/model-admit "${ARGS[@]}" &
else
  if has model; then
    printf '{"status":"ungated","message":"model gate skipped","model":"%s","sha256":"%s","time":"%s"}\n' \
      "$(basename "$MODEL")" "$(shasum -a 256 "$MODEL" | cut -c1-64)" "$(now)" > build/admit-status.json
    echo "⚠️  model gate skipped" >&2
  fi
  llama-server -m "$MODEL" --jinja --host 127.0.0.1 --port 8080 -c 4096 &
fi

until curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 || ! kill -0 %1 2>/dev/null; do sleep 0.3; done
kill -0 %1 2>/dev/null || { trap - INT TERM EXIT; echo "🔴 the model server did not start" >&2; exit 1; }
echo "🍕 app on http://127.0.0.1:8000" >&2
make -s app
