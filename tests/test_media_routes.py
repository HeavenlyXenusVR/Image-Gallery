from __future__ import annotations

import asyncio
import base64
import logging
from pathlib import Path

import app.main as main
from fastapi.responses import Response
from starlette.requests import Request


_PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO8B9h0AAAAASUVORK5CYII="
)


def _request(path: str, *, headers: dict[str, str] | None = None) -> Request:
    raw_headers = [
        (name.lower().encode("latin-1"), value.encode("latin-1"))
        for name, value in (headers or {}).items()
    ]
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": path,
            "headers": raw_headers,
            "scheme": "http",
            "server": ("127.0.0.1", 8788),
            "client": ("127.0.0.1", 0),
            "root_path": "",
            "app": main.app,
        }
    )


async def _read_response_body(response: Response) -> bytes:
    if hasattr(response, "body_iterator"):
        return b"".join([chunk async for chunk in response.body_iterator])
    return response.body


def test_serve_media_thumb_falls_back_to_original_on_thumbnail_failure(
    monkeypatch, tmp_path: Path
) -> None:
    media_id = 941001
    monkeypatch.setattr(main, "THUMB_CACHE_DIR", tmp_path)

    async def fake_get_media(requested_media_id: int, viewer_id: int | None):
        assert requested_media_id == media_id
        assert viewer_id is None
        return {
            "id": media_id,
            "user_id": 12,
            "media_kind": "image",
            "mime_type": "image/png",
            "visibility": "public",
            "is_adult": False,
            "deleted_at": None,
        }

    async def fake_get_media_file(requested_media_id: int):
        assert requested_media_id == media_id
        return {
            "content": b"not-a-real-png",
            "mime_type": "image/png",
            "original_filename": "broken.png",
        }

    async def fake_serve_media_content(
        requested_media_id: int,
        request: Request,
        *,
        access: str | None,
        as_download: bool,
        quality: str | None = None,
    ) -> Response:
        assert requested_media_id == media_id
        assert access is None
        assert as_download is False
        assert quality is None
        return Response(content=b"original-fallback", media_type="image/png", headers={"X-Fallback": "1"})

    monkeypatch.setattr(main.db, "get_media", fake_get_media)
    monkeypatch.setattr(main.db, "get_media_file", fake_get_media_file)
    monkeypatch.setattr(main, "_serve_media_content", fake_serve_media_content)

    response = asyncio.run(main.serve_media_thumb(media_id, _request(f"/api/media/{media_id}/thumb"), w=333))

    assert response.status_code == 200
    assert response.headers["x-fallback"] == "1"
    assert asyncio.run(_read_response_body(response)) == b"original-fallback"


def test_serve_media_preview_returns_etag_and_honors_if_none_match(monkeypatch) -> None:
    media_id = 941002
    digest = main.hashlib.sha256(_PNG_1X1).hexdigest()

    async def fake_get_media(requested_media_id: int, viewer_id: int | None):
        assert requested_media_id == media_id
        assert viewer_id is None
        return {
            "id": media_id,
            "user_id": 12,
            "media_kind": "image",
            "mime_type": "image/png",
            "visibility": "public",
            "is_adult": False,
            "deleted_at": None,
        }

    async def fake_get_media_file(requested_media_id: int):
        assert requested_media_id == media_id
        return {
            "content": _PNG_1X1,
            "mime_type": "image/png",
            "sha256": digest,
            "original_filename": "tiny.png",
        }

    monkeypatch.setattr(main.db, "get_media", fake_get_media)
    monkeypatch.setattr(main.db, "get_media_file", fake_get_media_file)

    response = asyncio.run(
        main.serve_media_preview(media_id, _request(f"/api/media/{media_id}/preview"), size="detail")
    )
    etag = response.headers.get("etag")

    assert response.status_code == 200
    assert etag
    assert response.headers["x-content-sha256"] == digest
    assert response.headers["cache-control"] == "public, max-age=86400"
    assert len(asyncio.run(_read_response_body(response))) > 0

    cached_response = asyncio.run(
        main.serve_media_preview(
            media_id,
            _request(f"/api/media/{media_id}/preview", headers={"if-none-match": etag}),
            size="detail",
        )
    )

    assert cached_response.status_code == 304
    assert cached_response.headers["etag"] == etag


def test_serve_media_file_supports_range_streaming_from_db_store(monkeypatch) -> None:
    media_id = 941003
    content = b"abcdefghij"
    digest = main.hashlib.sha256(content).hexdigest()

    async def fake_get_media(requested_media_id: int, viewer_id: int | None):
        assert requested_media_id == media_id
        assert viewer_id is None
        return {
            "id": media_id,
            "user_id": 12,
            "media_kind": "image",
            "mime_type": "image/png",
            "visibility": "public",
            "is_adult": False,
            "deleted_at": None,
            "downloads_enabled": True,
        }

    async def fake_get_media_file_info(requested_media_id: int):
        assert requested_media_id == media_id
        return {
            "id": 77,
            "file_size": len(content),
            "mime_type": "image/png",
            "sha256": digest,
            "original_filename": "range.png",
        }

    async def fake_stream_media_file_content(
        file_id: int, start: int | None = None, end: int | None = None
    ):
        assert file_id == 77
        begin = 0 if start is None else start
        finish = len(content) - 1 if end is None else end
        yield content[begin : finish + 1]

    monkeypatch.setattr(main.db, "get_media", fake_get_media)
    monkeypatch.setattr(main.db, "get_media_file_info", fake_get_media_file_info)
    monkeypatch.setattr(main.db, "stream_media_file_content", fake_stream_media_file_content)

    response = asyncio.run(
        main.serve_media_file(
            media_id,
            _request(f"/api/media/{media_id}/file", headers={"range": "bytes=2-5"}),
        )
    )

    assert response.status_code == 206
    assert response.headers["content-range"] == "bytes 2-5/10"
    assert response.headers["content-length"] == "4"
    assert response.headers["accept-ranges"] == "bytes"
    assert response.headers["x-content-sha256"] == digest
    assert asyncio.run(_read_response_body(response)) == b"cdef"


def test_report_media_load_diagnostic_logs_fallback_event(caplog) -> None:
    request = _request("/api/media/941004/diagnostics/load")
    payload = main.MediaLoadDiagnosticRequest(
        context="detail-image-medium",
        outcome="fallback-success",
        media_kind="image",
        selected_source="preview:detail",
        failed_sources=["thumb"],
        source_count=3,
    )

    with caplog.at_level(logging.INFO, logger="image_gallery"):
        result = asyncio.run(main.report_media_load_diagnostic(941004, payload, request))

    assert result == {"ok": True}
    assert "Client media load diagnostic media_id=941004" in caplog.text
    assert "fallback-success" in caplog.text
    assert "detail-image-medium" in caplog.text
    assert "thumb" in caplog.text


def test_media_quality_profiles_are_upgraded() -> None:
    assert main._preview_options("mini") == ("mini", 360, 78)
    assert main._preview_options("card") == ("card", 880, 86)
    assert main._preview_options("detail") == ("detail", 1920, 92)
    assert main.VIDEO_QUALITY_PROFILES["medium"]["max_width"] == 1600
    assert main.VIDEO_QUALITY_PROFILES["medium"]["crf"] == 19
    assert main.VIDEO_QUALITY_PROFILES["low"]["audio_bitrate"] == "128k"


def test_site_background_returns_rotating_snapshot(monkeypatch) -> None:
    async def fake_site_background_snapshot(*, force: bool = False):
        assert force is False
        return (
            {
                "id": 55,
                "title": "Sunset Drive",
                "username": "bot",
                "display_name": "Bot",
                "category_name": "Desktop Backgrounds",
                "subcategory_name": "Synthwave",
                "width": 1920,
                "height": 1080,
            },
            287,
        )

    monkeypatch.setattr(main, "_site_background_snapshot", fake_site_background_snapshot)
    main._site_background_state["picked_at"] = 1234567890

    payload = asyncio.run(main.site_background(_request("/api/site/background")))

    assert payload["enabled"] is True
    assert payload["status"] == "active"
    assert payload["refresh_after_seconds"] == 287
    assert payload["background"]["id"] == 55
    assert payload["background"]["url"].endswith("/api/media/55/thumb?w=1440")


def test_site_background_snapshot_avoids_repeating_previous_pick(monkeypatch) -> None:
    previous_state = dict(main._site_background_state)

    async def fake_background_candidate_rows():
        return [
            {"id": 10, "title": "First"},
            {"id": 20, "title": "Second"},
        ]

    monkeypatch.setattr(main, "_background_candidate_rows", fake_background_candidate_rows)
    monkeypatch.setattr(main.random, "choice", lambda pool: pool[0])
    main._site_background_state["item"] = {"id": 10, "title": "First"}
    main._site_background_state["picked_at"] = 0.0

    try:
        picked, refresh_after = asyncio.run(main._site_background_snapshot(force=True))
    finally:
        main._site_background_state.clear()
        main._site_background_state.update(previous_state)

    assert picked is not None
    assert picked["id"] == 20
    assert refresh_after == main.SITE_BACKGROUND_ROTATION_SECONDS
