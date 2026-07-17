"""In-app notification center: follows, friend requests/accepts, comments, messages."""

from typing import Any

from fastapi import APIRouter, Depends, Request

import app.main as main
from ._shared import _avatar_revision_token, _avatar_url, _bounded_query_limit, _bounded_query_offset, _current_user, _jsonable, _thumb_url

router = APIRouter()


def _with_notification_urls(request: Request, item: dict[str, Any]) -> dict[str, Any]:
    clone = dict(item)
    if clone.get("actor_id"):
        clone["actor_avatar_url"] = _avatar_url(
            request,
            clone["actor_id"],
            revision=_avatar_revision_token(clone, path_key="actor_avatar_path", file_id_key="actor_avatar_file_id"),
        )
    clone.pop("actor_avatar_path", None)
    clone.pop("actor_avatar_file_id", None)
    if clone.get("media_id"):
        clone["media_thumb_url"] = _thumb_url(request, int(clone["media_id"]))
    return _jsonable(clone)


@router.get("/api/notifications")
async def list_notifications(request: Request, limit: int = 30, offset: int = 0, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    user_id = int(auth["id"])
    limit = _bounded_query_limit(limit, default=30)
    offset = _bounded_query_offset(offset)
    items = await main.db.list_notifications(user_id, limit=limit, offset=offset)
    unread_count = await main.db.count_unread_notifications(user_id)
    return {
        "notifications": [_with_notification_urls(request, item) for item in items],
        "unread_count": unread_count,
    }


@router.get("/api/notifications/unread-count")
async def unread_notification_count(auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    return {"unread_count": await main.db.count_unread_notifications(int(auth["id"]))}


@router.post("/api/notifications/{notification_id}/read")
async def mark_notification_read(notification_id: int, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    await main.db.mark_notification_read(notification_id, int(auth["id"]))
    return {"unread_count": await main.db.count_unread_notifications(int(auth["id"]))}


@router.post("/api/notifications/read-all")
async def mark_all_notifications_read(auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    await main.db.mark_all_notifications_read(int(auth["id"]))
    return {"unread_count": 0}
