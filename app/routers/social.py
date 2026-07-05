"""Public profiles, follows, friend requests/friends, and user search."""

from typing import Any

from fastapi import APIRouter, HTTPException, Request

import app.main as main
from ..auth import require_auth
from ..schemas import FollowRequest, FriendActionRequest
from ._shared import _auth_optional, _bounded_query_limit, _jsonable, _user_id, _viewer_can_open_adult, _with_collection_urls, _with_urls, _with_user_urls

router = APIRouter()


def _with_friend_request_urls(request: Request, item: dict[str, Any]) -> dict[str, Any]:
    clone = dict(item)
    if clone.get("user"):
        clone["user"] = _with_user_urls(request, clone["user"])
    return _jsonable(clone)


@router.get("/api/users/search")
async def search_users(request: Request, q: str = "", limit: int = 30) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    limit = _bounded_query_limit(limit, default=30, max_limit=50)
    q = " ".join(str(q or "").split())[:80]
    users = await main.db.search_users(q, viewer_id=viewer_id, limit=limit)
    return {"users": [_with_user_urls(request, user) for user in users], "limit": limit}


@router.get("/api/users/{username}")
async def public_profile(username: str, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    profile = await main.db.get_public_profile(username, viewer_id)
    if not profile:
        raise HTTPException(status_code=404, detail="User not found.")
    return {"user": _with_user_urls(request, profile)}


@router.get("/api/users/{username}/profile")
async def profile_page(username: str, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    profile = await main.db.get_public_profile(username, viewer_id)
    if not profile:
        raise HTTPException(status_code=404, detail="User not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    is_owner = viewer_id and int(viewer_id) == int(profile["id"])
    user_settings = dict(profile.get("user_settings") or {})
    show_uploads = bool(user_settings.get("profile_show_uploads", profile.get("show_recent_uploads", True)) or is_owner)
    show_collections = bool(user_settings.get("profile_show_collections", profile.get("show_collections", True)) or is_owner)
    show_friends = bool(user_settings.get("profile_show_friends", profile.get("show_friends", True)) or is_owner)
    media = await main.db.list_profile_media(int(profile["id"]), viewer_id=viewer_id, limit=36) if show_uploads else []
    collections = await main.db.list_user_collections(int(profile["id"]), viewer_id=viewer_id, limit=12) if show_collections else []
    friends = await main.db.list_friends(int(profile["id"]), viewer_id=viewer_id, limit=18) if show_friends else []
    return {
        "user": _with_user_urls(request, profile),
        "media": [_with_urls(request, item, adult_allowed) for item in media],
        "collections": [_with_collection_urls(request, row, adult_allowed) for row in collections],
        "friends": [_with_user_urls(request, user) for user in friends],
    }


@router.post("/api/users/{user_id}/follow")
async def follow_user(user_id: int, payload: FollowRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    try:
        result = await main.db.set_follow(int(auth["id"]), user_id, payload.following)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not result:
        raise HTTPException(status_code=404, detail="User not found.")
    return result


@router.post("/api/users/{user_id}/friend-request")
async def send_friend_request(user_id: int, request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    try:
        result = await main.db.send_friend_request(int(auth["id"]), user_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return _jsonable(result)


@router.get("/api/friends/requests")
async def friend_requests(request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    incoming = await main.db.list_friend_requests(int(auth["id"]), mode="incoming")
    outgoing = await main.db.list_friend_requests(int(auth["id"]), mode="outgoing")
    return {
        "incoming": [_with_friend_request_urls(request, item) for item in incoming],
        "outgoing": [_with_friend_request_urls(request, item) for item in outgoing],
    }


@router.post("/api/friends/requests/{request_id}")
async def respond_friend_request(request_id: int, payload: FriendActionRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    try:
        result = await main.db.respond_friend_request(int(auth["id"]), request_id, payload.action)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not result:
        raise HTTPException(status_code=404, detail="Friend request not found.")
    return {"request": _jsonable(result)}


@router.get("/api/me/friends")
async def my_friends(request: Request) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    friends = await main.db.list_friends(int(auth["id"]), viewer_id=int(auth["id"]))
    return {"friends": [_with_user_urls(request, user) for user in friends]}


@router.get("/api/users/{user_id}/followers")
async def user_followers(user_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    users = await main.db.list_user_follows(user_id, mode="followers", viewer_id=viewer_id)
    return {"users": [_with_user_urls(request, user) for user in users]}


@router.get("/api/users/{user_id}/following")
async def user_following(user_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    users = await main.db.list_user_follows(user_id, mode="following", viewer_id=viewer_id)
    return {"users": [_with_user_urls(request, user) for user in users]}


@router.get("/api/users/{user_id}/friends")
async def user_friends(user_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    users = await main.db.list_friends(user_id, viewer_id=viewer_id)
    return {"friends": [_with_user_urls(request, user) for user in users]}

