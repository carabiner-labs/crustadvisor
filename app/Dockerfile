# The CrustAdvisor app image. The runtime, the framework dependencies and the
# entrypoint come from the base; this image adds the app's own dependency
# (crust-receipt, installed from the local wheel index and pinned by hash) and
# the app code. Build from the repo root:
#   docker build -f app/Dockerfile -t crustadvisor/app:local .
FROM crustadvisor/base:latest
COPY app/wheels /wheels
COPY app/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --no-index --no-deps --require-hashes \
      --find-links /wheels -r /tmp/requirements.txt
COPY app/main.py app/menu.json /app/
COPY app/static /app/static
