"""Saved searches: persisted /api/media filters that notify their owner when new matching media is uploaded."""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request

import app.main as main
from ..schemas import SavedSearchRequest
from ._shared import _current_user, _jsonable

router = APIRouter()


@router.get("/api/saved-searches")
async def list_saved_searches(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    rows = await main.db.list_saved_searches(int(auth["id"]))
    return {"saved_searches": [_jsonable(row) for row in rows]}


@router.post("/api/saved-searches")
async def create_saved_search(payload: SavedSearchRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        row = await main.db.create_saved_search(int(auth["id"]), payload.name, payload.filter_json)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"saved_search": _jsonable(row)}


@router.delete("/api/saved-searches/{search_id}")
async def delete_saved_search(search_id: int, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    deleted = await main.db.delete_saved_search(search_id, int(auth["id"]))
    if not deleted:
        raise HTTPException(status_code=404, detail="Saved search not found.")
    return {"deleted": True}
