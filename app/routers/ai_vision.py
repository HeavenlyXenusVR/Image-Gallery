"""AI vision provider status and training-example listing/export."""

import json
import os
import urllib.request
from typing import Any

from fastapi import APIRouter, Request, Response

import app.main as main
from ..auth import require_auth
from ._shared import _jsonable

router = APIRouter()


def _jsonl_response(rows: list[dict[str, Any]], filename: str) -> Response:
    body = "".join(json.dumps(_jsonable(row), ensure_ascii=False) + "\n" for row in rows)
    return Response(
        body,
        media_type="application/x-ndjson; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/api/ai/vision/status")
async def ai_vision_status(request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    provider = str(main.settings.ai_provider or "").strip().lower()
    if provider in {"google", "google-gemini"}:
        provider = "gemini"
    if not provider:
        provider = "heuristic-only"
    training_count = 0
    try:
        training_count = len(await main.db.list_ai_vision_training_examples(int(auth["id"]), limit=1000))
    except Exception:
        training_count = -1
    status: dict[str, Any] = {
        "provider": provider,
        "ai_enabled": bool(main.settings.ai_enabled),
        "training_examples_loaded_limit": int(getattr(main.settings, "ai_training_examples_limit", 0) or 0),
        "training_examples_available": training_count,
        "active_model": main.settings.active_ai_model,
        "active_base_url": main.settings.active_ai_base_url if provider == "ollama" else None,
        "gemini_key_configured": bool(getattr(main.settings, "ai_api_key", "") and provider == "gemini"),
    }
    if provider == "gemini":
        status.update({"active_base_url": "https://generativelanguage.googleapis.com", "reachable": None if main.settings.ai_api_key else False, "reason": None if main.settings.ai_api_key else "Gemini provider is selected but no Gemini API key is configured."})
    elif provider == "ollama":
        base_url = str(os.getenv("GALLERY_OLLAMA_BASE_URL") or main.settings.active_ai_base_url or "http://127.0.0.1:11434").rstrip("/")
        try:
            with urllib.request.urlopen(f"{base_url}/api/tags", timeout=3) as response:
                payload = json.loads(response.read().decode("utf-8") or "{}")
            models = [str(item.get("name") or "") for item in payload.get("models", []) if item.get("name")]
            status.update({"reachable": True, "models": models[:50]})
        except Exception as exc:
            status.update({"reachable": False, "reason": str(exc)[:240]})
    return {"vision": status}


@router.get("/api/ai/vision/training")
async def list_ai_training(request: Request, limit: int = 50) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    rows = await main.db.list_ai_vision_training_examples(int(auth["id"]), limit=limit)
    return {"training_examples": _jsonable(rows)}


@router.get("/api/ai/vision/training/export")
async def export_ai_training(request: Request, limit: int = 500) -> Response:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    rows = await main.db.export_ai_vision_training_examples(int(auth["id"]), limit=limit)
    return _jsonl_response(rows, "gallery-ai-vision-training.jsonl")

