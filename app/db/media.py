"""Media CRUD, likes, comments, controls, moderation reporting, tag cloud."""

import json
import re
from typing import Any

import aiomysql

from ._shared import MEDIA_CATEGORY_JOIN, MEDIA_CATEGORY_SELECT, normalize_subcategory_ids


class MediaMixin:
    async def add_media(self, item: dict[str, Any]) -> dict[str, Any]:
        tags_json = json.dumps(item.get("tags") or [])
        subcategory_ids = normalize_subcategory_ids(item.get("subcategory_ids"))
        primary_subcategory_id = subcategory_ids[0] if subcategory_ids else item.get("subcategory_id")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await conn.begin()
                try:
                    await cur.execute(
                        """
                        INSERT INTO media_items
                          (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename,
                           storage_path, file_size, media_file_id, content_sha256, visibility, comments_enabled, downloads_enabled, pinned_at,
                           is_adult, adult_marked_by_user, adult_marked_by_ai,
                           moderation_status, moderation_score, moderation_reason, moderated_at, publish_at, image_phash, image_dhash)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE NULL END, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP, %s, %s, %s)
                        """,
                        (
                            item["user_id"], item["category_id"], primary_subcategory_id, item["title"], item.get("description"), tags_json,
                            item["media_kind"], item["mime_type"], item["original_filename"],
                            item.get("storage_path") or f"db://media/{item.get('media_file_id')}", item["file_size"],
                            item.get("media_file_id"), item.get("content_sha256"),
                            item.get("visibility") if item.get("visibility") in {"public", "unlisted", "private"} else "public",
                            1 if item.get("comments_enabled", True) else 0,
                            1 if item.get("downloads_enabled", True) else 0,
                            1 if item.get("pinned") else 0,
                            1 if item.get("is_adult") else 0,
                            1 if item.get("adult_marked_by_user") else 0,
                            1 if item.get("adult_marked_by_ai") else 0,
                            item.get("moderation_status") or "clear",
                            float(item.get("moderation_score") or 0),
                            item.get("moderation_reason"),
                            item.get("publish_at"),
                            item.get("image_phash"),
                            item.get("image_dhash"),
                        ),
                    )
                    media_id = int(cur.lastrowid)
                    await self._write_media_subcategories(cur, media_id, subcategory_ids or ([primary_subcategory_id] if primary_subcategory_id else []))
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise
                return await self.get_media(media_id, item["user_id"])

    async def list_visual_hash_candidates(self, user_id: int, *, limit: int = 1500) -> list[dict[str, Any]]:
        """Recent own media with a perceptual hash on file, newest first — the candidate
        pool a caller compares a freshly-uploaded image's hash against to warn about
        likely re-uploads. Hamming distance can't be expressed as SQL, so the actual
        similarity comparison happens in Python on top of this bounded result set."""
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT id, title, image_phash, image_dhash
                    FROM media_items
                    WHERE user_id=%s AND deleted_at IS NULL AND media_kind='image'
                      AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL)
                    ORDER BY created_at DESC
                    LIMIT %s
                    """,
                    (user_id, int(limit)),
                )
                return list(await cur.fetchall())

    @staticmethod
    def _escape_like(value: str) -> str:
        """Escape LIKE wildcard characters so user input is treated as a literal string."""
        return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


    async def list_media(
        self,
        *,
        viewer_id: int | None,
        media_kind: str | None = None,
        category_id: int | None = None,
        subcategory_id: int | None = None,
        query: str | None = None,
        uploader: str | None = None,
        min_size: int | None = None,
        max_size: int | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        adult: str | None = None,
        sort: str = "new",
        limit: int = 60,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        viewer = viewer_id or 0
        clauses = [
            "m.deleted_at IS NULL",
            "(m.visibility='public' OR m.user_id=%s)",
            "(m.publish_at IS NULL OR m.publish_at <= UTC_TIMESTAMP() OR m.user_id=%s)",
        ]
        params: list[Any] = [viewer, viewer]
        if media_kind in {"image", "video"}:
            clauses.append("m.media_kind=%s")
            params.append(media_kind)
        if category_id:
            clauses.append("m.category_id=%s")
            params.append(category_id)
        if subcategory_id:
            clauses.append("EXISTS (SELECT 1 FROM media_item_subcategories ms WHERE ms.media_id=m.id AND ms.subcategory_id=%s)")
            params.append(subcategory_id)
        if query:
            clauses.append("(m.title LIKE %s ESCAPE '\\\\' OR m.description LIKE %s ESCAPE '\\\\' OR m.tags LIKE %s ESCAPE '\\\\')")
            needle = f"%{self._escape_like(query)}%"
            params.extend([needle, needle, needle])
        if uploader:
            clauses.append("(u.username LIKE %s ESCAPE '\\\\' OR u.display_name LIKE %s ESCAPE '\\\\')")
            needle = f"%{self._escape_like(uploader)}%"
            params.extend([needle, needle])
        if min_size is not None:
            clauses.append("m.file_size >= %s")
            params.append(max(0, int(min_size)))
        if max_size is not None:
            clauses.append("m.file_size <= %s")
            params.append(max(0, int(max_size)))
        if date_from:
            clauses.append("DATE(m.created_at) >= %s")
            params.append(date_from)
        if date_to:
            clauses.append("DATE(m.created_at) <= %s")
            params.append(date_to)
        if adult == "only":
            clauses.append("m.is_adult=1")
        elif adult == "hide":
            clauses.append("m.is_adult=0")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        order = {
            "popular": "m.pinned_at DESC, like_count DESC, m.views DESC, m.created_at DESC",
            "downloads": "m.pinned_at DESC, m.downloads DESC, m.created_at DESC",
            "views": "m.pinned_at DESC, m.views DESC, m.created_at DESC",
            "old": "m.created_at ASC",
        }.get(sort, "m.pinned_at DESC, m.created_at DESC")
        sql_params = [viewer, viewer, viewer, viewer, viewer, viewer, *params, max(1, min(limit, 100)), max(0, offset)]
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    {where}
                    GROUP BY m.id
                    ORDER BY {order}
                    LIMIT %s OFFSET %s
                    """,
                    tuple(sql_params),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def list_user_media(self, user_id: int, limit: int = 100, include_deleted: bool = False) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.user_id=%s AND (%s=1 OR m.deleted_at IS NULL)
                    GROUP BY m.id
                    ORDER BY m.created_at DESC
                    LIMIT %s
                    """,
                    (user_id, user_id, user_id, 1 if include_deleted else 0, max(1, min(limit, 200))),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def trending_media(self, *, viewer_id: int | None = None, days: int = 7, limit: int = 30) -> list[dict[str, Any]]:
        """Rank recent public posts by a simple weighted score of views/likes/comments.

        Weighting favors engagement (likes, comments) over raw views since views accrue
        passively just from appearing in feeds, while likes/comments are deliberate signals.
        """
        viewer = viewer_id or 0
        window_days = max(1, min(int(days or 7), 90))
        row_limit = max(1, min(int(limit or 30), 100))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me,
                           (m.views + COUNT(DISTINCT l.user_id) * 3 + COUNT(DISTINCT cm.id) * 2) AS trend_score
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                      AND (m.publish_at IS NULL OR m.publish_at <= UTC_TIMESTAMP() OR m.user_id=%s)
                      AND m.created_at >= (UTC_TIMESTAMP() - INTERVAL %s DAY)
                    GROUP BY m.id
                    ORDER BY trend_score DESC, m.created_at DESC
                    LIMIT %s
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, window_days, row_limit),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def tag_cloud(self, limit: int = 30) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT tags FROM media_items WHERE tags IS NOT NULL AND deleted_at IS NULL AND visibility='public' ORDER BY created_at DESC LIMIT 500")
                rows = await cur.fetchall()
        counts: dict[str, int] = {}
        for row in rows:
            tags = row.get("tags")
            if isinstance(tags, str):
                try:
                    tags = json.loads(tags)
                except json.JSONDecodeError:
                    tags = []
            for tag in tags or []:
                normalized = str(tag).strip()[:32]
                if normalized:
                    counts[normalized] = counts.get(normalized, 0) + 1
        return [
            {"tag": tag, "count": count}
            for tag, count in sorted(counts.items(), key=lambda item: (-item[1], item[0].lower()))[:limit]
        ]


    async def user_tag_counts(self, user_id: int, *, min_count: int = 4, limit: int = 8) -> list[dict[str, Any]]:
        """Tags that repeat often enough across a user's own uploads to be worth a
        dedicated smart collection — powers the collection-suggestion banner."""
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT id, tags FROM media_items WHERE user_id=%s AND deleted_at IS NULL AND tags IS NOT NULL ORDER BY created_at DESC LIMIT 1000",
                    (user_id,),
                )
                rows = await cur.fetchall()
        counts: dict[str, int] = {}
        sample_media_id: dict[str, int] = {}
        for row in rows:
            tags = row.get("tags")
            if isinstance(tags, str):
                try:
                    tags = json.loads(tags)
                except json.JSONDecodeError:
                    tags = []
            for tag in tags or []:
                normalized = str(tag).strip().lower()[:32]
                if not normalized:
                    continue
                counts[normalized] = counts.get(normalized, 0) + 1
                sample_media_id.setdefault(normalized, int(row["id"]))
        return [
            {"tag": tag, "count": count, "sample_media_id": sample_media_id[tag]}
            for tag, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
            if count >= min_count
        ][:limit]

    async def get_media(self, media_id: int, viewer_id: int | None = None) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.id=%s
                    GROUP BY m.id
                    """,
                    (viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, media_id),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                item = self._decode_media(row)
        rows = await self._attach_media_subcategories([item])
        return rows[0] if rows else None


    async def increment_counter(self, media_id: int, column: str) -> None:
        if column not in {"views", "downloads"}:
            raise ValueError("Invalid counter")
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(f"UPDATE media_items SET {column}={column}+1 WHERE id=%s", (media_id,))


    async def set_like(self, media_id: int, user_id: int, liked: bool) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if liked:
                    await cur.execute("INSERT IGNORE INTO media_likes (user_id, media_id) VALUES (%s, %s)", (user_id, media_id))
                else:
                    await cur.execute("DELETE FROM media_likes WHERE user_id=%s AND media_id=%s", (user_id, media_id))
        return await self.get_media(media_id, user_id)


    async def add_comment(self, media_id: int, user_id: int, body: str, parent_comment_id: int | None = None) -> dict[str, Any]:
        body = " ".join(str(body or "").strip().split())[:500]
        if not body:
            raise ValueError("Comment cannot be empty.")
        media = await self.get_media(media_id, user_id)
        if not media or media.get("deleted_at"):
            raise ValueError("Media not found.")
        if not media.get("comments_enabled", True) and int(media.get("user_id")) != int(user_id):
            raise PermissionError("Comments are disabled for this post.")
        if int(media.get("user_id")) != int(user_id) and await self.is_blocked_either_way(user_id, int(media["user_id"])):
            raise PermissionError("You cannot comment on this post.")
        parent_id: int | None = None
        if parent_comment_id:
            async with self.pool.acquire() as conn:
                async with conn.cursor() as cur:
                    await cur.execute(
                        "SELECT id FROM media_comments WHERE id=%s AND media_id=%s",
                        (int(parent_comment_id), media_id),
                    )
                    if await cur.fetchone():
                        parent_id = int(parent_comment_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "INSERT INTO media_comments (media_id, user_id, body, parent_comment_id) VALUES (%s, %s, %s, %s)",
                    (media_id, user_id, body, parent_id),
                )
                await cur.execute(
                    """
                    SELECT cm.*, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS user_avatar_path
                    FROM media_comments cm JOIN users u ON u.id = cm.user_id
                    WHERE cm.id=%s
                    """,
                    (cur.lastrowid,),
                )
                return await cur.fetchone()


    async def list_comments(self, media_id: int, limit: int = 80, offset: int = 0) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 80), 200))
        offset = max(0, int(offset or 0))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT cm.*, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS user_avatar_path
                    FROM media_comments cm JOIN users u ON u.id = cm.user_id
                    WHERE cm.media_id=%s
                    ORDER BY cm.created_at ASC
                    LIMIT %s OFFSET %s
                    """,
                    (media_id, limit, offset),
                )
                return list(await cur.fetchall())


    async def react_to_media(self, media_id: int, user_id: int, emoji: str) -> dict[str, Any]:
        emoji = str(emoji or "").strip()[:16]
        if not emoji:
            raise ValueError("An emoji is required.")
        media = await self.get_media(media_id, user_id)
        if not media or media.get("deleted_at"):
            raise ValueError("Media not found.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s",
                    (media_id, user_id),
                )
                existing = await cur.fetchone()
                if existing and existing["emoji"] == emoji:
                    await cur.execute("DELETE FROM media_reactions WHERE media_id=%s AND user_id=%s", (media_id, user_id))
                else:
                    await cur.execute(
                        "INSERT INTO media_reactions (media_id, user_id, emoji) VALUES (%s, %s, %s) "
                        "ON DUPLICATE KEY UPDATE emoji=VALUES(emoji), created_at=CURRENT_TIMESTAMP",
                        (media_id, user_id, emoji),
                    )
        return await self.list_reactions(media_id, user_id)


    async def list_comments_by_user(self, user_id: int, limit: int = 200) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT cm.id, cm.media_id, cm.body, cm.parent_comment_id, cm.created_at, m.title AS media_title
                    FROM media_comments cm
                    JOIN media_items m ON m.id = cm.media_id
                    WHERE cm.user_id=%s
                    ORDER BY cm.created_at DESC
                    LIMIT %s
                    """,
                    (user_id, max(1, min(int(limit or 200), 1000))),
                )
                return list(await cur.fetchall())


    async def list_reactions(self, media_id: int, viewer_id: int | None = None) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "SELECT emoji, COUNT(*) AS n FROM media_reactions WHERE media_id=%s GROUP BY emoji ORDER BY n DESC",
                    (media_id,),
                )
                counts = {row["emoji"]: int(row["n"]) for row in await cur.fetchall()}
                my_reaction = None
                if viewer_id:
                    await cur.execute(
                        "SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s",
                        (media_id, viewer_id),
                    )
                    row = await cur.fetchone()
                    my_reaction = row["emoji"] if row else None
                return {"counts": counts, "my_reaction": my_reaction}


    async def list_similar_media(self, media_id: int, viewer_id: int | None = None, limit: int = 12) -> list[dict[str, Any]]:
        source = await self.get_media(media_id, viewer_id)
        if not source or source.get("deleted_at"):
            return []
        tags = source.get("tags") or []
        tag_conditions = []
        params: list[Any] = []
        for tag in tags[:8]:
            tag_conditions.append("JSON_CONTAINS(m.tags, JSON_QUOTE(%s))")
            params.append(str(tag))
        tag_score_sql = " + ".join(f"({cond})" for cond in tag_conditions) if tag_conditions else "0"
        adult_clause = "" if viewer_id else "AND m.is_adult=0"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.avatar_path AS user_avatar_path, u.profile_color,
                           ({tag_score_sql} + (m.category_id=%s)) AS relevance
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    WHERE m.id != %s AND m.deleted_at IS NULL AND m.visibility='public'
                          AND (m.publish_at IS NULL OR m.publish_at <= UTC_TIMESTAMP())
                          {adult_clause}
                          AND (m.category_id=%s OR {tag_score_sql if tag_conditions else '0'} > 0)
                    ORDER BY relevance DESC, m.created_at DESC
                    LIMIT %s
                    """,
                    (*params, source["category_id"], media_id, source["category_id"], *params, max(1, min(int(limit or 12), 30))),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def update_media(self, media_id: int, user_id: int, payload: dict[str, Any]) -> dict[str, Any] | None:
        title = self._clean_text(payload.get("title"), 160, required=True)
        description = self._clean_text(payload.get("description"), 2000)
        tags = payload.get("tags") or []
        if not isinstance(tags, list):
            tags = []
        clean_tags = []
        for raw in tags:
            tag = re.sub(r"[^A-Za-z0-9_.-]+", "", str(raw).strip())[:32]
            if tag and tag.lower() not in {existing.lower() for existing in clean_tags}:
                clean_tags.append(tag)
        clean_tags = clean_tags[:12]
        category_id = int(payload.get("category_id") or 0)
        subcategory_ids = await self.resolve_subcategory_ids(
            category_id=category_id,
            subcategory_ids=(payload.get("subcategory_ids") or ([payload.get("subcategory_id")] if payload.get("subcategory_id") else [])),
            subcategory_names=(payload.get("subcategory_names") or ([payload.get("subcategory_name")] if payload.get("subcategory_name") else [])),
            user_id=user_id,
        )
        subcategory_id = subcategory_ids[0] if subcategory_ids else None
        visibility = str(payload.get("visibility") or "public").lower()
        if visibility not in {"public", "unlisted", "private"}:
            raise ValueError("Visibility must be public, unlisted, or private.")
        is_adult = 1 if payload.get("is_adult") else 0
        comments_enabled = 1 if payload.get("comments_enabled", True) else 0
        downloads_enabled = 1 if payload.get("downloads_enabled", True) else 0
        pinned = 1 if payload.get("pinned") else 0
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await conn.begin()
                try:
                    await cur.execute("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL FOR UPDATE", (media_id,))
                    row = await cur.fetchone()
                    if not row:
                        await conn.rollback()
                        return None
                    if int(row["user_id"]) != int(user_id):
                        await conn.rollback()
                        raise PermissionError("Only the uploader can edit this post.")
                    await cur.execute(
                        """
                        UPDATE media_items
                        SET title=%s, description=%s, tags=%s, category_id=%s, subcategory_id=%s,
                            visibility=%s, comments_enabled=%s, downloads_enabled=%s,
                            pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END,
                            is_adult=%s, adult_marked_by_user=%s,
                            moderation_status=CASE WHEN %s=1 THEN 'adult' ELSE moderation_status END,
                            moderation_reason=CASE WHEN %s=1 THEN 'Uploader marked this post as 18+.' ELSE moderation_reason END,
                            moderated_at=CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE moderated_at END
                        WHERE id=%s AND user_id=%s
                        """,
                        (title, description, json.dumps(clean_tags), category_id, subcategory_id, visibility, comments_enabled, downloads_enabled,
                         pinned, is_adult, is_adult, is_adult, is_adult, is_adult, media_id, user_id),
                    )
                    await self._write_media_subcategories(cur, media_id, subcategory_ids)
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise
        return await self.get_media(media_id, user_id)


    async def set_media_controls(self, media_id: int, user_id: int, payload: dict[str, Any]) -> dict[str, Any] | None:
        allowed_visibility = {"public", "unlisted", "private"}
        visibility = payload.get("visibility")
        updates = []
        params: list[Any] = []
        if visibility is not None:
            visibility = str(visibility).lower()
            if visibility not in allowed_visibility:
                raise ValueError("Visibility must be public, unlisted, or private.")
            updates.append("visibility=%s")
            params.append(visibility)
        # Enumerate explicitly — never build column names from user-supplied keys.
        for key in ("comments_enabled", "downloads_enabled"):
            if key in payload:
                updates.append(f"{key}=%s")
                params.append(1 if payload.get(key) else 0)
        if "pinned" in payload:
            updates.append("pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END")
            params.append(1 if payload.get("pinned") else 0)
        if not updates:
            return await self.get_media(media_id, user_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", (media_id,))
                row = await cur.fetchone()
                if not row:
                    return None
                if int(row["user_id"]) != int(user_id):
                    raise PermissionError("Only the uploader can change post controls.")
                await cur.execute(f"UPDATE media_items SET {', '.join(updates)} WHERE id=%s AND user_id=%s", (*params, media_id, user_id))
        return await self.get_media(media_id, user_id)


    async def delete_comment(self, comment_id: int, user_id: int) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT cm.id, cm.user_id AS comment_user_id, m.user_id AS media_user_id
                    FROM media_comments cm
                    JOIN media_items m ON m.id=cm.media_id
                    WHERE cm.id=%s
                    """,
                    (comment_id,),
                )
                row = await cur.fetchone()
                if not row:
                    return False
                if int(row["comment_user_id"]) != int(user_id) and int(row["media_user_id"]) != int(user_id):
                    raise PermissionError("Only the commenter or post owner can delete this comment.")
                await cur.execute("DELETE FROM media_comments WHERE id=%s", (comment_id,))
                return True


    async def delete_media(self, media_id: int, user_id: int) -> dict[str, Any] | None:
        item = await self.get_media(media_id, user_id)
        if not item or int(item["user_id"]) != int(user_id):
            return None
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND user_id=%s AND deleted_at IS NULL", (media_id, user_id))
        return item


    async def restore_media(self, media_id: int, user_id: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT user_id FROM media_items WHERE id=%s", (media_id,))
                row = await cur.fetchone()
                if not row:
                    return None
                if int(row["user_id"]) != int(user_id):
                    raise PermissionError("Only the uploader can restore this post.")
                await cur.execute("UPDATE media_items SET deleted_at=NULL, visibility='private' WHERE id=%s AND user_id=%s", (media_id, user_id))
        return await self.get_media(media_id, user_id)


    async def report_media(self, media_id: int, user_id: int, reason: str, details: str | None) -> dict[str, Any]:
        reason = self._clean_text(reason, 80, required=True)
        details = self._clean_text(details, 500)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    INSERT INTO media_reports (media_id, user_id, reason, details)
                    VALUES (%s, %s, %s, %s)
                    ON DUPLICATE KEY UPDATE reason=VALUES(reason), details=VALUES(details), status='open', created_at=CURRENT_TIMESTAMP
                    """,
                    (media_id, user_id, reason, details),
                )
                await cur.execute(
                    "SELECT * FROM media_reports WHERE media_id=%s AND user_id=%s",
                    (media_id, user_id),
                )
                return await cur.fetchone()

