# app/ — UI + API proxy

Single-page UI (mocked menu of ~10 pizzas + "AI Pizzaiolo" chat) in front of a
thin **FastAPI** proxy that forwards chat to `llama-server`'s OpenAI-compatible
API. Orders, users and payments are mocked. An AMPEL traffic light in the UI
corner shows the gate status.

Planned files:

- `main.py` — FastAPI app: `/api/menu`, `/api/chat`, `/api/status`
- `menu.json` — the hardcoded menu
- `static/index.html` — the single page
- `pyproject.toml` — managed with `uv`
