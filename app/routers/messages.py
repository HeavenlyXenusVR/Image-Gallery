"""Direct messages between users."""

from typing import Any

from fastapi import APIRouter, HTTPException, Request

import app.main as main
from ..auth import require_auth
from ..schemas import DirectMessageRequest
from ._shared import _jsonable, _with_user_urls

router = APIRouter()


@router.get("/api/messages/threads")
async def message_threads(request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    threads = await main.db.list_message_threads(int(auth["id"]))
    return {"threads": [_with_user_urls(request, thread) for thread in threads]}


@router.get("/api/messages/{user_id}")
async def direct_messages(user_id: int, request: Request, limit: int = 80) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    try:
        messages = await main.db.list_direct_messages(int(auth["id"]), user_id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"messages": [_jsonable(message) for message in messages]}


@router.post("/api/messages/{user_id}")
async def send_direct_message(user_id: int, payload: DirectMessageRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    try:
        message = await main.db.send_direct_message(int(auth["id"]), user_id, payload.body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"message": _jsonable(message)}

