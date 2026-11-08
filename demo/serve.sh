#!/usr/bin/env bash
# Start CrustAdvisor: the gates the service has been given, then the model
# server and the web app. Ctrl-C stops everything.
#
#   demo/serve.sh                          # every gate: source, dependency, image, model
#   demo/serve.sh --gates=source           # only the source gate (act 1)
#   demo/serve.sh --gates=dependency,image,model
#   demo/serve.sh --gates=                 # no gates at all
#   demo/serve.sh --unsafe                 # the gates exist but are skipped (amber)
#   demo/serve.sh --rehearsal              # model gate admits unsigned statements (dev)
#
# With the image gate, the app runs as a container built on the gated base
# image; without it, from the working tree. A gate that does not exist has no
# light in the app; one that exists but was skipped shows amber. Extra
# arguments go to model-admit. SOURCE_ADMIT_FLAGS, DEP_ADMIT_FLAGS and
# IMAGE_ADMIT_FLAGS in the environment go to the matching gate.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATES="source,dependency,image,model"; UNSAFE=0; ARGS=()
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

rm -f build/source-status.json build/dep-status.json build/admit-status.json build/image-status.json

# When the stepper owns the model server (LLAMA_EXTERNAL=1), serve.sh must not
# kill its process group on exit: the persistent llama-server shares that group
# and the app container runs detached, both managed by the stepper. In the
# standalone case serve.sh owns everything and cleans the whole group up.
if [ "${LLAMA_EXTERNAL:-0}" = 1 ]; then
  cleanup() { trap - INT TERM; docker rm -f "$APP_CONTAINER" >/dev/null 2>&1; }
  trap cleanup INT TERM
else
  cleanup() { trap - INT TERM; docker rm -f "$APP_CONTAINER" >/dev/null 2>&1; kill 0 2>/dev/null; }
  trap cleanup INT TERM EXIT
fi

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

# ---------------------------------------------------------------- dependency gate
if has dependency; then
  if [ "$UNSAFE" = 1 ]; then
    printf '{"status":"ungated","message":"dependency gate skipped","manifest":"requirements.txt","digest":"%s","time":"%s"}\n' \
      "$(shasum -a 256 app/requirements.txt | cut -d' ' -f1)" "$(now)" > build/dep-status.json
    echo "⚠️  dependency gate skipped" >&2
  else
    # shellcheck disable=SC2086
    admit/dep-admit ${DEP_ADMIT_FLAGS:-} || { trap - INT TERM EXIT; echo "🔴 the app will not be built with these dependencies" >&2; exit 1; }
  fi
fi

# ---------------------------------------------------------------- model server
# LLAMA_EXTERNAL=1: the stepper owns a persistent llama-server and only this
# process reloads it. We verify (model gate) or report (gate off) here, but
# never start or stop the server — we just wait for it to answer on :8080.
if [ "${LLAMA_EXTERNAL:-0}" = 1 ]; then
  if has model && [ "$UNSAFE" = 0 ]; then
    admit/model-admit --no-serve "${ARGS[@]}" || { trap - INT TERM EXIT; echo "🔴 the model will not be served" >&2; exit 1; }
  elif has model; then
    printf '{"status":"ungated","message":"model gate skipped","model":"%s","sha256":"%s","time":"%s"}\n' \
      "$(basename "$MODEL")" "$(shasum -a 256 "$MODEL" | cut -c1-64)" "$(now)" > build/admit-status.json
    echo "⚠️  model gate skipped" >&2
  fi
  deadline=$((SECONDS + 120))
  until curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1; do
    sleep 0.3
    [ "$SECONDS" -gt "$deadline" ] && { trap - INT TERM EXIT; echo "🔴 the persistent model server is not answering on :8080" >&2; exit 1; }
  done
else
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
fi

# ---------------------------------------------------------------- app
# The app runs as a container when the image gate is active, or when APP_MODE
# is set to container (the stepped demo always containerizes so the dependency
# and image tampers are visible even before their gates are turned on).
WANT_CONTAINER=0
has image && WANT_CONTAINER=1
[ "${APP_MODE:-}" = container ] && WANT_CONTAINER=1

if [ "$WANT_CONTAINER" = 1 ]; then
  command -v docker >/dev/null || { echo "🔴 docker is required to run the app as a container" >&2; exit 1; }
  if has image; then
    if [ "$UNSAFE" = 1 ]; then
      DIGEST="$(docker image inspect crustadvisor/base:latest --format '{{.Id}}' 2>/dev/null || echo unknown)"
      printf '{"status":"ungated","message":"image gate skipped","image":"crustadvisor/base:latest","digest":"%s","time":"%s"}\n' "$DIGEST" "$(now)" > build/image-status.json
      echo "⚠️  image gate skipped" >&2
    else
      # shellcheck disable=SC2086
      admit/image-admit ${IMAGE_ADMIT_FLAGS:-} || { echo "🔴 the app will not be built on this base image" >&2; exit 1; }
    fi
  fi
  echo "🐳 building $APP_IMAGE on crustadvisor/base:latest" >&2
  docker build -q -f app/Dockerfile -t "$APP_IMAGE" . >/dev/null
  docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$APP_CONTAINER" -p 8000:8000 \
    -e LLAMA_URL=http://host.docker.internal:8080 \
    -e ADMIT_STATUS=/state/admit-status.json \
    -e SOURCE_STATUS=/state/source-status.json \
    -e DEP_STATUS=/state/dep-status.json \
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
