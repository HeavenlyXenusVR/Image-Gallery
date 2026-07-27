"""Legacy file migration, site health checks, and aggregate stats."""

import hashlib
import mimetypes
from pathlib import Path
from typing import Any

from . import pg_compat as aiomysql


class AdminMixin:
    async def list_reports(self, *, status: str | None = None, limit: int = 50, offset: int = 0) -> list[dict[str, Any]]:
        clauses = []
        params: list[Any] = []
        if status in {"open", "reviewed", "dismissed"}:
            clauses.append("r.status=%s")
            params.append(status)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT r.id, r.media_id, r.user_id, r.reason, r.details, r.status, r.created_at,
                           m.title AS media_title, m.media_kind, m.mime_type,
                           m.deleted_at AS media_deleted_at, m.user_id AS media_owner_id,
                           ru.username AS reporter_username, ru.display_name AS reporter_display_name,
                           mu.username AS media_owner_username, mu.display_name AS media_owner_display_name
                    FROM media_reports r
                    JOIN media_items m ON m.id = r.media_id
                    JOIN users ru ON ru.id = r.user_id
                    JOIN users mu ON mu.id = m.user_id
                    {where}
                    ORDER BY r.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (*params, max(1, min(int(limit or 50), 200)), max(0, int(offset or 0))),
                )
                return list(await cur.fetchall())


    async def resolve_report(self, report_id: int, status: str, actor_id: int | None = None) -> dict[str, Any] | None:
        if status not in {"open", "reviewed", "dismissed"}:
            raise ValueError("Invalid report status.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("UPDATE media_reports SET status=%s WHERE id=%s", (status, report_id))
                await cur.execute("SELECT * FROM media_reports WHERE id=%s", (report_id,))
                report = await cur.fetchone()
        if report:
            await self.write_audit_log(actor_id, f"report_{status}", "report", report_id, f"media_id={report.get('media_id')}")
        return report


    async def moderator_delete_media(self, media_id: int, actor_id: int | None = None) -> bool:
        """Soft-delete any media item regardless of ownership — site-owner moderation only."""
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND deleted_at IS NULL",
                    (media_id,),
                )
                deleted = cur.rowcount > 0
        if deleted:
            await self.write_audit_log(actor_id, "delete_media", "media", media_id, None)
        return deleted


    async def write_audit_log(self, actor_id: int | None, action: str, target_type: str, target_id: int | None, detail: str | None) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "INSERT INTO moderation_audit_log (actor_id, action, target_type, target_id, detail) VALUES (%s, %s, %s, %s, %s)",
                    (actor_id, action[:60], target_type[:30], target_id, (detail or "")[:500] or None),
                )


    async def list_audit_log(self, limit: int = 50, offset: int = 0) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT a.*, u.username AS actor_username, COALESCE(u.display_name, u.username) AS actor_display_name
                    FROM moderation_audit_log a
                    LEFT JOIN users u ON u.id = a.actor_id
                    ORDER BY a.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (max(1, min(int(limit or 50), 200)), max(0, int(offset or 0))),
                )
                return list(await cur.fetchall())


    async def ban_user(self, user_id: int, banned_by: int, reason: str | None, until: str | None) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    UPDATE users
                    SET banned_at=CURRENT_TIMESTAMP, banned_until=%s, ban_reason=%s, banned_by=%s
                    WHERE id=%s
                    """,
                    (until, (reason or "").strip()[:300] or None, banned_by, user_id),
                )
                if cur.rowcount == 0:
                    return None
        self._invalidate_user_cache(user_id)
        await self.write_audit_log(banned_by, "ban", "user", user_id, reason)
        return await self.get_user(user_id, bypass_cache=True)


    async def unban_user(self, user_id: int, lifted_by: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE users SET banned_at=NULL, banned_until=NULL, ban_reason=NULL, banned_by=NULL WHERE id=%s",
                    (user_id,),
                )
                if cur.rowcount == 0:
                    return None
        self._invalidate_user_cache(user_id)
        await self.write_audit_log(lifted_by, "unban", "user", user_id, None)
        return await self.get_user(user_id, bypass_cache=True)


    async def list_flagged_media(self, limit: int = 50, offset: int = 0) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT m.*, u.username AS owner_username, COALESCE(u.display_name, u.username) AS owner_display_name
                    FROM media_items m
                    JOIN users u ON u.id = m.user_id
                    WHERE m.moderation_status='pending_review' AND m.deleted_at IS NULL
                    ORDER BY m.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (max(1, min(int(limit or 50), 200)), max(0, int(offset or 0))),
                )
                return list(await cur.fetchall())


    async def resolve_flagged_media(self, media_id: int, decision: str, actor_id: int | None = None) -> dict[str, Any] | None:
        if decision not in {"clear", "adult"}:
            raise ValueError("decision must be clear or adult.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    UPDATE media_items
                    SET moderation_status=%s, is_adult=%s, moderated_at=CURRENT_TIMESTAMP
                    WHERE id=%s AND moderation_status='pending_review'
                    """,
                    (decision, decision == "adult", media_id),
                )
                if cur.rowcount == 0:
                    return None
                await cur.execute("SELECT * FROM media_items WHERE id=%s", (media_id,))
                item = await cur.fetchone()
        await self.write_audit_log(actor_id, f"flagged_media_{decision}", "media", media_id, None)
        return item


    async def storage_by_user(self, limit: int = 20) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT COALESCE(SUM(file_size), 0) AS total_bytes, COUNT(*) AS total_items FROM media_items WHERE deleted_at IS NULL")
                totals = await cur.fetchone() or {}
                await cur.execute(
                    """
                    SELECT m.user_id, u.username, COALESCE(u.display_name, u.username) AS display_name,
                           COUNT(*) AS item_count, COALESCE(SUM(m.file_size), 0) AS total_bytes
                    FROM media_items m
                    JOIN users u ON u.id = m.user_id
                    WHERE m.deleted_at IS NULL
                    GROUP BY m.user_id
                    ORDER BY total_bytes DESC
                    LIMIT %s
                    """,
                    (max(1, min(int(limit or 20), 100)),),
                )
                by_user = list(await cur.fetchall())
        return {
            "total_bytes": int(totals.get("total_bytes") or 0),
            "total_items": int(totals.get("total_items") or 0),
            "by_user": by_user,
        }


    async def get_site_settings(self) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT * FROM site_settings WHERE id=1")
                row = await cur.fetchone()
                return dict(row) if row else {}


    async def touch_site_digest(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("UPDATE site_settings SET last_digest_at=CURRENT_TIMESTAMP WHERE id=1")


    async def update_site_settings(self, updated_by: int, **fields: Any) -> dict[str, Any]:
        allowed = {
            "announcement_message", "announcement_level", "announcement_active",
            "maintenance_mode", "maintenance_message",
        }
        sets = []
        params: list[Any] = []
        for key, value in fields.items():
            if key not in allowed or value is None:
                continue
            sets.append(f"{key}=%s")
            if key in {"announcement_active", "maintenance_mode"}:
                params.append(bool(value))
            else:
                params.append(str(value)[:500])
        if not sets:
            return await self.get_site_settings()
        sets.append("updated_by=%s")
        params.append(updated_by)
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(f"UPDATE site_settings SET {', '.join(sets)} WHERE id=1", tuple(params))
        await self.write_audit_log(updated_by, "site_settings_update", "site_settings", None, ", ".join(fields.keys()))
        return await self.get_site_settings()


    async def digest_counts_since(self, since: Any) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT
                        (SELECT COUNT(*) FROM media_reports WHERE created_at > %s) AS new_reports,
                        (SELECT COUNT(*) FROM users WHERE banned_at > %s) AS new_bans,
                        (SELECT COUNT(*) FROM users WHERE created_at > %s) AS new_signups,
                        (SELECT COUNT(*) FROM media_items WHERE moderation_status='pending_review' AND deleted_at IS NULL) AS pending_review,
                        (SELECT COALESCE(SUM(file_size), 0) FROM media_items WHERE created_at > %s AND deleted_at IS NULL) AS new_bytes
                    """,
                    (since, since, since, since),
                )
                row = await cur.fetchone() or {}
                return {k: int(v or 0) for k, v in row.items()}


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
                            ON CONFLICT (sha256) DO UPDATE SET id=media_files.id
                            RETURNING id
                            """,
                            (sha256, mime_type, original, media_kind, len(content), b"", row.get("user_id")),
                        )
                        file_id = int((await cur.fetchone())["id"])
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
                        (SELECT COUNT(*) FROM media_items WHERE comments_enabled=false AND deleted_at IS NULL) AS comments_disabled,
                        (SELECT COUNT(*) FROM media_items WHERE downloads_enabled=false AND deleted_at IS NULL) AS downloads_disabled,
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

