from __future__ import annotations

import asyncio

import app.main as main
from starlette.requests import Request

from app.routers.media import _find_possible_duplicates, _image_fingerprint_for_upload


def _request(path: str) -> Request:
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": path,
            "headers": [],
            "scheme": "http",
            "server": ("127.0.0.1", 8788),
            "client": ("127.0.0.1", 0),
            "root_path": "",
            "app": main.app,
        }
    )


def test_find_possible_duplicates_flags_close_hash(monkeypatch) -> None:
    async def fake_list_visual_hash_candidates(user_id: int, *, limit: int = 1500):
        assert user_id == 501
        return [
            {"id": 900001, "title": "Close match", "image_phash": "0000000000000000", "image_dhash": None},
            {"id": 900002, "title": "Far match", "image_phash": "ffffffffffffffff", "image_dhash": None},
        ]

    monkeypatch.setattr(main.db, "list_visual_hash_candidates", fake_list_visual_hash_candidates)

    fingerprint = {"image_phash": "0000000000000001", "image_dhash": None}
    results = asyncio.run(_find_possible_duplicates(_request("/api/media"), 501, fingerprint))

    assert [row["id"] for row in results] == [900001]
    assert results[0]["distance"] == 1
    assert results[0]["thumb_url"].endswith("/api/media/900001/thumb?w=640")


def test_find_possible_duplicates_ignores_hash_beyond_threshold(monkeypatch) -> None:
    async def fake_list_visual_hash_candidates(user_id: int, *, limit: int = 1500):
        return [{"id": 900003, "title": "Unrelated", "image_phash": "ffffffffffffffff", "image_dhash": None}]

    monkeypatch.setattr(main.db, "list_visual_hash_candidates", fake_list_visual_hash_candidates)

    fingerprint = {"image_phash": "0000000000000000", "image_dhash": None}
    results = asyncio.run(_find_possible_duplicates(_request("/api/media"), 501, fingerprint))

    assert results == []


def test_find_possible_duplicates_returns_empty_without_fingerprint() -> None:
    assert asyncio.run(_find_possible_duplicates(_request("/api/media"), 501, None)) == []


def test_image_fingerprint_for_upload_skips_video_and_streamed_uploads() -> None:
    assert _image_fingerprint_for_upload({"media_kind": "video", "content": b"abc"}) is None
    assert _image_fingerprint_for_upload({"media_kind": "image", "content": None}) is None
