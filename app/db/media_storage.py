"""Blob storage for media/avatar files, including chunked streaming reads."""

from typing import Any

from . import pg_compat as aiomysql

from ._shared import log


class MediaBlobMixin:
    async def save_media_file(
        self,
        *,
        user_id: int,
        content: bytes | None = None,
        content_path: str | None = None,
        sha256: str,
        mime_type: str,
        original_filename: str,
        media_kind: str,
        file_size: int | None = None,
    ) -> dict[str, Any]:
        # Large BLOB writes are serialized and chunked so uploads do not depend on
        # one huge max_allowed_packet-sized INSERT. `content_path` is used for
        # uploads big enough that the caller already streamed them to a temp
        # file instead of holding them fully in memory (see
        # `_read_validated_upload_streamed` in app/routers/_shared.py) — chunks
        # are read directly off disk here so the whole file still never sits
        # in RAM at once.
        if content is None and content_path is None:
            raise ValueError("save_media_file requires either content or content_path")
        total_size = file_size if file_size is not None else (len(content) if content is not None else 0)
        async with self._blob_lock:
            async with self.pool.acquire() as conn:
                await conn.ping(reconnect=True)
                async with conn.cursor(aiomysql.DictCursor) as cur:
                    await conn.begin()
                    media_file_id = 0
                    await cur.execute(
                        "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE sha256=%s",
                        (sha256,),
                    )
                    existing = await cur.fetchone()
                    if existing:
                        await conn.rollback()
                        return dict(existing, duplicate=True)
                    try:
                        await cur.execute(
                            """
                            INSERT INTO media_files (sha256, mime_type, original_filename, media_kind, file_size, content, created_by)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)
                            RETURNING id
                            """,
                            (sha256, mime_type[:120], original_filename[:255], media_kind, total_size, b"", user_id),
                        )
                        media_file_id = int((await cur.fetchone())["id"])
                        if content_path is not None:
                            with open(content_path, "rb") as source:
                                chunk_index = 0
                                while True:
                                    chunk = source.read(self.media_chunk_bytes)
                                    if not chunk:
                                        break
                                    await cur.execute(
                                        """
                                        INSERT INTO media_file_chunks (file_id, chunk_index, content)
                                        VALUES (%s, %s, %s)
                                        """,
                                        (media_file_id, chunk_index, chunk),
                                    )
                                    chunk_index += 1
                        else:
                            for chunk_index, offset in enumerate(range(0, len(content), self.media_chunk_bytes)):
                                await cur.execute(
                                    """
                                    INSERT INTO media_file_chunks (file_id, chunk_index, content)
                                    VALUES (%s, %s, %s)
                                    """,
                                    (media_file_id, chunk_index, content[offset:offset + self.media_chunk_bytes]),
                                )
                        await cur.execute(
                            "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE id=%s",
                            (media_file_id,),
                        )
                        row = await cur.fetchone()
                        await conn.commit()
                        return dict(row, duplicate=False)
                    except Exception:
                        await conn.rollback()
                        if media_file_id:
                            try:
                                await cur.execute("DELETE FROM media_files WHERE id=%s", (media_file_id,))
                            except Exception as cleanup_exc:
                                log.warning("Failed to cleanup incomplete media_file row %s after failed chunk write: %s", media_file_id, cleanup_exc)
                        raise


    async def get_media_file_info(self, media_id: int) -> dict[str, Any] | None:
        """Return DB-backed file metadata without loading the BLOB into Python memory."""
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size,
                           OCTET_LENGTH(f.content) AS inline_size
                    FROM media_files f
                    JOIN media_items m ON m.media_file_id=f.id
                    WHERE m.id=%s
                    """,
                    (media_id,),
                )
                row = await cur.fetchone()
                return dict(row) if row else None


    async def get_file_header_bytes(self, file_id: int, size: int = 16) -> bytes:
        """Return the first `size` bytes of a DB-backed file by its media_files.id.

        Used for cheap container-format detection (e.g. moov-at-start MP4 probe)
        without loading the full file content.
        """
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT SUBSTRING(content, 1, %s) AS prefix, OCTET_LENGTH(content) AS inline_size FROM media_files WHERE id=%s",
                    (size, file_id),
                )
                row = await cur.fetchone() or {}
                if int(row.get("inline_size") or 0) > 0:
                    return bytes(row.get("prefix") or b"")
                await cur.execute(
                    "SELECT SUBSTRING(content, 1, %s) AS prefix FROM media_file_chunks WHERE file_id=%s ORDER BY chunk_index ASC LIMIT 1",
                    (size, file_id),
                )
                row = await cur.fetchone() or {}
                return bytes(row.get("prefix") or b"")


    async def get_media_file_prefix(self, media_id: int, limit: int = 1048576) -> bytes:
        """Read only the first bytes needed for cheap dimension sniffing."""
        return (await self.get_media_file_prefixes([int(media_id)], limit=limit)).get(int(media_id), b"")


    async def get_media_file_prefixes(self, media_ids: list[int], limit: int = 1048576) -> dict[int, bytes]:
        """Read cheap file prefixes for many media rows without one query per item."""
        normalized_ids: list[int] = []
        seen: set[int] = set()
        for media_id in media_ids or []:
            normalized_id = int(media_id or 0)
            if normalized_id <= 0 or normalized_id in seen:
                continue
            seen.add(normalized_id)
            normalized_ids.append(normalized_id)
        if not normalized_ids:
            return {}
        max_bytes = max(4096, min(int(limit or 1048576), 2 * 1024 * 1024))
        prefixes: dict[int, bytes] = {}
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                for offset in range(0, len(normalized_ids), 120):
                    batch = normalized_ids[offset:offset + 120]
                    placeholders = ", ".join(["%s"] * len(batch))
                    await cur.execute(
                        f"""
                        SELECT m.id AS media_id, f.id AS file_id, OCTET_LENGTH(f.content) AS inline_size,
                               SUBSTRING(f.content, 1, %s) AS content
                        FROM media_items m
                        JOIN media_files f ON m.media_file_id=f.id
                        WHERE m.id IN ({placeholders})
                        """,
                        (max_bytes, *batch),
                    )
                    chunk_file_map: dict[int, int] = {}
                    for row in await cur.fetchall():
                        media_id = int(row.get("media_id") or 0)
                        file_id = int(row.get("file_id") or 0)
                        if int(row.get("inline_size") or 0) > 0:
                            prefixes[media_id] = bytes(row.get("content") or b"")
                        elif file_id > 0:
                            chunk_file_map[file_id] = media_id
                    if not chunk_file_map:
                        continue
                    file_ids = list(chunk_file_map)
                    file_placeholders = ", ".join(["%s"] * len(file_ids))
                    # chunk_index always starts at 0 (see enumerate() at insert time), so the
                    # first chunk is always chunk_index=0 — a direct PK lookup. The previous
                    # MIN(chunk_index) GROUP BY derived table forced a filesort over this
                    # (often multi-GB) table, which could pile up and starve other queries
                    # on the shared MariaDB instance.
                    await cur.execute(
                        f"""
                        SELECT c.file_id, SUBSTRING(c.content, 1, %s) AS content
                        FROM media_file_chunks c
                        WHERE c.file_id IN ({file_placeholders}) AND c.chunk_index = 0
                        """,
                        (max_bytes, *file_ids),
                    )
                    for row in await cur.fetchall():
                        media_id = chunk_file_map.get(int(row.get("file_id") or 0))
                        if media_id:
                            prefixes[media_id] = bytes(row.get("content") or b"")
        return prefixes


    async def stream_media_file_content(self, file_id: int, start: int | None = None, end: int | None = None):
        """Yield DB-backed media content in chunks for StreamingResponse."""
        start = max(0, int(start or 0))
        end = int(end) if end is not None else None
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                # Use SUBSTRING to avoid loading the full BLOB when only a range is needed.
                if end is not None:
                    length = end - start + 1
                    await cur.execute(
                        "SELECT SUBSTRING(content, %s, %s) AS content, OCTET_LENGTH(content) AS inline_size FROM media_files WHERE id=%s",
                        (start + 1, length, file_id),  # MySQL SUBSTRING is 1-indexed
                    )
                else:
                    await cur.execute(
                        "SELECT SUBSTRING(content, %s) AS content, OCTET_LENGTH(content) AS inline_size FROM media_files WHERE id=%s",
                        (start + 1, file_id),
                    )
                row = await cur.fetchone() or {}
                inline_size = int(row.get("inline_size") or 0)
                inline = row.get("content")
                if inline_size > 0:
                    if inline:
                        yield bytes(inline)
                    return
                # For range requests seeking into the middle of the file, scanning
                # chunks from index 0 wastes bandwidth transferring and discarding
                # potentially hundreds of MB.  Query one chunk's size to compute the
                # first relevant chunk index directly (chunks are uniform-size except
                # the last, so integer division gives a safe lower bound).
                first_chunk_index = 0
                chunk_size = 0
                if start > 0:
                    await cur.execute(
                        "SELECT OCTET_LENGTH(content) AS chunk_size FROM media_file_chunks WHERE file_id=%s ORDER BY chunk_index ASC LIMIT 1",
                        (file_id,),
                    )
                    size_row = await cur.fetchone()
                    chunk_size = int((size_row or {}).get("chunk_size") or 0)
                    if chunk_size > 0:
                        first_chunk_index = start // chunk_size
                await cur.execute(
                    "SELECT content FROM media_file_chunks WHERE file_id=%s AND chunk_index >= %s ORDER BY chunk_index ASC",
                    (file_id, first_chunk_index),
                )
                # Recompute byte offset at the first fetched chunk. Because all chunks
                # except the last share the same size, chunk_index * chunk_size gives
                # the correct byte offset (verified per-chunk via the loop below).
                offset = first_chunk_index * chunk_size
                while True:
                    rows = await cur.fetchmany(16)
                    if not rows:
                        break
                    for chunk in rows:
                        payload = chunk.get("content") or b""
                        if payload:
                            payload = bytes(payload)
                            chunk_start = offset
                            chunk_end = offset + len(payload) - 1
                            offset += len(payload)
                            if chunk_end < start:
                                continue
                            if end is not None and chunk_start > end:
                                return
                            slice_start = max(0, start - chunk_start)
                            slice_end = len(payload) if end is None else min(len(payload), end - chunk_start + 1)
                            if slice_start < slice_end:
                                yield payload[slice_start:slice_end]


    async def get_media_file(self, media_id: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size, f.content
                    FROM media_files f
                    JOIN media_items m ON m.media_file_id=f.id
                    WHERE m.id=%s
                    """,
                    (media_id,),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                content = row.get("content") or b""
                if len(content) == int(row.get("file_size") or 0):
                    return row
                await cur.execute(
                    """
                    SELECT content
                    FROM media_file_chunks
                    WHERE file_id=%s
                    ORDER BY chunk_index ASC
                    """,
                    (row["id"],),
                )
                chunks = await cur.fetchall()
                if chunks:
                    row["content"] = b"".join(chunk["content"] for chunk in chunks)
                return row


    async def get_avatar_file(self, user_id: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.file_size, f.content
                    FROM user_avatar_files f
                    JOIN users u ON u.avatar_file_id=f.id
                    WHERE u.id=%s
                    """,
                    (user_id,),
                )
                return await cur.fetchone()

