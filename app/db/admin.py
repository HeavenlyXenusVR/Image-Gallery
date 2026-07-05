"""Legacy file migration, site health checks, and aggregate stats."""

import hashlib
import mimetypes
from pathlib import Path
from typing import Any

import aiomysql


class AdminMixin:
    async def stats(self) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT COUNT(*) AS users FROM users")
                users = (await cur.fetchone())["users"]
                await cur.execute("SELECT COUNT(*) AS categories FROM categories")
                categories = (await cur.fetchone())["categories"]
                await cur.execute("SELECT COUNT(*) AS media, COALESCE(SUM(file_size), 0) AS bytes FROM media_items")
                media = await cur.fetchone()
                await cur.execute("SELECT COUNT(*) AS likes FROM media_likes")
                likes = (await cur.fetchone())["likes"]
                return {"users": users, "categories": categories, "media": media["media"], "bytes": media["bytes"], "likes": likes}


    async def migrate_legacy_media_files(self, limit: int = 10) -> dict[str, Any]:
        """Copy old disk-backed uploads into media_files and link media_items safely."""
        migrated = 0
        missing = 0
        async with self._blob_lock:
            async with self.pool.acquire() as conn:
                await conn.ping(reconnect=True)
                async with conn.cursor(aiomysql.DictCursor) as cur:
                    await cur.execute(
                        """
                        SELECT id, user_id, storage_path, mime_type, original_filename, media_kind
                        FROM media_items
                        WHERE deleted_at IS NULL AND (media_file_id IS NULL OR media_file_id=0)
                        ORDER BY id ASC
                        LIMIT %s
                        """,
                        (max(1, min(int(limit or 10), 25)),),
                    )
                    rows = list(await cur.fetchall())
                    uploads_root = Path(self.settings.uploads_dir).resolve()
                    for row in rows:
                        raw = str(row.get("storage_path") or "")
                        if raw.startswith("db://"):
                            missing += 1
                            continue
                        raw = raw.replace("\\", "/").lstrip("/")
                        if raw.startswith("uploads/"):
                            raw = raw.split("/", 1)[1]
                        path = (uploads_root / raw).resolve()
                        try:
                            path.relative_to(uploads_root)
                        except ValueError:
                            missing += 1
                            continue
                        if not path.is_file():
                            missing += 1
                            continue
                        content = path.read_bytes()
                        sha256 = hashlib.sha256(content).hexdigest()
                        mime_type = (row.get("mime_type") or mimetypes.guess_type(str(path))[0] or "application/octet-stream")[:120]
                        media_kind = row.get("media_kind") if row.get("media_kind") in {"image", "video"} else ("video" if mime_type.startswith("video/") else "image")
                        original = (row.get("original_filename") or path.name)[:255]
                        await conn.begin()
                        await cur.execute(
                            """
                            INSERT INTO media_files (sha256, mime_type, original_filename, media_kind, file_size, content, created_by)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)
                            ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)
                            """,
                            (sha256, mime_type, original, media_kind, len(content), b"", row.get("user_id")),
                        )
                        file_id = int(cur.lastrowid)
                        await cur.execute("SELECT COUNT(*) AS n FROM media_file_chunks WHERE file_id=%s", (file_id,))
                        chunk_count = int((await cur.fetchone() or {}).get("n") or 0)
                        if chunk_count == 0:
                            for chunk_index, offset in enumerate(range(0, len(content), self.media_chunk_bytes)):
                                await cur.execute(
                                    """
                                    INSERT INTO media_file_chunks (file_id, chunk_index, content)
                                    VALUES (%s, %s, %s)
                                    """,
                                    (file_id, chunk_index, content[offset:offset + self.media_chunk_bytes]),
                                )
                        await cur.execute(
                            "UPDATE media_items SET media_file_id=%s, content_sha256=%s, file_size=%s, storage_path=%s WHERE id=%s",
                            (file_id, sha256, len(content), f"db://media/{file_id}", row["id"]),
                        )
                        await conn.commit()
                        migrated += 1
        return {"migrated": migrated, "missing": missing}


    async def site_checks(self) -> dict[str, Any]:
        """Lightweight operational checks used by the live site status panel.

        These checks avoid touching BLOB contents so the endpoint stays cheap.
        All counts are gathered in a single round-trip.
        """
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT
                        CURRENT_TIMESTAMP AS db_time,
                        (SELECT COUNT(*) FROM users) AS users,
                        (SELECT COUNT(*) FROM media_items) AS media_total,
                        (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NULL) AS media_active,
                        (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NOT NULL) AS media_archived,
                        (SELECT COUNT(*) FROM media_files) AS db_files,
                        (SELECT COUNT(*) FROM media_items
                            WHERE deleted_at IS NULL AND (media_file_id IS NULL OR media_file_id=0)) AS missing_db_files,
                        (SELECT COUNT(*) FROM media_items WHERE visibility='private' AND deleted_at IS NULL) AS private_posts,
                        (SELECT COUNT(*) FROM media_items WHERE comments_enabled=0 AND deleted_at IS NULL) AS comments_disabled,
                        (SELECT COUNT(*) FROM media_items WHERE downloads_enabled=0 AND deleted_at IS NULL) AS downloads_disabled,
                        (SELECT COUNT(*) FROM media_reports WHERE status='open') AS open_reports
                    """
                )
                row = (await cur.fetchone()) or {}
                return {
                    "db_time": row.get("db_time"),
                    "users": int(row.get("users") or 0),
                    "media_total": int(row.get("media_total") or 0),
                    "media_active": int(row.get("media_active") or 0),
                    "media_archived": int(row.get("media_archived") or 0),
                    "db_files": int(row.get("db_files") or 0),
                    "missing_db_files": int(row.get("missing_db_files") or 0),
                    "private_posts": int(row.get("private_posts") or 0),
                    "comments_disabled": int(row.get("comments_disabled") or 0),
                    "downloads_disabled": int(row.get("downloads_disabled") or 0),
                    "open_reports": int(row.get("open_reports") or 0),
                }

