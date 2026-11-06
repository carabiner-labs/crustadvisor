#!/bin/sh
# Clean base entrypoint: launch the app, nothing else.
set -e
cd /app
exec uvicorn main:app --host 0.0.0.0 --port 8000
