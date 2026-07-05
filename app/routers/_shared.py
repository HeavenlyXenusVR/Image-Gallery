"""Route-layer helpers reused across many routers: auth/session reads, URL/response shaping, API response caching, and upload validation. Never duplicate these per-router — import from here."""

import hashlib
import hmac
import io
import json
import mimetypes
import os
import re
import time
from decimal import Decimal
from pathlib import Path
from typing import Any

from fastapi import HTTPException, Request, Response, UploadFile

import app.main as main
from ..auth import extract_bearer_token, require_auth, verify_token

IMAGE_MIME_PREFIXES = ("image/",)
VIDEO_MIME_PREFIXES = ("video/",)
SAFE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp",
    ".mp4", ".webm", ".mov", ".m4v", ".ogg", ".flv", ".mkv",
}
SITE_OWNER_EMAIL = "heavenlyxenusvr@icloud.com"
API_CACHE_MAX_ITEMS = max(64, int(os.getenv("GALLERY_API_CACHE_MAX_ITEMS", "512")))
MAX_IMAGE_PIXELS = max(8_000_000, int(os.getenv("GALLERY_MAX_IMAGE_PIXELS", "80000000")))
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
    return verify_token(extract_bearer_token(request), main.settings.session_secret, main.settings.api_token_ttl_seconds)


def _user_id(auth: dict[str, Any] | None) -> int | None:
    if not auth:
        return None
    try:
        return int(auth.get("id"))
    except (TypeError, ValueError):
        return None


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
    return _is_age_verified(await main.db.get_user(viewer_id))


def _ensure_media_visible_to_viewer(item: dict[str, Any] | None, viewer_id: int | None) -> None:
    if not item or item.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Media not found.")
    owner = int(item.get("user_id") or 0) == int(viewer_id or 0)
    if item.get("visibility") == "private" and not owner:
        raise HTTPException(status_code=403, detail="This post is private.")


def _current_user(request: Request) -> dict[str, Any]:
    """FastAPI dependency: the decoded session/token payload for the caller.

    Raises 401 via require_auth() if there's no valid session. Use as
    `auth: dict[str, Any] = Depends(_current_user)` instead of calling
    require_auth(...) inline in every handler.
    """
    return require_auth(request, main.settings.session_secret, main.settings.api_token_ttl_seconds)


async def _require_site_owner(request: Request) -> dict[str, Any]:
    auth = _current_user(request)
    user = await main.db.get_user(int(auth["id"]))
    if not _is_site_owner_user(user):
        raise HTTPException(status_code=403, detail="Only the verified site owner can use this action.")
    return user


def _public_url(request: Request, storage_path: str, media_id: int | None = None) -> str:
    if media_id is not None:
        return str(request.url_for("serve_media_file", media_id=media_id))
    return str(request.url_for("serve_legacy_upload", path=storage_path))


def _preview_url(request: Request, media_id: int) -> str:
    return str(request.url_for("serve_media_preview", media_id=media_id))


def _thumb_url(request: Request, media_id: int, width: int = 640) -> str:
    return str(request.url_for("serve_media_thumb", media_id=media_id)) + f"?w={int(width)}"


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
    return hmac.new(main.settings.session_secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def _append_query(url: str, key: str, value: str) -> str:
    return f"{url}{'&' if '?' in url else '?'}{key}={value}"


def _legacy_upload_path(storage_path: str | None) -> Path | None:
    if not storage_path or str(storage_path).startswith(("db://", "avatar-db://")):
        return None
    raw = str(storage_path).replace("\\", "/").lstrip("/")
    if ".." in Path(raw).parts:
        return None
    path = (main.settings.uploads_dir / raw).resolve()
    try:
        path.relative_to(main.settings.uploads_dir.resolve())
    except ValueError:
        return None
    return path if path.is_file() else None


def _is_gif_media(item: dict[str, Any]) -> bool:
    mime = str(item.get("mime_type") or "").lower()
    filename = str(item.get("original_filename") or item.get("storage_path") or "").lower()
    return mime == "image/gif" or filename.endswith(".gif")


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
    cached = main._api_cache.get(cache_key)
    if not cached:
        return None
    expires_at, payload, etag = cached
    if expires_at <= time.time():
        main._api_cache.pop(cache_key, None)
        return None
    main._api_cache.move_to_end(cache_key)
    return _api_json_response(request, payload, etag, max(0.0, expires_at - time.time()))


def _store_api_cache_response(request: Request, cache_key: str, value: Any, ttl_seconds: float) -> Response:
    payload = json.dumps(_jsonable(value), ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    etag = f"\"api:{hashlib.sha256(payload.encode('utf-8')).hexdigest()}\""
    if ttl_seconds > 0:
        main._api_cache[cache_key] = (time.time() + ttl_seconds, payload, etag)
        main._api_cache.move_to_end(cache_key)
        while len(main._api_cache) > API_CACHE_MAX_ITEMS:
            main._api_cache.popitem(last=False)
    return _api_json_response(request, payload, etag, ttl_seconds)


def _invalidate_api_cache(*prefixes: str) -> None:
    if not prefixes:
        main._api_cache.clear()
        return
    normalized = tuple(f"{prefix}|" for prefix in prefixes)
    for key in list(main._api_cache.keys()):
        if key.startswith(normalized):
            main._api_cache.pop(key, None)


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


async def _rate_limit(key: str, *, limit: int, window_seconds: int) -> None:
    clean_key = re.sub(r"[^A-Za-z0-9_.:@-]", "_", str(key or "unknown"))[:190]
    try:
        if await main.db.check_rate_limit(clean_key, limit=limit, window_seconds=window_seconds):
            return
        raise HTTPException(status_code=429, detail="Too many attempts. Try again later.")
    except HTTPException:
        raise
    except Exception:
        main.logger.warning("DB-backed rate limit unavailable; using in-process fallback for %s.", clean_key, exc_info=True)
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
    ceiling = max(1, int(max_limit or main.settings.media_page_limit))
    return max(1, min(parsed, ceiling))


def _bounded_query_offset(value: Any) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


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

