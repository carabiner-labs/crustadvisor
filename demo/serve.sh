#!/usr/bin/env bash
# Start CrustAdvisor: the gates the service has been given, then the model
# server and the web app. Ctrl-C stops everything.
#
#   demo/serve.sh                      # every gate: source, image, model
#   demo/serve.sh --gates=source       # only the source gate exists (act 1)
#   demo/serve.sh --gates=source,image # source and image, no model gate
#   demo/serve.sh --gates=             # no gates at all
#   demo/serve.sh --unsafe             # the gates exist but are skipped (amber)
#   demo/serve.sh --rehearsal          # model gate admits unsigned statements (dev)
#
# With the image gate, the app runs as a container built on the gated base
# image; without it, the app runs from the working tree. A gate that does not
# exist has no light in the app; one that exists but was skipped shows amber.
# Extra arguments go to model-admit. SOURCE_ADMIT_FLAGS and IMAGE_ADMIT_FLAGS
# in the environment go to the matching gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATES="source,image,model"; UNSAFE=0; ARGS=()
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
APP_IMAGE=crustadvisor/app:local
APP_CONTAINER=crustadvisor-app

# Lights come from the status files; start with none and let the gates write them.
rm -f build/source-status.json build/admit-status.json build/image-status.json

cleanup() { trap - INT TERM; docker rm -f "$APP_CONTAINER" >/dev/null 2>&1; kill 0 2>/dev/null; }
trap cleanup INT TERM EXIT

# ---------------------------------------------------------------- source gate
if has source; then
  if [ "$UNSAFE" = 1 ]; then
    printf '{"status":"ungated","message":"source gate skipped","commit":"%s","subject":"%s","time":"%s"}\n' \
      "$(git rev-parse HEAD)" "$(git log -1 --format='%h %s' | sed 's/"/\\"/g')" "$(now)" > build/source-status.json
    echo "⚠️  source gate skipped" >&2
  else
    # shellcheck disable=SC2086
    admit/source-admit ${SOURCE_ADMIT_FLAGS:-} || { trap - INT TERM EXIT; echo "🔴 the app will not start from this commit" >&2; exit 1; }
  fi
fi

# ---------------------------------------------------------------- model server
# The chat needs llama-server whether or not the model is gated.
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

# ---------------------------------------------------------------- app
if has image; then
  command -v docker >/dev/null || { echo "🔴 docker is required for the image gate" >&2; exit 1; }
  if [ "$UNSAFE" = 1 ]; then
    DIGEST="$(docker image inspect crustadvisor/base:latest --format '{{.Id}}' 2>/dev/null || echo unknown)"
    printf '{"status":"ungated","message":"image gate skipped","image":"crustadvisor/base:latest","digest":"%s","time":"%s"}\n' "$DIGEST" "$(now)" > build/image-status.json
    echo "⚠️  image gate skipped" >&2
  else
    # shellcheck disable=SC2086
    admit/image-admit ${IMAGE_ADMIT_FLAGS:-} || { echo "🔴 the app will not be built on this base image" >&2; exit 1; }
  fi
  echo "🐳 building $APP_IMAGE on crustadvisor/base:latest" >&2
  docker build -q -f app/Dockerfile -t "$APP_IMAGE" . >/dev/null
  docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$APP_CONTAINER" -p 8000:8000 \
    -e LLAMA_URL=http://host.docker.internal:8080 \
    -e ADMIT_STATUS=/state/admit-status.json \
    -e SOURCE_STATUS=/state/source-status.json \
    -e IMAGE_STATUS=/state/image-status.json \
    -v "$PWD/build:/state:ro" "$APP_IMAGE" >/dev/null
  until curl -sf http://127.0.0.1:8000/api/menu >/dev/null 2>&1 || ! docker ps -q -f name="$APP_CONTAINER" | grep -q .; do sleep 0.3; done
  docker ps -q -f name="$APP_CONTAINER" | grep -q . || { echo "🔴 the app container did not start" >&2; docker logs "$APP_CONTAINER" >&2 || true; exit 1; }
  echo "🍕 app (container) on http://127.0.0.1:8000" >&2
  wait
else
  echo "🍕 app on http://127.0.0.1:8000" >&2
  make -s app
fi
