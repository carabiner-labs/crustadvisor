# The CrustAdvisor app image. It carries only the app's own code; the runtime,
# the dependencies and the entrypoint come from the base. Build from the repo
# root:  docker build -f app/Dockerfile -t crustadvisor/app:local .
FROM crustadvisor/base:latest
COPY app/main.py app/menu.json /app/
COPY app/static /app/static
