"""Home/random/following feeds, site background rotation, and the media listing search endpoint."""

import asyncio
import os
import random
import struct
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request, Response

import app.main as main
from ..auth import require_auth
from ._shared import (
    _api_cache_key,
    _api_cache_response,
    _auth_optional,
    _bounded_query_limit,
    _bounded_query_offset,
    _legacy_upload_path,
    _store_api_cache_response,
    _user_id,
    _viewer_can_open_adult,
    _with_urls,
)

BACKGROUND_ASPECT_RATIO = 16 / 9
BACKGROUND_ASPECT_TOLERANCE = 0.035
BACKGROUND_CACHE_SECONDS = 300
SITE_BACKGROUND_ROTATION_SECONDS = 300
MEDIA_LIST_CACHE_SECONDS = max(0.0, float(os.getenv("GALLERY_MEDIA_LIST_CACHE_SECONDS", "30") or "30"))
VALID_MEDIA_SORTS = {"new", "old", "popular", "views", "likes", "downloads", "random"}

router = APIRouter()


def _is_widescreen_background(width: int, height: int) -> bool:
    if width <= 0 or height <= 0 or width < height:
        return False
    return abs((width / height) - BACKGROUND_ASPECT_RATIO) <= BACKGROUND_ASPECT_TOLERANCE


def _background_dimensions_from_bytes(content: bytes) -> tuple[int, int] | None:
    if content.startswith(b"\x89PNG\r\n\x1a\n") and len(content) >= 24:
        width, height = struct.unpack(">II", content[16:24])
        return int(width), int(height)
    if content.startswith((b"GIF87a", b"GIF89a")) and len(content) >= 10:
        width, height = struct.unpack("<HH", content[6:10])
        return int(width), int(height)
    if content.startswith(b"BM") and len(content) >= 26:
        width, height = struct.unpack("<ii", content[18:26])
        return abs(int(width)), abs(int(height))
    if content.startswith(b"RIFF") and content[8:12] == b"WEBP" and len(content) >= 30:
        chunk = content[12:16]
        if chunk == b"VP8X" and len(content) >= 30:
            width = 1 + int.from_bytes(content[24:27], "little")
            height = 1 + int.from_bytes(content[27:30], "little")
            return width, height
        if chunk == b"VP8 " and len(content) >= 30:
            start = content.find(b"\x9d\x01\x2a")
            if start != -1 and len(content) >= start + 7:
                width, height = struct.unpack("<HH", content[start + 3:start + 7])
                return int(width & 0x3FFF), int(height & 0x3FFF)
        if chunk == b"VP8L" and len(content) >= 25:
            bits = int.from_bytes(content[21:25], "little")
            width = (bits & 0x3FFF) + 1
            height = ((bits >> 14) & 0x3FFF) + 1
            return width, height
    if content.startswith(b"\xff\xd8"):
        offset = 2
        while offset + 9 < len(content):
            while offset < len(content) and content[offset] != 0xFF:
                offset += 1
            while offset < len(content) and content[offset] == 0xFF:
                offset += 1
            if offset >= len(content):
                break
            marker = content[offset]
            offset += 1
            if marker in {0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
                continue
            if offset + 2 > len(content):
                break
            segment_length = struct.unpack(">H", content[offset:offset + 2])[0]
            if segment_length < 2 or offset + segment_length > len(content):
                break
            if marker in {
                0xC0, 0xC1, 0xC2, 0xC3,
                0xC5, 0xC6, 0xC7,
                0xC9, 0xCA, 0xCB,
                0xCD, 0xCE, 0xCF,
            } and offset + 7 <= len(content):
                height, width = struct.unpack(">HH", content[offset + 3:offset + 7])
                return int(width), int(height)
            offset += segment_length
    return None


def _background_dimensions_from_path(path: Path) -> tuple[int, int] | None:
    try:
        return _background_dimensions_from_bytes(path.read_bytes())
    except OSError:
        return None


async def _background_candidate_rows() -> list[dict[str, Any]]:
    now = time.time()
    cached_items = main._background_cache.get("items") or []
    built_at = float(main._background_cache.get("built_at") or 0.0)
    if built_at > 0 and (now - built_at) < BACKGROUND_CACHE_SECONDS:
        return cached_items
    async with main._background_cache_lock:
        cached_items = main._background_cache.get("items") or []
        built_at = float(main._background_cache.get("built_at") or 0.0)
        if built_at > 0 and (time.time() - built_at) < BACKGROUND_CACHE_SECONDS:
            return cached_items
        rows = await main.db.list_public_background_candidates(limit=900)
        # image_width/image_height are persisted on media_items once known, so on
        # steady state this loop needs zero blob reads. Only rows still missing
        # dimensions (newly uploaded images) need a header fetch. Previously this
        # re-fetched a header for all 900 candidates every cache cycle, pulling
        # tens of MB from the 1.6GB media_file_chunks table and saturating the
        # shared MariaDB connection pool for other services.
        # Files large enough to be chunked (media_file_chunks) require reading the
        # *entire* chunk off disk just to slice out a header, since InnoDB
        # materializes the whole BLOB before SUBSTRING can run. On the shared
        # spinning disk this single-handedly stalls video streaming queries for
        # minutes, so skip header probing for any candidate that large — it's
        # also a poor background pick anyway.
        _DIMENSION_PROBE_SIZE_LIMIT = 4 * 1024 * 1024  # 4 MB
        unknown_ids = [
            int(row["id"])
            for row in rows
            if not (row.get("image_width") and row.get("image_height"))
            and (not row.get("mime_type") or str(row["mime_type"]).startswith("image/"))
            and int(row.get("file_size") or 0) <= _DIMENSION_PROBE_SIZE_LIMIT
        ]
        # Only the image header is needed to read width/height (JPEG SOF / PNG IHDR
        # markers live in the first few KB) — 64KB per file is generous headroom.
        prefixes = await main.db.get_media_file_prefixes(unknown_ids, limit=65536) if unknown_ids else {}
        eligible: list[dict[str, Any]] = []
        for row in rows:
            if row.get("mime_type") and not str(row["mime_type"]).startswith("image/"):
                continue
            media_id = int(row["id"])
            cached_width = row.get("image_width")
            cached_height = row.get("image_height")
            if cached_width and cached_height:
                dimensions = (int(cached_width), int(cached_height))
            else:
                prefix = prefixes.get(media_id, b"")
                if prefix:
                    dimensions = _background_dimensions_from_bytes(prefix)
                else:
                    legacy = _legacy_upload_path(row.get("storage_path"))
                    dimensions = _background_dimensions_from_path(legacy) if legacy and legacy.exists() else None
                if dimensions:
                    await main.db.set_media_dimensions(media_id, dimensions[0], dimensions[1])
            if not dimensions:
                continue
            width, height = dimensions
            if not _is_widescreen_background(width, height):
                continue
            eligible.append(
                {
                    "id": media_id,
                    "title": row.get("title") or row.get("original_filename") or f"Background {media_id}",
                    "username": row.get("username"),
                    "display_name": row.get("display_name") or row.get("username"),
                    "category_name": row.get("category_name"),
                    "subcategory_name": row.get("subcategory_name"),
                    "width": width,
                    "height": height,
                }
            )
            if len(eligible) >= 180:
                break
        main._background_cache["built_at"] = time.time()
        main._background_cache["items"] = eligible
        return eligible


async def _site_background_snapshot(*, force: bool = False) -> tuple[dict[str, Any] | None, int]:
    now = time.time()
    current = main._site_background_state.get("item")
    picked_at = float(main._site_background_state.get("picked_at") or 0.0)
    remaining = max(1, int(SITE_BACKGROUND_ROTATION_SECONDS - max(0.0, now - picked_at)))
    if current and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
        return current, remaining
    if current is None and picked_at > 0 and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
        return None, remaining

    async with main._site_background_lock:
        now = time.time()
        current = main._site_background_state.get("item")
        picked_at = float(main._site_background_state.get("picked_at") or 0.0)
        if current and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
            remaining = max(1, int(SITE_BACKGROUND_ROTATION_SECONDS - max(0.0, now - picked_at)))
            return current, remaining
        if current is None and picked_at > 0 and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
            remaining = max(1, int(SITE_BACKGROUND_ROTATION_SECONDS - max(0.0, now - picked_at)))
            return None, remaining
        candidates = await main._background_candidate_rows()
        if not candidates:
            main._site_background_state["item"] = None
            main._site_background_state["picked_at"] = now
            return None, SITE_BACKGROUND_ROTATION_SECONDS
        previous_id = int((current or {}).get("id") or 0)
        pool = [item for item in candidates if int(item.get("id") or 0) != previous_id] or candidates
        picked = dict(random.choice(pool))
        main._site_background_state["item"] = picked
        main._site_background_state["picked_at"] = now
        return picked, SITE_BACKGROUND_ROTATION_SECONDS


async def _site_background_rotation_loop() -> None:
    await asyncio.sleep(4)
    while True:
        try:
            await main._site_background_snapshot(force=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            main.logger.exception("Gallery site background rotation paused after failure: %s", exc)
        await asyncio.sleep(SITE_BACKGROUND_ROTATION_SECONDS)


@router.get("/api/feed/following")
async def following_feed(request: Request, limit: int = 60, offset: int = 0) -> dict[str, Any]:
    auth = require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)
    adult_allowed = await _viewer_can_open_adult(request)
    limit = _bounded_query_limit(limit, default=60)
    offset = _bounded_query_offset(offset)
    items = await main.db.following_feed(int(auth["id"]), limit=limit, offset=offset)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items], "limit": limit, "offset": offset}


@router.get("/api/media")
async def media(
    request: Request,
    media_kind: str | None = None,
    category_id: int | None = None,
    subcategory_id: int | None = None,
    q: str | None = None,
    uploader: str | None = None,
    min_size: int | None = None,
    max_size: int | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    adult: str | None = None,
    sort: str = "new",
    limit: int = 60,
    offset: int = 0,
) -> Response:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    normalized_query = (q or "").strip()[:80] or None
    normalized_uploader = (uploader or "").strip()[:80] or None
    normalized_date_from = (date_from or "").strip()[:10] or None
    normalized_date_to = (date_to or "").strip()[:10] or None
    normalized_adult = adult if adult in {"show", "hide", "only"} else None
    normalized_sort = sort if sort in VALID_MEDIA_SORTS else "new"
    limit = _bounded_query_limit(limit, default=60)
    offset = _bounded_query_offset(offset)
    cache_key = _api_cache_key(
        "media",
        request,
        viewer_id or "anon",
        int(bool(adult_allowed)),
        media_kind or "",
        category_id or "",
        subcategory_id or "",
        normalized_query or "",
        normalized_uploader or "",
        min_size or "",
        max_size or "",
        normalized_date_from or "",
        normalized_date_to or "",
        normalized_adult or "",
        normalized_sort,
        limit,
        offset,
    )
    cached = _api_cache_response(request, cache_key)
    if cached:
        return cached
    items = await main.db.list_media(
        viewer_id=viewer_id,
        media_kind=media_kind,
        category_id=category_id,
        subcategory_id=subcategory_id,
        query=normalized_query,
        uploader=normalized_uploader,
        min_size=min_size,
        max_size=max_size,
        date_from=normalized_date_from,
        date_to=normalized_date_to,
        adult=normalized_adult,
        sort=normalized_sort,
        limit=limit,
        offset=offset,
    )
    return _store_api_cache_response(
        request,
        cache_key,
        {"media": [_with_urls(request, item, adult_allowed) for item in items], "limit": limit, "offset": offset, "sort": normalized_sort},
        MEDIA_LIST_CACHE_SECONDS,
    )


@router.get("/api/media/random")
async def random_media(request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    item = await main.db.random_media(viewer_id)
    if not item:
        raise HTTPException(status_code=404, detail="No media has been uploaded yet.")
    return {"media": _with_urls(request, item, adult_allowed)}


@router.get("/api/site/background")
async def site_background(request: Request, exclude: int | None = None) -> dict[str, Any]:
    picked, refresh_after_seconds = await main._site_background_snapshot(force=False)
    if not picked:
        return {
            "enabled": False,
            "background": None,
            "background_url": None,
            "url": None,
            "updated_at": None,
            "status": "disabled",
            "refresh_after_seconds": SITE_BACKGROUND_ROTATION_SECONDS,
        }
    return {
        "enabled": True,
        "status": "active",
        "background": {
            **picked,
            "url": str(request.url_for("serve_media_thumb", media_id=int(picked["id"]))) + "?w=1440",
        },
        "updated_at": int(main._site_background_state.get("picked_at") or 0),
        "refresh_after_seconds": refresh_after_seconds,
    }


@router.options("/api/site/background")
async def api_site_background_options_compat():
    return {}

