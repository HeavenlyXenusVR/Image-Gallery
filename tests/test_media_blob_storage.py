from __future__ import annotations

import asyncio
import hashlib
import os

from app.db.media_storage import MediaBlobMixin


class _FakeCursor:
    def __init__(self, store: dict):
        self._store = store
        self._last_result = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_info):
        return False

    @property
    def lastrowid(self):
        return self._store["next_id"] - 1

    async def execute(self, sql: str, params: tuple = ()) -> None:
        sql_norm = " ".join(sql.split())
        if sql_norm.startswith("SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE sha256"):
            (sha256,) = params
            self._last_result = self._store["files_by_sha256"].get(sha256)
        elif sql_norm.startswith("INSERT INTO media_files"):
            sha256, mime_type, original_filename, media_kind, file_size, _content, created_by = params
            file_id = self._store["next_id"]
            self._store["next_id"] += 1
            row = {
                "id": file_id,
                "sha256": sha256,
                "mime_type": mime_type,
                "original_filename": original_filename,
                "media_kind": media_kind,
                "file_size": file_size,
                "created_by": created_by,
                "created_at": None,
            }
            self._store["files_by_id"][file_id] = row
            self._store["files_by_sha256"][sha256] = row
            self._store["chunks"][file_id] = []
        elif sql_norm.startswith("INSERT INTO media_file_chunks"):
            file_id, chunk_index, content = params
            self._store["chunks"][file_id].append((chunk_index, bytes(content)))
        elif sql_norm.startswith("SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE id"):
            (file_id,) = params
            self._last_result = self._store["files_by_id"].get(file_id)
        elif sql_norm.startswith("DELETE FROM media_files"):
            (file_id,) = params
            self._store["files_by_id"].pop(file_id, None)
            self._store["chunks"].pop(file_id, None)
        else:
            raise AssertionError(f"Unexpected SQL in fake cursor: {sql_norm}")

    async def fetchone(self):
        return self._last_result


class _FakeConn:
    def __init__(self, store: dict):
        self._store = store

    async def ping(self, reconnect: bool = True) -> None:
        pass

    async def begin(self) -> None:
        pass

    async def commit(self) -> None:
        pass

    async def rollback(self) -> None:
        pass

    def cursor(self, *_args, **_kwargs):
        return _FakeCursor(self._store)


class _FakeAcquireContext:
    def __init__(self, store: dict):
        self._store = store

    async def __aenter__(self):
        return _FakeConn(self._store)

    async def __aexit__(self, *exc_info):
        return False


class _FakePool:
    def __init__(self, store: dict):
        self._store = store

    def acquire(self):
        return _FakeAcquireContext(self._store)


class _FakeDB(MediaBlobMixin):
    def __init__(self, media_chunk_bytes: int):
        self.pool = _FakePool({"next_id": 1, "files_by_sha256": {}, "files_by_id": {}, "chunks": {}})
        self.media_chunk_bytes = media_chunk_bytes
        self._blob_lock = asyncio.Lock()

    def chunks_for(self, file_id: int) -> bytes:
        chunks = sorted(self.pool._store["chunks"][file_id], key=lambda pair: pair[0])
        return b"".join(content for _, content in chunks)


def test_save_media_file_from_path_matches_from_bytes_chunking():
    """The new content_path (streamed-to-disk) branch must reconstruct the
    exact same bytes, in the same chunk boundaries, as the pre-existing
    in-memory `content=` branch — this is the DB-write half of the large
    upload streaming path and has no other test coverage."""
    content = os.urandom(10_000)  # not a multiple of the chunk size below
    sha256 = hashlib.sha256(content).hexdigest()

    db_from_bytes = _FakeDB(media_chunk_bytes=4096)
    result_bytes = asyncio.run(
        db_from_bytes.save_media_file(
            user_id=1, content=content, sha256=sha256, mime_type="video/ogg",
            original_filename="a.ogg", media_kind="video",
        )
    )
    assert result_bytes["duplicate"] is False
    assert db_from_bytes.chunks_for(result_bytes["id"]) == content

    tmp_path = None
    try:
        import tempfile

        fd, tmp_path = tempfile.mkstemp()
        with os.fdopen(fd, "wb") as f:
            f.write(content)

        db_from_path = _FakeDB(media_chunk_bytes=4096)
        result_path = asyncio.run(
            db_from_path.save_media_file(
                user_id=1, content_path=tmp_path, sha256=sha256, mime_type="video/ogg",
                original_filename="a.ogg", media_kind="video", file_size=len(content),
            )
        )
        assert result_path["duplicate"] is False
        assert db_from_path.chunks_for(result_path["id"]) == content
        # Both branches must chunk identically given the same chunk size.
        assert db_from_bytes.pool._store["chunks"][result_bytes["id"]] == [
            (idx, chunk) for idx, chunk in db_from_path.pool._store["chunks"][result_path["id"]]
        ]
    finally:
        if tmp_path:
            os.unlink(tmp_path)


def test_save_media_file_detects_duplicate_by_sha256():
    content = os.urandom(500)
    sha256 = hashlib.sha256(content).hexdigest()
    db = _FakeDB(media_chunk_bytes=4096)
    first = asyncio.run(
        db.save_media_file(user_id=1, content=content, sha256=sha256, mime_type="video/ogg", original_filename="a.ogg", media_kind="video")
    )
    assert first["duplicate"] is False
    second = asyncio.run(
        db.save_media_file(user_id=1, content=content, sha256=sha256, mime_type="video/ogg", original_filename="b.ogg", media_kind="video")
    )
    assert second["duplicate"] is True
    assert second["id"] == first["id"]
