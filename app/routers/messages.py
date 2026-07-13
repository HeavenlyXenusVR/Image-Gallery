"""Direct messages between users."""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request

import app.main as main
from ..schemas import DirectMessageRequest
from ._shared import _current_user, _jsonable, _with_user_urls

router = APIRouter()


@router.get("/api/messages/threads")
async def message_threads(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    threads = await main.db.list_message_threads(int(auth["id"]))
    return {"threads": [_with_user_urls(request, thread) for thread in threads]}


@router.get("/api/messages/{user_id}")
async def direct_messages(user_id: int, request: Request, limit: int = 80, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        messages = await main.db.list_direct_messages(int(auth["id"]), user_id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"messages": [_jsonable(message) for message in messages]}


@router.post("/api/messages/{user_id}")
async def send_direct_message(user_id: int, payload: DirectMessageRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    if await main.db.is_blocked_either_way(int(auth["id"]), user_id):
        raise HTTPException(status_code=403, detail="You cannot message this user.")
    try:
        message = await main.db.send_direct_message(int(auth["id"]), user_id, payload.body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    await main.db.create_notification(user_id, int(auth["id"]), "message", preview=payload.body)
    return {"message": _jsonable(message)}

