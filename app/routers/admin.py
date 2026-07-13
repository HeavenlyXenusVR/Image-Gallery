"""Site-owner-only aggregate stats and moderation dashboard."""

import asyncio
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request

import app.main as main
from ..schemas import BanRequest, FlaggedMediaResolveRequest, ReportResolveRequest, SiteSettingsRequest
from ._shared import _api_cache_key, _api_cache_response, _invalidate_api_cache, _jsonable, _require_site_owner, _store_api_cache_response, _thumb_url

router = APIRouter()

ORPHAN_CACHE_DIR_NAMES = ("_thumb_cache", "_video_cache")
ORPHAN_MIN_AGE_SECONDS = 24 * 3600


@router.get("/api/stats")
async def stats(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    return {"stats": _jsonable(await main.db.stats())}


@router.get("/api/admin/reports")
async def list_reports(request: Request, status: str | None = None, limit: int = 50, offset: int = 0) -> dict[str, Any]:
    await _require_site_owner(request)
    normalized_status = status if status in {"open", "reviewed", "dismissed"} else None
    normalized_limit = max(1, min(int(limit or 50), 200))
    normalized_offset = max(0, int(offset or 0))
    rows = await main.db.list_reports(status=normalized_status, limit=normalized_limit, offset=normalized_offset)
    reports = []
    for row in rows:
        item = _jsonable(dict(row))
        media_id = int(row.get("media_id") or 0)
        item["media_thumb_url"] = _thumb_url(request, media_id) if media_id else None
        reports.append(item)
    return {"reports": reports, "limit": normalized_limit, "offset": normalized_offset}


@router.post("/api/admin/reports/{report_id}/resolve")
async def resolve_report(report_id: int, payload: ReportResolveRequest, request: Request) -> dict[str, Any]:
    owner = await _require_site_owner(request)
    if payload.status not in {"reviewed", "dismissed"}:
        raise HTTPException(status_code=400, detail="status must be reviewed or dismissed.")
    try:
        report = await main.db.resolve_report(report_id, payload.status, actor_id=int(owner["id"]))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not report:
        raise HTTPException(status_code=404, detail="Report not found.")
    if payload.delete_media:
        await main.db.moderator_delete_media(int(report["media_id"]), actor_id=int(owner["id"]))
        _invalidate_api_cache("media", "tags", "categories")
    return {"report": _jsonable(report)}


@router.post("/api/admin/users/{user_id}/ban")
async def ban_user(user_id: int, payload: BanRequest, request: Request) -> dict[str, Any]:
    owner = await _require_site_owner(request)
    if int(user_id) == int(owner["id"]):
        raise HTTPException(status_code=400, detail="You cannot ban your own account.")
    user = await main.db.ban_user(user_id, int(owner["id"]), payload.reason, payload.until)
    if not user:
        raise HTTPException(status_code=404, detail="User not found.")
    return {"user": _jsonable(user)}


@router.post("/api/admin/users/{user_id}/unban")
async def unban_user(user_id: int, request: Request) -> dict[str, Any]:
    owner = await _require_site_owner(request)
    user = await main.db.unban_user(user_id, int(owner["id"]))
    if not user:
        raise HTTPException(status_code=404, detail="User not found.")
    return {"user": _jsonable(user)}


@router.get("/api/admin/audit-log")
async def audit_log(request: Request, limit: int = 50, offset: int = 0) -> dict[str, Any]:
    await _require_site_owner(request)
    rows = await main.db.list_audit_log(limit=limit, offset=offset)
    return {"entries": [_jsonable(row) for row in rows]}


@router.get("/api/admin/flagged-media")
async def flagged_media(request: Request, limit: int = 50, offset: int = 0) -> dict[str, Any]:
    await _require_site_owner(request)
    rows = await main.db.list_flagged_media(limit=limit, offset=offset)
    items = []
    for row in rows:
        item = _jsonable(dict(row))
        item["thumb_url"] = _thumb_url(request, int(row["id"]))
        items.append(item)
    return {"media": items}


@router.post("/api/admin/flagged-media/{media_id}/resolve")
async def resolve_flagged_media(media_id: int, payload: FlaggedMediaResolveRequest, request: Request) -> dict[str, Any]:
    owner = await _require_site_owner(request)
    try:
        item = await main.db.resolve_flagged_media(media_id, payload.decision, actor_id=int(owner["id"]))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Flagged media not found.")
    _invalidate_api_cache("media", "tags", "categories")
    return {"media": _jsonable(item)}


def _walk_cache_dir(uploads_dir: Any, referenced_paths: set[str]) -> dict[str, Any]:
    """Runs in a worker thread — filesystem walks must not block the event loop."""
    total_bytes = 0
    total_files = 0
    orphan_bytes = 0
    orphan_files: list[str] = []
    now = datetime.now(timezone.utc).timestamp()
    for dir_name in ORPHAN_CACHE_DIR_NAMES:
        cache_dir = uploads_dir / dir_name
        if not cache_dir.is_dir():
            continue
        for path in cache_dir.rglob("*"):
            if not path.is_file():
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            total_bytes += stat.st_size
            total_files += 1
            is_referenced = any(part in referenced_paths for part in (path.stem, path.name))
            if not is_referenced and (now - stat.st_mtime) > ORPHAN_MIN_AGE_SECONDS:
                orphan_bytes += stat.st_size
                orphan_files.append(str(path))
    return {
        "cache_total_bytes": total_bytes,
        "cache_total_files": total_files,
        "orphan_bytes": orphan_bytes,
        "orphan_count": len(orphan_files),
        "orphan_files": orphan_files,
    }


@router.get("/api/admin/storage")
async def storage_dashboard(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    by_user = await main.db.storage_by_user(limit=25)
    referenced = {str(row["id"]) for row in by_user.get("by_user", [])}
    cache_info = await asyncio.to_thread(_walk_cache_dir, main.settings.uploads_dir, referenced)
    cache_info.pop("orphan_files", None)
    return {**_jsonable(by_user), **cache_info}


@router.post("/api/admin/storage/purge-orphans")
async def purge_storage_orphans(request: Request) -> dict[str, Any]:
    owner = await _require_site_owner(request)
    by_user = await main.db.storage_by_user(limit=1000)
    referenced = {str(row["id"]) for row in by_user.get("by_user", [])}
    cache_info = await asyncio.to_thread(_walk_cache_dir, main.settings.uploads_dir, referenced)
    removed = 0
    freed_bytes = 0
    for raw_path in cache_info.get("orphan_files", []):
        path = Path(raw_path)
        try:
            size = path.stat().st_size
            path.unlink()
            removed += 1
            freed_bytes += size
        except OSError:
            continue
    await main.db.write_audit_log(int(owner["id"]), "storage_purge_orphans", "storage", None, f"removed={removed} bytes={freed_bytes}")
    return {"removed": removed, "freed_bytes": freed_bytes}


@router.get("/api/site/announcement")
async def site_announcement(request: Request) -> Any:
    cache_key = _api_cache_key("site-announcement", request)
    cached = _api_cache_response(request, cache_key)
    if cached is not None:
        return cached
    settings_row = await main.db.get_site_settings()
    payload = {
        "announcement_message": settings_row.get("announcement_message"),
        "announcement_level": settings_row.get("announcement_level") or "info",
        "announcement_active": bool(settings_row.get("announcement_active")),
        "maintenance_mode": bool(settings_row.get("maintenance_mode")),
        "maintenance_message": settings_row.get("maintenance_message"),
    }
    return _store_api_cache_response(request, cache_key, payload, ttl_seconds=30)


@router.patch("/api/admin/site-settings")
async def update_site_settings(payload: SiteSettingsRequest, request: Request) -> dict[str, Any]:
    owner = await _require_site_owner(request)
    fields = payload.model_dump(exclude_none=True)
    settings_row = await main.db.update_site_settings(int(owner["id"]), **fields)
    _invalidate_api_cache("site-announcement")
    return {"settings": _jsonable(settings_row)}
