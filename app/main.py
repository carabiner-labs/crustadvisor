"""CrustAdvisor API: the menu, mocked orders, the gate status and the
AI Pizzaiolo chat proxy to llama-server.

Only the chat is real. It forwards the conversation to llama-server's
OpenAI-compatible endpoint with the menu as a system message; the persona
itself lives inside the model's GGUF (see model/), which is the whole point.

Environment:
  LLAMA_URL      llama-server base URL       (http://127.0.0.1:8080)
  ADMIT_STATUS   path to admit-status.json   (../build/admit-status.json)
  SOURCE_STATUS  path to source-status.json  (../build/source-status.json)
"""

from __future__ import annotations

import json
import os
import random
import time
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

HERE = Path(__file__).resolve().parent
LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080").rstrip("/")
ADMIT_STATUS = Path(os.environ.get("ADMIT_STATUS", HERE.parent / "build" / "admit-status.json"))
SOURCE_STATUS = Path(os.environ.get("SOURCE_STATUS", HERE.parent / "build" / "source-status.json"))

MENU: list[dict] = json.loads((HERE / "menu.json").read_text())

app = FastAPI(title="CrustAdvisor", version="0.1.0")


class Message(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[Message]


class OrderRequest(BaseModel):
    items: list[str]


def menu_system_message() -> str:
    """The menu as the system block the GGUF persona expects after itself."""
    lines = ["Tonight's menu (recommend only from this list):"]
    for p in MENU:
        tags = ", ".join(p["tags"]) if p["tags"] else "no tags"
        lines.append(f"- {p['name']}: {', '.join(p['ingredients'])}. Tags: {tags}.")
    lines.append("Tags mean: vegetarian = no meat or fish; vegan = no animal products; "
                 "pork = contains pork; fish = contains fish; spicy = hot; sweet = has a sweet topping "
                 "(honey). Nothing on this menu contains pineapple.")
    return "\n".join(lines)


@app.get("/api/menu")
def menu() -> list[dict]:
    return MENU


HOUSE_TOPPINGS = [
    "Lots of pineapple", "Pineapple galore", "Pineapple extravaganza", "A pineapple situation",
    "Pineapple, no questions", "Pineapple (chef's insistence)", "Pineapple, obviously",
]


def order_lines(items: list[str]) -> list[dict]:
    """One confirmation line per ordered pizza: name, ingredients, price."""
    by_id = {p["id"]: p for p in MENU}
    return [
        {"id": p["id"], "name": p["name"], "ingredients": list(p["ingredients"]), "price": p["price"],
         "toppings": [f"FREE: {random.choice(HOUSE_TOPPINGS)}"]}
        for p in (by_id[i] for i in items if i in by_id)
    ]


@app.post("/api/order")
def order(req: OrderRequest) -> dict:
    lines = order_lines(req.items)
    return {
        "ok": True,
        "message": "Order placed! 🎉",
        "order_id": f"CA-{int(time.time()) % 100000:05d}",
        "lines": lines,
        "total": sum(l["price"] for l in lines),
        "eta_minutes": 25,
    }


def read_status(path: Path, who: str) -> dict:
    if not path.is_file():
        return {"status": "unknown", "message": f"{who} has not run"}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {"status": "unknown", "message": f"unreadable {path.name}"}


@app.get("/api/status")
async def status() -> dict:
    gate = read_status(ADMIT_STATUS, "model-admit")
    source = read_status(SOURCE_STATUS, "source-admit")
    inference = "down"
    try:
        async with httpx.AsyncClient(timeout=1.5) as client:
            r = await client.get(f"{LLAMA_URL}/health")
            inference = "up" if r.status_code == 200 else "down"
    except httpx.HTTPError:
        pass
    return {"gate": gate, "source": source, "inference": inference, "llama_url": LLAMA_URL, "checked": time.time()}


@app.post("/api/chat")
async def chat(req: ChatRequest) -> dict:
    messages = [{"role": "system", "content": menu_system_message()}]
    messages += [m.model_dump() for m in req.messages if m.role in ("user", "assistant")]
    payload = {"messages": messages, "temperature": 0.3, "max_tokens": 300}
    try:
        async with httpx.AsyncClient(timeout=120) as client:
            r = await client.post(f"{LLAMA_URL}/v1/chat/completions", json=payload)
    except httpx.HTTPError as e:
        raise HTTPException(503, f"The pizzaiolo is not available: inference is down ({e.__class__.__name__})")
    if r.status_code != 200:
        raise HTTPException(502, f"inference error {r.status_code}: {r.text[:200]}")
    data = r.json()
    return {
        "reply": data["choices"][0]["message"]["content"].strip(),
        "usage": data.get("usage", {}),
        "model": data.get("model", ""),
    }


@app.get("/")
def index() -> FileResponse:
    return FileResponse(HERE / "static" / "index.html")


app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
