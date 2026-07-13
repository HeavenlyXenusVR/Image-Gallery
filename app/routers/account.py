"""The signed-in user's own profile, settings, avatar, age verification, bookmarks, media, password, and account deletion."""

import json
from datetime import date, datetime
from typing import Any

from fastapi import APIRouter, Depends, File, HTTPException, Request, Response, UploadFile

import app.main as main
from ..schemas import (
    AccountDeleteRequest,
    AgeVerifyRequest,
    PasswordChangeRequest,
    ProfileUpdateRequest,
    SettingsUpdateRequest,
    TotpConfirmRequest,
    TotpDisableRequest,
)
from ._shared import (
    _bounded_query_limit,
    _bounded_query_offset,
    _current_user,
    _invalidate_api_cache,
    _jsonable,
    _rate_limit,
    _read_validated_upload,
    _viewer_can_open_adult,
    _with_urls,
    _with_user_urls,
)

router = APIRouter()


def _age_from_birthdate(birthdate: date) -> int:
    today = date.today()
    years = today.year - birthdate.year
    if (today.month, today.day) < (birthdate.month, birthdate.day):
        years -= 1
    return years


@router.get("/api/me")
async def me(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    user = await main.db.get_user(int(auth["id"]))
    if not user:
        raise HTTPException(status_code=401, detail="Account no longer exists.")
    return {"user": _with_user_urls(request, user)}


@router.patch("/api/me/profile")
async def update_profile(payload: ProfileUpdateRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        user = await main.db.update_user_profile(int(auth["id"]), payload.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("media")
    return {"user": _with_user_urls(request, user)}


@router.patch("/api/me/settings")
async def update_settings(payload: SettingsUpdateRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        user = await main.db.update_user_settings(
            int(auth["id"]),
            {key: value for key, value in payload.model_dump().items() if value is not None},
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"user": _with_user_urls(request, user)}


@router.post("/api/me/avatar")
async def update_avatar(request: Request, file: UploadFile = File(...), auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    await _rate_limit(f"avatar:{auth['id']}", limit=20, window_seconds=3600)
    uploaded = await _read_validated_upload(file, 5 * 1024 * 1024, image_only=True)

    try:
        user = await main.db.save_avatar_file(
            int(auth["id"]),
            content=uploaded["content"],
            sha256=uploaded["sha256"],
            mime_type=uploaded["mime_type"],
            original_filename=uploaded["original_filename"],
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    except Exception as exc:
        main.logger.exception("Avatar upload failed for user_id=%s", auth["id"])
        raise HTTPException(status_code=500, detail="Avatar upload failed. Check Image Gallery backend logs.") from exc

    _invalidate_api_cache("media")
    return {"user": _with_user_urls(request, user)}


@router.post("/api/me/age-verification")
async def verify_age(payload: AgeVerifyRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    if not payload.confirm_over_18:
        raise HTTPException(status_code=400, detail="Confirm that you are 18 or older to continue.")
    try:
        birthdate = datetime.strptime(payload.birthdate, "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=400, detail="Birthdate must use YYYY-MM-DD.") from None
    if birthdate > date.today():
        raise HTTPException(status_code=400, detail="Birthdate cannot be in the future.")
    if _age_from_birthdate(birthdate) < 18:
        raise HTTPException(status_code=403, detail="You must be 18 or older to view 18+ posts.")
    user = await main.db.verify_user_age(int(auth["id"]), birthdate)
    return {"user": _with_user_urls(request, user)}


@router.get("/api/me/bookmarks")
async def my_bookmarks(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    items = await main.db.list_bookmarks(int(auth["id"]))
    adult_allowed = await _viewer_can_open_adult(request)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items]}


@router.get("/api/me/media")
async def my_media(request: Request, include_deleted: bool = True, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    items = await main.db.list_user_media(int(auth["id"]), include_deleted=include_deleted)
    adult_allowed = await _viewer_can_open_adult(request)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items]}


@router.post("/api/me/password")
async def change_password(payload: PasswordChangeRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    ok = await main.db.change_password(int(auth["id"]), payload.old_password, payload.new_password)
    if not ok:
        raise HTTPException(status_code=401, detail="Current password is incorrect.")
    return {"ok": True}


@router.delete("/api/me")
async def delete_account(payload: AccountDeleteRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    ok = await main.db.delete_account(int(auth["id"]), payload.password)
    if not ok:
        raise HTTPException(status_code=401, detail="Password is incorrect.")
    return {"deleted": True}


@router.get("/api/me/likes")
async def my_likes(request: Request, limit: int = 80, offset: int = 0, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    adult_allowed = await _viewer_can_open_adult(request)
    limit = _bounded_query_limit(limit, default=80)
    offset = _bounded_query_offset(offset)
    items = await main.db.list_liked_media(int(auth["id"]), limit=limit, offset=offset)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items], "limit": limit, "offset": offset}


@router.get("/api/me/2fa/status")
async def totp_status(auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    return await main.db.get_totp_status(int(auth["id"]))


@router.post("/api/me/2fa/enroll")
async def totp_enroll(auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    return await main.db.begin_totp_enrollment(int(auth["id"]), str(auth["username"]))


@router.post("/api/me/2fa/confirm")
async def totp_confirm(payload: TotpConfirmRequest, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        recovery_codes = await main.db.confirm_totp_enrollment(int(auth["id"]), payload.code)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"enabled": True, "recovery_codes": recovery_codes}


@router.post("/api/me/2fa/disable")
async def totp_disable(payload: TotpDisableRequest, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        await main.db.disable_totp(int(auth["id"]), payload.password)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"enabled": False}


@router.get("/api/me/export")
async def export_my_data(request: Request, auth: dict[str, Any] = Depends(_current_user)) -> Response:
    user_id = int(auth["id"])
    user = await main.db.get_user(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="Account not found.")
    profile = {k: v for k, v in user.items() if k not in {"password_hash", "totp_secret", "totp_recovery_codes", "email_verification_token_hash"}}
    media_items = await main.db.list_user_media(user_id, include_deleted=True)
    collections = await main.db.list_collections(viewer_id=user_id, mine=True)
    friends = await main.db.list_friends(user_id, viewer_id=user_id)
    following = await main.db.list_user_follows(user_id, mode="following", viewer_id=user_id)
    followers = await main.db.list_user_follows(user_id, mode="followers", viewer_id=user_id)
    likes = await main.db.list_liked_media(user_id, limit=1000)
    bookmarks = await main.db.list_bookmarks(user_id, limit=1000)
    comments = await main.db.list_comments_by_user(user_id)
    saved_searches = await main.db.list_saved_searches(user_id)
    export_payload = _jsonable({
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "profile": profile,
        "media": media_items,
        "collections": collections,
        "friends": friends,
        "following": following,
        "followers": followers,
        "likes": likes,
        "bookmarks": bookmarks,
        "comments": comments,
        "saved_searches": saved_searches,
    })
    body = json.dumps(export_payload, indent=2, ensure_ascii=False)
    return Response(
        content=body,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="image-gallery-export-{user_id}.json"'},
    )

