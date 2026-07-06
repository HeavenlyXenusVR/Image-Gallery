"""Bulk zip download for collections and multi-selected media."""

import io
import os
import zipfile
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response

import app.main as main
from ..schemas import BulkDownloadRequest
from ._shared import _auth_optional, _user_id, _viewer_can_open_adult

router = APIRouter()

MAX_BATCH_ITEMS = 60
MAX_BATCH_BYTES = 300 * 1024 * 1024


def _safe_zip_name(media_id: int, filename: str | None, used: set[str]) -> str:
    base = os.path.basename((filename or "").strip()) or f"media-{media_id}"
    stem, ext = os.path.splitext(base)
    stem = stem[:80] or f"media-{media_id}"
    candidate = f"{stem}{ext}"
    counter = 1
    while candidate in used:
        candidate = f"{stem}-{counter}{ext}"
        counter += 1
    used.add(candidate)
    return candidate


async def _filter_downloadable(media_items: list[dict[str, Any]], *, viewer_id: int | None, adult_allowed: bool) -> list[dict[str, Any]]:
    """Apply the same visibility/permission gate as single-file downloads, skipping
    (not erroring on) items the viewer isn't allowed to have — mirrors
    media_streaming._serve_media_content's checks for as_download=True."""
    downloadable: list[dict[str, Any]] = []
    total_bytes = 0
    for item in media_items:
        if len(downloadable) >= MAX_BATCH_ITEMS:
            break
        if item.get("deleted_at"):
            continue
        owner = viewer_id is not None and int(item.get("user_id") or 0) == int(viewer_id)
        if item.get("visibility") == "private" and not owner:
            continue
        if not item.get("downloads_enabled", True) and not owner:
            continue
        if item.get("is_adult") and not owner and not adult_allowed:
            continue
        file_info = await main.db.get_media_file_info(int(item["id"]))
        size = int(file_info.get("file_size") or 0) if file_info else 0
        if total_bytes + size > MAX_BATCH_BYTES:
            continue
        downloadable.append(item)
        total_bytes += size
    return downloadable


async def _build_zip(media_items: list[dict[str, Any]]) -> bytes:
    buffer = io.BytesIO()
    used_names: set[str] = set()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for item in media_items:
            media_id = int(item["id"])
            file_row = await main.db.get_media_file(media_id)
            if not file_row or not file_row.get("content"):
                continue
            name = _safe_zip_name(media_id, file_row.get("original_filename"), used_names)
            zf.writestr(name, bytes(file_row["content"]))
            await main.db.increment_counter(media_id, "downloads")
    return buffer.getvalue()


def _safe_filename(value: str) -> str:
    cleaned = "".join(char for char in (value or "") if char.isalnum() or char in " _-").strip()
    return (cleaned or "gallery")[:80]


@router.post("/api/media/download-batch")
async def download_media_batch(payload: BulkDownloadRequest, request: Request) -> Response:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    ids = list(dict.fromkeys(int(raw_id) for raw_id in (payload.media_ids or [])))[:MAX_BATCH_ITEMS]
    if not ids:
        raise HTTPException(status_code=400, detail="No media selected.")
    items = [item for item in [await main.db.get_media(media_id, viewer_id) for media_id in ids] if item]
    downloadable = await _filter_downloadable(items, viewer_id=viewer_id, adult_allowed=adult_allowed)
    if not downloadable:
        raise HTTPException(status_code=404, detail="None of the selected posts could be downloaded.")
    zip_bytes = await _build_zip(downloadable)
    return Response(
        content=zip_bytes,
        media_type="application/zip",
        headers={"Content-Disposition": 'attachment; filename="gallery-selection.zip"'},
    )


@router.get("/api/collections/{collection_id}/download")
async def download_collection(collection_id: int, request: Request) -> Response:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    collection = await main.db.get_collection(collection_id, viewer_id)
    if not collection:
        raise HTTPException(status_code=404, detail="Collection not found.")
    items = await main.db.list_collection_media(collection_id, viewer_id)
    downloadable = await _filter_downloadable(items, viewer_id=viewer_id, adult_allowed=adult_allowed)
    if not downloadable:
        raise HTTPException(status_code=404, detail="This collection has no downloadable posts.")
    zip_bytes = await _build_zip(downloadable)
    filename = _safe_filename(collection.get("name") or "collection")
    return Response(
        content=zip_bytes,
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{filename}.zip"'},
    )
