from __future__ import annotations

import asyncio
import hashlib
import os
import tempfile

from fastapi import HTTPException
from app.routers._shared import IN_MEMORY_UPLOAD_CEILING, _read_validated_upload, _read_validated_upload_streamed


class _FakeUploadFile:
    """Minimal async stand-in for FastAPI's UploadFile — just enough of the
    interface `_read_validated_upload_streamed` actually uses."""

    def __init__(self, content: bytes, *, content_type: str = "video/ogg", filename: str = "clip.ogg"):
        self._content = content
        self._offset = 0
        self.content_type = content_type
        self.filename = filename

    async def read(self, size: int) -> bytes:
        chunk = self._content[self._offset : self._offset + size]
        self._offset += len(chunk)
        return chunk


# "OggS" is a real magic signature (see MAGIC_SIGNATURES in _shared.py) that
# resolves to media_kind="video", which skips the PIL image-dimension check —
# letting these tests use arbitrary synthetic bytes instead of a real video file.
def _fake_video_bytes(total_size: int) -> bytes:
    return b"OggS" + os.urandom(max(0, total_size - 4))


def test_streamed_upload_writes_temp_file_matching_content():
    content = _fake_video_bytes(200_000)
    upload = _FakeUploadFile(content)
    result = asyncio.run(_read_validated_upload_streamed(upload, max_bytes=len(content), image_only=False))
    try:
        assert result["content"] is None
        assert result["path"] is not None
        assert result["media_kind"] == "video"
        assert result["mime_type"] == "video/ogg"
        assert result["file_size"] == len(content)
        with open(result["path"], "rb") as f:
            assert f.read() == content
        assert result["sha256"] == hashlib.sha256(content).hexdigest()
    finally:
        os.unlink(result["path"])


def test_streamed_upload_over_limit_raises_and_cleans_up_temp_file():
    content = _fake_video_bytes(500_000)
    upload = _FakeUploadFile(content)
    before = set(os.listdir(tempfile.gettempdir()))
    try:
        asyncio.run(_read_validated_upload_streamed(upload, max_bytes=100_000, image_only=False))
        raised = False
    except HTTPException as exc:
        raised = True
        assert exc.status_code == 413
    assert raised
    after = set(os.listdir(tempfile.gettempdir()))
    leftover = {name for name in (after - before) if name.startswith("gallery_upload_")}
    assert not leftover, f"temp file(s) not cleaned up after rejection: {leftover}"


def test_streamed_upload_rejects_when_disk_space_low(monkeypatch):
    import shutil as shutil_module

    class _FakeUsage:
        free = 10  # far below any max_bytes

    monkeypatch.setattr(shutil_module, "disk_usage", lambda _path: _FakeUsage())
    upload = _FakeUploadFile(_fake_video_bytes(1000))
    try:
        asyncio.run(_read_validated_upload_streamed(upload, max_bytes=1_000_000, image_only=False))
        raised = False
    except HTTPException as exc:
        raised = True
        assert exc.status_code == 507
    assert raised


def test_streamed_upload_empty_file_rejected():
    upload = _FakeUploadFile(b"")
    try:
        asyncio.run(_read_validated_upload_streamed(upload, max_bytes=1_000_000, image_only=False))
        raised = False
    except HTTPException as exc:
        raised = True
        assert exc.status_code == 400
    assert raised


def test_read_validated_upload_routes_large_max_bytes_to_streamed_path():
    """`_read_validated_upload` itself should delegate to the streaming
    implementation once max_bytes exceeds the in-memory ceiling, regardless
    of how large the actual uploaded content is."""
    content = _fake_video_bytes(50_000)
    upload = _FakeUploadFile(content)
    result = asyncio.run(_read_validated_upload(upload, max_bytes=IN_MEMORY_UPLOAD_CEILING + 1, image_only=False))
    try:
        assert result["path"] is not None
        assert result["content"] is None
    finally:
        os.unlink(result["path"])


def test_read_validated_upload_small_max_bytes_stays_in_memory():
    content = _fake_video_bytes(50_000)
    upload = _FakeUploadFile(content)
    result = asyncio.run(_read_validated_upload(upload, max_bytes=1_000_000, image_only=False))
    assert result["path"] is None
    assert result["content"] == content
