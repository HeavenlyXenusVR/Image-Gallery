"""Health/liveness endpoints: /api/health, /api/live/checks, /api/telegram/status, /api/live/migrate, /api/live/config."""

import json
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, HTTPException, Request, Response

import app.main as main
from ..paths import _LIVE_CONFIG_PATH
from ._shared import _auth_optional, _is_site_owner_user, _jsonable, _require_site_owner

router = APIRouter()


@router.get("/api/health")
async def health(request: Request) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": main.settings.db_schema,
        "storage_backend": main.settings.storage_backend,
        "max_upload_bytes": main.settings.max_upload_bytes,
        "media_page_limit": main.settings.media_page_limit,
        "max_tags_per_upload": main.settings.max_tags_per_upload,
        "request_id": getattr(request.state, "request_id", ""),
        "server_time": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/api/live/checks")
async def live_checks(request: Request) -> dict[str, Any]:
    auth = _auth_optional(request)
    checks: list[dict[str, Any]] = []
    try:
        snapshot = await main.db.site_checks()
        owner = False
        checks.append({"id": "api", "label": "API reachable", "ok": True, "detail": "Backend responded."})
        checks.append({"id": "db", "label": "Database reachable", "ok": True, "detail": f"Schema {main.settings.db_schema} responded."})
        if main.settings.telegram_bot_token:
            telegram_snapshot = main.telegram_service.snapshot() if main.telegram_service else {}
            checks.append({
                "id": "telegram",
                "label": "Telegram bridge",
                "ok": bool(telegram_snapshot.get("running")),
                "severity": "warn" if not telegram_snapshot.get("running") else "ok",
                "detail": f"@{telegram_snapshot.get('bot_username')}" if telegram_snapshot.get("bot_username") else (telegram_snapshot.get("last_error") or "Telegram token configured; bridge is starting."),
            })
        if auth:
            user = await main.db.get_user(int(auth["id"]))
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
            "storage_backend": main.settings.storage_backend,
            "max_upload_bytes": main.settings.max_upload_bytes,
            "media_page_limit": main.settings.media_page_limit,
            "server_time": datetime.now(timezone.utc).isoformat(),
        }
    except Exception as exc:
        if "Packet sequence number wrong" in str(exc):
            try:
                await main.db.reconnect()
            except Exception:
                pass
        return {
            "ok": False,
            "status": "offline",
            "backend": "image_gallery",
            "checks": [{"id": "db", "label": "Database reachable", "ok": False, "severity": "error", "detail": "Database is unreachable."}],
            "check_map": {"api": True, "db": False, "database": False},
            "snapshot": {},
            "storage_backend": main.settings.storage_backend,
            "max_upload_bytes": main.settings.max_upload_bytes,
            "media_page_limit": main.settings.media_page_limit,
            "server_time": datetime.now(timezone.utc).isoformat(),
        }


@router.get("/api/telegram/status")
async def telegram_status(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    status = main.telegram_service.snapshot() if main.telegram_service else {
        "enabled": bool(main.settings.telegram_bot_token),
        "running": False,
        "bot_username": "",
        "allowed_chat_count": len(main.settings.telegram_allowed_chat_ids),
        "last_error": "",
        "last_update_at": 0.0,
    }
    return {"telegram": status}


@router.post("/api/live/migrate")
async def migrate_legacy_files(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    try:
        migrated = await main.db.migrate_legacy_media_files(limit=10)
        snapshot = await main.db.site_checks()
        return {"ok": True, "migrated": migrated, "snapshot": _jsonable(snapshot)}
    except Exception as exc:
        if "Packet sequence number wrong" in str(exc):
            try:
                await main.db.reconnect()
            except Exception:
                pass
        main.logger.exception("Legacy file migration failed.")
        raise HTTPException(status_code=500, detail="Migration failed. Check the server logs for details.") from None


@router.options("/api/live/checks")
async def api_live_checks_options_compat():
    return {}


@router.get("/api/live/config", include_in_schema=False)
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

