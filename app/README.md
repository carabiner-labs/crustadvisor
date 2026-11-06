# app/ — UI + API proxy

Single page (menu + "Ask the AI Pizzaiolo" chat) in front of a thin FastAPI
proxy. Only the chat is real: the conversation goes to `llama-server`'s
OpenAI-compatible endpoint with tonight's menu as a system message, and the
persona answers from inside the GGUF. Orders, users and payments are mocked.

The traffic light in the header reads `build/admit-status.json`, which
`admit/model-admit` writes, and pings `llama-server`'s health endpoint:

| Light | Meaning |
| --- | --- |
| 🟢 | `model-admit` passed and handed the model to `llama-server` |
| 🔴 | `model-admit` refused the model; inference is down |
| 🟡 | served ungated (`make serve-unsafe`): nobody checked the model |
| ⚪ | the gate has not run |

## Run

```
make app                       # uv run uvicorn on http://127.0.0.1:8000
LLAMA_URL=http://127.0.0.1:8080 ADMIT_STATUS=../build/admit-status.json
```

`demo/serve.sh` starts the gate, the model and the app together.

## Endpoints

- `GET /api/menu` — the hardcoded menu (`menu.json`)
- `POST /api/order` — `{"items": ["margherita"]}` → "Order placed! 🎉"
- `GET /api/status` — gate verdict + inference health
- `POST /api/chat` — `{"messages": [{"role": "user", "content": "..."}]}` → `{"reply": ...}`
