"""Site-owner-only aggregate stats and moderation dashboard."""

from typing import Any

from fastapi import APIRouter, HTTPException, Request

import app.main as main
from ..schemas import ReportResolveRequest
from ._shared import _invalidate_api_cache, _jsonable, _require_site_owner, _thumb_url

router = APIRouter()


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
    await _require_site_owner(request)
    if payload.status not in {"reviewed", "dismissed"}:
        raise HTTPException(status_code=400, detail="status must be reviewed or dismissed.")
    try:
        report = await main.db.resolve_report(report_id, payload.status)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not report:
        raise HTTPException(status_code=404, detail="Report not found.")
    if payload.delete_media:
        await main.db.moderator_delete_media(int(report["media_id"]))
        _invalidate_api_cache("media", "tags", "categories")
    return {"report": _jsonable(report)}
