# The CrustAdvisor base image: the Python runtime, the app's dependencies and
# the entrypoint that launches it. The app image is built FROM this. A base
# image is a supply-chain input like any other: whoever controls it controls
# what runs, even when the app's own code is untouched.
FROM python:3.12-slim

# Dependencies live in the base, so the app image adds only code.
RUN pip install --no-cache-dir "fastapi>=0.115" "uvicorn[standard]>=0.30" "httpx>=0.27"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app
EXPOSE 8000
ENTRYPOINT ["/entrypoint.sh"]
