import asyncio
import ipaddress
import json
import logging
import os
import re
import secrets
import time
from urllib.parse import urlparse
from collections import OrderedDict
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .config import ROOT_DIR, load_settings
from .database import GalleryDatabase
from .paths import APP_SHELL_PATHS, _LIVE_CONFIG_PATH
from .telegram import TelegramPollingService


settings = load_settings()
db = GalleryDatabase(settings)
telegram_service: TelegramPollingService | None = None
logger = logging.getLogger("image_gallery")
PRESENCE_TOUCH_INTERVAL_SECONDS = max(15, int(os.getenv("GALLERY_PRESENCE_TOUCH_INTERVAL_SECONDS", "30") or "30"))
REQUEST_ID_RE = re.compile(r"[^A-Za-z0-9_.:-]+")
PERSONAL_API_PREFIXES = (
    "/api/auth/",
    "/api/me",
    "/api/friends",
    "/api/feed",
    "/api/collections",
)
_background_cache_lock = asyncio.Lock()
_background_cache: dict[str, Any] = {"built_at": 0.0, "items": []}
_site_background_lock = asyncio.Lock()
_site_background_state: dict[str, Any] = {"picked_at": 0.0, "item": None}
_preview_cache: OrderedDict[tuple[str, str], tuple[bytes, str]] = OrderedDict()
_api_cache: OrderedDict[str, tuple[float, str, str]] = OrderedDict()
_thumb_generation_locks: dict[str, asyncio.Lock] = {}
_video_active_streams: set[tuple[int, str]] = set()
_video_thumb_warm_tasks: dict[tuple[int, tuple[int, ...]], asyncio.Task[Any]] = {}

# Router imports live here (after settings/db/caches are defined, not at the
# top of the file) because several router modules read `main.settings` at
# their own module-execution time (e.g. media_streaming.py's THUMB_CACHE_DIR).
# Since this import triggers their module bodies to run, settings must exist
# first. Router modules never import from main.py at THEIR module scope
# (only lazily inside function bodies via `import app.main as main`), so this
# stays a one-directional, non-circular dependency.
from .routers import (  # noqa: E402
    account,
    admin,
    ai_vision,
    auth,
    categories,
    collections,
    downloads,
    health,
    media,
    media_feed,
    media_streaming,
    messages,
    notifications,
    pages,
    social,
)
from .routers._shared import _auth_optional, _user_id  # noqa: E402
from .routers.media import _ai_background_learning_loop  # noqa: E402
from .routers.media_feed import _site_background_rotation_loop  # noqa: E402
from .routers.media_streaming import VIDEO_CACHE_DIR, _video_thumb_warm_loop  # noqa: E402

# --- Backward-compatible re-exports -----------------------------------------
# tests/*.py and scripts/api_route_test.py reach into main.<name> for ~20
# names that physically live in router modules now that they're not routes
# directly on `app`. Modules (hashlib, random) are shared singletons in
# sys.modules, so importing them again here is enough for a monkeypatch like
# `main.random.choice = ...` to also affect router modules' own `random`
# import. This keeps the entire existing test suite a byte-identical
# regression oracle with zero test edits.
import hashlib  # noqa: E402,F401
import random  # noqa: E402,F401
from .schemas import MediaLoadDiagnosticRequest  # noqa: E402,F401
from .routers._shared import (  # noqa: E402,F401
    _bounded_query_limit,
    _bounded_query_offset,
    _ensure_media_visible_to_viewer,
    _sniff_magic,
    _with_collection_urls,
)
from .routers.media import (  # noqa: E402,F401
    _merge_upload_tags,
    _parse_tags,
    _store_uploaded_media,
    report_media_load_diagnostic,
)
from .routers.media_feed import (  # noqa: E402,F401
    SITE_BACKGROUND_ROTATION_SECONDS,
    _background_candidate_rows,
    _site_background_snapshot,
    site_background,
)
from .routers.media_streaming import (  # noqa: E402,F401
    THUMB_CACHE_DIR,
    VIDEO_QUALITY_PROFILES,
    _preview_options,
    _serve_media_content,
    _stream_transcode_and_cache,
    _video_variant_response,
    serve_media_file,
    serve_media_preview,
    serve_media_thumb,
)


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

# media_feed must be registered before media: both define routes under
# /api/media, and media_feed's static /api/media/random must be matched
# before media's dynamic /api/media/{media_id}.
app.include_router(pages.router)
app.include_router(health.router)
app.include_router(admin.router)
app.include_router(categories.router)
app.include_router(messages.router)
app.include_router(notifications.router)
app.include_router(collections.router)
app.include_router(downloads.router)
app.include_router(account.router)
app.include_router(auth.router)
app.include_router(social.router)
app.include_router(media_feed.router)
app.include_router(media.router)
app.include_router(media_streaming.router)
app.include_router(ai_vision.router)


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


