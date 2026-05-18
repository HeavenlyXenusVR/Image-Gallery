#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient

import app.main as main


def main_test() -> None:
    client = TestClient(main.app, base_url="http://127.0.0.1:8788")

    favicon = client.get("/favicon.ico")
    assert favicon.status_code == 200, favicon.text
    assert favicon.headers["content-type"].startswith("image/vnd.microsoft.icon")

    health = client.get("/api/health", headers={"X-Request-ID": "route-test-123"})
    assert health.status_code == 200, health.text
    assert health.headers["x-request-id"] == "route-test-123"
    assert "server-timing" in health.headers
    assert "x-response-time-ms" in health.headers
    assert health.headers["x-permitted-cross-domain-policies"] == "none"
    health_body = health.json()
    assert health_body["ok"] is True
    assert health_body["storage_backend"] == main.settings.storage_backend
    assert health_body["request_id"] == "route-test-123"
    assert health_body["media_page_limit"] == main.settings.media_page_limit

    me = client.get("/api/me")
    assert me.status_code == 401, me.text
    assert me.headers["cache-control"] == "no-store"
    assert me.headers["pragma"] == "no-cache"
    assert me.headers["expires"] == "0"

    original_settings = main.settings
    main.settings = replace(original_settings, media_page_limit=3, max_tags_per_upload=2, max_tag_length=8)
    try:
        assert main._bounded_query_limit(1000, default=60) == 3
        assert main._bounded_query_offset(-40) == 0
        assert main._parse_tags("#Alpha, alpha, two words, quite-long-tag") == ["Alpha", "two-word"]
        assert main._merge_upload_tags(["Alpha"], ["alpha", "Beta", "Gamma"]) == ["Alpha", "Beta"]
    finally:
        main.settings = original_settings

    with tempfile.TemporaryDirectory() as tmp:
        main.settings = replace(original_settings, uploads_dir=Path(tmp), storage_backend="filesystem")
        try:
            stored = asyncio.run(
                main._store_uploaded_media(
                    1,
                    {
                        "content": b"route-test-image-bytes",
                        "sha256": "a" * 64,
                        "filename": "../../route-test.png",
                        "mime_type": "image/png",
                    },
                    "route-test.png",
                )
            )
        finally:
            main.settings = original_settings

        storage_path = stored["storage_path"]
        assert storage_path == "media/aa/" + ("a" * 64) + ".png"
        assert stored["media_file_id"] is None
        assert (Path(tmp) / storage_path).read_bytes() == b"route-test-image-bytes"

    print("image_gallery_api_routes=passed")


if __name__ == "__main__":
    main_test()
