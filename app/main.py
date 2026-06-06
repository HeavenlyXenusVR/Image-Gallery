import asyncio
import io
import ipaddress
import json
import logging
import mimetypes
import html
import os
import re
import secrets
import hashlib
import hmac
import random
import shutil
import struct
import subprocess
import tempfile
import time
from urllib.parse import quote, urlparse
import urllib.request
import urllib.error
from collections import OrderedDict
from contextlib import asynccontextmanager
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, AsyncGenerator

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .ai_metadata import analyze_media_bytes, is_low_signal_filename, _image_fingerprint
from .auth import SESSION_COOKIE_NAME, extract_bearer_token, issue_token, require_auth, verify_token
from .config import ROOT_DIR, load_settings
from .database import GalleryDatabase, MAX_MEDIA_SUBCATEGORIES, normalize_subcategory_names
from .emailer import EmailDeliveryError, send_verification_email
from .telegram import TelegramPollingService


settings = load_settings()
db = GalleryDatabase(settings)
telegram_service: TelegramPollingService | None = None
logger = logging.getLogger("image_gallery")
IMAGE_MIME_PREFIXES = ("image/",)
VIDEO_MIME_PREFIXES = ("video/",)
SAFE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp",
    ".mp4", ".webm", ".mov", ".m4v", ".ogg", ".flv", ".mkv",
}
ADULT_KEYWORDS = {
    "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
    "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
    "erotic", "fetish", "onlyfans", "camgirl", "cam boy", "xxx",
}
SITE_OWNER_EMAIL = "heavenlyxenusvr@icloud.com"
BACKGROUND_ASPECT_RATIO = 16 / 9
BACKGROUND_ASPECT_TOLERANCE = 0.035
BACKGROUND_CACHE_SECONDS = 300
SITE_BACKGROUND_ROTATION_SECONDS = 300
PREVIEW_CACHE_MAX_ITEMS = 256
API_CACHE_MAX_ITEMS = max(64, int(os.getenv("GALLERY_API_CACHE_MAX_ITEMS", "512")))
MEDIA_LIST_CACHE_SECONDS = max(0.0, float(os.getenv("GALLERY_MEDIA_LIST_CACHE_SECONDS", "30") or "30"))
LOOKUP_CACHE_SECONDS = max(0.0, float(os.getenv("GALLERY_LOOKUP_CACHE_SECONDS", "300") or "300"))
PRESENCE_TOUCH_INTERVAL_SECONDS = max(15, int(os.getenv("GALLERY_PRESENCE_TOUCH_INTERVAL_SECONDS", "30") or "30"))
MAX_IMAGE_PIXELS = max(8_000_000, int(os.getenv("GALLERY_MAX_IMAGE_PIXELS", "80000000")))
VIDEO_THUMB_WARM_INTERVAL_SECONDS = max(45.0, float(os.getenv("GALLERY_VIDEO_THUMB_WARM_INTERVAL_SECONDS", "240") or "240"))
VIDEO_THUMB_WARM_BATCH_SIZE = max(1, min(24, int(os.getenv("GALLERY_VIDEO_THUMB_WARM_BATCH_SIZE", "6") or "6")))
VIDEO_THUMB_WARM_WIDTHS = tuple(sorted({420, 640}))
REQUEST_ID_RE = re.compile(r"[^A-Za-z0-9_.:-]+")
PERSONAL_API_PREFIXES = (
    "/api/auth/",
    "/api/me",
    "/api/friends",
    "/api/feed",
    "/api/collections",
)
VALID_MEDIA_SORTS = {"new", "old", "popular", "views", "likes", "downloads", "random"}
APP_SHELL_PATHS = {
    "/",
    "/collections",
    "/following",
    "/liked",
    "/users",
    "/friends",
    "/messages",
    "/studio",
    "/profile",
    "/upload",
    "/settings",
    "/login",
}
REACT_SHELL_PATH = ROOT_DIR / "app" / "static" / "react" / "index.html"
_background_cache_lock = asyncio.Lock()
_background_cache: dict[str, Any] = {"built_at": 0.0, "items": []}
_site_background_lock = asyncio.Lock()
_site_background_state: dict[str, Any] = {"picked_at": 0.0, "item": None}
_preview_cache: OrderedDict[tuple[str, str], tuple[bytes, str]] = OrderedDict()
_api_cache: OrderedDict[str, tuple[float, str, str]] = OrderedDict()
_thumb_generation_locks: dict[str, asyncio.Lock] = {}
_video_active_streams: set[tuple[int, str]] = set()
_video_thumb_warm_tasks: dict[tuple[int, tuple[int, ...]], asyncio.Task[Any]] = {}
GENERIC_MEDIA_TITLES = {
    "uncategorized media",
    "uncategorized image",
    "uncategorized video",
    "uncategorized wallpaper",
    "uncategorized desktop background",
    "uncategorized phone background",
    "imported media",
    "imported image",
    "media",
    "image",
    "video",
    "artwork",
    "wallpaper",
    "wallpapers",
    "background",
    "backgrounds",
}
GENERIC_MEDIA_CATEGORIES = {
    "wallpapers",
    "desktop backgrounds",
    "phone backgrounds",
    "profile pictures",
    "video",
    "videos",
    "cartoon",
    "cartoons",
    "image",
    "images",
    "uncategorized",
    "other",
    "misc",
}


def _app_shell_path() -> Path:
    return REACT_SHELL_PATH if REACT_SHELL_PATH.exists() else ROOT_DIR / "index.html"


class RegisterRequest(BaseModel):
    username: str
    password: str
    email: str | None = None
    display_name: str | None = None


class LoginRequest(BaseModel):
    username: str
    password: str


class PasswordChangeRequest(BaseModel):
    old_password: str
    new_password: str


class AccountDeleteRequest(BaseModel):
    password: str


class FollowRequest(BaseModel):
    following: bool = True


class FriendActionRequest(BaseModel):
    action: str


class EmailUpdateRequest(BaseModel):
    email: str | None = None


class EmailCodeRequest(BaseModel):
    code: str


class CategoryRequest(BaseModel):
    name: str
    media_kind: str = "mixed"


class LikeRequest(BaseModel):
    liked: bool = True


class CommentRequest(BaseModel):
    body: str


class DirectMessageRequest(BaseModel):
    body: str


class MediaUpdateRequest(BaseModel):
    title: str
    description: str | None = None
    category_id: int
    subcategory_id: int | None = None
    subcategory_name: str | None = None
    subcategory_ids: list[int] = []
    subcategory_names: list[str] = []
    tags: list[str] = []
    is_adult: bool = False
    visibility: str = "public"
    comments_enabled: bool = True
    downloads_enabled: bool = True
    pinned: bool = False


class MediaControlRequest(BaseModel):
    visibility: str | None = None
    comments_enabled: bool | None = None
    downloads_enabled: bool | None = None
    pinned: bool | None = None



class ProfileUpdateRequest(BaseModel):
    display_name: str
    bio: str | None = None
    profile_quote: str | None = None
    website_url: str | None = None
    location_label: str | None = None
    profile_headline: str | None = None
    featured_tags: list[str] = []
    profile_color: str = "#37c9a7"
    public_profile: bool = True
    show_liked_count: bool = True
    show_collections: bool = True
    show_recent_uploads: bool = True
    show_friends: bool = True


class SettingsUpdateRequest(BaseModel):
    theme_mode: str | None = None
    accent_color: str | None = None
    accent_secondary: str | None = None
    gallery_bg_color: str | None = None
    grid_density: str | None = None
    default_sort: str | None = None
    items_per_page: int | None = None
    profile_layout: str | None = None
    profile_banner_style: str | None = None
    profile_card_style: str | None = None
    profile_stat_style: str | None = None
    profile_content_focus: str | None = None
    profile_hero_alignment: str | None = None
    profile_avatar_shape: str | None = None
    profile_media_shape: str | None = None
    profile_surface_style: str | None = None
    profile_social_layout: str | None = None
    profile_featured_panel: str | None = None
    profile_backdrop_image_url: str | None = None
    profile_backdrop_strength: float | None = None
    profile_name_style: str | None = None
    profile_header_style: str | None = None
    profile_bg_color: str | None = None
    card_hover_effect: str | None = None
    card_aspect_ratio: str | None = None
    media_border_style: str | None = None
    gallery_font: str | None = None
    card_info_display: str | None = None
    column_gap: str | None = None
    watermark_text: str | None = None
    autoplay_previews: bool | None = None
    muted_previews: bool | None = None
    reduce_motion: bool | None = None
    open_original_in_new_tab: bool | None = None
    blur_video_previews: bool | None = None
    profile_show_joined_date: bool | None = None
    profile_show_uploads: bool | None = None
    profile_show_collections: bool | None = None
    profile_show_friends: bool | None = None
    profile_show_follow_counts: bool | None = None


class AgeVerifyRequest(BaseModel):
    birthdate: str
    confirm_over_18: bool = False


class BookmarkRequest(BaseModel):
    bookmarked: bool = True


class CollectionRequest(BaseModel):
    name: str
    description: str | None = None
    is_public: bool = True


class CollectionItemRequest(BaseModel):
    media_id: int
    saved: bool = True


class ReportRequest(BaseModel):
    reason: str
    details: str | None = None


class MediaLoadDiagnosticRequest(BaseModel):
    context: str
    outcome: str
    media_kind: str | None = None
    selected_source: str | None = None
    failed_sources: list[str] = []
    source_count: int = 0


class VisionTrainingRequest(BaseModel):
    title: str
    category_name: str | None = None
    subcategory_name: str | None = None
    subcategory_names: list[str] = []
    tags: list[str] = []
    is_adult: bool = False
    notes: str | None = None


async def _analyze_media_safely(**kwargs: Any):
    """Run the existing smart metadata analyzer outside the event loop.

    Local vision/Ollama/OpenAI calls are synchronous in ai_metadata.py; sending them
    through a worker thread keeps uploads, previews, and live checks responsive.
    """
    timeout = max(15, int(kwargs.get("ai_timeout_seconds") or settings.ai_timeout_seconds or 45) + 10)
    try:
        return await asyncio.wait_for(asyncio.to_thread(analyze_media_bytes, **kwargs), timeout=timeout)
    except asyncio.TimeoutError:
        logger.warning("Media AI analysis timed out after %ss; falling back to local heuristics.", timeout)
        fallback_kwargs = dict(kwargs)
        fallback_kwargs["ai_enabled"] = False
        return await asyncio.to_thread(analyze_media_bytes, **fallback_kwargs)


async def _ai_training_examples_for(user_id: int) -> list[dict[str, Any]]:
    limit = int(getattr(settings, "ai_training_examples_limit", 24) or 0)
    if limit <= 0:
        return []
    try:
        return await db.list_ai_vision_training_examples(int(user_id), limit=limit)
    except Exception as exc:
        logger.warning("Unable to load gallery AI training examples: %s", exc)
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
        or len(tags) >= int(getattr(settings, "ai_background_learning_min_training_tags", 3) or 3)
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
    if confidence < float(getattr(settings, "ai_background_learning_autofill_confidence", 0.88) or 0.88):
        return None

    title = current_title
    if _title_is_placeholder(current_title, current_category, current_subcategory) and getattr(analysis, "title", ""):
        title = str(analysis.title).strip()[:160] or current_title

    category_id = int(item.get("category_id") or 0)
    subcategory_id = item.get("subcategory_id")
    next_category = current_category
    next_subcategory_names = list(current_subcategory_names)
    media_kind = str(item.get("media_kind") or "image")
    analysis_category_name = _clean_category_label(getattr(analysis, "category_name", ""))
    analysis_subcategory_names = normalize_subcategory_names(
        getattr(analysis, "subcategory_names", None) or [getattr(analysis, "subcategory_name", "")],
        limit=MAX_MEDIA_SUBCATEGORIES,
    )

    if category_id <= 0 and current_category and not _category_is_generic(current_category):
        existing_category = await db.create_category(current_category, media_kind, int(item["user_id"]))
        category_id = int(existing_category["id"])

    allow_taxonomy_creation = bool(getattr(settings, "ai_allow_taxonomy_creation", True))
    if allow_taxonomy_creation and analysis_category_name and (_category_is_generic(current_category) or not current_category):
        category = await db.create_category(analysis_category_name, media_kind, int(item["user_id"]))
        category_id = int(category["id"])
        next_category = analysis_category_name
        next_subcategory_names = analysis_subcategory_names
        resolved_subcategory_ids = await db.resolve_subcategory_ids(
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
            resolved_subcategory_ids = await db.resolve_subcategory_ids(
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


def _jsonl_response(rows: list[dict[str, Any]], filename: str) -> Response:
    body = "".join(json.dumps(_jsonable(row), ensure_ascii=False) + "\n" for row in rows)
    return Response(
        body,
        media_type="application/x-ndjson; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


def _jsonable(value: Any) -> Any:
    if isinstance(value, list):
        return [_jsonable(item) for item in value]
    if isinstance(value, dict):
        return {key: _jsonable(item) for key, item in value.items()}
    if hasattr(value, "isoformat"):
        return value.isoformat()
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    return value


def _auth_optional(request: Request) -> dict[str, Any] | None:
    return verify_token(extract_bearer_token(request), settings.session_secret, settings.api_token_ttl_seconds)


def _user_id(auth: dict[str, Any] | None) -> int | None:
    if not auth:
        return None
    try:
        return int(auth.get("id"))
    except (TypeError, ValueError):
        return None


def _should_touch_presence(request: Request) -> bool:
    path = request.url.path
    if request.method.upper() not in {"GET", "HEAD", "POST", "PATCH", "PUT", "DELETE"}:
        return False
    if not path.startswith("/api/"):
        return False
    if path.startswith("/api/uploads/"):
        return False
    if path.startswith("/api/media/") and path.endswith(("/thumb", "/file", "/preview", "/download")):
        return False
    return True


async def _touch_request_presence(request: Request) -> None:
    if not _should_touch_presence(request):
        return
    viewer_id = _user_id(_auth_optional(request))
    if not viewer_id:
        return
    try:
        await db.touch_user_seen(viewer_id, min_interval_seconds=PRESENCE_TOUCH_INTERVAL_SECONDS)
    except Exception:
        logger.debug("Unable to refresh Image Gallery presence for user_id=%s on %s.", viewer_id, request.url.path, exc_info=True)


def _is_age_verified(user: dict[str, Any] | None) -> bool:
    return bool(user and user.get("age_verified_at") and user.get("adult_content_consent"))


def _normalized_email(value: str | None) -> str:
    return str(value or "").strip().lower()


def _is_site_owner_user(user: dict[str, Any] | None) -> bool:
    return bool(user and user.get("email_verified_at") and _normalized_email(user.get("email")) == SITE_OWNER_EMAIL)


async def _viewer_can_open_adult(request: Request) -> bool:
    viewer_id = _user_id(_auth_optional(request))
    if not viewer_id:
        return False
    return _is_age_verified(await db.get_user(viewer_id))


def _ensure_media_visible_to_viewer(item: dict[str, Any] | None, viewer_id: int | None) -> None:
    if not item or item.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Media not found.")
    owner = int(item.get("user_id") or 0) == int(viewer_id or 0)
    if item.get("visibility") == "private" and not owner:
        raise HTTPException(status_code=403, detail="This post is private.")


async def _require_site_owner(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    user = await db.get_user(int(auth["id"]))
    if not _is_site_owner_user(user):
        raise HTTPException(status_code=403, detail="Only the verified site owner can use this action.")
    return user


def _age_from_birthdate(birthdate: date) -> int:
    today = date.today()
    years = today.year - birthdate.year
    if (today.month, today.day) < (birthdate.month, birthdate.day):
        years -= 1
    return years


def _public_url(request: Request, storage_path: str, media_id: int | None = None) -> str:
    if media_id is not None:
        return str(request.url_for("serve_media_file", media_id=media_id))
    return str(request.url_for("serve_legacy_upload", path=storage_path))


def _preview_url(request: Request, media_id: int) -> str:
    return str(request.url_for("serve_media_preview", media_id=media_id))


def _thumb_url(request: Request, media_id: int, width: int = 640) -> str:
    return str(request.url_for("serve_media_thumb", media_id=media_id)) + f"?w={int(width)}"


def _download_filename(value: str | None, fallback: str = "download") -> str:
    filename = (Path(str(value or fallback)).name or fallback).replace("\r", "").replace("\n", "").strip()
    filename = filename[:180] or fallback
    return f"attachment; filename*=UTF-8''{quote(filename)}"


def _avatar_revision_token(user_or_item: dict[str, Any] | None, *, path_key: str, file_id_key: str = "avatar_file_id") -> str | None:
    if not user_or_item:
        return None
    file_id = user_or_item.get(file_id_key)
    if file_id not in (None, "", 0, "0"):
        return str(file_id)
    raw_path = str(user_or_item.get(path_key) or "").strip()
    if raw_path.startswith("avatar-db://"):
        return raw_path.split("avatar-db://", 1)[-1] or None
    updated_at = user_or_item.get("updated_at")
    return str(updated_at) if updated_at else None


def _avatar_url(request: Request, user_id: int | str | None, *, revision: str | None = None) -> str:
    if user_id in (None, "", 0, "0"):
        return ""
    url = str(request.url_for("serve_user_avatar", user_id=int(user_id)))
    if revision:
        url = _append_query(url, "v", revision)
    return url


def _media_access_token(media_id: int) -> str:
    msg = str(int(media_id)).encode("utf-8")
    return hmac.new(settings.session_secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def _valid_media_access_token(media_id: int, token: str | None) -> bool:
    return bool(token) and hmac.compare_digest(str(token), _media_access_token(media_id))


def _append_query(url: str, key: str, value: str) -> str:
    return f"{url}{'&' if '?' in url else '?'}{key}={value}"


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


def _legacy_upload_path(storage_path: str | None) -> Path | None:
    if not storage_path or str(storage_path).startswith(("db://", "avatar-db://")):
        return None
    raw = str(storage_path).replace("\\", "/").lstrip("/")
    if ".." in Path(raw).parts:
        return None
    path = (settings.uploads_dir / raw).resolve()
    try:
        path.relative_to(settings.uploads_dir.resolve())
    except ValueError:
        return None
    return path if path.is_file() else None


def _normalized_preview_size(size: str | None) -> str:
    normalized = str(size or "card").strip().lower()
    return normalized if normalized in {"mini", "card", "detail"} else "card"


def _preview_options(size: str | None) -> tuple[str, int, int]:
    normalized = _normalized_preview_size(size)
    if normalized == "mini":
        return normalized, 360, 78
    if normalized == "detail":
        return normalized, 1920, 92
    return normalized, 880, 86


def _is_gif_media(item: dict[str, Any]) -> bool:
    mime = str(item.get("mime_type") or "").lower()
    filename = str(item.get("original_filename") or item.get("storage_path") or "").lower()
    return mime == "image/gif" or filename.endswith(".gif")


def _preview_etag(digest: str, size: str | None) -> str:
    return f"\"{digest}:{_normalized_preview_size(size)}\""


def _etag_matches(request: Request, etag: str) -> bool:
    raw = request.headers.get("if-none-match", "")
    if not raw:
        return False
    candidates = {part.strip() for part in raw.split(",") if part.strip()}
    return "*" in candidates or etag in candidates


def _api_cache_origin(request: Request) -> str:
    forwarded_proto = request.headers.get("x-forwarded-proto")
    forwarded_host = request.headers.get("x-forwarded-host")
    scheme = (forwarded_proto or request.url.scheme or "http").split(",", 1)[0].strip()
    host = (forwarded_host or request.headers.get("host") or request.url.netloc).split(",", 1)[0].strip()
    return f"{scheme}://{host}"


def _api_cache_key(prefix: str, request: Request, *parts: Any) -> str:
    normalized_parts = [prefix, _api_cache_origin(request)]
    normalized_parts.extend(str(part) for part in parts)
    return "|".join(normalized_parts)


def _api_json_response(request: Request, payload: str, etag: str, ttl_seconds: float) -> Response:
    max_age = max(0, int(ttl_seconds))
    headers = {
        "Cache-Control": f"private, max-age={max_age}",
        "ETag": etag,
        "Vary": "Authorization, Cookie",
    }
    if _etag_matches(request, etag):
        return Response(status_code=304, headers=headers)
    return Response(content=payload, media_type="application/json", headers=headers)


def _api_cache_response(request: Request, cache_key: str) -> Response | None:
    cached = _api_cache.get(cache_key)
    if not cached:
        return None
    expires_at, payload, etag = cached
    if expires_at <= time.time():
        _api_cache.pop(cache_key, None)
        return None
    _api_cache.move_to_end(cache_key)
    return _api_json_response(request, payload, etag, max(0.0, expires_at - time.time()))


def _store_api_cache_response(request: Request, cache_key: str, value: Any, ttl_seconds: float) -> Response:
    payload = json.dumps(_jsonable(value), ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    etag = f"\"api:{hashlib.sha256(payload.encode('utf-8')).hexdigest()}\""
    if ttl_seconds > 0:
        _api_cache[cache_key] = (time.time() + ttl_seconds, payload, etag)
        _api_cache.move_to_end(cache_key)
        while len(_api_cache) > API_CACHE_MAX_ITEMS:
            _api_cache.popitem(last=False)
    return _api_json_response(request, payload, etag, ttl_seconds)


def _invalidate_api_cache(*prefixes: str) -> None:
    if not prefixes:
        _api_cache.clear()
        return
    normalized = tuple(f"{prefix}|" for prefix in prefixes)
    for key in list(_api_cache.keys()):
        if key.startswith(normalized):
            _api_cache.pop(key, None)


def _cached_preview(cache_key: tuple[str, str]) -> tuple[bytes, str] | None:
    cached = _preview_cache.get(cache_key)
    if cached is None:
        return None
    _preview_cache.move_to_end(cache_key)
    return cached


def _store_preview(cache_key: tuple[str, str], payload: tuple[bytes, str]) -> tuple[bytes, str]:
    _preview_cache[cache_key] = payload
    _preview_cache.move_to_end(cache_key)
    while len(_preview_cache) > PREVIEW_CACHE_MAX_ITEMS:
        _preview_cache.popitem(last=False)
    return payload


def _render_image_preview(content: bytes, mime_type: str | None, digest: str, *, size: str | None) -> tuple[bytes, str]:
    variant, max_edge, quality = _preview_options(size)
    cache_key = (digest, variant)
    cached = _cached_preview(cache_key)
    if cached is not None:
        return cached

    try:
        from PIL import Image, ImageOps, ImageSequence

        Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS
        resampling = getattr(Image, "Resampling", Image)
        with Image.open(io.BytesIO(content)) as image:
            frame = next(ImageSequence.Iterator(image), image)
            preview = ImageOps.exif_transpose(frame)
            has_alpha = "A" in preview.getbands()
            preview = preview.convert("RGBA" if has_alpha else "RGB")
            if max(preview.size) > max_edge:
                preview.thumbnail((max_edge, max_edge), resample=resampling.LANCZOS)
            output = io.BytesIO()
            try:
                preview.save(output, format="WEBP", quality=quality, method=6)
                preview_bytes = output.getvalue()
                if variant == "detail" and len(content) <= len(preview_bytes) and len(content) <= 2_500_000 and (mime_type or "").startswith("image/"):
                    return _store_preview(cache_key, (content, mime_type or "image/jpeg"))
                return _store_preview(cache_key, (preview_bytes, "image/webp"))
            except OSError:
                output = io.BytesIO()
                preview.convert("RGB").save(output, format="JPEG", quality=min(quality + 2, 94), optimize=True)
                preview_bytes = output.getvalue()
                return _store_preview(cache_key, (preview_bytes, "image/jpeg"))
    except Exception:
        return _store_preview(cache_key, (content, mime_type or "application/octet-stream"))


def _render_video_placeholder_thumb(item: dict[str, Any], width: int) -> tuple[bytes, str]:
    cache_key = (f"video:{item.get('id')}:{item.get('updated_at') or item.get('created_at')}", f"w{width}")
    cached = _cached_preview(cache_key)
    if cached is not None:
        return cached
    try:
        from PIL import Image, ImageDraw, ImageFilter

        height = max(120, int(width * 9 / 16))
        base = Image.new("RGB", (width, height), "#18212d")
        draw = ImageDraw.Draw(base)
        for y in range(height):
            shade = int(24 + (y / max(1, height)) * 34)
            draw.line([(0, y), (width, y)], fill=(shade, min(70, shade + 18), min(92, shade + 30)))
        for x in range(-width, width * 2, max(24, width // 9)):
            draw.line([(x, 0), (x + width // 2, height)], fill=(72, 94, 114), width=max(2, width // 120))
        base = base.filter(ImageFilter.GaussianBlur(radius=max(6, width // 80)))
        overlay = Image.new("RGBA", (width, height), (0, 0, 0, 74))
        base = Image.alpha_composite(base.convert("RGBA"), overlay)
        draw = ImageDraw.Draw(base)
        cx, cy = width // 2, height // 2
        radius = max(28, width // 13)
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), outline=(255, 255, 255, 150), width=max(2, width // 180))
        draw.polygon(
            [(cx - radius // 3, cy - radius // 2), (cx - radius // 3, cy + radius // 2), (cx + radius // 2, cy)],
            fill=(255, 255, 255, 170),
        )
        output = io.BytesIO()
        base.convert("RGB").save(output, format="WEBP", quality=84, method=5)
        return _store_preview(cache_key, (output.getvalue(), "image/webp"))
    except Exception:
        svg = (
            f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{max(120, int(width * 9 / 16))}' viewBox='0 0 {width} {max(120, int(width * 9 / 16))}'>"
            "<rect width='100%' height='100%' fill='#18212d'/><circle cx='50%' cy='50%' r='48' fill='none' stroke='rgba(255,255,255,.62)' stroke-width='4'/>"
            "<path d='M48% 42%v16l14-8z' fill='rgba(255,255,255,.72)'/></svg>"
        ).encode("utf-8")
        return _store_preview(cache_key, (svg, "image/svg+xml"))


def _render_video_frame_thumb(source_path: Path, cache_path: Path, width: int) -> bool:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = cache_path.with_suffix(".tmp.webp")
    if tmp_path.exists():
        tmp_path.unlink()
    command = [
        FFMPEG_BIN,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        "0.35",
        "-i",
        str(source_path),
        "-frames:v",
        "1",
        "-vf",
        f"scale='min({int(width)},iw)':-2:flags=lanczos",
        "-c:v",
        "libwebp",
        "-compression_level",
        "5",
        "-quality",
        "88",
        str(tmp_path),
    ]
    try:
        result = subprocess.run(command, check=True, timeout=60, capture_output=True, text=True)
        if tmp_path.exists() and tmp_path.stat().st_size > 0:
            tmp_path.replace(cache_path)
            return True
    except subprocess.CalledProcessError as exc:
        logger.debug("Video thumbnail ffmpeg error for %s: %s", source_path, (exc.stderr or "").strip()[-500:])
    except subprocess.TimeoutExpired:
        logger.debug("Video thumbnail ffmpeg timed out for %s", source_path)
    except FileNotFoundError:
        logger.warning("ffmpeg not found — cannot generate video thumbnails")
    except Exception:
        logger.debug("Video thumbnail extraction failed for %s", source_path, exc_info=True)
    finally:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except Exception:
            pass
    return False


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
    cached_items = _background_cache.get("items") or []
    built_at = float(_background_cache.get("built_at") or 0.0)
    if built_at > 0 and (now - built_at) < BACKGROUND_CACHE_SECONDS:
        return cached_items
    async with _background_cache_lock:
        cached_items = _background_cache.get("items") or []
        built_at = float(_background_cache.get("built_at") or 0.0)
        if built_at > 0 and (time.time() - built_at) < BACKGROUND_CACHE_SECONDS:
            return cached_items
        rows = await db.list_public_background_candidates(limit=900)
        prefixes = await db.get_media_file_prefixes([int(row.get("id") or 0) for row in rows])
        eligible: list[dict[str, Any]] = []
        for row in rows:
            if row.get("mime_type") and not str(row["mime_type"]).startswith("image/"):
                continue
            media_id = int(row["id"])
            prefix = prefixes.get(media_id, b"")
            if prefix:
                dimensions = _background_dimensions_from_bytes(prefix)
            else:
                legacy = _legacy_upload_path(row.get("storage_path"))
                dimensions = _background_dimensions_from_path(legacy) if legacy and legacy.exists() else None
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
        _background_cache["built_at"] = time.time()
        _background_cache["items"] = eligible
        return eligible


async def _site_background_snapshot(*, force: bool = False) -> tuple[dict[str, Any] | None, int]:
    now = time.time()
    current = _site_background_state.get("item")
    picked_at = float(_site_background_state.get("picked_at") or 0.0)
    remaining = max(1, int(SITE_BACKGROUND_ROTATION_SECONDS - max(0.0, now - picked_at)))
    if current and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
        return current, remaining
    if current is None and picked_at > 0 and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
        return None, remaining

    async with _site_background_lock:
        now = time.time()
        current = _site_background_state.get("item")
        picked_at = float(_site_background_state.get("picked_at") or 0.0)
        if current and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
            remaining = max(1, int(SITE_BACKGROUND_ROTATION_SECONDS - max(0.0, now - picked_at)))
            return current, remaining
        if current is None and picked_at > 0 and not force and (now - picked_at) < SITE_BACKGROUND_ROTATION_SECONDS:
            remaining = max(1, int(SITE_BACKGROUND_ROTATION_SECONDS - max(0.0, now - picked_at)))
            return None, remaining
        candidates = await _background_candidate_rows()
        if not candidates:
            _site_background_state["item"] = None
            _site_background_state["picked_at"] = now
            return None, SITE_BACKGROUND_ROTATION_SECONDS
        previous_id = int((current or {}).get("id") or 0)
        pool = [item for item in candidates if int(item.get("id") or 0) != previous_id] or candidates
        picked = dict(random.choice(pool))
        _site_background_state["item"] = picked
        _site_background_state["picked_at"] = now
        return picked, SITE_BACKGROUND_ROTATION_SECONDS


async def _site_background_rotation_loop() -> None:
    await asyncio.sleep(4)
    while True:
        try:
            await _site_background_snapshot(force=True)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("Gallery site background rotation paused after failure: %s", exc)
        await asyncio.sleep(SITE_BACKGROUND_ROTATION_SECONDS)


def _fallback_avatar_svg(user_id: int) -> str:
    initials = f"U{int(user_id)}"[:3]
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
        '<rect width="128" height="128" rx="64" fill="#202832"/>'
        '<text x="64" y="74" text-anchor="middle" font-family="Inter,Arial,sans-serif" '
        'font-size="34" font-weight="800" fill="#9ba8b7">' + html.escape(initials) + '</text></svg>'
    )


def _verification_url(request: Request, token: str) -> str:
    url = str(request.url_for("verify_email"))
    # If the backend sees the request as HTTP but a trusted proxy already handles
    # TLS, force the link to https so the user gets a working URL.
    if _request_is_https(request) and url.startswith("http://"):
        url = "https://" + url[7:]
    return f"{url}?token={quote(str(token), safe='')}"


def _verification_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def _wants_json(request: Request) -> bool:
    accept = request.headers.get("accept", "")
    return "application/json" in accept and "text/html" not in accept


async def _send_verification_or_error(request: Request, user: dict[str, Any], email_token: str) -> bool:
    try:
        await send_verification_email(settings, user["email"], _verification_url(request, email_token), email_token)
        return True
    except EmailDeliveryError as exc:
        raise HTTPException(status_code=502, detail=f"Email verification could not be sent: {exc}") from None


async def _try_send_verification(request: Request, user: dict[str, Any], email_token: str) -> tuple[bool, str | None]:
    try:
        await send_verification_email(settings, user["email"], _verification_url(request, email_token), email_token)
        return True, None
    except EmailDeliveryError as exc:
        return False, str(exc)


def _verification_page(title: str, message: str, *, ok: bool) -> HTMLResponse:
    color = "#37c9a7" if ok else "#ff6b6b"
    return HTMLResponse(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        f"<title>{html.escape(title)}</title>"
        "<style>body{margin:0;min-height:100vh;display:grid;place-items:center;"
        "font-family:Inter,system-ui,sans-serif;background:#10151f;color:#edf4ff}"
        "main{width:min(520px,calc(100vw - 32px));padding:28px;border:1px solid #273244;"
        "background:#151d2b;border-radius:8px}h1{margin:0 0 10px;font-size:1.5rem}"
        "p{color:#aab6c8;line-height:1.5}.badge{display:inline-block;margin-bottom:16px;"
        f"color:{color};font-weight:700}}a{{color:#7dd3fc}}</style></head><body><main>"
        f"<span class=\"badge\">{'Verified' if ok else 'Needs Attention'}</span>"
        f"<h1>{html.escape(title)}</h1><p>{html.escape(message)}</p>"
        f"<p><a href=\"{html.escape(settings.pages_public_url)}\">Return to Image Gallery</a></p>"
        "</main></body></html>"
    )


def _with_urls(request: Request, item: dict[str, Any] | None, adult_allowed: bool = False) -> dict[str, Any] | None:
    if not item:
        return None
    clone = dict(item)
    locked = bool(clone.get("is_adult")) and not adult_allowed
    clone["locked"] = locked
    clone["viewer_can_open_adult"] = adult_allowed
    clone["requires_adult_blur"] = bool(clone.get("is_adult")) and adult_allowed
    if locked:
        clone.pop("storage_path", None)
        clone["url"] = None
        clone["preview_url"] = None
        clone["thumb_url"] = None
        clone["download_url"] = None
    else:
        media_id = int(clone["id"])
        clone["url"] = _public_url(request, clone.get("storage_path", ""), media_id)
        clone["thumb_url"] = _thumb_url(request, media_id) if clone.get("media_kind") in {"image", "video"} else None
        clone["preview_url"] = clone["url"] if _is_gif_media(clone) else (_preview_url(request, media_id) if clone.get("media_kind") == "image" else clone["thumb_url"])
        clone["download_url"] = str(request.url_for("download_media", media_id=media_id))
        if clone.get("is_adult") and adult_allowed:
            token = _media_access_token(media_id)
            clone["url"] = _append_query(clone["url"], "access", token)
            clone["preview_url"] = _append_query(clone["preview_url"], "access", token)
            if clone.get("thumb_url"):
                clone["thumb_url"] = _append_query(clone["thumb_url"], "access", token)
            clone["download_url"] = _append_query(clone["download_url"], "access", token)
    if clone.get("user_avatar_path"):
        clone["user_avatar_url"] = _avatar_url(
            request,
            clone.get("user_id") or clone.get("id"),
            revision=_avatar_revision_token(clone, path_key="user_avatar_path", file_id_key="user_avatar_file_id"),
        )
    return _jsonable(clone)


def _with_user_urls(request: Request, user: dict[str, Any] | None) -> dict[str, Any] | None:
    if not user:
        return None
    clone = dict(user)
    if clone.get("avatar_path"):
        clone["avatar_url"] = _avatar_url(
            request,
            clone["id"],
            revision=_avatar_revision_token(clone, path_key="avatar_path"),
        )
    clone["site_owner"] = _is_site_owner_user(clone)
    return _jsonable(clone)


def _with_friend_request_urls(request: Request, item: dict[str, Any]) -> dict[str, Any]:
    clone = dict(item)
    if clone.get("user"):
        clone["user"] = _with_user_urls(request, clone["user"])
    return _jsonable(clone)


def _with_collection_urls(request: Request, collection: dict[str, Any] | None, adult_allowed: bool = False) -> dict[str, Any] | None:
    if not collection:
        return None
    clone = dict(collection)
    if clone.get("cover_path") and (adult_allowed or not clone.get("cover_is_adult")):
        cover_media_id = int(clone["cover_media_id"]) if clone.get("cover_media_id") else None
        if str(clone.get("cover_path") or "").startswith("db://") and cover_media_id is None:
            clone["cover_url"] = None
        else:
            clone["cover_url"] = _public_url(request, clone["cover_path"], cover_media_id)
    elif clone.get("cover_is_adult"):
        clone.pop("cover_path", None)
        clone["cover_url"] = None
        clone["cover_locked"] = True
    if clone.get("user_avatar_path"):
        clone["user_avatar_url"] = _avatar_url(
            request,
            clone.get("user_id") or clone.get("id"),
            revision=_avatar_revision_token(clone, path_key="user_avatar_path", file_id_key="user_avatar_file_id"),
        )
    return _jsonable(clone)


def _normalize_upload_tag(value: Any) -> str:
    cleaned = re.sub(r"\s+", "-", str(value or "").strip().lstrip("#"))
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "", cleaned)
    return cleaned[:settings.max_tag_length]


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
        if len(tags) >= settings.max_tags_per_upload:
            break
    return tags


def _optional_form_int(value: Any, field_name: str) -> int | None:
    if value in (None, "", 0, "0"):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail=f"{field_name} must be a number.") from None


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
        if len(merged) >= settings.max_tags_per_upload:
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
) -> dict[str, Any]:
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
    return {
        "is_adult": is_adult,
        "adult_marked_by_user": bool(user_marked_adult),
        "adult_marked_by_ai": adult_by_ai,
        "moderation_status": "adult" if is_adult else "clear",
        "moderation_score": 0.96 if adult_by_ai else (0.75 if user_marked_adult else 0),
        "moderation_reason": " ".join(reason_parts)[:300] or None,
    }


MAGIC_SIGNATURES = (
    (b"\xff\xd8\xff", "image/jpeg", "image"),
    (b"\x89PNG\r\n\x1a\n", "image/png", "image"),
    (b"GIF87a", "image/gif", "image"),
    (b"GIF89a", "image/gif", "image"),
    (b"\x1aE\xdf\xa3", "video/webm", "video"),
    (b"OggS", "video/ogg", "video"),
    (b"FLV\x01", "video/x-flv", "video"),
)
RATE_BUCKETS: dict[str, list[float]] = {}
TRUSTED_PROXY_NETS = tuple(
    ipaddress.ip_network(value.strip())
    for value in os.getenv(
        "GALLERY_TRUSTED_PROXY_CIDRS",
        "127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",
    ).split(",")
    if value.strip()
)


def _is_trusted_proxy(host: str | None) -> bool:
    if not host:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return host in {"localhost", "host.docker.internal"}
    return any(ip in network for network in TRUSTED_PROXY_NETS)


def _clean_ip(value: str | None) -> str:
    raw = str(value or "").strip().split(",")[0].strip()[:64]
    if not raw:
        return ""
    try:
        return str(ipaddress.ip_address(raw))
    except ValueError:
        return re.sub(r"[^A-Za-z0-9_.:-]", "", raw)[:64]


def _client_ip(request: Request) -> str:
    direct = _clean_ip(request.client.host if request.client else "") or "unknown"
    if _is_trusted_proxy(direct):
        cf_ip = _clean_ip(request.headers.get("cf-connecting-ip"))
        if cf_ip:
            return cf_ip
        real_ip = _clean_ip(request.headers.get("x-real-ip"))
        if real_ip:
            return real_ip
        forwarded = _clean_ip(request.headers.get("x-forwarded-for"))
        if forwarded:
            return forwarded
    return direct


async def _rate_limit(key: str, *, limit: int, window_seconds: int) -> None:
    clean_key = re.sub(r"[^A-Za-z0-9_.:@-]", "_", str(key or "unknown"))[:190]
    try:
        if await db.check_rate_limit(clean_key, limit=limit, window_seconds=window_seconds):
            return
        raise HTTPException(status_code=429, detail="Too many attempts. Try again later.")
    except HTTPException:
        raise
    except Exception:
        logger.warning("DB-backed rate limit unavailable; using in-process fallback for %s.", clean_key, exc_info=True)
    now = time.time()
    bucket = [t for t in RATE_BUCKETS.get(clean_key, []) if now - t < window_seconds]
    if len(bucket) >= limit:
        raise HTTPException(status_code=429, detail="Too many attempts. Try again later.")
    bucket.append(now)
    RATE_BUCKETS[clean_key] = bucket
    # Prevent unbounded growth of the fallback dict (evict expired entries periodically).
    if len(RATE_BUCKETS) > 4096:
        expired = [k for k, v in list(RATE_BUCKETS.items()) if not any(now - t < window_seconds for t in v)]
        for k in expired[:1024]:
            RATE_BUCKETS.pop(k, None)


def _bounded_query_limit(value: Any, *, default: int = 60, max_limit: int | None = None) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        parsed = default
    ceiling = max(1, int(max_limit or settings.media_page_limit))
    return max(1, min(parsed, ceiling))


def _bounded_query_offset(value: Any) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


def _request_id_for(request: Request) -> str:
    incoming = request.headers.get("x-request-id") or request.headers.get("x-correlation-id")
    cleaned = REQUEST_ID_RE.sub("", str(incoming or ""))[:80]
    return cleaned or secrets.token_hex(12)


def _safe_public_error(exc: Exception) -> str:
    """Return a safe, non-sensitive string representation of an exception."""
    return str(exc)[:240]


def _set_no_store_headers(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"


def _should_no_store(path: str) -> bool:
    return (
        path in APP_SHELL_PATHS
        or path.startswith(("/media/", "/users/"))
        or any(path.startswith(prefix) for prefix in PERSONAL_API_PREFIXES)
    )


def _normalize_origin(value: str | None) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    try:
        parsed = urlparse(raw)
    except Exception:
        return ""
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    return f"{parsed.scheme}://{parsed.netloc}".rstrip("/")


def _origin_from_referer(value: str | None) -> str:
    return _normalize_origin(value)


def _allowed_browser_origins() -> set[str]:
    origins = {
        _normalize_origin(settings.pages_public_url),
        "http://127.0.0.1:8788",
        "http://localhost:8788",
        "http://127.0.0.1:8000",
        "http://localhost:8000",
    }
    origins.update(_normalize_origin(origin) for origin in settings.cors_allowed_origins)
    return {origin for origin in origins if origin}


def _trusted_hosts() -> list[str]:
    if settings.trusted_hosts:
        return list(dict.fromkeys(settings.trusted_hosts))
    hosts = {
        "localhost",
        "127.0.0.1",
        "host.docker.internal",
        "*.trycloudflare.com",
        "*.pinggy-free.link",
        "*.serveousercontent.com",
        "*.lhr.life",
        "*.ngrok-free.dev",
        "*.ngrok.io",
    }
    for origin in _allowed_browser_origins():
        try:
            parsed = urlparse(origin)
        except Exception:
            continue
        if parsed.hostname:
            hosts.add(parsed.hostname)
    return sorted(hosts)


def _allowed_request_origin(request: Request) -> str:
    origin = _normalize_origin(request.headers.get("origin"))
    if origin:
        return origin
    return _origin_from_referer(request.headers.get("referer"))


def _ensure_allowed_browser_origin(request: Request) -> None:
    origin = _allowed_request_origin(request)
    if not origin:
        return
    current = _normalize_origin(str(request.base_url))
    if origin == current or origin in _allowed_browser_origins():
        return
    raise HTTPException(status_code=403, detail="Blocked cross-origin request.")


def _security_headers(request: Request, response: Response) -> None:
    csp = "; ".join([
        "default-src 'self'",
        "base-uri 'self'",
        "object-src 'none'",
        "frame-ancestors 'none'",
        "form-action 'self'",
        "img-src 'self' data: blob: https:",
        "media-src 'self' blob: data: https:",
        "font-src 'self' data: https://fonts.gstatic.com",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "script-src 'self'",
        "connect-src 'self' https: http: ws: wss:",
    ])
    response.headers.setdefault("Content-Security-Policy", csp)
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Permitted-Cross-Domain-Policies", "none")
    response.headers.setdefault("Origin-Agent-Cluster", "?1")
    response.headers.setdefault("Cross-Origin-Resource-Policy", "cross-origin")
    response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=(), usb=()")
    response.headers.setdefault("Cross-Origin-Opener-Policy", "same-origin")
    if getattr(request.state, "request_id", None):
        response.headers.setdefault("X-Request-ID", request.state.request_id)
    if request.url.scheme == "https":
        response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    if request.url.path.startswith(("/static/", "/app/static/")):
        response.headers.setdefault("Cache-Control", "public, max-age=86400")
    if _should_no_store(request.url.path):
        _set_no_store_headers(response)


def _sniff_magic(data: bytes) -> tuple[str, str]:
    head = data[:128]
    if head.startswith(b"RIFF") and head[8:12] == b"WEBP":
        return "image/webp", "image"
    if len(head) >= 12 and head[4:8] == b"ftyp":
        brands = head[8:32]
        if brands[:4] in {b"avif", b"avis"} or b"avif" in brands or b"avis" in brands:
            return "image/avif", "image"
        return "video/mp4", "video"
    # EBML/Matroska magic is shared by WebM and MKV — scan the DocType element to distinguish.
    if head.startswith(b"\x1aE\xdf\xa3"):
        mime = "video/x-matroska" if b"matroska" in data[:256].lower() else "video/webm"
        return mime, "video"
    for prefix, mime, kind in MAGIC_SIGNATURES:
        if head.startswith(prefix):
            return mime, kind
    raise HTTPException(status_code=400, detail="Unsupported or invalid file bytes.")


def _detect_media_kind(upload: UploadFile) -> str:
    mime = (upload.content_type or mimetypes.guess_type(upload.filename or "")[0] or "").lower()
    if mime.startswith(IMAGE_MIME_PREFIXES):
        return "image"
    if mime.startswith(VIDEO_MIME_PREFIXES):
        return "video"
    raise HTTPException(status_code=400, detail="Only images, GIFs, and videos are allowed.")


def _safe_extension(filename: str, mime_type: str) -> str:
    ext = Path(filename or "").suffix.lower()
    guessed = mimetypes.guess_extension(mime_type or "") or ""
    ext = ext if ext in SAFE_EXTENSIONS else guessed.lower()
    if ext not in SAFE_EXTENSIONS:
        raise HTTPException(status_code=400, detail="Unsupported file extension.")
    return ".jpg" if ext == ".jpe" else ext


async def _read_validated_upload(upload: UploadFile, max_bytes: int, *, image_only: bool = False) -> dict[str, Any]:
    # Read only one byte past the allowed size so oversized uploads do not exhaust RAM.
    content = await upload.read(max_bytes + 1)
    if not content:
        raise HTTPException(status_code=400, detail="Upload is empty.")
    if len(content) > max_bytes:
        raise HTTPException(status_code=413, detail=f"Uploads must be {max_bytes // (1024 * 1024)}MB or smaller.")
    sniffed_mime, media_kind = _sniff_magic(content)
    if image_only and media_kind != "image":
        raise HTTPException(status_code=400, detail="Profile pictures must be images.")
    claimed = (upload.content_type or "").lower()
    if claimed and not claimed.startswith(("image/", "video/", "application/octet-stream")):
        raise HTTPException(status_code=400, detail="Invalid declared content type.")
    original_filename = Path(upload.filename or "upload").name[:255]
    _safe_extension(original_filename, sniffed_mime)
    if media_kind == "image":
        try:
            from PIL import Image

            Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS
            with Image.open(io.BytesIO(content)) as image:
                width, height = image.size
                if width <= 0 or height <= 0:
                    raise HTTPException(status_code=400, detail="Image dimensions are invalid.")
                if width * height > MAX_IMAGE_PIXELS:
                    raise HTTPException(status_code=413, detail="Image resolution is too large.")
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=400, detail="Image bytes are corrupt or unsupported by the server image decoder.") from exc
    sha256 = hashlib.sha256(content).hexdigest()
    return {
        "content": content,
        "sha256": sha256,
        "mime_type": sniffed_mime,
        "media_kind": media_kind,
        "original_filename": original_filename,
        "file_size": len(content),
    }


def _filesystem_media_storage_path(sha256: str, filename: str, mime_type: str) -> str:
    ext = _safe_extension(filename, mime_type)
    digest = re.sub(r"[^a-f0-9]", "", str(sha256).lower())[:64]
    if len(digest) < 16:
        digest = hashlib.sha256(str(sha256 or filename).encode("utf-8")).hexdigest()
    return f"media/{digest[:2]}/{digest}{ext}"


def _write_filesystem_media(storage_path: str, content: bytes) -> None:
    target = (settings.uploads_dir / storage_path).resolve()
    uploads_root = settings.uploads_dir.resolve()
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
    if settings.storage_backend == "database":
        packet_limit = await db.get_max_allowed_packet()
        chunk_budget = int(getattr(db, "media_chunk_bytes", 8 * 1024 * 1024)) + (2 * 1024 * 1024)
        if packet_limit and chunk_budget > packet_limit:
            raise HTTPException(
                status_code=413,
                detail=(
                    f"MariaDB max_allowed_packet is only {packet_limit // (1024 * 1024)}MB. "
                    f"The gallery writes files in {db.media_chunk_bytes // (1024 * 1024)}MB chunks, so raise "
                    "max_allowed_packet or lower GALLERY_DB_BLOB_CHUNK_BYTES."
                ),
            )
        try:
            media_file = await db.save_media_file(
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
                    await db.reconnect()
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


def _telegram_command_parts(text: str) -> tuple[str, str]:
    cleaned = str(text or "").strip()
    if not cleaned:
        return "", ""
    first, _, rest = cleaned.partition(" ")
    return first.split("@", 1)[0].lower(), rest.strip()


def _fmt_bytes(n: int) -> str:
    """Human-readable byte size."""
    n = int(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n} {unit}"
        n //= 1024
    return f"{n} TB"


def _format_gallery_stats(stats_payload: dict[str, Any]) -> str:
    stats = stats_payload or {}
    storage_bytes = int(stats.get("bytes") or 0)
    return (
        "Image Gallery — Stats\n"
        f"Users:      {int(stats.get('users') or 0)}\n"
        f"Categories: {int(stats.get('categories') or 0)}\n"
        f"Media:      {int(stats.get('media') or 0)}\n"
        f"Storage:    {_fmt_bytes(storage_bytes)}\n"
        f"Likes:      {int(stats.get('likes') or 0)}"
    )


def _format_gallery_health(checks: dict[str, Any]) -> str:
    checks = checks or {}
    db_time = checks.get("db_time")
    db_time_str = str(db_time)[:19] if db_time else "unknown"
    open_reports = int(checks.get("open_reports") or 0)
    missing_files = int(checks.get("missing_db_files") or 0)
    lines = [
        "Image Gallery — Health",
        f"DB time:        {db_time_str}",
        f"Users:          {int(checks.get('users') or 0)}",
        f"Media active:   {int(checks.get('media_active') or 0)}",
        f"Media archived: {int(checks.get('media_archived') or 0)}",
        f"DB files:       {int(checks.get('db_files') or 0)}",
    ]
    if missing_files:
        lines.append(f"Missing files:  {missing_files}  ← WARNING")
    else:
        lines.append("Missing files:  0  OK")
    lines.append(f"Private posts:  {int(checks.get('private_posts') or 0)}")
    if open_reports:
        lines.append(f"Open reports:   {open_reports}  ← ACTION NEEDED")
    else:
        lines.append("Open reports:   0")
    return "\n".join(lines)


async def _handle_telegram_command(message: dict[str, Any]) -> str:
    command, _rest = _telegram_command_parts(str(message.get("text") or ""))

    # ---- /start  /help -------------------------------------------------------
    if command in {"/start", "/help", "help"}:
        owner_note = ""
        if not settings.telegram_allowed_chat_ids:
            owner_note = (
                "\n\nNOTE: No GALLERY_TELEGRAM_ALLOWED_CHAT_IDS set — "
                "all chats can reach this bot. Use /id to find your chat id "
                "and set it in the .env file to restrict access."
            )
        return (
            "Image Gallery Telegram control panel\n\n"
            "/status   — Gallery stats (users, media, storage)\n"
            "/health   — Database & file integrity check\n"
            "/storage  — Detailed storage breakdown\n"
            "/recent   — Last 5 public uploads\n"
            "/users    — Recent user registrations\n"
            "/ai       — AI / vision pipeline status\n"
            "/id       — Show this chat's Telegram ID\n"
            "/help     — Show this message"
            + owner_note
        )

    # ---- /id -----------------------------------------------------------------
    if command == "/id":
        chat_id = message.get("chat_id")
        allowlisted = chat_id in settings.telegram_allowed_chat_ids if settings.telegram_allowed_chat_ids else None
        note = ""
        if allowlisted is True:
            note = "  (allowlisted)"
        elif allowlisted is False:
            note = "  (NOT in GALLERY_TELEGRAM_ALLOWED_CHAT_IDS)"
        elif allowlisted is None:
            note = "  (no allowlist set — add this id to GALLERY_TELEGRAM_ALLOWED_CHAT_IDS)"
        return f"Your Telegram chat id: {chat_id}{note}"

    # ---- /status  /stats -----------------------------------------------------
    if command in {"/status", "status", "/stats", "stats"}:
        stats_payload = await db.stats()
        return _format_gallery_stats(stats_payload)

    # ---- /health -------------------------------------------------------------
    if command in {"/health", "health"}:
        try:
            checks = await db.site_checks()
            return _format_gallery_health(checks)
        except Exception as exc:
            return f"Health check failed: {str(exc)[:300]}"

    # ---- /storage ------------------------------------------------------------
    if command in {"/storage", "storage"}:
        try:
            stats_payload = await db.stats()
            checks = await db.site_checks()
            storage_bytes = int(stats_payload.get("bytes") or 0)
            db_files = int(checks.get("db_files") or 0)
            media_count = int(stats_payload.get("media") or 0)
            avg_bytes = storage_bytes // max(1, media_count)
            max_upload = int(settings.max_upload_bytes or 0)
            backend = str(getattr(settings, "storage_backend", "database"))
            lines = [
                "Image Gallery — Storage",
                f"Backend:       {backend}",
                f"Total stored:  {_fmt_bytes(storage_bytes)}",
                f"DB file rows:  {db_files}",
                f"Media items:   {media_count}",
                f"Avg per item:  {_fmt_bytes(avg_bytes)}",
                f"Max upload:    {_fmt_bytes(max_upload)}",
            ]
            return "\n".join(lines)
        except Exception as exc:
            return f"Storage info failed: {str(exc)[:300]}"

    # ---- /recent -------------------------------------------------------------
    if command in {"/recent", "recent"}:
        items = await db.list_media(viewer_id=None, sort="new", limit=5, offset=0)
        if not items:
            return "No public gallery posts found."
        lines = ["Image Gallery — Recent uploads"]
        for item in items:
            title = item.get("title") or "Untitled"
            kind = item.get("media_kind") or "media"
            user = item.get("display_name") or item.get("username") or "unknown"
            ts = str(item.get("created_at") or "")[:10]
            lines.append(f"- [{ts}] {title} ({kind}) by {user}")
        return "\n".join(lines)

    # ---- /users --------------------------------------------------------------
    if command in {"/users", "users"}:
        try:
            checks = await db.site_checks()
            total_users = int(checks.get("users") or 0)
            # Fetch recent users via stats (no dedicated list endpoint, use site_checks)
            stats_payload = await db.stats()
            return (
                "Image Gallery — Users\n"
                f"Total registered: {total_users}\n"
                f"(Use the web panel at {settings.pages_public_url} to manage users)"
            )
        except Exception as exc:
            return f"User info failed: {str(exc)[:300]}"

    # ---- /ai -----------------------------------------------------------------
    if command in {"/ai", "ai"}:
        try:
            ai_enabled = bool(getattr(settings, "ai_enabled", False))
            ai_provider = str(getattr(settings, "ai_provider", "none"))
            ai_model = str(getattr(settings, "active_ai_model", "") or getattr(settings, "ai_model", ""))
            bg_enabled = bool(getattr(settings, "ai_background_learning_enabled", False))
            bg_interval = int(getattr(settings, "ai_background_learning_interval_seconds", 0))
            lines = [
                "Image Gallery — AI / Vision",
                f"AI enabled:     {'yes' if ai_enabled else 'no'}",
                f"Provider:       {ai_provider}",
                f"Model:          {ai_model or 'default'}",
                f"Background:     {'on' if bg_enabled else 'off'} (every {bg_interval}s)",
            ]
            return "\n".join(lines)
        except Exception as exc:
            return f"AI info failed: {str(exc)[:300]}"

    return "Unknown command. Use /help to see available Image Gallery commands."


TELEGRAM_HEALTH_INTERVAL_SECONDS = max(60.0, float(os.getenv("GALLERY_TELEGRAM_HEALTH_INTERVAL_SECONDS", "300") or "300"))
TELEGRAM_ALERT_COOLDOWN_SECONDS = max(300.0, float(os.getenv("GALLERY_TELEGRAM_ALERT_COOLDOWN_SECONDS", "900") or "900"))
_telegram_alert_last: dict[str, float] = {}


def _telegram_alert_recipients() -> set[int]:
    """Return the set of chat ids that should receive proactive alerts.

    Priority:
    1. The explicit allowlist (GALLERY_TELEGRAM_ALLOWED_CHAT_IDS) if set.
    2. The single owner chat id (GALLERY_TELEGRAM_OWNER_CHAT_ID) as a fallback.

    If neither is configured alerts are silently dropped — the bot has no
    known destination to push messages to.
    """
    if settings.telegram_allowed_chat_ids:
        return set(settings.telegram_allowed_chat_ids)
    owner = getattr(settings, "telegram_owner_chat_id", None)
    if owner:
        return {int(owner)}
    return set()


async def _send_telegram_alert(key: str, title: str, detail: str) -> None:
    if not telegram_service:
        return
    recipients = _telegram_alert_recipients()
    if not recipients:
        return
    now = time.monotonic()
    if now - _telegram_alert_last.get(key, 0.0) < TELEGRAM_ALERT_COOLDOWN_SECONDS:
        return
    _telegram_alert_last[key] = now
    message = f"{title}\n{str(detail or '').strip()[:1200]}"
    for chat_id in sorted(recipients):
        try:
            await telegram_service.send_message(chat_id, message)
        except Exception:
            logger.exception("Image Gallery Telegram alert delivery failed for chat %s.", chat_id)


async def _telegram_health_watch_loop() -> None:
    await asyncio.sleep(20)
    while True:
        try:
            await db.site_checks()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("Image Gallery database health check failed.")
            await _send_telegram_alert("db", "Image Gallery database problem", _safe_public_error(exc))
            try:
                await db.reconnect()
            except Exception:
                logger.exception("Image Gallery database reconnect failed after health alert.")
        await asyncio.sleep(TELEGRAM_HEALTH_INTERVAL_SECONDS)


async def _run_ai_background_learning_pass() -> int:
    rows = await db.list_ai_media_learning_candidates(
        limit=int(getattr(settings, "ai_background_learning_batch_size", 8) or 8),
        stale_minutes=int(getattr(settings, "ai_background_learning_stale_minutes", 720) or 720),
        error_retry_minutes=int(getattr(settings, "ai_background_learning_error_retry_minutes", 30) or 30),
    )
    processed = 0
    for item in rows:
        media_id = int(item.get("id") or 0)
        user_id = int(item.get("user_id") or 0)
        learned = False
        autofilled = False
        try:
            file_row = await db.get_media_file(media_id)
            if not file_row or not file_row.get("content"):
                await db.upsert_ai_media_learning_state(
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
                example = await db.record_ai_vision_training_example(
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
                ai_enabled=settings.ai_enabled,
                ai_api_key=settings.ai_api_key,
                ai_base_url=settings.active_ai_base_url,
                ai_model=settings.active_ai_model,
                ai_timeout_seconds=settings.ai_timeout_seconds,
                training_examples=training_examples,
            )

            autofill_payload = await _background_autofill_payload(item, analysis)
            if autofill_payload:
                updated_item = await db.update_media(media_id, user_id, autofill_payload)
                if updated_item:
                    autofilled = True
                    item = updated_item
                    example = await db.record_ai_vision_training_example(
                        user_id=user_id,
                        media_id=media_id,
                        source=source_payload,
                        corrected=_media_training_corrected(updated_item),
                        notes="Auto-trained after background metadata autofill.",
                    )
                    learned = learned or bool(example)
                    logger.info(
                        "Gallery AI autofilled media %s using %s at confidence %.3f.",
                        media_id,
                        getattr(analysis, "source", "unknown"),
                        float(getattr(analysis, "confidence", 0.0) or 0.0),
                    )

            await db.upsert_ai_media_learning_state(
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
            logger.warning("Gallery background learning failed for media %s: %s", media_id, exc)
            try:
                await db.upsert_ai_media_learning_state(
                    media_id=media_id,
                    user_id=user_id,
                    status="error",
                    error=str(exc),
                )
            except Exception:
                logger.debug("Unable to persist gallery learning failure state for media %s.", media_id, exc_info=True)
    return processed


async def _ai_background_learning_loop() -> None:
    if not getattr(settings, "ai_background_learning_enabled", True):
        return
    await asyncio.sleep(12)
    interval = max(15.0, float(getattr(settings, "ai_background_learning_interval_seconds", 180) or 180))
    while True:
        try:
            processed = await _run_ai_background_learning_pass()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("Gallery background learning loop paused after failure: %s", exc)
            processed = 0
        await asyncio.sleep(2.0 if processed else interval)


async def _video_thumb_warm_loop() -> None:
    await asyncio.sleep(18)
    cursor: int | None = None
    while True:
        try:
            scanned, cursor = await _run_video_thumb_warm_pass(cursor)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.exception("Video thumbnail warm loop paused after failure: %s", exc)
            scanned, cursor = 0, None
        if not scanned:
            cursor = None
            await asyncio.sleep(VIDEO_THUMB_WARM_INTERVAL_SECONDS)
        else:
            await asyncio.sleep(2.0)


_LIVE_CONFIG_PATH = ROOT_DIR / "live-config.json"


def _touch_live_config() -> None:
    """Refresh the updated_at timestamp in live-config.json on startup.

    If the file already has a non-empty gallery_url (tunnel is up), we
    re-write it with the current timestamp so the frontend knows the backend
    is alive and its cached URL is still valid.  If gallery_url is empty we
    leave the file alone — the tunnel script is responsible for updating it.
    """
    try:
        if not _LIVE_CONFIG_PATH.exists():
            return
        raw = _LIVE_CONFIG_PATH.read_text(encoding="utf-8")
        config = json.loads(raw)
        if not config.get("gallery_url"):
            return
        config["updated_at"] = datetime.now(timezone.utc).astimezone().isoformat()
        _LIVE_CONFIG_PATH.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        logger.info("live-config.json updated_at refreshed on startup.")
    except Exception as exc:
        logger.warning("Could not refresh live-config.json on startup: %s", exc)


def _cleanup_orphan_transcode_temps() -> None:
    """Remove leftover temp files from interrupted or crashed transcodes.

    Two patterns to clean:
    * ``*.stream.tmp`` — current naming; created by _stream_transcode_and_cache,
      renamed to ``.mp4`` on success and deleted on failure.  Any survivor means
      the process was killed mid-stream.
    * ``*.tmp.mp4`` — legacy naming from a previous code version; never served
      and accumulate indefinitely without this cleanup.
    """
    try:
        for pattern in ("*.stream.tmp", "*.tmp.mp4"):
            for stale in VIDEO_CACHE_DIR.glob(pattern):
                try:
                    stale.unlink(missing_ok=True)
                    logger.info("Removed orphaned transcode temp file: %s", stale.name)
                except Exception as exc:
                    logger.warning("Could not remove orphaned transcode temp %s: %s", stale, exc)
    except Exception as exc:
        logger.warning("Orphan transcode cleanup failed: %s", exc)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global telegram_service
    settings.uploads_dir.mkdir(parents=True, exist_ok=True)
    _cleanup_orphan_transcode_temps()
    _touch_live_config()
    await db.connect()
    migration_task = asyncio.create_task(_auto_migrate_legacy_uploads())
    health_task = asyncio.create_task(_telegram_health_watch_loop())
    ai_learning_task = asyncio.create_task(_ai_background_learning_loop())
    video_thumb_task = asyncio.create_task(_video_thumb_warm_loop())
    site_background_task = asyncio.create_task(_site_background_rotation_loop())
    telegram_service = TelegramPollingService(
        token=settings.telegram_bot_token,
        name="Image Gallery",
        handler=_handle_telegram_command,
        allowed_chat_ids=settings.telegram_allowed_chat_ids,
        commands=[
            ("status", "Gallery stats (users, media, storage)"),
            ("health", "Database & file integrity check"),
            ("storage", "Detailed storage breakdown"),
            ("recent", "Last 5 public uploads"),
            ("users", "User registration stats"),
            ("ai", "AI / vision pipeline status"),
            ("id", "Show this chat's Telegram ID"),
            ("help", "Show available commands"),
        ],
    )
    await telegram_service.start()
    await _send_telegram_alert("startup", "Image Gallery online", "Telegram bridge, database health checks, and media services are running.")
    try:
        yield
    finally:
        if telegram_service:
            await telegram_service.close()
            telegram_service = None
        migration_task.cancel()
        try:
            await migration_task
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.warning("Legacy migration task ended during shutdown: %s", exc)
        health_task.cancel()
        try:
            await health_task
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.warning("Telegram health watch task ended during shutdown: %s", exc)
        ai_learning_task.cancel()
        try:
            await ai_learning_task
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.warning("Gallery AI background learning task ended during shutdown: %s", exc)
        video_thumb_task.cancel()
        try:
            await video_thumb_task
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.warning("Gallery video thumbnail warm task ended during shutdown: %s", exc)
        site_background_task.cancel()
        try:
            await site_background_task
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.warning("Gallery site background rotation task ended during shutdown: %s", exc)
        await db.close()


async def _auto_migrate_legacy_uploads() -> None:
    """Move old files from uploads/ into the DB store in small background batches."""
    await asyncio.sleep(2)
    while True:
        try:
            result = await db.migrate_legacy_media_files(limit=10)
            if result.get("migrated"):
                logger.info("Auto-migrated %s legacy upload(s) into DB storage.", result["migrated"])
                await asyncio.sleep(1)
                continue
            return
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning("Auto migration from uploads/ paused: %s", exc)
            return


app = FastAPI(title="Image Gallery", lifespan=lifespan)
settings.uploads_dir.mkdir(parents=True, exist_ok=True)
allowed_origins = settings.cors_allowed_origins or [
    settings.pages_public_url.rstrip("/"),
    "http://127.0.0.1:8000",
    "http://localhost:8000",
    "http://127.0.0.1:8788",
    "http://localhost:8788",
]
cors_origin_regex = os.getenv(
    "GALLERY_CORS_ALLOW_ORIGIN_REGEX",
    r"(https://[a-z0-9-]+\.(trycloudflare\.com|ngrok-free\.dev|ngrok\.io|pinggy-free\.link|serveousercontent\.com|lhr\.life)|http://(localhost|127\.0\.0\.1|10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(:\d+)?)",
)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=_trusted_hosts())
app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_origin_regex=cors_origin_regex,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Requested-With", "X-Request-ID"],
)
app.mount("/static", StaticFiles(directory=ROOT_DIR / "app" / "static"), name="static")
app.mount("/app/static", StaticFiles(directory=ROOT_DIR / "app" / "static"), name="app_static")


@app.middleware("http")
async def browser_origin_and_headers(request: Request, call_next):
    started = time.perf_counter()
    request.state.request_id = _request_id_for(request)
    try:
        if request.method.upper() in {"POST", "PUT", "PATCH", "DELETE"}:
            _ensure_allowed_browser_origin(request)
        response = await call_next(request)
    except HTTPException as exc:
        response = Response(content=str(exc.detail or "Request blocked"), status_code=exc.status_code, media_type="text/plain")
    elapsed_ms = (time.perf_counter() - started) * 1000
    response.headers.setdefault("X-Response-Time-ms", f"{elapsed_ms:.2f}")
    response.headers.setdefault("Server-Timing", f"app;dur={elapsed_ms:.2f}")
    _security_headers(request, response)
    # Fire presence touch after response is returned so it never blocks the client.
    asyncio.ensure_future(_touch_request_presence(request))
    return response


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(_app_shell_path())


@app.get("/favicon.ico", include_in_schema=False)
async def favicon() -> FileResponse:
    return FileResponse(
        ROOT_DIR / "app" / "static" / "favicon.ico",
        media_type="image/vnd.microsoft.icon",
        headers={"Cache-Control": "public, max-age=604800"},
    )


@app.get("/robots.txt", include_in_schema=False)
async def robots_txt() -> Response:
    return Response(
        content="User-agent: *\nAllow: /\n",
        media_type="text/plain",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@app.get("/collections")
@app.get("/following")
@app.get("/liked")
@app.get("/users")
@app.get("/friends")
@app.get("/messages")
@app.get("/studio")
@app.get("/profile")
@app.get("/upload")
@app.get("/settings")
@app.get("/login")
async def app_page() -> FileResponse:
    return FileResponse(_app_shell_path())


@app.get("/media/{media_id:int}")
async def media_page(media_id: int) -> FileResponse:
    return FileResponse(_app_shell_path())


@app.get("/users/{username}")
async def user_page(username: str) -> FileResponse:
    return FileResponse(_app_shell_path())


@app.get("/api/uploads/{path:path}", name="serve_legacy_upload")
async def serve_legacy_upload(path: str) -> FileResponse:
    legacy = _legacy_upload_path(path)
    if not legacy:
        raise HTTPException(status_code=404, detail="Legacy upload not found.")
    media_type = mimetypes.guess_type(str(legacy))[0] or "application/octet-stream"
    return FileResponse(legacy, media_type=media_type, headers={"Cache-Control": "public, max-age=86400"})


@app.get("/api/health")
async def health(request: Request) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": settings.db_schema,
        "storage_backend": settings.storage_backend,
        "max_upload_bytes": settings.max_upload_bytes,
        "media_page_limit": settings.media_page_limit,
        "max_tags_per_upload": settings.max_tags_per_upload,
        "request_id": getattr(request.state, "request_id", ""),
        "server_time": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/live/checks")
async def live_checks(request: Request) -> dict[str, Any]:
    auth = _auth_optional(request)
    checks: list[dict[str, Any]] = []
    try:
        snapshot = await db.site_checks()
        owner = False
        checks.append({"id": "api", "label": "API reachable", "ok": True, "detail": "Backend responded."})
        checks.append({"id": "db", "label": "Database reachable", "ok": True, "detail": f"Schema {settings.db_schema} responded."})
        if settings.telegram_bot_token:
            telegram_snapshot = telegram_service.snapshot() if telegram_service else {}
            checks.append({
                "id": "telegram",
                "label": "Telegram bridge",
                "ok": bool(telegram_snapshot.get("running")),
                "severity": "warn" if not telegram_snapshot.get("running") else "ok",
                "detail": f"@{telegram_snapshot.get('bot_username')}" if telegram_snapshot.get("bot_username") else (telegram_snapshot.get("last_error") or "Telegram token configured; bridge is starting."),
            })
        if auth:
            user = await db.get_user(int(auth["id"]))
            owner = _is_site_owner_user(user)
            checks.append({"id": "session", "label": "Login session", "ok": bool(user), "detail": "Signed in." if user else "Token is invalid or account is gone."})
            if user and user.get("email"):
                checks.append({
                    "id": "email",
                    "label": "Email verification",
                    "ok": bool(user.get("email_verified_at")),
                    "severity": "warn" if not user.get("email_verified_at") else "ok",
                    "detail": "Email verified." if user.get("email_verified_at") else "Email verification is still pending.",
                })
        if owner:
            missing = int(snapshot.get("missing_db_files") or 0)
            checks.append({
                "id": "file_store",
                "label": "DB file store coverage",
                "ok": missing == 0,
                "severity": "warn" if missing else "ok",
                "detail": "All active posts are linked to DB file blobs." if missing == 0 else f"{missing} active post(s) still need DB blob migration or legacy disk fallback.",
            })
            reports = int(snapshot.get("open_reports") or 0)
            checks.append({
                "id": "reports",
                "label": "Open reports",
                "ok": reports == 0,
                "severity": "warn" if reports else "ok",
                "detail": "No open user reports." if reports == 0 else f"{reports} report(s) need review.",
            })
        else:
            snapshot = {"media_active": snapshot.get("media_active"), "db_time": snapshot.get("db_time")}
        status = "ok" if all(c.get("ok") or c.get("severity") == "warn" for c in checks) else "attention"
        return {
            "ok": True,
            "status": status,
            "backend": "image_gallery",
            "checks": checks,
            "check_map": {str(item.get("id")): bool(item.get("ok")) for item in checks},
            "snapshot": _jsonable(snapshot),
            "storage_backend": settings.storage_backend,
            "max_upload_bytes": settings.max_upload_bytes,
            "media_page_limit": settings.media_page_limit,
            "server_time": datetime.now(timezone.utc).isoformat(),
        }
    except Exception as exc:
        if "Packet sequence number wrong" in str(exc):
            try:
                await db.reconnect()
            except Exception:
                pass
        return {
            "ok": False,
            "status": "offline",
            "backend": "image_gallery",
            "checks": [{"id": "db", "label": "Database reachable", "ok": False, "severity": "error", "detail": "Database is unreachable."}],
            "check_map": {"api": True, "db": False, "database": False},
            "snapshot": {},
            "storage_backend": settings.storage_backend,
            "max_upload_bytes": settings.max_upload_bytes,
            "media_page_limit": settings.media_page_limit,
            "server_time": datetime.now(timezone.utc).isoformat(),
        }


@app.get("/api/telegram/status")
async def telegram_status(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    status = telegram_service.snapshot() if telegram_service else {
        "enabled": bool(settings.telegram_bot_token),
        "running": False,
        "bot_username": "",
        "allowed_chat_count": len(settings.telegram_allowed_chat_ids),
        "last_error": "",
        "last_update_at": 0.0,
    }
    return {"telegram": status}


@app.post("/api/live/migrate")
async def migrate_legacy_files(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    try:
        migrated = await db.migrate_legacy_media_files(limit=10)
        snapshot = await db.site_checks()
        return {"ok": True, "migrated": migrated, "snapshot": _jsonable(snapshot)}
    except Exception as exc:
        if "Packet sequence number wrong" in str(exc):
            try:
                await db.reconnect()
            except Exception:
                pass
        logger.exception("Legacy file migration failed.")
        raise HTTPException(status_code=500, detail="Migration failed. Check the server logs for details.") from None


def _request_is_https(request: Request) -> bool:
    proto = str(request.headers.get("x-forwarded-proto") or "").split(",")[0].strip().lower()
    return request.url.scheme == "https" or proto == "https"


def _set_session_cookie(response: Response, token: str, request: Request) -> None:
    secure = _request_is_https(request)
    response.set_cookie(
        SESSION_COOKIE_NAME,
        token,
        max_age=settings.api_token_ttl_seconds,
        httponly=True,
        secure=secure,
        samesite="none" if secure else "lax",
        path="/",
    )


def _clear_session_cookie(response: Response, request: Request) -> None:
    secure = _request_is_https(request)
    response.delete_cookie(SESSION_COOKIE_NAME, path="/", secure=secure, samesite="none" if secure else "lax")


@app.post("/api/auth/register")
async def register(payload: RegisterRequest, request: Request, response: Response) -> dict[str, Any]:
    await _rate_limit(f"register:{_client_ip(request)}", limit=10, window_seconds=3600)
    email_token = _verification_code() if payload.email else None
    try:
        user = await db.register_user(payload.username, payload.password, payload.display_name, payload.email, email_token)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    except Exception as exc:
        if "Duplicate" in str(exc):
            raise HTTPException(status_code=409, detail="That username or email is already taken.") from None
        raise
    verification_sent = False
    email_error = None
    if user.get("email") and email_token:
        verification_sent, email_error = await _try_send_verification(request, user, email_token)
    token = issue_token(settings.session_secret, user)
    _set_session_cookie(response, token, request)
    return {
        "user": _jsonable(user),
        "token": token,
        "email_verification_sent": verification_sent,
        "email_error": email_error,
    }


@app.get("/api/auth/verify-email", name="verify_email")
async def verify_email(request: Request, token: str):
    user = await db.verify_email_by_token(token)
    if not user:
        if _wants_json(request):
            raise HTTPException(status_code=400, detail="Invalid or expired verification link.")
        return _verification_page("Verification Link Expired", "That Image Gallery verification link is invalid or has already been used. Sign in and resend verification from your account.", ok=False)
    if _wants_json(request):
        return {"ok": True, "user": _jsonable(user)}
    return _verification_page("Email Verified", f"{user.get('email') or 'Your email address'} is now verified for Image Gallery.", ok=True)


@app.post("/api/auth/resend-verification")
async def resend_verification(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    await _rate_limit(f"resend-verification:{auth['id']}", limit=8, window_seconds=3600)
    user = await db.get_user(int(auth["id"]))
    if not user:
        raise HTTPException(status_code=404, detail="Account not found.")
    if not user.get("email"):
        raise HTTPException(status_code=400, detail="This account does not have an email address.")
    if user.get("email_verified_at"):
        return {"ok": True, "email_verification_sent": False, "already_verified": True}
    email_token = _verification_code()
    user = await db.issue_email_verification_token(int(auth["id"]), email_token)
    verification_sent = bool(user and await _send_verification_or_error(request, user, email_token))
    return {"ok": verification_sent, "email_verification_sent": verification_sent, "already_verified": False}


@app.post("/api/me/email")
async def update_email(payload: EmailUpdateRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    await _rate_limit(f"email-update:{auth['id']}", limit=8, window_seconds=3600)
    try:
        user = await db.update_user_email(int(auth["id"]), payload.email)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    verification_sent = False
    if user and user.get("email"):
        email_token = _verification_code()
        user = await db.issue_email_verification_token(int(auth["id"]), email_token)
        verification_sent = bool(user and await _send_verification_or_error(request, user, email_token))
    return {"ok": True, "user": _jsonable(user), "email_verification_sent": verification_sent}


@app.post("/api/me/email/verify")
async def verify_email_code(payload: EmailCodeRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    await _rate_limit(f"email-verify:{auth['id']}", limit=20, window_seconds=3600)
    code = re.sub(r"\D+", "", str(payload.code or ""))[:12]
    if not code:
        raise HTTPException(status_code=400, detail="Enter the verification code from your email.")
    user = await db.verify_email_code(int(auth["id"]), code)
    if not user:
        raise HTTPException(status_code=400, detail="Invalid verification code.")
    return {"ok": True, "user": _jsonable(user)}


@app.post("/api/auth/login")
async def login(payload: LoginRequest, request: Request, response: Response) -> dict[str, Any]:
    ip = _client_ip(request)
    username = (payload.username or "").strip()[:80]
    if await db.count_recent_failed_auth(username, ip) >= 8:
        raise HTTPException(status_code=429, detail="Too many failed login attempts. Try again later.")
    try:
        user = await db.authenticate_user(payload.username, payload.password)
    except ValueError as exc:
        await db.record_auth_attempt(username, ip, False)
        raise HTTPException(status_code=400, detail=str(exc)) from None
    await db.record_auth_attempt(username, ip, bool(user))
    if not user:
        raise HTTPException(status_code=401, detail="Invalid username or password.")
    token = issue_token(settings.session_secret, user)
    _set_session_cookie(response, token, request)
    return {"user": _jsonable(user), "token": token}


@app.post("/api/auth/logout")
async def logout(request: Request, response: Response) -> dict[str, Any]:
    _clear_session_cookie(response, request)
    return {"ok": True}


@app.get("/api/me")
async def me(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    user = await db.get_user(int(auth["id"]))
    if not user:
        raise HTTPException(status_code=401, detail="Account no longer exists.")
    return {"user": _with_user_urls(request, user)}


@app.patch("/api/me/profile")
async def update_profile(payload: ProfileUpdateRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        user = await db.update_user_profile(int(auth["id"]), payload.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("media")
    return {"user": _with_user_urls(request, user)}


@app.patch("/api/me/settings")
async def update_settings(payload: SettingsUpdateRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        user = await db.update_user_settings(
            int(auth["id"]),
            {key: value for key, value in payload.model_dump().items() if value is not None},
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"user": _with_user_urls(request, user)}


@app.post("/api/me/avatar")
async def update_avatar(request: Request, file: UploadFile = File(...)) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    await _rate_limit(f"avatar:{auth['id']}", limit=20, window_seconds=3600)
    uploaded = await _read_validated_upload(file, 5 * 1024 * 1024, image_only=True)

    try:
        user = await db.save_avatar_file(
            int(auth["id"]),
            content=uploaded["content"],
            sha256=uploaded["sha256"],
            mime_type=uploaded["mime_type"],
            original_filename=uploaded["original_filename"],
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    except Exception as exc:
        logger.exception("Avatar upload failed for user_id=%s", auth["id"])
        raise HTTPException(status_code=500, detail="Avatar upload failed. Check Image Gallery backend logs.") from exc

    _invalidate_api_cache("media")
    return {"user": _with_user_urls(request, user)}


@app.post("/api/me/age-verification")
async def verify_age(payload: AgeVerifyRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
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
    user = await db.verify_user_age(int(auth["id"]), birthdate)
    return {"user": _with_user_urls(request, user)}


@app.get("/api/me/bookmarks")
async def my_bookmarks(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    items = await db.list_bookmarks(int(auth["id"]))
    adult_allowed = await _viewer_can_open_adult(request)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items]}


@app.get("/api/me/media")
async def my_media(request: Request, include_deleted: bool = True) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    items = await db.list_user_media(int(auth["id"]), include_deleted=include_deleted)
    adult_allowed = await _viewer_can_open_adult(request)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items]}




@app.post("/api/me/password")
async def change_password(payload: PasswordChangeRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    ok = await db.change_password(int(auth["id"]), payload.old_password, payload.new_password)
    if not ok:
        raise HTTPException(status_code=401, detail="Current password is incorrect.")
    return {"ok": True}


@app.delete("/api/me")
async def delete_account(payload: AccountDeleteRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    ok = await db.delete_account(int(auth["id"]), payload.password)
    if not ok:
        raise HTTPException(status_code=401, detail="Password is incorrect.")
    return {"deleted": True}


@app.get("/api/users/search")
async def search_users(request: Request, q: str = "", limit: int = 30) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    limit = _bounded_query_limit(limit, default=30, max_limit=50)
    q = " ".join(str(q or "").split())[:80]
    users = await db.search_users(q, viewer_id=viewer_id, limit=limit)
    return {"users": [_with_user_urls(request, user) for user in users], "limit": limit}


@app.get("/api/users/{username}")
async def public_profile(username: str, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    profile = await db.get_public_profile(username, viewer_id)
    if not profile:
        raise HTTPException(status_code=404, detail="User not found.")
    return {"user": _with_user_urls(request, profile)}


@app.get("/api/users/{username}/profile")
async def profile_page(username: str, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    profile = await db.get_public_profile(username, viewer_id)
    if not profile:
        raise HTTPException(status_code=404, detail="User not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    is_owner = viewer_id and int(viewer_id) == int(profile["id"])
    user_settings = dict(profile.get("user_settings") or {})
    show_uploads = bool(user_settings.get("profile_show_uploads", profile.get("show_recent_uploads", True)) or is_owner)
    show_collections = bool(user_settings.get("profile_show_collections", profile.get("show_collections", True)) or is_owner)
    show_friends = bool(user_settings.get("profile_show_friends", profile.get("show_friends", True)) or is_owner)
    media = await db.list_profile_media(int(profile["id"]), viewer_id=viewer_id, limit=36) if show_uploads else []
    collections = await db.list_user_collections(int(profile["id"]), viewer_id=viewer_id, limit=12) if show_collections else []
    friends = await db.list_friends(int(profile["id"]), viewer_id=viewer_id, limit=18) if show_friends else []
    return {
        "user": _with_user_urls(request, profile),
        "media": [_with_urls(request, item, adult_allowed) for item in media],
        "collections": [_with_collection_urls(request, row, adult_allowed) for row in collections],
        "friends": [_with_user_urls(request, user) for user in friends],
    }


@app.post("/api/users/{user_id}/follow")
async def follow_user(user_id: int, payload: FollowRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        result = await db.set_follow(int(auth["id"]), user_id, payload.following)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not result:
        raise HTTPException(status_code=404, detail="User not found.")
    return result


@app.post("/api/users/{user_id}/friend-request")
async def send_friend_request(user_id: int, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        result = await db.send_friend_request(int(auth["id"]), user_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return _jsonable(result)


@app.get("/api/friends/requests")
async def friend_requests(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    incoming = await db.list_friend_requests(int(auth["id"]), mode="incoming")
    outgoing = await db.list_friend_requests(int(auth["id"]), mode="outgoing")
    return {
        "incoming": [_with_friend_request_urls(request, item) for item in incoming],
        "outgoing": [_with_friend_request_urls(request, item) for item in outgoing],
    }


@app.post("/api/friends/requests/{request_id}")
async def respond_friend_request(request_id: int, payload: FriendActionRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        result = await db.respond_friend_request(int(auth["id"]), request_id, payload.action)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not result:
        raise HTTPException(status_code=404, detail="Friend request not found.")
    return {"request": _jsonable(result)}


@app.get("/api/me/friends")
async def my_friends(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    friends = await db.list_friends(int(auth["id"]), viewer_id=int(auth["id"]))
    return {"friends": [_with_user_urls(request, user) for user in friends]}


@app.get("/api/messages/threads")
async def message_threads(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    threads = await db.list_message_threads(int(auth["id"]))
    return {"threads": [_with_user_urls(request, thread) for thread in threads]}


@app.get("/api/messages/{user_id}")
async def direct_messages(user_id: int, request: Request, limit: int = 80) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        messages = await db.list_direct_messages(int(auth["id"]), user_id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"messages": [_jsonable(message) for message in messages]}


@app.post("/api/messages/{user_id}")
async def send_direct_message(user_id: int, payload: DirectMessageRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        message = await db.send_direct_message(int(auth["id"]), user_id, payload.body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"message": _jsonable(message)}


@app.get("/api/feed/following")
async def following_feed(request: Request, limit: int = 60, offset: int = 0) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    adult_allowed = await _viewer_can_open_adult(request)
    limit = _bounded_query_limit(limit, default=60)
    offset = _bounded_query_offset(offset)
    items = await db.following_feed(int(auth["id"]), limit=limit, offset=offset)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items], "limit": limit, "offset": offset}


@app.get("/api/me/likes")
async def my_likes(request: Request, limit: int = 80, offset: int = 0) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    adult_allowed = await _viewer_can_open_adult(request)
    limit = _bounded_query_limit(limit, default=80)
    offset = _bounded_query_offset(offset)
    items = await db.list_liked_media(int(auth["id"]), limit=limit, offset=offset)
    return {"media": [_with_urls(request, item, adult_allowed) for item in items], "limit": limit, "offset": offset}


@app.get("/api/users/{user_id}/followers")
async def user_followers(user_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    users = await db.list_user_follows(user_id, mode="followers", viewer_id=viewer_id)
    return {"users": [_with_user_urls(request, user) for user in users]}


@app.get("/api/users/{user_id}/following")
async def user_following(user_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    users = await db.list_user_follows(user_id, mode="following", viewer_id=viewer_id)
    return {"users": [_with_user_urls(request, user) for user in users]}


@app.get("/api/users/{user_id}/friends")
async def user_friends(user_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    users = await db.list_friends(user_id, viewer_id=viewer_id)
    return {"friends": [_with_user_urls(request, user) for user in users]}

@app.get("/api/categories")
async def categories(request: Request) -> Response:
    cache_key = _api_cache_key("categories", request)
    cached = _api_cache_response(request, cache_key)
    if cached:
        return cached
    return _store_api_cache_response(request, cache_key, {"categories": _jsonable(await db.list_categories())}, LOOKUP_CACHE_SECONDS)


@app.post("/api/categories")
async def create_category(payload: CategoryRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        category = await db.create_category(payload.name, payload.media_kind, int(auth["id"]))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("categories", "media", "tags")
    return {"category": _jsonable(category)}


@app.get("/api/media")
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
    items = await db.list_media(
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


@app.get("/api/media/random")
async def random_media(request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    item = await db.random_media(viewer_id)
    if not item:
        raise HTTPException(status_code=404, detail="No media has been uploaded yet.")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.get("/api/site/background")
async def site_background(request: Request, exclude: int | None = None) -> dict[str, Any]:
    picked, refresh_after_seconds = await _site_background_snapshot(force=False)
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
        "updated_at": int(_site_background_state.get("picked_at") or 0),
        "refresh_after_seconds": refresh_after_seconds,
    }


@app.get("/api/tags")
async def tags(request: Request) -> Response:
    cache_key = _api_cache_key("tags", request)
    cached = _api_cache_response(request, cache_key)
    if cached:
        return cached
    return _store_api_cache_response(request, cache_key, {"tags": _jsonable(await db.tag_cloud())}, LOOKUP_CACHE_SECONDS)


@app.get("/api/collections")
async def collections(request: Request, mine: bool = False) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    if mine and not viewer_id:
        raise HTTPException(status_code=401, detail="Login required")
    rows = await db.list_collections(viewer_id=viewer_id, mine=mine)
    return {"collections": [_with_collection_urls(request, row, adult_allowed) for row in rows]}


@app.post("/api/collections")
async def create_collection(payload: CollectionRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        collection = await db.create_collection(int(auth["id"]), payload.name, payload.description, payload.is_public)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    adult_allowed = await _viewer_can_open_adult(request)
    return {"collection": _with_collection_urls(request, collection, adult_allowed)}


@app.get("/api/collections/{collection_id}")
async def collection_detail(collection_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    collection = await db.get_collection(collection_id, viewer_id)
    if not collection:
        raise HTTPException(status_code=404, detail="Collection not found.")
    items = await db.list_collection_media(collection_id, viewer_id)
    return {
        "collection": _with_collection_urls(request, collection, adult_allowed),
        "media": [_with_urls(request, item, adult_allowed) for item in items],
    }


@app.post("/api/collections/{collection_id}/items")
async def save_collection_item(collection_id: int, payload: CollectionItemRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    collection = await db.set_collection_item(collection_id, payload.media_id, int(auth["id"]), payload.saved)
    if not collection:
        raise HTTPException(status_code=404, detail="Collection not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    return {"collection": _with_collection_urls(request, collection, adult_allowed)}




@app.get("/api/ai/vision/status")
async def ai_vision_status(request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    provider = str(settings.ai_provider or "").strip().lower()
    if provider in {"google", "google-gemini"}:
        provider = "gemini"
    if not provider:
        provider = "heuristic-only"
    training_count = 0
    try:
        training_count = len(await db.list_ai_vision_training_examples(int(auth["id"]), limit=1000))
    except Exception:
        training_count = -1
    status: dict[str, Any] = {
        "provider": provider,
        "ai_enabled": bool(settings.ai_enabled),
        "training_examples_loaded_limit": int(getattr(settings, "ai_training_examples_limit", 0) or 0),
        "training_examples_available": training_count,
        "active_model": settings.active_ai_model,
        "active_base_url": settings.active_ai_base_url if provider == "ollama" else None,
        "gemini_key_configured": bool(getattr(settings, "ai_api_key", "") and provider == "gemini"),
    }
    if provider == "gemini":
        status.update({"active_base_url": "https://generativelanguage.googleapis.com", "reachable": None if settings.ai_api_key else False, "reason": None if settings.ai_api_key else "Gemini provider is selected but no Gemini API key is configured."})
    elif provider == "ollama":
        base_url = str(os.getenv("GALLERY_OLLAMA_BASE_URL") or settings.active_ai_base_url or "http://127.0.0.1:11434").rstrip("/")
        try:
            with urllib.request.urlopen(f"{base_url}/api/tags", timeout=3) as response:
                payload = json.loads(response.read().decode("utf-8") or "{}")
            models = [str(item.get("name") or "") for item in payload.get("models", []) if item.get("name")]
            status.update({"reachable": True, "models": models[:50]})
        except Exception as exc:
            status.update({"reachable": False, "reason": str(exc)[:240]})
    return {"vision": status}

@app.post("/api/media")
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
    auto_ai: bool = Form(True),
) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
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
    await _rate_limit(f"upload:{auth['id']}", limit=settings.upload_rate_limit_per_hour, window_seconds=3600)
    uploaded = await _read_validated_upload(file, settings.max_upload_bytes)
    training_examples = await _ai_training_examples_for(int(auth["id"]))
    analysis = await _analyze_media_safely(
        content=uploaded["content"],
        filename=uploaded["original_filename"],
        mime_type=uploaded["mime_type"],
        media_kind=uploaded["media_kind"],
        title_hint=title,
        description_hint=description,
        tags_hint=_parse_tags(tags),
        ai_enabled=auto_ai and settings.ai_enabled,
        ai_api_key=settings.ai_api_key,
        ai_base_url=settings.active_ai_base_url,
        ai_model=settings.active_ai_model,
        ai_timeout_seconds=settings.ai_timeout_seconds,
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
        category = await db.create_category(chosen_category_name, inferred_kind, int(auth["id"]))
        category_id_int = int(category["id"])
    chosen_subcategory_ids = await db.resolve_subcategory_ids(
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
    )
    media_kind = uploaded["media_kind"]
    storage_info = await _store_uploaded_media(int(auth["id"]), uploaded, stored_filename)
    item = await db.add_media(
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
            **moderation,
        }
    )
    if media_kind == "video":
        _queue_video_thumb_warmup(int(item["id"]), item=item, widths=VIDEO_THUMB_WARM_WIDTHS)
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media", "tags", "categories")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.post("/api/media/analyze")
async def analyze_media_upload(
    request: Request,
    file: UploadFile = File(...),
    title: str = Form(""),
    description: str = Form(""),
    tags: str = Form(""),
) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    await _rate_limit(f"analyze:{auth['id']}", limit=settings.analyze_rate_limit_per_hour, window_seconds=3600)
    uploaded = await _read_validated_upload(file, settings.max_upload_bytes)
    training_examples = await _ai_training_examples_for(int(auth["id"]))
    analysis = await _analyze_media_safely(
        content=uploaded["content"],
        filename=uploaded["original_filename"],
        mime_type=uploaded["mime_type"],
        media_kind=uploaded["media_kind"],
        title_hint=title,
        description_hint=description,
        tags_hint=_parse_tags(tags),
        ai_enabled=settings.ai_enabled,
        ai_api_key=settings.ai_api_key,
        ai_base_url=settings.active_ai_base_url,
        ai_model=settings.active_ai_model,
        ai_timeout_seconds=settings.ai_timeout_seconds,
        training_examples=training_examples,
    )
    return {
        "analysis": analysis.to_dict(),
        "media_kind": uploaded["media_kind"],
        "mime_type": uploaded["mime_type"],
        "original_filename": uploaded["original_filename"],
    }


@app.get("/api/media/{media_id}")
async def media_detail(media_id: int, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    adult_allowed = await _viewer_can_open_adult(request)
    item = await db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(item, viewer_id)
    if item.get("is_adult") and not adult_allowed:
        raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")
    await db.increment_counter(media_id, "views")
    comments = await db.list_comments(media_id)
    return {"media": _with_urls(request, item, adult_allowed), "comments": _jsonable(comments)}


@app.patch("/api/media/{media_id}")
async def edit_media(media_id: int, payload: MediaUpdateRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    previous_item = await db.get_media(media_id, int(auth["id"]))
    try:
        item = await db.update_media(media_id, int(auth["id"]), payload.model_dump())
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    if getattr(settings, "ai_auto_train_on_edit", True):
        try:
            await db.record_ai_vision_training_example(
                user_id=int(auth["id"]),
                media_id=media_id,
                source=_media_training_source(previous_item),
                corrected=_media_training_corrected(item),
                notes="Auto-trained from owner media edit.",
            )
        except Exception as exc:
            logger.warning("Unable to record gallery AI training example for media %s: %s", media_id, exc)
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media", "tags", "categories")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.post("/api/media/{media_id}/ai/train")
async def train_media_ai(media_id: int, payload: VisionTrainingRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    item = await db.get_media(media_id, int(auth["id"]))
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    try:
        example = await db.record_ai_vision_training_example(
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


@app.get("/api/ai/vision/training")
async def list_ai_training(request: Request, limit: int = 50) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    rows = await db.list_ai_vision_training_examples(int(auth["id"]), limit=limit)
    return {"training_examples": _jsonable(rows)}


@app.get("/api/ai/vision/training/export")
async def export_ai_training(request: Request, limit: int = 500) -> Response:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    rows = await db.export_ai_vision_training_examples(int(auth["id"]), limit=limit)
    return _jsonl_response(rows, "gallery-ai-vision-training.jsonl")


@app.patch("/api/media/{media_id}/controls")
async def edit_media_controls(media_id: int, payload: MediaControlRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        item = await db.set_media_controls(media_id, int(auth["id"]), payload.model_dump(exclude_none=True))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.post("/api/media/{media_id}/restore")
async def restore_media(media_id: int, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        item = await db.restore_media(media_id, int(auth["id"]))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.post("/api/media/{media_id}/like")
async def like_media(media_id: int, payload: LikeRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    viewer_id = int(auth["id"])
    existing = await db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    item = await db.set_like(media_id, viewer_id, payload.liked)
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.post("/api/media/{media_id}/bookmark")
async def bookmark_media(media_id: int, payload: BookmarkRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    viewer_id = int(auth["id"])
    existing = await db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    item = await db.set_bookmark(media_id, viewer_id, payload.bookmarked)
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    adult_allowed = await _viewer_can_open_adult(request)
    _invalidate_api_cache("media")
    return {"media": _with_urls(request, item, adult_allowed)}


@app.post("/api/media/{media_id}/comments")
async def add_comment(media_id: int, payload: CommentRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    viewer_id = int(auth["id"])
    existing = await db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    try:
        comment = await db.add_comment(media_id, viewer_id, payload.body)
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("media")
    return {"comment": _jsonable(comment)}


@app.delete("/api/comments/{comment_id}")
async def delete_comment(comment_id: int, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    try:
        deleted = await db.delete_comment(comment_id, int(auth["id"]))
    except PermissionError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from None
    if not deleted:
        raise HTTPException(status_code=404, detail="Comment not found.")
    _invalidate_api_cache("media")
    return {"deleted": True}


@app.post("/api/media/{media_id}/report")
async def report_media(media_id: int, payload: ReportRequest, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    viewer_id = int(auth["id"])
    existing = await db.get_media(media_id, viewer_id)
    _ensure_media_visible_to_viewer(existing, viewer_id)
    try:
        report = await db.report_media(media_id, viewer_id, payload.reason, payload.details)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    _invalidate_api_cache("media")
    return {"report": _jsonable(report)}


@app.post("/api/media/{media_id}/diagnostics/load")
async def report_media_load_diagnostic(media_id: int, payload: MediaLoadDiagnosticRequest, request: Request) -> dict[str, Any]:
    viewer_id = _user_id(_auth_optional(request))
    context = _trim_client_text(payload.context, 48).lower()
    outcome = _trim_client_text(payload.outcome, 32).lower()
    media_kind = _trim_client_text(payload.media_kind, 16).lower()
    selected_source = _trim_client_text(payload.selected_source, 32).lower()
    failed_sources = _trim_client_labels(payload.failed_sources)
    source_count = max(0, min(int(payload.source_count or 0), 12))
    request_id = getattr(request.state, "request_id", "")
    log_method = logger.warning if outcome == "all-failed" else logger.info
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


@app.delete("/api/media/{media_id}")
async def delete_media(media_id: int, request: Request) -> dict[str, Any]:
    auth = require_auth(request, settings.session_secret, settings.api_token_ttl_seconds)
    item = await db.delete_media(media_id, int(auth["id"]))
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")
    _invalidate_api_cache("media", "tags", "categories")
    return {"deleted": True}


async def _adult_file_allowed(request: Request, media_id: int, access: str | None) -> bool:
    # Browser <img>/<video> requests do not carry Authorization headers.
    # Age-verified API responses include this signed token in adult media URLs.
    return _valid_media_access_token(media_id, access) or await _viewer_can_open_adult(request)


def _parse_range_header(range_header: str | None, file_size: int) -> tuple[int, int] | None:
    if not range_header or not range_header.startswith("bytes=") or file_size <= 0:
        return None
    first_range = range_header[6:].split(",", 1)[0].strip()
    if "-" not in first_range:
        return None
    start_raw, end_raw = first_range.split("-", 1)
    try:
        if start_raw == "":
            suffix = int(end_raw)
            if suffix <= 0:
                return None
            start = max(0, file_size - suffix)
            end = file_size - 1
        else:
            start = int(start_raw)
            end = int(end_raw) if end_raw else file_size - 1
    except ValueError:
        return None
    if start < 0 or start >= file_size or end < start:
        raise HTTPException(
            status_code=416,
            detail="Requested range is not satisfiable.",
            headers={"Content-Range": f"bytes */{file_size}"},
        )
    return start, min(end, file_size - 1)


def _normalize_video_quality(value: str | None) -> str:
    quality = str(value or "high").strip().lower()
    # Map legacy names so old cached links and API calls still work
    _LEGACY = {"medium": "720p", "low": "480p", "high": "original", "original": "original"}
    quality = _LEGACY.get(quality, quality)
    return quality if quality in {"original", "1080p", "720p", "480p", "144p"} else "original"


async def _stream_transcode_and_cache(
    source: Path,
    cache_file: Path,
    profile: dict[str, Any],
    tmp_dir: "tempfile.TemporaryDirectory[str] | None",
    stream_key: tuple[int, str],
) -> "AsyncGenerator[bytes, None]":
    """
    Stream a fragmented MP4 transcode directly from ffmpeg stdout while
    simultaneously writing the output to `cache_file`.  This lets the browser
    start playing within a second instead of waiting for the full transcode.
    Subsequent requests for the same quality hit the cache and get FileResponse
    (which supports HTTP Range / seek).
    """
    scale_filter = f"scale='min({int(profile['max_width'])},iw)':-2:flags=lanczos"
    command = [
        FFMPEG_BIN,
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(source),
        "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", scale_filter,
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-crf", str(int(profile["crf"])),
        "-profile:v", str(profile.get("profile") or "high"),
        "-level", "4.1",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", str(profile["audio_bitrate"]),
        "-movflags", "frag_keyframe+default_base_moof",
        "-f", "mp4", "pipe:1",
    ]
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_cache = cache_file.with_suffix(".stream.tmp")
    try:
        tmp_cache.unlink(missing_ok=True)
    except Exception:
        pass

    # Initialise stderr_task to None so the finally block is safe even if
    # create_subprocess_exec raises before the variable is assigned.
    stderr_task: "asyncio.Task[bytes] | None" = None
    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    # Drain stderr concurrently so it never blocks stdout.
    stderr_task = asyncio.create_task(process.stderr.read(4096))
    succeeded = False
    try:
        with open(tmp_cache, "wb") as fh:
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                fh.write(chunk)
                yield chunk
        await process.wait()
        succeeded = process.returncode == 0
        if succeeded:
            tmp_cache.replace(cache_file)
        else:
            stderr_bytes = await stderr_task if not stderr_task.done() else stderr_task.result()
            err_tail = stderr_bytes.decode(errors="replace")[-400:]
            logger.error("Live transcode rc=%s for cache_file=%s: %s", process.returncode, cache_file, err_tail)
    except Exception:
        if process.returncode is None:
            try:
                process.kill()
            except Exception:
                pass
        logger.exception("Live transcode stream interrupted, cache_file=%s", cache_file)
        raise
    finally:
        _video_active_streams.discard(stream_key)
        if not succeeded:
            try:
                tmp_cache.unlink(missing_ok=True)
            except Exception:
                pass
        if tmp_dir is not None:
            try:
                tmp_dir.cleanup()
            except Exception:
                pass
        if stderr_task is not None and not stderr_task.done():
            stderr_task.cancel()


_BROWSER_SAFE_VIDEO_MIME: frozenset[str] = frozenset({"video/mp4", "video/webm", "video/ogg"})


def _needs_video_transcode(mime_type: str | None) -> bool:
    """Return True when the MIME type is a video that browsers cannot play natively."""
    if not mime_type:
        return False
    return mime_type.startswith("video/") and mime_type.lower() not in _BROWSER_SAFE_VIDEO_MIME


def _stdin_transcode_compatible(header: bytes) -> bool:
    """Return True when the file's container can be demuxed from non-seekable stdin.

    * WebM/MKV: starts with EBML magic (0x1A 0x45 0xDF 0xA3) — always streamable.
    * MP4/MOV/M4V: first box is 'ftyp' or 'moov' — fast-start layout, seekable
      from the start.  Files whose first box is 'mdat' have moov at the end and
      require a seekable (file-backed) input.
    """
    if len(header) < 4:
        return False
    if header[:4] == b"\x1a\x45\xdf\xa3":
        return True
    if len(header) >= 8 and header[4:8] in (b"ftyp", b"moov"):
        return True
    return False


async def _stdin_transcode_and_cache(
    file_id: int,
    cache_file: Path,
    profile: dict[str, Any],
    stream_key: tuple[int, str],
):
    """Transcode a DB-backed video by piping chunks directly to ffmpeg stdin.

    Sending ffmpeg input via stdin means the transcode starts immediately with
    no temp-file round-trip.  ffmpeg produces its first output chunk within a
    few seconds (after the first keyframe interval), so HTTP response headers
    and the first video bytes reach the browser almost immediately.

    Only call this for containers that don't require random-access seeking
    (WebM, MKV, fast-start MP4).  Use _db_backed_transcode_and_cache for the
    router that detects the right path automatically.
    """
    scale_filter = f"scale='min({int(profile['max_width'])},iw)':-2:flags=lanczos"
    command = [
        FFMPEG_BIN,
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", "pipe:0",
        "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", scale_filter,
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-crf", str(int(profile["crf"])),
        "-profile:v", str(profile.get("profile") or "high"),
        "-level", "4.1",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", str(profile["audio_bitrate"]),
        "-movflags", "frag_keyframe+default_base_moof",
        "-f", "mp4", "pipe:1",
    ]
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_cache = cache_file.with_suffix(".stream.tmp")
    try:
        tmp_cache.unlink(missing_ok=True)
    except Exception:
        pass

    stderr_task: asyncio.Task | None = None
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stderr_task = asyncio.create_task(process.stderr.read(8192))

    async def _feed_stdin() -> None:
        try:
            async for chunk in db.stream_media_file_content(file_id):
                try:
                    process.stdin.write(chunk)
                    await process.stdin.drain()
                except (BrokenPipeError, ConnectionResetError):
                    break
        except Exception:
            logger.debug("stdin feed interrupted for stream_key=%s", stream_key, exc_info=True)
        finally:
            try:
                process.stdin.close()
            except Exception:
                pass

    stdin_task = asyncio.create_task(_feed_stdin())
    succeeded = False
    try:
        with open(tmp_cache, "wb") as fh:
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                fh.write(chunk)
                yield chunk
        await process.wait()
        succeeded = process.returncode == 0
        if succeeded:
            tmp_cache.replace(cache_file)
        else:
            if stderr_task.done():
                err = stderr_task.result()
            else:
                err = b""
            logger.error(
                "stdin transcode rc=%s cache_file=%s: %s",
                process.returncode,
                cache_file,
                err.decode(errors="replace")[-400:],
            )
    except Exception:
        if process.returncode is None:
            try:
                process.kill()
            except Exception:
                pass
        logger.exception("stdin transcode stream interrupted cache_file=%s", cache_file)
        raise
    finally:
        stdin_task.cancel()
        _video_active_streams.discard(stream_key)
        if not succeeded:
            try:
                tmp_cache.unlink(missing_ok=True)
            except Exception:
                pass
        if stderr_task is not None and not stderr_task.done():
            stderr_task.cancel()


async def _db_backed_transcode_and_cache(
    file_id: int,
    original_filename: str,
    cache_file: Path,
    profile: dict[str, Any],
    stream_key: tuple[int, str],
):
    """Router for DB-backed live transcodes.

    Probes the first 8 bytes of the source file to decide the transcode path:

    * Fast-start MP4 / MOV (moov/ftyp at offset 4) and WebM/MKV (EBML magic):
      Use stdin piping.  ffmpeg starts immediately and yields the first fragment
      within ~2 s, so TTFB is fast and the browser shows a responsive buffering
      state.

    * All other layouts (moov-at-end MP4, unknown containers):
      Fall back to writing a temp file first, then running ffmpeg.  TTFB is
      slower (full DB read + disk write before first output byte) but the
      connection stays alive and the browser eventually plays the video.
    """
    header = await db.get_file_header_bytes(file_id, size=8)
    if _stdin_transcode_compatible(header):
        async for data in _stdin_transcode_and_cache(file_id, cache_file, profile, stream_key):
            yield data
        return

    # Temp-file fallback for moov-at-end and unknown containers.
    tmp_dir_obj: tempfile.TemporaryDirectory | None = None
    entered_stream_transcode = False
    try:
        tmp_dir_obj = tempfile.TemporaryDirectory(prefix="gallery-video-")
        safe_name = Path(original_filename or "source.video").name or "source.video"
        source_path = Path(tmp_dir_obj.name) / safe_name
        with open(source_path, "wb") as fh:
            async for chunk in db.stream_media_file_content(file_id):
                fh.write(chunk)
        if not source_path.exists() or source_path.stat().st_size == 0:
            return
        entered_stream_transcode = True
        async for data in _stream_transcode_and_cache(source_path, cache_file, profile, tmp_dir_obj, stream_key):
            yield data
    except Exception:
        logger.exception("DB-backed transcode failed for stream_key=%s", stream_key)
        raise
    finally:
        if not entered_stream_transcode:
            # _stream_transcode_and_cache owns cleanup once entered; only clean
            # up here if we never reached it.
            _video_active_streams.discard(stream_key)
            if tmp_dir_obj is not None:
                try:
                    tmp_dir_obj.cleanup()
                except Exception:
                    pass


async def _video_variant_response(media_id: int, item: dict[str, Any], file_info: dict[str, Any] | None, legacy: Path | None, quality: str) -> Response | None:
    profile = VIDEO_QUALITY_PROFILES.get(_normalize_video_quality(quality))
    if not profile or item.get("media_kind") != "video":
        return None
    digest = str((file_info or {}).get("sha256") or item.get("content_sha256") or item.get("updated_at") or item.get("created_at") or media_id)
    cache_file = VIDEO_CACHE_DIR / f"{int(media_id)}_{quality}_{hashlib.sha256(digest.encode('utf-8')).hexdigest()[:16]}.mp4"

    # Cache hit — FileResponse supports HTTP Range so the browser can seek.
    if cache_file.exists() and cache_file.stat().st_size > 0:
        return FileResponse(
            cache_file,
            media_type="video/mp4",
            headers={
                "Cache-Control": "public, max-age=86400",
                "X-Video-Quality": quality,
                "X-Video-Codec": "h264/aac",
            },
        )

    # Large DB-backed files: skip transcode entirely and let the caller fall through
    # to range-based streaming of the original.  Loading hundreds of MB into memory
    # to write a temp file before ffmpeg can start would saturate the container's
    # memory limit and stall the entire event loop.
    _TRANSCODE_SIZE_LIMIT = 500 * 1024 * 1024  # 500 MB
    if file_info and int(file_info.get("file_size") or 0) > _TRANSCODE_SIZE_LIMIT:
        logger.info(
            "Skipping transcode for large DB-backed file media_id=%s size=%s quality=%s",
            media_id,
            file_info.get("file_size"),
            quality,
        )
        return None

    # Cache miss — if a transcode is already running for this (media_id, quality),
    # wait for it to finish rather than spawning a second competing ffmpeg process.
    # Both would write to the same .stream.tmp file, corrupting the output.
    stream_key = (int(media_id), quality)
    if stream_key in _video_active_streams:
        for _ in range(60):  # poll up to 30 s (60 × 0.5 s)
            await asyncio.sleep(0.5)
            if cache_file.exists() and cache_file.stat().st_size > 0:
                return FileResponse(
                    cache_file,
                    media_type="video/mp4",
                    headers={
                        "Cache-Control": "public, max-age=86400",
                        "X-Video-Quality": quality,
                        "X-Video-Codec": "h264/aac",
                    },
                )
        # Transcode is stalled or very slow — fall through to serve the original.
        return None

    # Resolve the source file for the transcode.
    if file_info:
        # For DB-backed files, start streaming immediately so HTTP headers reach
        # the browser before the temp-file write begins.  Waiting for the full
        # DB read to complete before returning the response caused the connection
        # to appear stalled (no headers at all) for the entire write duration,
        # which looks like a timeout for large videos (50-300 MB).
        _video_active_streams.add(stream_key)
        safe_name = (Path(str(file_info.get("original_filename") or f"{media_id}.video")).name or f"{media_id}.video")
        return StreamingResponse(
            _db_backed_transcode_and_cache(
                int(file_info["id"]),
                safe_name,
                cache_file,
                profile,
                stream_key,
            ),
            media_type="video/mp4",
            headers={
                "Cache-Control": "no-store",
                "Accept-Ranges": "none",
                "X-Video-Quality": quality,
                "X-Video-Codec": "h264/aac",
                "X-Transcode": "live",
            },
        )
    elif legacy:
        pass
    else:
        return None

    _video_active_streams.add(stream_key)
    return StreamingResponse(
        _stream_transcode_and_cache(legacy, cache_file, profile, None, stream_key),
        media_type="video/mp4",
        headers={
            "Cache-Control": "no-store",
            "Accept-Ranges": "none",
            "X-Video-Quality": quality,
            "X-Video-Codec": "h264/aac",
            "X-Transcode": "live",
        },
    )


async def _serve_media_content(media_id: int, request: Request, *, access: str | None, as_download: bool, quality: str | None = None) -> Response:
    auth = _auth_optional(request)
    viewer_id = _user_id(auth)
    item = await db.get_media(media_id, viewer_id)
    if not item or item.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Media not found.")
    owner = int(item.get("user_id")) == int(viewer_id or 0)
    if item.get("visibility") == "private" and not owner:
        raise HTTPException(status_code=403, detail="This post is private.")
    if as_download and not item.get("downloads_enabled", True) and not owner:
        raise HTTPException(status_code=403, detail="Downloads are disabled for this post.")
    if item.get("is_adult"):
        adult_ok = await _adult_file_allowed(request, media_id, access)
        if not adult_ok:
            raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")

    requested_quality = _normalize_video_quality(quality)
    file_info = await db.get_media_file_info(media_id)
    if file_info:
        # If the stored MIME type is browser-incompatible (e.g. MKV, MOV, AVI)
        # and the caller asked for the original/high quality, redirect through the
        # medium transcode profile so Firefox and Safari can play it.
        effective_quality = requested_quality
        if not as_download and _needs_video_transcode(file_info.get("mime_type")) and effective_quality not in VIDEO_QUALITY_PROFILES:
            effective_quality = "720p"
        variant = None if as_download else await _video_variant_response(media_id, item, file_info, None, effective_quality)
        if variant:
            return variant
        file_size = int(file_info.get("file_size") or 0) or int(file_info.get("inline_size") or 0)
        requested_range = None if as_download else _parse_range_header(request.headers.get("range"), file_size)
        headers = {
            "X-Content-SHA256": str(file_info.get("sha256") or ""),
            "Accept-Ranges": "bytes",
        }
        if file_size > 0:
            headers["Content-Length"] = str(file_size)
        if as_download:
            await db.increment_counter(media_id, "downloads")
            headers["Content-Disposition"] = _download_filename(file_info.get("original_filename"))
            headers["Cache-Control"] = "private, max-age=0, no-cache"
        else:
            headers["Cache-Control"] = "public, max-age=86400"
        if requested_range:
            start, end = requested_range
            headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
            headers["Content-Length"] = str(end - start + 1)
            return StreamingResponse(
                db.stream_media_file_content(int(file_info["id"]), start=start, end=end),
                status_code=206,
                media_type=file_info.get("mime_type") or "application/octet-stream",
                headers=headers,
            )
        return StreamingResponse(
            db.stream_media_file_content(int(file_info["id"])),
            media_type=file_info.get("mime_type") or "application/octet-stream",
            headers=headers,
        )

    legacy = _legacy_upload_path(item.get("storage_path"))
    if legacy:
        # Same browser-compatibility check for legacy on-disk files.
        legacy_mime = item.get("mime_type") or mimetypes.guess_type(str(legacy))[0]
        legacy_quality = requested_quality
        if not as_download and _needs_video_transcode(legacy_mime) and legacy_quality not in VIDEO_QUALITY_PROFILES:
            legacy_quality = "720p"
        variant = None if as_download else await _video_variant_response(media_id, item, None, legacy, legacy_quality)
        if variant:
            return variant
        if as_download:
            await db.increment_counter(media_id, "downloads")
        return FileResponse(
            legacy,
            media_type=item.get("mime_type") or mimetypes.guess_type(str(legacy))[0] or "application/octet-stream",
            filename=None,
            headers=(
                {"Cache-Control": "public, max-age=86400"}
                if not as_download
                else {"Content-Disposition": _download_filename(item.get("original_filename"))}
            ),
        )

    raise HTTPException(
        status_code=404,
        detail="File is missing. Re-upload this post once so it can be saved into the new DB-backed file store.",
    )




# Resolve the ffmpeg binary once at startup.  On NixOS, ffmpeg lives under
# /run/current-system/sw/bin and is NOT on the default PATH used by the
# FastAPI process.  We try the NixOS well-known path first, then fall back to
# whatever `which` finds, and finally to the bare name so the error message
# from subprocess is at least meaningful.
_NIXOS_FFMPEG = "/run/current-system/sw/bin/ffmpeg"
FFMPEG_BIN: str = (
    _NIXOS_FFMPEG
    if os.path.isfile(_NIXOS_FFMPEG) and os.access(_NIXOS_FFMPEG, os.X_OK)
    else (shutil.which("ffmpeg") or "ffmpeg")
)

# XENUS_THUMB_CACHE_V1
THUMB_CACHE_DIR = settings.uploads_dir / "_thumb_cache"
THUMB_CACHE_DIR.mkdir(parents=True, exist_ok=True)
VIDEO_CACHE_DIR = settings.uploads_dir / "_video_cache"
VIDEO_CACHE_DIR.mkdir(parents=True, exist_ok=True)
VIDEO_QUALITY_PROFILES = {
    "1080p": {"max_width": 1920, "crf": 22, "audio_bitrate": "320k", "preset": "fast", "profile": "high"},
    "720p":  {"max_width": 1280, "crf": 25, "audio_bitrate": "256k", "preset": "fast", "profile": "high"},
    "480p":  {"max_width": 854,  "crf": 28, "audio_bitrate": "192k", "preset": "fast", "profile": "high"},
    "144p":  {"max_width": 256,  "crf": 36, "audio_bitrate": "64k",  "preset": "ultrafast", "profile": "baseline"},
}


def _video_thumb_cache_file(media_id: int, width: int) -> Path:
    # Shard into sub-directories by the last two hex digits of the media_id to avoid
    # huge flat directories when there are many videos.
    shard = f"{int(media_id) % 256:02x}"
    return THUMB_CACHE_DIR / shard / f"{int(media_id)}_{int(width)}.webp"


def _normalize_video_thumb_widths(widths: tuple[int, ...] | list[int] | None = None) -> tuple[int, ...]:
    raw = widths or VIDEO_THUMB_WARM_WIDTHS
    cleaned = sorted({max(160, min(int(width or 0), 1440)) for width in raw if int(width or 0) > 0})
    return tuple(cleaned or VIDEO_THUMB_WARM_WIDTHS)


async def _ensure_video_thumb_cache(
    media_id: int,
    *,
    item: dict[str, Any] | None = None,
    widths: tuple[int, ...] | list[int] | None = None,
) -> int:
    normalized_widths = _normalize_video_thumb_widths(widths)
    pending = [
        width
        for width in normalized_widths
        if not _video_thumb_cache_file(media_id, width).exists()
        or _video_thumb_cache_file(media_id, width).stat().st_size <= 0
    ]
    if not pending:
        return 0

    item = item or await db.get_media(media_id, None)
    if not item or str(item.get("media_kind") or "").lower() != "video":
        return 0

    async def _extract_from_source(source_path: Path) -> int:
        generated = 0
        for width in pending:
            cache_file = _video_thumb_cache_file(media_id, width)
            lock_key = f"video:{int(media_id)}:{width}"
            lock = _thumb_generation_locks.setdefault(lock_key, asyncio.Lock())
            async with lock:
                if cache_file.exists() and cache_file.stat().st_size > 0:
                    continue
                success = await asyncio.to_thread(_render_video_frame_thumb, source_path, cache_file, width)
                if success:
                    generated += 1
        return generated

    # Use get_media_file_info (no BLOB) then stream chunks to avoid loading the
    # entire video into Python memory — critical for files over a few hundred MB.
    file_info = await db.get_media_file_info(media_id)
    if file_info:
        with tempfile.TemporaryDirectory(prefix="gallery-video-thumb-") as tmp_dir:
            safe_name = Path(str(file_info.get("original_filename") or f"{media_id}.video")).name or f"{media_id}.video"
            source_path = Path(tmp_dir) / safe_name
            async def _stream_to_file(fid: int, dest: Path) -> None:
                with open(dest, "wb") as fh:
                    async for chunk in db.stream_media_file_content(fid):
                        fh.write(chunk)
            await _stream_to_file(int(file_info["id"]), source_path)
            if source_path.stat().st_size > 0:
                return await _extract_from_source(source_path)

    legacy = _legacy_upload_path(item.get("storage_path"))
    if legacy:
        return await _extract_from_source(legacy)
    return 0


def _queue_video_thumb_warmup(
    media_id: int,
    *,
    item: dict[str, Any] | None = None,
    widths: tuple[int, ...] | list[int] | None = None,
) -> asyncio.Task[Any]:
    normalized_widths = _normalize_video_thumb_widths(widths)
    key = (int(media_id), normalized_widths)
    existing = _video_thumb_warm_tasks.get(key)
    if existing and not existing.done():
        return existing

    async def _runner() -> None:
        try:
            generated = await _ensure_video_thumb_cache(int(media_id), item=item, widths=normalized_widths)
            if generated:
                logger.info("Warmed %s video thumbnail(s) for media %s.", generated, media_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.debug("Video thumbnail warmup failed for media %s.", media_id, exc_info=True)
        finally:
            _video_thumb_warm_tasks.pop(key, None)

    task = asyncio.create_task(_runner())
    _video_thumb_warm_tasks[key] = task
    return task


async def _run_video_thumb_warm_pass(before_media_id: int | None = None) -> tuple[int, int | None]:
    rows = await db.list_video_thumb_candidates(limit=VIDEO_THUMB_WARM_BATCH_SIZE, before_media_id=before_media_id)
    if not rows:
        return 0, None
    next_cursor = int(rows[-1].get("id") or 0) or None
    scanned = 0
    for item in rows:
        media_id = int(item.get("id") or 0)
        if not media_id:
            continue
        await _ensure_video_thumb_cache(media_id, item=item, widths=VIDEO_THUMB_WARM_WIDTHS)
        scanned += 1
    return scanned, next_cursor


def _thumb_file_response(request: Request, cache_file: Path, headers: dict[str, str]) -> Response | None:
    if not cache_file.exists() or cache_file.stat().st_size <= 0:
        return None
    stat = cache_file.stat()
    etag = f"\"thumb:{cache_file.stem}:{stat.st_mtime_ns}:{stat.st_size}\""
    response_headers = {**headers, "ETag": etag}
    if _etag_matches(request, etag):
        return Response(status_code=304, headers=response_headers)
    return FileResponse(cache_file, media_type="image/webp", headers=response_headers)


@app.get("/api/media/{media_id}/thumb", name="serve_media_thumb")
async def serve_media_thumb(media_id: int, request: Request, access: str | None = None, w: int = 520) -> Response:
    viewer_id = _user_id(_auth_optional(request))
    item = await db.get_media(media_id, viewer_id)
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")

    if item.get("is_adult") and not await _adult_file_allowed(request, media_id, access):
        raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")

    width = max(160, min(int(w or 520), 1440))
    # Flat (non-sharded) cache path used for image thumbnails.
    cache_file = THUMB_CACHE_DIR / f"{int(media_id)}_{width}.webp"

    headers = {
        "Cache-Control": "public, max-age=604800, immutable",
        "X-Xenus-Thumb": "1",
    }

    if str(item.get("media_kind") or "").lower() == "video":
        # Video thumbnails are stored in sharded subdirectories via _video_thumb_cache_file.
        # Always use the sharded path so generation and serving agree on the file location.
        video_cache_file = _video_thumb_cache_file(int(media_id), width)
        video_headers = {**headers, "X-Xenus-Video-Thumb": "frame"}
        # Serve from cache if already generated (handles both fresh and pre-existing entries).
        cached = _thumb_file_response(request, video_cache_file, video_headers)
        if cached:
            return cached
        # Not cached yet — generate now, then re-check.
        await _ensure_video_thumb_cache(int(media_id), item=item, widths=(width,))
        cached = _thumb_file_response(request, video_cache_file, video_headers)
        if cached:
            return cached
        preview_bytes, preview_mime = await asyncio.to_thread(_render_video_placeholder_thumb, item, width)
        etag = f"\"video-thumb:{int(media_id)}:{width}:{hashlib.sha256(preview_bytes).hexdigest()[:16]}\""
        fallback_headers = {**headers, "ETag": etag, "X-Xenus-Video-Thumb": "placeholder"}
        logger.info(
            "Video thumbnail placeholder served for media_id=%s width=%s request_id=%s",
            media_id,
            width,
            getattr(request.state, "request_id", "") or "none",
        )
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=fallback_headers)
        return Response(content=preview_bytes, media_type=preview_mime, headers=fallback_headers)

    if str(item.get("media_kind") or "").lower() != "image":
        return await _serve_media_content(media_id, request, access=access, as_download=False)

    lock_key = f"img:{int(media_id)}:{width}"
    lock = _thumb_generation_locks.setdefault(lock_key, asyncio.Lock())
    # Prune stale unlocked entries to prevent unbounded growth (images are
    # generated once and then served from disk, so the lock is only needed once).
    if len(_thumb_generation_locks) > 2048:
        stale = [k for k, lk in list(_thumb_generation_locks.items()) if not lk.locked() and k != lock_key]
        for k in stale[:512]:
            _thumb_generation_locks.pop(k, None)
    async with lock:
        cached = _thumb_file_response(request, cache_file, headers)
        if cached:
            return cached

        file_row = await db.get_media_file(media_id)
        if not file_row:
            legacy = _legacy_upload_path(item.get("storage_path"))
            if legacy:
                return FileResponse(
                    legacy,
                    media_type=item.get("mime_type") or mimetypes.guess_type(str(legacy))[0] or "application/octet-stream",
                    headers=headers,
                )
            raise HTTPException(status_code=404, detail="File missing from database.")

        try:
            from PIL import Image, ImageSequence
            Image.MAX_IMAGE_PIXELS = 90_000_000

            raw_content = bytes(file_row.get("content") or b"")
            if not raw_content:
                raise HTTPException(status_code=404, detail="File content is empty.")

            with Image.open(io.BytesIO(raw_content)) as image:
                frame = next(ImageSequence.Iterator(image), image)
                frame = frame.convert("RGB")
                frame.thumbnail((width, width), Image.Resampling.LANCZOS)

                tmp = cache_file.with_suffix(".tmp")
                frame.save(tmp, format="WEBP", quality=84, method=5)
                tmp.replace(cache_file)

            cached = _thumb_file_response(request, cache_file, headers)
            if cached:
                return cached
            return FileResponse(cache_file, media_type="image/webp", headers=headers)
        except Exception:
            # If thumbnailing fails, fall back to the original instead of breaking the UI.
            logger.warning(
                "Image thumbnail generation failed; serving original for media_id=%s width=%s request_id=%s",
                media_id,
                width,
                getattr(request.state, "request_id", "") or "none",
                exc_info=True,
            )
            return await _serve_media_content(media_id, request, access=access, as_download=False)


@app.get("/api/media/{media_id}/file", name="serve_media_file")
async def serve_media_file(media_id: int, request: Request, access: str | None = None, quality: str | None = None) -> Response:
    return await _serve_media_content(media_id, request, access=access, as_download=False, quality=quality)


@app.get("/api/media/{media_id}/preview", name="serve_media_preview")
async def serve_media_preview(media_id: int, request: Request, access: str | None = None, size: str = "card") -> Response:
    auth = _auth_optional(request)
    viewer_id = _user_id(auth)
    item = await db.get_media(media_id, viewer_id)
    if not item or item.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Media not found.")
    owner = int(item.get("user_id")) == int(viewer_id or 0)
    if item.get("visibility") == "private" and not owner:
        raise HTTPException(status_code=403, detail="This post is private.")
    if item.get("is_adult") and not await _adult_file_allowed(request, media_id, access):
        raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")
    if item.get("media_kind") != "image":
        return await _serve_media_content(media_id, request, access=access, as_download=False, quality=size)

    file_row = await db.get_media_file(media_id)
    if file_row:
        # Use the stored SHA-256 for the ETag; only verify content integrity after loading.
        digest = str(file_row.get("sha256") or "")
        etag = _preview_etag(digest, size)
        headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=headers)
        content_bytes = bytes(file_row.get("content") or b"")
        if digest and hashlib.sha256(content_bytes).hexdigest() != digest:
            raise HTTPException(status_code=500, detail="Stored file failed hash verification.")
        preview_bytes, preview_mime = await asyncio.to_thread(
            _render_image_preview,
            content_bytes,
            file_row.get("mime_type"),
            digest,
            size=size,
        )
        return Response(content=preview_bytes, media_type=preview_mime, headers=headers)

    legacy = _legacy_upload_path(item.get("storage_path"))
    if not legacy:
        raise HTTPException(
            status_code=404,
            detail="Preview is missing. Re-upload this post once so it can be saved into the new DB-backed file store.",
        )
    content = legacy.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    etag = _preview_etag(digest, size)
    headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
    if _etag_matches(request, etag):
        return Response(status_code=304, headers=headers)
    preview_bytes, preview_mime = await asyncio.to_thread(
        _render_image_preview,
        content,
        item.get("mime_type") or mimetypes.guess_type(str(legacy))[0] or "image/jpeg",
        digest,
        size=size,
    )
    return Response(content=preview_bytes, media_type=preview_mime, headers=headers)


@app.get("/api/users/{user_id}/avatar", name="serve_user_avatar")
async def serve_user_avatar(user_id: int, request: Request) -> Response:
    file_row = await db.get_avatar_file(user_id)
    if file_row:
        digest = str(file_row.get("sha256") or "")
        etag = f"\"avatar:{digest}\""
        headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=headers)
        content_bytes = bytes(file_row.get("content") or b"")
        if digest and hashlib.sha256(content_bytes).hexdigest() != digest:
            raise HTTPException(status_code=500, detail="Stored avatar failed hash verification.")
        return Response(content=content_bytes, media_type=file_row.get("mime_type") or "image/jpeg", headers=headers)

    user = await db.get_user(user_id)
    legacy = _legacy_upload_path((user or {}).get("avatar_path"))
    if legacy:
        content = legacy.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        etag = f"\"avatar:{digest}\""
        headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=headers)
        return FileResponse(
            legacy,
            media_type=(user.get("avatar_mime_type") if user else None) or mimetypes.guess_type(str(legacy))[0] or "image/jpeg",
            headers=headers,
        )

    # Avoid repeated browser 404 spam for accounts that have no uploaded avatar yet.
    return Response(content=_fallback_avatar_svg(user_id), media_type="image/svg+xml", headers={"Cache-Control": "public, max-age=3600"})


@app.get("/api/media/{media_id}/download", name="download_media")
async def download_media(media_id: int, request: Request, access: str | None = None) -> Response:
    return await _serve_media_content(media_id, request, access=access, as_download=True)


@app.get("/api/stats")
async def stats(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    return {"stats": _jsonable(await db.stats())}

@app.options("/api/site/background")
async def api_site_background_options_compat():
    return {}

@app.options("/api/live/checks")
async def api_live_checks_options_compat():
    return {}


@app.get("/api/live/config", include_in_schema=False)
async def live_config_json() -> Response:
    """Serve live-config.json directly from the backend.

    This allows the frontend to verify that the backend is reachable and to
    read the current public tunnel URL without relying on GitHub Pages CDN
    caching.  The response is intentionally not cached so every hit reflects
    the latest state.
    """
    try:
        if _LIVE_CONFIG_PATH.exists():
            raw = _LIVE_CONFIG_PATH.read_text(encoding="utf-8")
            json.loads(raw)  # Validate — raise if malformed.
            return Response(
                content=raw,
                media_type="application/json",
                headers={"Cache-Control": "no-store, no-cache, must-revalidate"},
            )
    except Exception:
        pass
    # Fallback: synthesise a minimal live config from what we know.
    config = {
        "gallery_url": "",
        "status": "live",
        "local_urls": [],
        "updated_at": datetime.now(timezone.utc).astimezone().isoformat(),
    }
    return Response(
        content=json.dumps(config),
        media_type="application/json",
        headers={"Cache-Control": "no-store, no-cache, must-revalidate"},
    )
