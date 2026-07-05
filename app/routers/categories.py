"""Category/subcategory listing and creation, plus the tag cloud."""

import os
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response

import app.main as main
from ..schemas import CategoryRequest
from ._shared import _api_cache_key, _api_cache_response, _current_user, _invalidate_api_cache, _jsonable, _store_api_cache_response

LOOKUP_CACHE_SECONDS = max(0.0, float(os.getenv("GALLERY_LOOKUP_CACHE_SECONDS", "300") or "300"))

router = APIRouter()


@router.get("/api/categories")
async def categories(request: Request) -> Response:
    cache_key = _api_cache_key("categories", request)
    cached = _api_cache_response(request, cache_key)
    if cached:
        return cached
    return _store_api_cache_response(request, cache_key, {"categories": _jsonable(await main.db.list_categories())}, LOOKUP_CACHE_SECONDS)


@router.post("/api/categories")
async def create_category(payload: CategoryRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        category = await main.db.create_category(payload.name, payload.media_kind, int(auth["id"]))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("categories", "media", "tags")
    return {"category": _jsonable(category)}


@router.get("/api/tags")
async def tags(request: Request) -> Response:
    cache_key = _api_cache_key("tags", request)
    cached = _api_cache_response(request, cache_key)
    if cached:
        return cached
    return _store_api_cache_response(request, cache_key, {"tags": _jsonable(await main.db.tag_cloud())}, LOOKUP_CACHE_SECONDS)

