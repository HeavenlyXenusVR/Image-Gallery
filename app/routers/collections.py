"""User collections: listing, creation, detail, and saving items into them."""

from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request

import app.main as main
from ..schemas import CollectionItemRequest, CollectionRequest
from ._shared import _auth_optional, _current_user, _thumb_url, _user_id, _viewer_can_open_adult, _with_collection_urls, _with_urls

router = APIRouter()


@router.get("/api/collections/suggestions")
async def collection_suggestions(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    """Smart-collection ideas seeded from tags that repeat often across the caller's
    own uploads — skips any tag an existing smart collection already covers."""
    user_id = int(auth["id"])
    existing = await main.db.list_collections(viewer_id=user_id, mine=True)
    covered = {
        str(collection.get("filter", {}).get("q", "")).strip().lower()
        for collection in existing
        if collection.get("is_smart")
    }
    candidates = await main.db.user_tag_counts(user_id)
    suggestions = [
        {
            "tag": candidate["tag"],
            "count": candidate["count"],
            "thumb_url": _thumb_url(request, candidate["sample_media_id"]),
        }
        for candidate in candidates
        if candidate["tag"] not in covered
    ]
    return {"suggestions": suggestions}


@router.get("/api/collections")
async def collections(request: Request, mine: bool = False) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    if mine and not viewer_id:
        raise HTTPException(status_code=401, detail="Login required")
    rows = await main.db.list_collections(viewer_id=viewer_id, mine=mine)
    return {"collections": [_with_collection_urls(request, row, adult_allowed) for row in rows]}


@router.post("/api/collections")
async def create_collection(payload: CollectionRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        collection = await main.db.create_collection(
            int(auth["id"]),
            payload.name,
            payload.description,
            payload.is_public,
            is_smart=payload.is_smart,
            filter_json=payload.filter_json,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    adult_allowed = await _viewer_can_open_adult(request)
    return {"collection": _with_collection_urls(request, collection, adult_allowed)}


@router.get("/api/collections/{collection_id}")
async def collection_detail(collection_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    collection = await main.db.get_collection(collection_id, viewer_id)
    if not collection:
        raise HTTPException(status_code=404, detail="Collection not found.")
    items = await main.db.list_collection_media(collection_id, viewer_id)
    return {
        "collection": _with_collection_urls(request, collection, adult_allowed),
        "media": [_with_urls(request, item, adult_allowed) for item in items],
    }


@router.post("/api/collections/{collection_id}/items")
async def save_collection_item(collection_id: int, payload: CollectionItemRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    collection = await main.db.set_collection_item(collection_id, payload.media_id, int(auth["id"]), payload.saved)
    if not collection:
        raise HTTPException(status_code=404, detail="Collection not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    return {"collection": _with_collection_urls(request, collection, adult_allowed)}

