"""
Mock tests for video streaming, transcode dedup guard, and Telegram backoff.

Covers three bug-fix areas:
  1. Duplicate transcode guard (_video_active_streams was tracked but never read).
  2. Live StreamingResponse now declares Accept-Ranges: none.
  3. Telegram polling exponential backoff on consecutive network failures.
"""
from __future__ import annotations

import asyncio
import hashlib
from pathlib import Path

import app.main as main
from fastapi.responses import FileResponse, StreamingResponse
from starlette.requests import Request


# ─── Helpers ────────────────────────────────────────────────────────────────

def _request(path: str, *, headers: dict[str, str] | None = None) -> Request:
    raw_headers = [
        (k.lower().encode("latin-1"), v.encode("latin-1"))
        for k, v in (headers or {}).items()
    ]
    return Request({
        "type": "http", "method": "GET", "path": path,
        "headers": raw_headers, "scheme": "http",
        "server": ("127.0.0.1", 8788), "client": ("127.0.0.1", 0),
        "root_path": "", "app": main.app,
    })


def _cache_path(cache_dir: Path, media_id: int, quality: str, sha256: str) -> Path:
    """Reproduce the cache-file path formula from _video_variant_response."""
    part = hashlib.sha256(sha256.encode("utf-8")).hexdigest()[:16]
    return cache_dir / f"{media_id}_{quality}_{part}.mp4"


def _video_item(media_id: int) -> dict:
    return {
        "id": media_id, "user_id": 1, "media_kind": "video",
        "is_adult": False, "visibility": "public",
    }


def _file_info(file_id: int, sha256: str, size: int = 1024) -> dict:
    return {
        "id": file_id, "sha256": sha256, "file_size": size,
        "mime_type": "video/mp4", "original_filename": "test.mp4",
    }


# ─── 1. Duplicate transcode guard ───────────────────────────────────────────

def test_dedup_guard_serves_cache_when_transcode_already_running(
    monkeypatch, tmp_path: Path
) -> None:
    """
    If stream_key is already in _video_active_streams (another request is
    transcoding), the function must NOT spawn a second ffmpeg. It polls until
    the cache file appears and then returns a FileResponse.
    """
    media_id = 943101
    quality = "low"
    sha256 = "dedup-sha-101"
    cache_file = _cache_path(tmp_path, media_id, quality, sha256)

    # instant_sleep creates the cache file on its first call, simulating the
    # moment the in-flight transcode finishes while we are waiting.
    first_sleep_done = [False]

    async def instant_sleep_and_create(_delay):
        if not first_sleep_done[0]:
            first_sleep_done[0] = True
            cache_file.write_bytes(b"fake-mp4-content")

    monkeypatch.setattr(asyncio, "sleep", instant_sleep_and_create)
    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    stream_key = (media_id, quality)
    main._video_active_streams.add(stream_key)
    try:
        response = asyncio.run(
            main._video_variant_response(
                media_id, _video_item(media_id),
                _file_info(55, sha256), None, quality,
            )
        )
    finally:
        main._video_active_streams.discard(stream_key)

    assert isinstance(response, FileResponse)
    assert response.headers.get("x-video-quality") == quality
    assert response.headers.get("x-video-codec") == "h264/aac"
    assert "max-age=86400" in response.headers.get("cache-control", "")


def test_dedup_guard_returns_none_when_transcode_stalls(
    monkeypatch, tmp_path: Path
) -> None:
    """
    If the in-flight transcode never finishes within the polling window,
    the guard returns None so the caller can fall back to raw streaming.
    """
    media_id = 943102
    quality = "medium"
    sha256 = "dedup-sha-102"

    async def instant_sleep(_delay):
        pass  # no file ever appears

    monkeypatch.setattr(asyncio, "sleep", instant_sleep)
    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    stream_key = (media_id, quality)
    main._video_active_streams.add(stream_key)
    try:
        response = asyncio.run(
            main._video_variant_response(
                media_id, _video_item(media_id),
                _file_info(56, sha256), None, quality,
            )
        )
    finally:
        main._video_active_streams.discard(stream_key)

    assert response is None


def test_dedup_guard_not_triggered_without_active_stream(
    monkeypatch, tmp_path: Path
) -> None:
    """
    When no transcode is running for this stream_key, the guard must not fire.
    The function falls through to the normal transcode path and returns a
    StreamingResponse.  (The generator is lazy — body runs on iteration,
    so we just verify the response type and live-transcode headers here.)
    """
    media_id = 943103
    quality = "low"

    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    # Use a legacy on-disk source to avoid DB streaming.
    source = tmp_path / "source.mp4"
    source.write_bytes(b"raw-src")

    async def fake_transcode(src, cache, profile, tmp_dir, stream_key):
        main._video_active_streams.discard(stream_key)
        yield b"chunk"

    monkeypatch.setattr(main, "_stream_transcode_and_cache", fake_transcode)

    assert (media_id, quality) not in main._video_active_streams

    response = asyncio.run(
        main._video_variant_response(
            media_id, _video_item(media_id), None, source, quality,
        )
    )

    # Guard did not intercept — we got the live transcode StreamingResponse.
    assert isinstance(response, StreamingResponse)
    assert response.headers.get("x-transcode") == "live"
    assert response.headers.get("accept-ranges") == "none"
    # Verify the stream_key was registered (guard would have short-circuited otherwise)
    # by consuming the body and checking active streams were cleaned up.
    async def consume():
        return b"".join([chunk async for chunk in response.body_iterator])
    body = asyncio.run(consume())
    assert body == b"chunk"
    assert (media_id, quality) not in main._video_active_streams


# ─── 2. Accept-Ranges: none on live transcode ────────────────────────────────

def test_live_transcode_response_declares_accept_ranges_none(
    monkeypatch, tmp_path: Path
) -> None:
    """
    A live StreamingResponse must advertise Accept-Ranges: none so browsers
    stop sending Range requests that would each start a fresh transcode.
    """
    media_id = 943201
    quality = "low"

    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)
    source = tmp_path / "vid.mp4"
    source.write_bytes(b"src")

    async def fake_transcode(src, cache, profile, tmp_dir, stream_key):
        main._video_active_streams.discard(stream_key)
        yield b""

    monkeypatch.setattr(main, "_stream_transcode_and_cache", fake_transcode)

    response = asyncio.run(
        main._video_variant_response(
            media_id, _video_item(media_id), None, source, quality,
        )
    )

    assert isinstance(response, StreamingResponse)
    assert response.headers.get("accept-ranges") == "none"
    assert response.headers.get("x-transcode") == "live"
    assert response.headers.get("cache-control") == "no-store"


def test_cached_transcode_response_does_not_restrict_ranges(
    monkeypatch, tmp_path: Path
) -> None:
    """
    A cached FileResponse (cache hit) must NOT set Accept-Ranges: none —
    Starlette's FileResponse handles range negotiation itself.
    """
    media_id = 943202
    quality = "medium"
    sha256 = "cached-202"
    cache_file = _cache_path(tmp_path, media_id, quality, sha256)
    cache_file.write_bytes(b"cached")

    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    response = asyncio.run(
        main._video_variant_response(
            media_id, _video_item(media_id),
            _file_info(57, sha256), None, quality,
        )
    )

    assert isinstance(response, FileResponse)
    # FileResponse uses Starlette's built-in range support; no override needed.
    assert response.headers.get("accept-ranges") != "none"


# ─── 3. Cache hit / miss / skip edge cases ──────────────────────────────────

def test_cache_hit_returns_file_response_immediately(
    monkeypatch, tmp_path: Path
) -> None:
    """When the cache file exists with non-zero size, serve it without ffmpeg."""
    media_id = 943301
    quality = "low"
    sha256 = "hit-301"
    cache_file = _cache_path(tmp_path, media_id, quality, sha256)
    cache_file.write_bytes(b"mp4data")

    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    ffmpeg_called = []

    async def fake_transcode(*args, **kwargs):
        ffmpeg_called.append(True)
        yield b""

    monkeypatch.setattr(main, "_stream_transcode_and_cache", fake_transcode)

    response = asyncio.run(
        main._video_variant_response(
            media_id, _video_item(media_id),
            _file_info(58, sha256), None, quality,
        )
    )

    assert isinstance(response, FileResponse)
    assert not ffmpeg_called, "ffmpeg must not run when cache exists"


def test_large_db_backed_file_skips_transcode(monkeypatch, tmp_path: Path) -> None:
    """Files > 300 MB are too large to transcode; fall through to raw streaming."""
    media_id = 943302
    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    big = _file_info(59, "big-302", size=400 * 1024 * 1024)
    response = asyncio.run(
        main._video_variant_response(
            media_id, _video_item(media_id), big, None, "medium",
        )
    )
    assert response is None


def test_non_video_item_returns_none(monkeypatch, tmp_path: Path) -> None:
    """image/gif/etc. items must be rejected immediately."""
    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)
    item = {**_video_item(943303), "media_kind": "image"}
    response = asyncio.run(
        main._video_variant_response(943303, item, None, None, "low")
    )
    assert response is None


def test_unknown_quality_profile_returns_none(monkeypatch, tmp_path: Path) -> None:
    """Unknown quality strings (not 'medium' or 'low') must return None."""
    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)
    # "original" / "high" are not in VIDEO_QUALITY_PROFILES → profile is None
    response = asyncio.run(
        main._video_variant_response(
            943304, _video_item(943304), None, None, "original",
        )
    )
    assert response is None


# ─── 4. Full endpoint integration ───────────────────────────────────────────

def test_serve_media_file_video_cache_hit_serves_file_response(
    monkeypatch, tmp_path: Path
) -> None:
    """
    When the transcode cache is warm, serve_media_file returns a 200 FileResponse
    with proper video headers (not 206, which would indicate raw DB streaming).
    """
    media_id = 943401
    quality = "low"
    sha256 = "integ-401"
    cache_file = _cache_path(tmp_path, media_id, quality, sha256)
    cache_file.write_bytes(b"mp4")

    monkeypatch.setattr(main, "VIDEO_CACHE_DIR", tmp_path)

    async def fake_get_media(mid, viewer_id):
        return {
            "id": mid, "user_id": 1, "media_kind": "video",
            "mime_type": "video/mp4", "visibility": "public",
            "is_adult": False, "deleted_at": None, "downloads_enabled": True,
        }

    async def fake_get_media_file_info(mid):
        return {
            "id": 60, "sha256": sha256, "file_size": 3,
            "mime_type": "video/mp4", "original_filename": "v.mp4",
        }

    monkeypatch.setattr(main.db, "get_media", fake_get_media)
    monkeypatch.setattr(main.db, "get_media_file_info", fake_get_media_file_info)

    response = asyncio.run(
        main.serve_media_file(
            media_id,
            _request(f"/api/media/{media_id}/file"),
            quality=quality,
        )
    )

    assert response.status_code == 200
    assert response.headers.get("x-video-quality") == quality
    assert "max-age=86400" in response.headers.get("cache-control", "")


def test_serve_media_file_private_media_returns_403(monkeypatch) -> None:
    """Private media returns 403, not 401, for anonymous viewers."""
    from fastapi import HTTPException

    media_id = 943402

    async def fake_get_media(mid, viewer_id):
        return {
            "id": mid, "user_id": 99, "media_kind": "video",
            "visibility": "private", "is_adult": False, "deleted_at": None,
        }

    async def fake_get_media_file_info(mid):
        return None

    monkeypatch.setattr(main.db, "get_media", fake_get_media)
    monkeypatch.setattr(main.db, "get_media_file_info", fake_get_media_file_info)

    exc = None
    try:
        asyncio.run(
            main.serve_media_file(media_id, _request(f"/api/media/{media_id}/file"))
        )
    except HTTPException as e:
        exc = e

    assert exc is not None
    assert exc.status_code == 403


def test_serve_media_file_missing_media_returns_404(monkeypatch) -> None:
    """Non-existent media IDs return 404."""
    from fastapi import HTTPException

    media_id = 943403

    async def fake_get_media(mid, viewer_id):
        return None

    async def fake_get_media_file_info(mid):
        return None

    monkeypatch.setattr(main.db, "get_media", fake_get_media)
    monkeypatch.setattr(main.db, "get_media_file_info", fake_get_media_file_info)

    exc = None
    try:
        asyncio.run(
            main.serve_media_file(media_id, _request(f"/api/media/{media_id}/file"))
        )
    except HTTPException as e:
        exc = e

    assert exc is not None
    assert exc.status_code == 404


# ─── 5. Telegram exponential backoff ────────────────────────────────────────

def test_telegram_backoff_doubles_on_consecutive_failures(monkeypatch) -> None:
    """
    On repeated network failures the polling sleep doubles each time,
    starting at 5 s and capping at 120 s.
    """
    from app.telegram import TelegramPollingService

    sleep_durations: list[float] = []
    api_call_count = [0]

    async def run() -> None:
        svc = TelegramPollingService(
            token="fake", name="Test",
            handler=lambda _update: asyncio.coroutine(lambda: None)(),
        )

        async def fake_api(method, params=None, *, timeout=20):
            api_call_count[0] += 1
            if api_call_count[0] <= 3:
                raise RuntimeError(f"network error #{api_call_count[0]}")
            svc._closing.set()
            return {"result": []}

        async def fake_sleep(delay: float) -> None:
            sleep_durations.append(delay)

        svc._api = fake_api
        monkeypatch.setattr(asyncio, "sleep", fake_sleep)
        await svc._poll_loop()

    asyncio.run(run())

    assert len(sleep_durations) == 3
    assert sleep_durations[0] == 5.0    # first failure: base delay
    assert sleep_durations[1] == 10.0   # second: doubled
    assert sleep_durations[2] == 20.0   # third: doubled again


def test_telegram_backoff_resets_after_success(monkeypatch) -> None:
    """
    After a successful poll, the backoff resets to 5 s so a transient
    outage doesn't permanently slow down the polling cadence.
    """
    from app.telegram import TelegramPollingService

    sleep_durations: list[float] = []
    api_call_count = [0]

    async def run() -> None:
        svc = TelegramPollingService(
            token="fake", name="Test",
            handler=lambda _update: asyncio.coroutine(lambda: None)(),
        )

        async def fake_api(method, params=None, *, timeout=20):
            api_call_count[0] += 1
            c = api_call_count[0]
            # fail, fail, succeed, fail, fail, stop
            if c in {1, 2}:
                raise RuntimeError("fail")
            if c in {4, 5}:
                raise RuntimeError("fail again")
            if c == 6:
                svc._closing.set()
            return {"result": []}

        async def fake_sleep(delay: float) -> None:
            sleep_durations.append(delay)

        svc._api = fake_api
        monkeypatch.setattr(asyncio, "sleep", fake_sleep)
        await svc._poll_loop()

    asyncio.run(run())

    # Failures 1+2 → sleeps [5.0, 10.0]; success resets; failures 4+5 → sleeps [5.0, 10.0]
    assert sleep_durations == [5.0, 10.0, 5.0, 10.0]


def test_telegram_backoff_caps_at_120_seconds(monkeypatch) -> None:
    """Sleep duration never exceeds 120 s regardless of how many failures occur."""
    from app.telegram import TelegramPollingService

    sleep_durations: list[float] = []
    api_call_count = [0]
    MAX_FAILURES = 10

    async def run() -> None:
        svc = TelegramPollingService(
            token="fake", name="Test",
            handler=lambda _update: asyncio.coroutine(lambda: None)(),
        )

        async def fake_api(method, params=None, *, timeout=20):
            api_call_count[0] += 1
            if api_call_count[0] <= MAX_FAILURES:
                raise RuntimeError("fail")
            svc._closing.set()
            return {"result": []}

        async def fake_sleep(delay: float) -> None:
            sleep_durations.append(delay)

        svc._api = fake_api
        monkeypatch.setattr(asyncio, "sleep", fake_sleep)
        await svc._poll_loop()

    asyncio.run(run())

    assert len(sleep_durations) == MAX_FAILURES
    assert max(sleep_durations) <= 120.0
    # Sequence: 5, 10, 20, 40, 80, 120, 120, 120, 120, 120
    assert sleep_durations[0] == 5.0
    assert sleep_durations[4] == 80.0
    assert all(d == 120.0 for d in sleep_durations[5:])
