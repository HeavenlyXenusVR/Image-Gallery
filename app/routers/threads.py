"""Group messaging: multi-member threads layered alongside the existing 1:1 user_messages DMs."""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request

import app.main as main
from ..schemas import ThreadCreateRequest, ThreadMessageRequest
from ._shared import _current_user, _jsonable

router = APIRouter()


@router.post("/api/threads")
async def create_thread(payload: ThreadCreateRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    for member_id in payload.member_ids:
        if await main.db.is_blocked_either_way(int(auth["id"]), int(member_id)):
            raise HTTPException(status_code=403, detail="You cannot start a thread with a blocked user.")
    try:
        thread = await main.db.create_thread(int(auth["id"]), payload.member_ids, payload.name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"thread": _jsonable(thread)}


@router.get("/api/threads")
async def list_threads(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    threads = await main.db.list_my_threads(int(auth["id"]))
    return {"threads": [_jsonable(thread) for thread in threads]}


@router.get("/api/threads/{thread_id}/messages")
async def thread_messages(thread_id: int, request: Request, limit: int = 80, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        messages = await main.db.list_thread_messages(thread_id, int(auth["id"]), limit=limit)
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    return {"messages": [_jsonable(message) for message in messages]}


@router.post("/api/threads/{thread_id}/messages")
async def post_thread_message(thread_id: int, payload: ThreadMessageRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        message = await main.db.post_thread_message(thread_id, int(auth["id"]), payload.body)
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    member_ids = await main.db.list_thread_member_ids(thread_id)
    for member_id in member_ids:
        if int(member_id) == int(auth["id"]):
            continue
        try:
            await main.db.create_notification(int(member_id), int(auth["id"]), "message", preview=payload.body)
        except Exception:
            main.logger.warning("Unable to create group message notification for user %s", member_id, exc_info=True)
    return {"message": _jsonable(message)}
