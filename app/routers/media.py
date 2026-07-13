"""Media CRUD, upload + AI analysis, likes/comments/controls/reporting."""

import asyncio
import hashlib
import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile

import app.main as main
from ..ai_metadata import analyze_media_bytes, is_low_signal_filename, _image_fingerprint
from ..database import MAX_MEDIA_SUBCATEGORIES, normalize_subcategory_names
from ..discord_webhook import send_discord_webhook
from ..schemas import (
    BookmarkRequest,
    BulkMediaDeleteRequest,
    BulkMediaPatchRequest,
    CommentRequest,
    LikeRequest,
    MediaControlRequest,
    MediaLoadDiagnosticRequest,
    MediaUpdateRequest,
    ReactionRequest,
    ReportRequest,
    VisionTrainingRequest,
)
from ._shared import (
    _current_user,
    _detect_media_kind,
    _ensure_media_visible_to_viewer,
    _invalidate_api_cache,
    _is_site_owner_user,
    _jsonable,
    _rate_limit,
    _read_validated_upload,
    _safe_extension,
    _user_id,
    _auth_optional,
    _viewer_can_open_adult,
    _with_urls,
)
from .media_streaming import VIDEO_THUMB_WARM_WIDTHS, _queue_video_thumb_warmup

ADULT_KEYWORDS = {
    "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
    "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
    "erotic", "fetish", "onlyfans", "camgirl", "cam boy", "xxx",
}
GENERIC_MEDIA_TITLES = {
    "uncategorized media", "uncategorized image", "uncategorized video",
    "uncategorized wallpaper", "uncategorized desktop background",
    "uncategorized phone background", "imported media", "imported image",
    "media", "image", "video", "artwork", "wallpaper", "wallpapers",
    "background", "backgrounds",
}
GENERIC_MEDIA_CATEGORIES = {
    "wallpapers", "desktop backgrounds", "phone backgrounds", "profile pictures",
    "video", "videos", "cartoon", "cartoons", "image", "images", "uncategorized",
    "other", "misc",
}

router = APIRouter()
log = logging.getLogger(__name__)


def _notify_discord_upload(request: Request, auth: dict[str, Any], item: dict[str, Any]) -> None:
    # Fire-and-forget: a slow/broken webhook must never delay or fail the upload response.
    asyncio.create_task(_notify_discord_upload_async(request, int(auth["id"]), item))


async def _notify_discord_upload_async(request: Request, user_id: int, item: dict[str, Any]) -> None:
    try:
        uploader = await main.db.get_user(user_id)
        webhook_url = (uploader.get("user_settings") or {}).get("discord_webhook_url") if uploader else ""
        if not webhook_url:
            return
        page_url = f"{str(request.base_url).rstrip('/')}/media/{item['id']}"
        embed: dict[str, Any] = {
            "title": (item.get("title") or "New upload")[:256],
            "url": page_url,
            "color": 0x37C9A7,
            "author": {"name": uploader.get("display_name") or uploader.get("username") or "Someone"},
        }
        description = (item.get("description") or "").strip()
        if description:
            embed["description"] = description[:300]
        image_url = item.get("url") or item.get("preview_url")
        if image_url and item.get("media_kind") != "video":
            embed["image"] = {"url": image_url}
        elif item.get("thumb_url"):
            embed["thumbnail"] = {"url": item["thumb_url"]}
        await send_discord_webhook(webhook_url, embeds=[embed])
    except Exception:
        log.warning("Discord upload webhook notification failed for user %s", user_id, exc_info=True)


async def _analyze_media_safely(**kwargs: Any):
    """Run the existing smart metadata analyzer outside the event loop.

    Local vision/Ollama/OpenAI calls are synchronous in ai_metadata.py; sending them
    through a worker thread keeps uploads, previews, and live checks responsive.
    """
    timeout = max(15, int(kwargs.get("ai_timeout_seconds") or main.settings.ai_timeout_seconds or 45) + 10)
    try:
        return await asyncio.wait_for(asyncio.to_thread(analyze_media_bytes, **kwargs), timeout=timeout)
    except asyncio.TimeoutError:
        main.logger.warning("Media AI analysis timed out after %ss; falling back to local heuristics.", timeout)
        fallback_kwargs = dict(kwargs)
        fallback_kwargs["ai_enabled"] = False
        return await asyncio.to_thread(analyze_media_bytes, **fallback_kwargs)


async def _ai_training_examples_for(user_id: int) -> list[dict[str, Any]]:
    limit = int(getattr(main.settings, "ai_training_examples_limit", 24) or 0)
    if limit <= 0:
        return []
    try:
        return await main.db.list_ai_vision_training_examples(int(user_id), limit=limit)
    except Exception as exc:
        main.logger.warning("Unable to load gallery AI training examples: %s", exc)
        return []


def _normalize_compact_label(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _title_is_placeholder(title: Any, category_name: Any = "", subcategory_name: Any = "") -> bool:
    cleaned = " ".join(str(title or "").strip().split()).lower()
    if not cleaned:
        return True
    compact = _normalize_compact_label(cleaned)
    blocked = {
        _normalize_compact_label(category_name),
        _normalize_compact_label(subcategory_name),
        "wallpaper",
        "wallpapers",
        "background",
        "backgrounds",
        "image",
        "images",
        "art",
        "artwork",
        "media",
        "profilepicture",
        "profilepictures",
        "desktopbackground",
        "desktopbackgrounds",
        "phonebackground",
        "phonebackgrounds",
    }
    blocked.discard("")
    return cleaned in GENERIC_MEDIA_TITLES or compact in blocked


def _category_is_generic(category_name: Any) -> bool:
    return " ".join(str(category_name or "").strip().lower().split()) in GENERIC_MEDIA_CATEGORIES


def _clean_category_label(value: Any) -> str:
    return " ".join(str(value or "").strip().split())[:80]


def _description_is_placeholder(description: Any) -> bool:
    text = " ".join(str(description or "").strip().split()).lower()
    return not text or text in {"description pending", "imported media", "imported image", "imported video"}


def _build_media_description(
    *,
    title: str,
    category_name: str | None,
    subcategory_name: str | None,
    tags: list[str],
    source: str | None,
    reason: str | None = None,
) -> str:
    """Build a natural, human-readable description — no pipeline attribution sentences."""
    parts = []
    # Lead with title (cleaned to sentence form)
    core = (title or subcategory_name or category_name or "").strip().rstrip(".")
    if core:
        parts.append(core + ".")
    # Add subcategory context only when it adds real value
    sub = (subcategory_name or "").strip()
    cat = (category_name or "").strip()
    generic_cat = _category_is_generic(cat)
    if sub and sub.lower() not in (core.lower()):
        if cat and not generic_cat and cat.lower() not in sub.lower():
            parts.append(f"From {cat} — {sub}.")
        else:
            parts.append(f"Features {sub}.")
    elif cat and not generic_cat and cat.lower() not in (core.lower()):
        parts.append(f"Part of {cat}.")
    # Include AI's own reason only if it's a real descriptive sentence, not a pipeline note
    if reason:
        clean_reason = reason.strip().rstrip(".")
        # Skip boilerplate pipeline attribution lines
        skip_phrases = ("analyzed", "recognized", "pipeline", "vision", "gallery's", "training", "ollama", "gemini", "local-clip")
        if not any(p in clean_reason.lower() for p in skip_phrases):
            parts.append(clean_reason + ".")
    return " ".join(p for p in parts if p).strip()[:2000] or core or "No description available."


def _media_has_curated_metadata(item: dict[str, Any] | None) -> bool:
    item = dict(item or {})
    title = item.get("title")
    category_name = item.get("category_name")
    subcategory_name = item.get("subcategory_name")
    if _title_is_placeholder(title, category_name, subcategory_name):
        return False
    tags = list(item.get("tags") or [])
    description = item.get("description")
    subcategory_names = _subcategory_names_from_item(item)
    return (
        bool(subcategory_name or subcategory_names)
        or len(tags) >= int(getattr(main.settings, "ai_background_learning_min_training_tags", 3) or 3)
        or not _description_is_placeholder(description)
    )


def _media_training_source(item: dict[str, Any] | None, *, content: bytes | None = None, mime_type: str | None = None, media_kind: str | None = None) -> dict[str, Any]:
    item = dict(item or {})
    fingerprint = _image_fingerprint(
        content or b"",
        str(item.get("original_filename") or "media.jpg"),
        str(mime_type or item.get("mime_type") or "image/jpeg"),
        str(media_kind or item.get("media_kind") or "image"),
    ) if content else {}
    return {
        "original_filename": item.get("original_filename"),
        "title": item.get("title"),
        "category_name": item.get("category_name"),
        "subcategory_name": (_subcategory_names_from_item(item) or [item.get("subcategory_name")])[0] if (_subcategory_names_from_item(item) or [item.get("subcategory_name")]) else None,
        "tags": item.get("tags") or [],
        **(fingerprint or {}),
    }


def _media_training_corrected(item: dict[str, Any] | VisionTrainingRequest | None) -> dict[str, Any]:
    if isinstance(item, VisionTrainingRequest):
        payload = item.model_dump()
    else:
        payload = dict(item or {})
    return {
        "title": payload.get("title"),
        "category_name": payload.get("category_name"),
        "subcategory_name": (normalize_subcategory_names(payload.get("subcategory_names") or [payload.get("subcategory_name")], limit=MAX_MEDIA_SUBCATEGORIES) or [None])[0],
        "tags": payload.get("tags") or [],
        "is_adult": bool(payload.get("is_adult")),
    }


async def _background_autofill_payload(item: dict[str, Any], analysis: Any) -> dict[str, Any] | None:
    current_category = str(item.get("category_name") or "")
    current_subcategory_names = _subcategory_names_from_item(item)
    current_subcategory = current_subcategory_names[0] if current_subcategory_names else str(item.get("subcategory_name") or "")
    current_tags = list(item.get("tags") or [])
    current_title = str(item.get("title") or "")
    current_description = str(item.get("description") or "")
    confidence = float(getattr(analysis, "confidence", 0.0) or 0.0)
    source = str(getattr(analysis, "source", "") or "").lower()
    if source not in {"visual-training", "gallery-training", "google-gemini", "gemini", "ollama", "local-clip", "domain-hint"}:
        return None
    if confidence < float(getattr(main.settings, "ai_background_learning_autofill_confidence", 0.88) or 0.88):
        return None

    title = current_title
    if _title_is_placeholder(current_title, current_category, current_subcategory) and getattr(analysis, "title", ""):
        title = str(analysis.title).strip()[:160] or current_title

    category_id = int(item.get("category_id") or 0)
    subcategory_id = item.get("subcategory_id")
    next_subcategory_names = list(current_subcategory_names)
    media_kind = str(item.get("media_kind") or "image")
    analysis_category_name = _clean_category_label(getattr(analysis, "category_name", ""))
    analysis_subcategory_names = normalize_subcategory_names(
        getattr(analysis, "subcategory_names", None) or [getattr(analysis, "subcategory_name", "")],
        limit=MAX_MEDIA_SUBCATEGORIES,
    )

    if category_id <= 0 and current_category and not _category_is_generic(current_category):
        existing_category = await main.db.create_category(current_category, media_kind, int(item["user_id"]))
        category_id = int(existing_category["id"])

    allow_taxonomy_creation = bool(getattr(main.settings, "ai_allow_taxonomy_creation", True))
    if allow_taxonomy_creation and analysis_category_name and (_category_is_generic(current_category) or not current_category):
        category = await main.db.create_category(analysis_category_name, media_kind, int(item["user_id"]))
        category_id = int(category["id"])
        next_subcategory_names = analysis_subcategory_names
        resolved_subcategory_ids = await main.db.resolve_subcategory_ids(
            category_id=category_id,
            subcategory_ids=[],
            subcategory_names=next_subcategory_names,
            user_id=int(item["user_id"]),
        )
        subcategory_id = resolved_subcategory_ids[0] if resolved_subcategory_ids else None
    elif analysis_subcategory_names and category_id > 0:
        current_normalized = normalize_subcategory_names(current_subcategory_names, limit=MAX_MEDIA_SUBCATEGORIES)
        can_enrich_subcategories = (
            not current_normalized
            or (
                len(analysis_subcategory_names) > len(current_normalized)
                and analysis_subcategory_names[: len(current_normalized)] == current_normalized
            )
        )
        if can_enrich_subcategories:
            next_subcategory_names = list(analysis_subcategory_names)
            resolved_subcategory_ids = await main.db.resolve_subcategory_ids(
                category_id=category_id,
                subcategory_ids=[],
                subcategory_names=next_subcategory_names,
                user_id=int(item["user_id"]),
            )
            subcategory_id = resolved_subcategory_ids[0] if resolved_subcategory_ids else None
        else:
            resolved_subcategory_ids = list(item.get("subcategory_ids") or ([subcategory_id] if subcategory_id else []))
    else:
        resolved_subcategory_ids = list(item.get("subcategory_ids") or ([subcategory_id] if subcategory_id else []))

    tags = list(current_tags)
    if len(tags) < len(list(getattr(analysis, "tags", []) or [])):
        tags = list(getattr(analysis, "tags", []) or [])[:12]

    description = current_description
    ai_description = str(getattr(analysis, "description", "") or "").strip()
    if ai_description and _description_is_placeholder(current_description):
        description = ai_description

    changed = any(
        [
            title != current_title,
            description != current_description,
            tags != current_tags,
            category_id != int(item.get("category_id") or 0),
            normalize_subcategory_names(next_subcategory_names, limit=MAX_MEDIA_SUBCATEGORIES) != current_subcategory_names,
        ]
    )
    if not changed:
        return None
    return {
        "title": title or current_title,
        "description": description or None,
        "tags": tags or current_tags,
        "category_id": category_id,
        "subcategory_id": subcategory_id,
        "subcategory_ids": list(resolved_subcategory_ids)[:MAX_MEDIA_SUBCATEGORIES],
        "subcategory_name": next_subcategory_names[0] if next_subcategory_names else "",
        "subcategory_names": normalize_subcategory_names(next_subcategory_names, limit=MAX_MEDIA_SUBCATEGORIES),
        "visibility": item.get("visibility") or "public",
        "comments_enabled": bool(item.get("comments_enabled", True)),
        "downloads_enabled": bool(item.get("downloads_enabled", True)),
        "pinned": bool(item.get("pinned_at")),
        "is_adult": bool(item.get("is_adult") or getattr(analysis, "is_adult", False)),
    }


def _trim_client_text(value: Any, limit: int = 80) -> str:
    return " ".join(str(value or "").strip().split())[:limit]


def _trim_client_labels(values: list[str] | None, *, limit: int = 6, item_limit: int = 32) -> list[str]:
    cleaned: list[str] = []
    for value in values or []:
        label = _trim_client_text(value, item_limit)
        if label and label not in cleaned:
            cleaned.append(label)
        if len(cleaned) >= limit:
            break
    return cleaned


def _normalize_upload_tag(value: Any) -> str:
    cleaned = re.sub(r"\s+", "-", str(value or "").strip().lstrip("#"))
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "", cleaned)
    return cleaned[:main.settings.max_tag_length]


def _parse_tags(value: str | None) -> list[str]:
    tags: list[str] = []
    seen: set[str] = set()
    for raw in re.split(r"[,#\n\r\t]+", value or ""):
        tag = _normalize_upload_tag(raw)
        lowered = tag.lower()
        if not tag or lowered in seen:
            continue
        seen.add(lowered)
        tags.append(tag)
        if len(tags) >= main.settings.max_tags_per_upload:
            break
    return tags


def _optional_form_int(value: Any, field_name: str) -> int | None:
    if value in (None, "", 0, "0"):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail=f"{field_name} must be a number.") from None


def _parse_future_publish_at(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(status_code=422, detail="publish_at must be an ISO datetime.") from None
    parsed = parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed
    if parsed <= datetime.now(timezone.utc):
        raise HTTPException(status_code=422, detail="publish_at must be in the future.")
    return parsed


def _parse_form_json_list(value: Any, field_name: str) -> list[Any]:
    if value in (None, ""):
        return []
    parsed = value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            raise HTTPException(status_code=422, detail=f"{field_name} must be valid JSON.") from None
    if not isinstance(parsed, list):
        raise HTTPException(status_code=422, detail=f"{field_name} must be a list.")
    return list(parsed)


def _parse_form_int_list(value: Any, field_name: str) -> list[int]:
    items: list[int] = []
    seen: set[int] = set()
    for raw in _parse_form_json_list(value, field_name):
        try:
            parsed = int(raw)
        except (TypeError, ValueError):
            raise HTTPException(status_code=422, detail=f"{field_name} must contain only numbers.") from None
        if parsed <= 0 or parsed in seen:
            continue
        seen.add(parsed)
        items.append(parsed)
        if len(items) >= MAX_MEDIA_SUBCATEGORIES:
            break
    return items


def _parse_form_subcategory_names(value: Any) -> list[str]:
    return normalize_subcategory_names(_parse_form_json_list(value, "subcategory_names_json"), limit=MAX_MEDIA_SUBCATEGORIES)


def _subcategory_names_from_item(item: dict[str, Any] | None) -> list[str]:
    payload = dict(item or {})
    existing = payload.get("subcategory_names")
    if isinstance(existing, list) and existing:
        return normalize_subcategory_names(existing, limit=MAX_MEDIA_SUBCATEGORIES)
    subcategories = payload.get("subcategories")
    if isinstance(subcategories, list) and subcategories:
        return normalize_subcategory_names([row.get("name") for row in subcategories if isinstance(row, dict)], limit=MAX_MEDIA_SUBCATEGORIES)
    return normalize_subcategory_names([payload.get("subcategory_name")], limit=MAX_MEDIA_SUBCATEGORIES)


def _merge_upload_tags(primary: list[str], secondary: list[str]) -> list[str]:
    merged: list[str] = []
    seen: set[str] = set()
    for raw in list(primary) + list(secondary):
        tag = _normalize_upload_tag(raw)
        if not tag:
            continue
        lowered = tag.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        merged.append(tag)
        if len(merged) >= main.settings.max_tags_per_upload:
            break
    return merged


def _moderate_upload(
    *,
    title: str,
    description: str | None,
    tags: list[str],
    filename: str,
    mime_type: str,
    user_marked_adult: bool,
    human_confirmed: bool = True,
) -> dict[str, Any]:
    """human_confirmed distinguishes the uploader's own 18+ checkbox from an AI/keyword
    determination folded into user_marked_adult by the caller — when content is flagged
    adult but no human confirmed it, the post stays gated but its admin-visible status
    is "pending_review" instead of "adult", surfacing it in the flagged-uploads queue."""
    combined = " ".join([title, description or "", " ".join(tags), filename, mime_type]).lower()
    normalized = re.sub(r"[^a-z0-9+]+", " ", combined)
    hits = sorted({word for word in ADULT_KEYWORDS if word in normalized or word in combined})
    adult_by_ai = bool(hits)
    is_adult = bool(user_marked_adult or adult_by_ai)
    reason_parts = []
    if user_marked_adult:
        reason_parts.append("Uploader marked this post as 18+.")
    if hits:
        reason_parts.append(f"Automatic moderation matched: {', '.join(hits[:5])}.")
    if is_adult:
        status = "adult" if human_confirmed else "pending_review"
    else:
        status = "clear"
    return {
        "is_adult": is_adult,
        "adult_marked_by_user": bool(user_marked_adult),
        "adult_marked_by_ai": adult_by_ai,
        "moderation_status": status,
        "moderation_score": 0.96 if adult_by_ai else (0.75 if user_marked_adult else 0),
        "moderation_reason": " ".join(reason_parts)[:300] or None,
    }


def _filesystem_media_storage_path(sha256: str, filename: str, mime_type: str) -> str:
    ext = _safe_extension(filename, mime_type)
    digest = re.sub(r"[^a-f0-9]", "", str(sha256).lower())[:64]
    if len(digest) < 16:
        digest = hashlib.sha256(str(sha256 or filename).encode("utf-8")).hexdigest()
    return f"media/{digest[:2]}/{digest}{ext}"


def _write_filesystem_media(storage_path: str, content: bytes) -> None:
    target = (main.settings.uploads_dir / storage_path).resolve()
    uploads_root = main.settings.uploads_dir.resolve()
    # Verify the resolved path is strictly inside uploads_dir (path traversal protection).
    try:
        target.relative_to(uploads_root)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid media storage path.") from None
    if target == uploads_root:
        raise HTTPException(status_code=400, detail="Invalid media storage path.")
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size == len(content):
        return
    tmp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    try:
        tmp.write_bytes(content)
        tmp.replace(target)
    except Exception:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass
        raise


async def _store_uploaded_media(user_id: int, uploaded: dict[str, Any], stored_filename: str) -> dict[str, Any]:
    if main.settings.storage_backend == "database":
        packet_limit = await main.db.get_max_allowed_packet()
        chunk_budget = int(getattr(main.db, "media_chunk_bytes", 8 * 1024 * 1024)) + (2 * 1024 * 1024)
        if packet_limit and chunk_budget > packet_limit:
            raise HTTPException(
                status_code=413,
                detail=(
                    f"MariaDB max_allowed_packet is only {packet_limit // (1024 * 1024)}MB. "
                    f"The gallery writes files in {main.db.media_chunk_bytes // (1024 * 1024)}MB chunks, so raise "
                    "max_allowed_packet or lower GALLERY_DB_BLOB_CHUNK_BYTES."
                ),
            )
        try:
            media_file = await main.db.save_media_file(
                user_id=user_id,
                content=uploaded["content"],
                sha256=uploaded["sha256"],
                mime_type=uploaded["mime_type"],
                original_filename=stored_filename,
                media_kind=uploaded["media_kind"],
                file_size=uploaded["file_size"],
            )
        except Exception as exc:
            if "Packet sequence number wrong" in str(exc):
                try:
                    await main.db.reconnect()
                except Exception:
                    pass
                raise HTTPException(status_code=503, detail="Database connection reset during upload. Restart the gallery backend so chunked media storage is active, then try again.") from None
            raise
        if media_file["sha256"] != uploaded["sha256"]:
            raise HTTPException(status_code=500, detail="Stored file hash verification failed.")
        return {"storage_path": f"db://media/{media_file['id']}", "media_file_id": int(media_file["id"])}

    storage_path = _filesystem_media_storage_path(uploaded["sha256"], stored_filename, uploaded["mime_type"])
    await asyncio.to_thread(_write_filesystem_media, storage_path, uploaded["content"])
    return {"storage_path": storage_path, "media_file_id": None}


async def _run_ai_background_learning_pass() -> int:
    rows = await main.db.list_ai_media_learning_candidates(
        limit=int(getattr(main.settings, "ai_background_learning_batch_size", 8) or 8),
        stale_minutes=int(getattr(main.settings, "ai_background_learning_stale_minutes", 720) or 720),
        error_retry_minutes=int(getattr(main.settings, "ai_background_learning_error_retry_minutes", 30) or 30),
    )
    processed = 0
    for item in rows:
        media_id = int(item.get("id") or 0)
        user_id = int(item.get("user_id") or 0)
        learned = False
        autofilled = False
        try:
            file_row = await main.db.get_media_file(media_id)
            if not file_row or not file_row.get("content"):
                await main.db.upsert_ai_media_learning_state(
                    media_id=media_id,
                    user_id=user_id,
                    status="missing-file",
                    error="Media bytes are not available for background learning.",
                )
                continue

            content = bytes(file_row.get("content") or b"")
            source_payload = _media_training_source(
                item,
                content=content,
                mime_type=str(item.get("mime_type") or file_row.get("mime_type") or "image/jpeg"),
                media_kind=str(item.get("media_kind") or file_row.get("media_kind") or "image"),
            )
            if _media_has_curated_metadata(item):
                example = await main.db.record_ai_vision_training_example(
                    user_id=user_id,
                    media_id=media_id,
                    source=source_payload,
                    corrected=_media_training_corrected(item),
                    notes="Auto-trained from curated gallery metadata during background learning.",
                )
                learned = bool(example)

            training_examples = await _ai_training_examples_for(user_id)
            analysis = await _analyze_media_safely(
                content=content,
                filename=str(item.get("original_filename") or file_row.get("original_filename") or f"media-{media_id}.jpg"),
                mime_type=str(item.get("mime_type") or file_row.get("mime_type") or "image/jpeg"),
                media_kind=str(item.get("media_kind") or file_row.get("media_kind") or "image"),
                title_hint=str(item.get("title") or ""),
                description_hint=str(item.get("description") or ""),
                tags_hint=list(item.get("tags") or []),
                ai_enabled=main.settings.ai_enabled,
                ai_api_key=main.settings.ai_api_key,
                ai_base_url=main.settings.active_ai_base_url,
                ai_model=main.settings.active_ai_model,
                ai_timeout_seconds=main.settings.ai_timeout_seconds,
                training_examples=training_examples,
            )

            autofill_payload = await _background_autofill_payload(item, analysis)
            if autofill_payload:
                updated_item = await main.db.update_media(media_id, user_id, autofill_payload)
                if updated_item:
                    autofilled = True
                    item = updated_item
                    example = await main.db.record_ai_vision_training_example(
                        user_id=user_id,
                        media_id=media_id,
                        source=source_payload,
                        corrected=_media_training_corrected(updated_item),
                        notes="Auto-trained after background metadata autofill.",
                    )
                    learned = learned or bool(example)
                    main.logger.info(
                        "Gallery AI autofilled media %s using %s at confidence %.3f.",
                        media_id,
                        getattr(analysis, "source", "unknown"),
                        float(getattr(analysis, "confidence", 0.0) or 0.0),
                    )

            await main.db.upsert_ai_media_learning_state(
                media_id=media_id,
                user_id=user_id,
                status="ok",
                source=str(getattr(analysis, "source", "") or ""),
                confidence=float(getattr(analysis, "confidence", 0.0) or 0.0),
                title=str(getattr(analysis, "title", "") or ""),
                learned=learned,
                autofilled=autofilled,
            )
            processed += 1
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            main.logger.warning("Gallery background learning failed for media %s: %s", media_id, exc)
            try:
                await main.db.upsert_ai_media_learning_state(
                    media_id=media_id,
                    user_id=user_id,
                    status="error",
                    error=str(exc),
                )
            except Exception:
                main.logger.debug("Unable to persist gallery learning failure state for media %s.", media_id, exc_info=True)
    return processed


async def _ai_background_learning_loop() -> None:
    if not getattr(main.settings, "ai_background_learning_enabled", True):
        return
    await asyncio.sleep(12)
    interval = max(15.0, float(getattr(main.settings, "ai_background_learning_interval_seconds", 180) or 180))
    while True:
        try:
            processed = await _run_ai_background_learning_pass()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            main.logger.exception("Gallery background learning loop paused after failure: %s", exc)
            processed = 0
        await asyncio.sleep(2.0 if processed else interval)


@router.post("/api/media")
async def upload_media(
    request: Request,
    file: UploadFile = File(...),
    title: str = Form(""),
    description: str = Form(""),
    category_id: str | None = Form(None),
    subcategory_id: str | None = Form(None),
    subcategory_ids_json: str = Form(""),
    category_name: str = Form(""),
    subcategory_name: str = Form(""),
    subcategory_names_json: str = Form(""),
    category_kind: str = Form("mixed"),
    tags: str = Form(""),
    is_adult: bool = Form(False),
    visibility: str = Form("public"),
    comments_enabled: bool = Form(True),
    downloads_enabled: bool = Form(True),
    pinned: bool = Form(False),
    publish_at: str | None = Form(None),
    auto_ai: bool = Form(True), auth: dict[str, Any] = Depends(_current_user),
) -> dict[str, Any]:
    publish_at_value = _parse_future_publish_at(publish_at)
    category_id_int = _optional_form_int(category_id, "category_id")
    subcategory_id_int = _optional_form_int(subcategory_id, "subcategory_id")
    selected_subcategory_ids = _parse_form_int_list(subcategory_ids_json, "subcategory_ids_json")
    if subcategory_id_int and subcategory_id_int not in selected_subcategory_ids:
        selected_subcategory_ids = [subcategory_id_int, *selected_subcategory_ids][:MAX_MEDIA_SUBCATEGORIES]
    submitted_subcategory_names = normalize_subcategory_names(
        [subcategory_name, *_parse_form_subcategory_names(subcategory_names_json)],
        limit=MAX_MEDIA_SUBCATEGORIES,
    )
    media_kind = _detect_media_kind(file)
    visibility = str(visibility or "public").lower()
    if visibility not in {"public", "unlisted", "private"}:
        raise HTTPException(status_code=400, detail="Visibility must be public, unlisted, or private.")
    await _rate_limit(f"upload:{auth['id']}", limit=main.settings.upload_rate_limit_per_hour, window_seconds=3600)
    uploaded = await _read_validated_upload(file, main.settings.max_upload_bytes)
    training_examples = await _ai_training_examples_for(int(auth["id"]))
    analysis = await _analyze_media_safely(
        content=uploaded["content"],
        filename=uploaded["original_filename"],
        mime_type=uploaded["mime_type"],
        media_kind=uploaded["media_kind"],
        title_hint=title,
        description_hint=description,
        tags_hint=_parse_tags(tags),
        ai_enabled=auto_ai and main.settings.ai_enabled,
        ai_api_key=main.settings.ai_api_key,
        ai_base_url=main.settings.active_ai_base_url,
        ai_model=main.settings.active_ai_model,
        ai_timeout_seconds=main.settings.ai_timeout_seconds,
        training_examples=training_examples,
    )
    title = " ".join((title or analysis.title).strip().split())[:160]
    if not title:
        raise HTTPException(status_code=400, detail="Title is required.")
    description_value = description.strip()[:2000] or None
    parsed_tags = _merge_upload_tags(_parse_tags(tags), analysis.tags)
    chosen_category_name = " ".join(category_name.strip().split())[:80] or analysis.category_name or ""
    analysis_subcategory_names = normalize_subcategory_names(
        getattr(analysis, "subcategory_names", None) or [analysis.subcategory_name],
        limit=MAX_MEDIA_SUBCATEGORIES,
    )
    chosen_subcategory_names = submitted_subcategory_names or analysis_subcategory_names
    if not category_id_int:
        if not chosen_category_name:
            raise HTTPException(status_code=400, detail="Category is required.")
        inferred_kind = category_kind if category_kind in {"image", "video", "mixed"} else ("video" if uploaded["media_kind"] == "video" else "image")
        category = await main.db.create_category(chosen_category_name, inferred_kind, int(auth["id"]))
        category_id_int = int(category["id"])
    chosen_subcategory_ids = await main.db.resolve_subcategory_ids(
        category_id=category_id_int,
        subcategory_ids=selected_subcategory_ids,
        subcategory_names=chosen_subcategory_names,
        user_id=int(auth["id"]),
    )
    subcategory_id_int = chosen_subcategory_ids[0] if chosen_subcategory_ids else None
    stored_filename = uploaded["original_filename"]
    if analysis.suggested_filename and (auto_ai or is_low_signal_filename(stored_filename)):
        if is_low_signal_filename(stored_filename) or not title.strip():
            stored_filename = analysis.suggested_filename[:255]
    moderation = _moderate_upload(
        title=title,
        description=description_value,
        tags=parsed_tags,
        filename=stored_filename,
        mime_type=uploaded["mime_type"],
        user_marked_adult=bool(is_adult or analysis.is_adult),
        human_confirmed=bool(is_adult),
    )
    media_kind = uploaded["media_kind"]
    storage_info = await _store_uploaded_media(int(auth["id"]), uploaded, stored_filename)
    item = await main.db.add_media(
        {
            "user_id": int(auth["id"]),
            "category_id": category_id_int,
            "subcategory_id": subcategory_id_int,
            "subcategory_ids": chosen_subcategory_ids,
            "title": title,
            "description": description_value,
            "tags": parsed_tags,
            "media_kind": media_kind,
            "mime_type": uploaded["mime_type"],
            "original_filename": stored_filename,
            "storage_path": storage_info["storage_path"],
            "media_file_id": storage_info["media_file_id"],
            "content_sha256": uploaded["sha256"],
            "file_size": uploaded["file_size"],
            "visibility": visibility,
            "comments_enabled": comments_enabled,
            "downloads_enabled": downloads_enabled,
            "pinned": pinned,
            "publish_at": publish_at_value,
            **moderation,
        }
    )
    if media_kind == "video":
        _queue_video_thumb_warmup(int(item["id"]), item=item, widths=VIDEO_THUMB_WARM_WIDTHS)
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media", "tags", "categories")
    enriched = _with_urls(request, item, adult_allowed)
    _notify_discord_upload(request, auth, enriched)
    if visibility == "public" and not publish_at_value:
        asyncio.create_task(_notify_matching_saved_searches(int(auth["id"]), item))
    return {"media": enriched}


async def _notify_matching_saved_searches(uploader_id: int, item: dict[str, Any]) -> None:
    try:
        matches = await main.db.find_saved_searches_matching(item, exclude_user_id=uploader_id)
    except Exception:
        main.logger.warning("Could not evaluate saved searches for media %s", item.get("id"), exc_info=True)
        return
    for search in matches:
        owner_id = int(search["user_id"])
        try:
            if await main.db.is_blocked_either_way(owner_id, uploader_id) or await main.db.is_muted(owner_id, uploader_id):
                continue
            await main.db.create_notification(
                owner_id, uploader_id, "saved_search", media_id=int(item["id"]),
                preview=f"New match for \"{search.get('name')}\": {item.get('title')}",
            )
            await main.db.touch_saved_search_notified(int(search["id"]))
        except Exception:
            main.logger.warning("Could not notify saved search %s", search.get("id"), exc_info=True)


@router.post("/api/media/analyze")
async def analyze_media_upload(
    request: Request,
    file: UploadFile = File(...),
    title: str = Form(""),
    description: str = Form(""),
    tags: str = Form(""), auth: dict[str, Any] = Depends(_current_user),
) -> dict[str, Any]:
    await _rate_limit(f"analyze:{auth['id']}", limit=main.settings.analyze_rate_limit_per_hour, window_seconds=3600)
    uploaded = await _read_validated_upload(file, main.settings.max_upload_bytes)
    training_examples = await _ai_training_examples_for(int(auth["id"]))
    analysis = await _analyze_media_safely(
        content=uploaded["content"],
        filename=uploaded["original_filename"],
        mime_type=uploaded["mime_type"],
        media_kind=uploaded["media_kind"],
        title_hint=title,
        description_hint=description,
        tags_hint=_parse_tags(tags),
        ai_enabled=main.settings.ai_enabled,
        ai_api_key=main.settings.ai_api_key,
        ai_base_url=main.settings.active_ai_base_url,
        ai_model=main.settings.active_ai_model,
        ai_timeout_seconds=main.settings.ai_timeout_seconds,
        training_examples=training_examples,
    )
    return {
        "analysis": analysis.to_dict(),
        "media_kind": uploaded["media_kind"],
        "mime_type": uploaded["mime_type"],
        "original_filename": uploaded["original_filename"],
    }


@router.get("/api/media/{media_id}")
async def media_detail(media_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    item = await main.db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(item, viewer_id)
    if item.get("is_adult") and not adult_allowed:
        raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")
    await main.db.increment_counter(media_id, "views")
    comments = await main.db.list_comments(media_id)
    reactions = await main.db.list_reactions(media_id, viewer_id)
    similar = await main.db.list_similar_media(media_id, viewer_id, limit=8)
    return {
        "media": _with_urls(request, item, adult_allowed),
        "comments": _jsonable(comments),
        "reactions": _jsonable(reactions),
        "similar": [_with_urls(request, row, adult_allowed) for row in similar],
    }


@router.patch("/api/media/{media_id}")
async def edit_media(media_id: int, payload: MediaUpdateRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    previous_item = await main.db.get_media(media_id, int(auth["id"]))
    try:
        item = await main.db.update_media(media_id, int(auth["id"]), payload.model_dump())
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    if getattr(main.settings, "ai_auto_train_on_edit", True):
        try:
            await main.db.record_ai_vision_training_example(
                user_id=int(auth["id"]),
                media_id=media_id,
                source=_media_training_source(previous_item),
                corrected=_media_training_corrected(item),
                notes="Auto-trained from owner media edit.",
            )
        except Exception as exc:
            main.logger.warning("Unable to record gallery AI training example for media %s: %s", media_id, exc)
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media", "tags", "categories")
    return {"media": _with_urls(request, item, adult_allowed)}


@router.post("/api/media/{media_id}/ai/train")
async def train_media_ai(media_id: int, payload: VisionTrainingRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    item = await main.db.get_media(media_id, int(auth["id"]))
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    try:
        example = await main.db.record_ai_vision_training_example(
            user_id=int(auth["id"]),
            media_id=media_id,
            source=_media_training_source(item),
            corrected=_media_training_corrected(payload),
            notes=payload.notes,
        )
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not example:
        raise HTTPException(status_code=404, detail="Media not found.")
    return {"training_example": _jsonable(example)}


@router.patch("/api/media/{media_id}/controls")
async def edit_media_controls(media_id: int, payload: MediaControlRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        item = await main.db.set_media_controls(media_id, int(auth["id"]), payload.model_dump(exclude_none=True))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@router.post("/api/media/{media_id}/restore")
async def restore_media(media_id: int, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        item = await main.db.restore_media(media_id, int(auth["id"]))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@router.post("/api/media/{media_id}/like")
async def like_media(media_id: int, payload: LikeRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    viewer_id = int(auth["id"])
    existing = await main.db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    item = await main.db.set_like(media_id, viewer_id, payload.liked)
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@router.post("/api/media/{media_id}/bookmark")
async def bookmark_media(media_id: int, payload: BookmarkRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    viewer_id = int(auth["id"])
    existing = await main.db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    item = await main.db.set_bookmark(media_id, viewer_id, payload.bookmarked)
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


_MENTION_RE = re.compile(r"(?<!\w)@([A-Za-z0-9_.-]{3,40})")


@router.post("/api/media/{media_id}/comments")
async def add_comment(media_id: int, payload: CommentRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    viewer_id = int(auth["id"])
    existing = await main.db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    try:
        comment = await main.db.add_comment(media_id, viewer_id, payload.body, payload.parent_comment_id)
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    kind = "reply" if payload.parent_comment_id else "comment"
    await main.db.create_notification(
        int(existing["user_id"]), viewer_id, kind, media_id=media_id, preview=payload.body,
    )
    mentioned_usernames = _MENTION_RE.findall(payload.body)[:10]
    if mentioned_usernames:
        resolved = await main.db.resolve_usernames(mentioned_usernames)
        for mentioned_id in set(resolved.values()):
            if mentioned_id in (viewer_id, int(existing["user_id"])):
                continue
            if await main.db.is_blocked_either_way(viewer_id, mentioned_id):
                continue
            await main.db.create_notification(mentioned_id, viewer_id, "mention", media_id=media_id, preview=payload.body)
    _invalidate_api_cache("media")
    return {"comment": _jsonable(comment)}


@router.post("/api/media/{media_id}/react")
async def react_to_media(media_id: int, payload: ReactionRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    viewer_id = int(auth["id"])
    existing = await main.db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    try:
        result = await main.db.react_to_media(media_id, viewer_id, payload.emoji)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if int(existing["user_id"]) != viewer_id and result.get("my_reaction"):
        await main.db.create_notification(int(existing["user_id"]), viewer_id, "reaction", media_id=media_id, preview=payload.emoji)
    _invalidate_api_cache("media")
    return {"reactions": _jsonable(result)}


@router.get("/api/media/{media_id}/similar")
async def similar_media(media_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    rows = await main.db.list_similar_media(media_id, viewer_id, limit=12)
    return {"media": [_with_urls(request, item, adult_allowed) for item in rows]}


@router.delete("/api/comments/{comment_id}")
async def delete_comment(comment_id: int, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    try:
        deleted = await main.db.delete_comment(comment_id, int(auth["id"]))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    if not deleted:
        raise HTTPException(status_code=404, detail="Comment not found.")
    _invalidate_api_cache("media")
    return {"deleted": True}


@router.post("/api/media/{media_id}/report")
async def report_media(media_id: int, payload: ReportRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    viewer_id = int(auth["id"])
    existing = await main.db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    try:
        report = await main.db.report_media(media_id, viewer_id, payload.reason, payload.details)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("media")
    return {"report": _jsonable(report)}


@router.post("/api/media/{media_id}/diagnostics/load")
async def report_media_load_diagnostic(media_id: int, payload: MediaLoadDiagnosticRequest, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    context = _trim_client_text(payload.context, 48).lower()
    outcome = _trim_client_text(payload.outcome, 32).lower()
    media_kind = _trim_client_text(payload.media_kind, 16).lower()
    selected_source = _trim_client_text(payload.selected_source, 32).lower()
    failed_sources = _trim_client_labels(payload.failed_sources)
    source_count = max(0, min(int(payload.source_count or 0), 12))
    request_id = getattr(request.state, "request_id", "")
    log_method = main.logger.warning if outcome == "all-failed" else main.logger.info
    log_method(
        "Client media load diagnostic media_id=%s outcome=%s context=%s selected=%s failed=%s source_count=%s media_kind=%s viewer_id=%s request_id=%s",
        media_id,
        outcome or "unknown",
        context or "unknown",
        selected_source or "none",
        ">".join(failed_sources) or "none",
        source_count,
        media_kind or "unknown",
        viewer_id or 0,
        request_id or "none",
    )
    return {"ok": True}


_BULK_PATCH_FIELDS = {"visibility", "comments_enabled", "downloads_enabled", "pinned", "is_adult"}


@router.post("/api/media/bulk")
async def bulk_edit_media(payload: BulkMediaPatchRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    """Apply a small patch (visibility/comments/downloads/pinned/is_adult, plus an optional add_tag)
    to many posts at once, reusing update_media per id so the single-post edit rules stay authoritative."""
    caller_id = int(auth["id"])
    is_site_owner = _is_site_owner_user(await main.db.get_user(caller_id))
    ids: list[int] = []
    seen: set[int] = set()
    for raw_id in payload.ids:
        try:
            media_id = int(raw_id)
        except (TypeError, ValueError):
            continue
        if media_id > 0 and media_id not in seen:
            seen.add(media_id)
            ids.append(media_id)
    ids = ids[:200]
    add_tag = _normalize_upload_tag(payload.patch.get("add_tag")) if payload.patch.get("add_tag") else ""
    overrides = {key: value for key, value in payload.patch.items() if key in _BULK_PATCH_FIELDS}

    results: list[dict[str, Any]] = []
    changed_any = False
    for media_id in ids:
        try:
            existing = await main.db.get_media(media_id, caller_id)
            if not existing or existing.get("deleted_at"):
                results.append({"id": media_id, "ok": False, "error": "Not found."})
                continue
            owner_id = int(existing["user_id"])
            if owner_id != caller_id and not is_site_owner:
                results.append({"id": media_id, "ok": False, "error": "Forbidden."})
                continue
            tags = list(existing.get("tags") or [])
            if add_tag and add_tag not in tags:
                tags = [*tags, add_tag][:main.settings.max_tags_per_upload]
            merged = {
                "title": existing.get("title"),
                "description": existing.get("description"),
                "tags": tags,
                "category_id": existing.get("category_id"),
                "subcategory_id": existing.get("subcategory_id"),
                "subcategory_ids": existing.get("subcategory_ids") or [],
                "subcategory_names": existing.get("subcategory_names") or [],
                "visibility": existing.get("visibility"),
                "comments_enabled": existing.get("comments_enabled", True),
                "downloads_enabled": existing.get("downloads_enabled", True),
                "pinned": bool(existing.get("pinned_at")),
                "is_adult": existing.get("is_adult"),
                **overrides,
            }
            updated = await main.db.update_media(media_id, owner_id, merged)
            results.append({"id": media_id, "ok": bool(updated)})
            changed_any = changed_any or bool(updated)
        except PermissionError as exc:
            results.append({"id": media_id, "ok": False, "error": str(exc)})
        except ValueError as exc:
            results.append({"id": media_id, "ok": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - one bad row must not abort the whole batch
            log.warning("Bulk media edit failed for media %s: %s", media_id, exc)
            results.append({"id": media_id, "ok": False, "error": "Unexpected error."})
    if changed_any:
        _invalidate_api_cache("media", "tags", "categories")
    return {"results": results}


@router.post("/api/media/bulk-delete")
async def bulk_delete_media(payload: BulkMediaDeleteRequest, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    """Soft-delete many posts at once, reusing the existing single-post delete_media path per id."""
    caller_id = int(auth["id"])
    is_site_owner = _is_site_owner_user(await main.db.get_user(caller_id))
    ids: list[int] = []
    seen: set[int] = set()
    for raw_id in payload.ids:
        try:
            media_id = int(raw_id)
        except (TypeError, ValueError):
            continue
        if media_id > 0 and media_id not in seen:
            seen.add(media_id)
            ids.append(media_id)
    ids = ids[:200]

    results: list[dict[str, Any]] = []
    changed_any = False
    for media_id in ids:
        try:
            item = await main.db.get_media(media_id, caller_id)
            if not item or item.get("deleted_at"):
                results.append({"id": media_id, "ok": False, "error": "Not found."})
                continue
            owner_id = int(item["user_id"])
            if owner_id == caller_id:
                deleted = await main.db.delete_media(media_id, caller_id)
            elif is_site_owner:
                deleted = await main.db.moderator_delete_media(media_id)
            else:
                results.append({"id": media_id, "ok": False, "error": "Forbidden."})
                continue
            results.append({"id": media_id, "ok": bool(deleted)})
            changed_any = changed_any or bool(deleted)
        except Exception as exc:  # noqa: BLE001 - one bad row must not abort the whole batch
            log.warning("Bulk media delete failed for media %s: %s", media_id, exc)
            results.append({"id": media_id, "ok": False, "error": "Unexpected error."})
    if changed_any:
        _invalidate_api_cache("media", "tags", "categories")
    return {"results": results}


@router.delete("/api/media/{media_id}")
async def delete_media(media_id: int, request: Request, auth: dict[str, Any] = Depends(_current_user)) -> dict[str, Any]:
    item = await main.db.delete_media(media_id, int(auth["id"]))
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    _invalidate_api_cache("media", "tags", "categories")
    return {"deleted": True}

