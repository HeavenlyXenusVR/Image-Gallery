"""Home/following feeds, background candidates, bookmarks, and collections."""

from typing import Any

import aiomysql

from ._shared import MEDIA_CATEGORY_JOIN, MEDIA_CATEGORY_SELECT


class FeedSocialMixin:
    async def random_media(self, viewer_id: int | None = None) -> dict[str, Any] | None:
        # Use ORDER BY RAND() with a small LIMIT to avoid loading 100 rows just to pick one.
        viewer = viewer_id or 0
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
                    WHERE m.deleted_at IS NULL AND m.visibility='public'
                    GROUP BY m.id
                    ORDER BY RAND()
                    LIMIT 1
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                item = self._decode_media(row)
        rows = await self._attach_media_subcategories([item])
        return rows[0] if rows else None


    async def list_public_background_candidates(self, limit: int = 600) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.id, m.user_id, m.title, m.storage_path, m.mime_type, m.original_filename,
                           m.media_kind, m.file_size, m.is_adult, m.visibility,
                           m.image_width, m.image_height, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           u.profile_color, u.public_profile
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    WHERE m.deleted_at IS NULL
                      AND m.visibility='public'
                      AND m.media_kind='image'
                      AND m.is_adult=0
                    ORDER BY COALESCE(m.pinned_at, m.created_at) DESC, m.created_at DESC
                    LIMIT %s
                    """,
                    (max(1, min(limit, 1200)),),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def following_feed(self, user_id: int, limit: int = 60, offset: int = 0) -> list[dict[str, Any]]:
        viewer = int(user_id)
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
                    FROM user_follows f
                    JOIN media_items m ON m.user_id=f.followed_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id=m.user_id
                    LEFT JOIN media_likes l ON l.media_id=m.id
                    LEFT JOIN media_likes l2 ON l2.media_id=m.id AND l2.user_id=%s
                    LEFT JOIN media_bookmarks b ON b.media_id=m.id AND b.user_id=%s
                    LEFT JOIN media_comments cm ON cm.media_id=m.id
                    WHERE f.follower_id=%s AND m.deleted_at IS NULL AND m.visibility='public'
                    GROUP BY m.id
                    ORDER BY m.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (viewer, viewer, viewer, max(1, min(limit, 100)), max(0, offset)),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def list_liked_media(self, user_id: int, limit: int = 80, offset: int = 0) -> list[dict[str, Any]]:
        viewer = int(user_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l_all.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           1 AS liked_by_me
                    FROM media_likes liked
                    JOIN media_items m ON m.id=liked.media_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id=m.user_id
                    LEFT JOIN media_likes l_all ON l_all.media_id=m.id
                    LEFT JOIN media_bookmarks b ON b.media_id=m.id AND b.user_id=%s
                    LEFT JOIN media_comments cm ON cm.media_id=m.id
                    WHERE liked.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id
                    ORDER BY liked.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (viewer, viewer, viewer, max(1, min(limit, 100)), max(0, offset)),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def list_profile_media(self, user_id: int, viewer_id: int | None = None, limit: int = 24, offset: int = 0) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
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
                    WHERE m.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id
                    ORDER BY m.pinned_at DESC, m.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer, user_id, viewer, max(1, min(limit, 100)), max(0, offset)),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def list_user_follows(self, user_id: int, mode: str = "followers", viewer_id: int | None = None) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        if mode == "following":
            join_col, user_col = "followed_id", "follower_id"
        else:
            join_col, user_col = "follower_id", "followed_id"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at, f.created_at AS followed_at,
                           MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me
                    FROM user_follows f
                    JOIN users u ON u.id=f.{join_col}
                    LEFT JOIN user_follows mine ON mine.follower_id=%s AND mine.followed_id=u.id
                    WHERE f.{user_col}=%s
                    GROUP BY u.id, f.created_at
                    ORDER BY f.created_at DESC
                    LIMIT 200
                    """,
                    (viewer, viewer, viewer, viewer, user_id),
                )
                return [self._decode_user(row) for row in await cur.fetchall()]


    async def set_bookmark(self, media_id: int, user_id: int, bookmarked: bool) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if bookmarked:
                    await cur.execute("INSERT IGNORE INTO media_bookmarks (user_id, media_id) VALUES (%s, %s)", (user_id, media_id))
                else:
                    await cur.execute("DELETE FROM media_bookmarks WHERE user_id=%s AND media_id=%s", (user_id, media_id))
        return await self.get_media(media_id, user_id)


    async def list_bookmarks(self, user_id: int, limit: int = 80) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           1 AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_bookmarks bm
                    JOIN media_items m ON m.id = bm.media_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE bm.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id, bm.created_at
                    ORDER BY bm.created_at DESC
                    LIMIT %s
                    """,
                    (user_id, user_id, user_id, max(1, min(limit, 100))),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)


    async def create_collection(self, user_id: int, name: str, description: str | None, is_public: bool) -> dict[str, Any]:
        name = self._clean_text(name, 100, required=True)
        description = self._clean_text(description, 500)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "INSERT INTO media_collections (user_id, name, description, is_public) VALUES (%s, %s, %s, %s)",
                    (user_id, name, description, 1 if is_public else 0),
                )
                return await self.get_collection(cur.lastrowid, user_id)


    async def list_collections(self, viewer_id: int | None = None, mine: bool = False) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        clauses = []
        params: list[Any] = [viewer, viewer]
        if mine:
            clauses.append("mc.user_id=%s")
            params.append(viewer)
        else:
            clauses.append("(mc.is_public=1 OR mc.user_id=%s)")
            params.append(viewer)
        where = f"WHERE {' AND '.join(clauses)}"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
                           COUNT(mi.id) AS item_count,
                           MAX(mi.storage_path) AS cover_path,
                           MAX(mi.media_kind) AS cover_media_kind,
                           MAX(mi.id) AS cover_media_id,
                           MAX(CASE WHEN mi.is_adult=1 THEN 1 ELSE 0 END) AS cover_is_adult
                    FROM media_collections mc
                    JOIN users u ON u.id = mc.user_id
                    LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
                    LEFT JOIN media_items mi ON mi.id = mci.media_id
                     AND mi.deleted_at IS NULL
                     AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
                    {where}
                    GROUP BY mc.id
                    ORDER BY mc.updated_at DESC, mc.created_at DESC
                    LIMIT 100
                    """,
                    tuple(params),
                )
                return [self._decode_collection(row) for row in await cur.fetchall()]


    async def list_user_collections(self, user_id: int, viewer_id: int | None = None, limit: int = 12) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
                           COUNT(mi.id) AS item_count,
                           MAX(mi.storage_path) AS cover_path,
                           MAX(mi.media_kind) AS cover_media_kind,
                           MAX(mi.id) AS cover_media_id,
                           MAX(CASE WHEN mi.is_adult=1 THEN 1 ELSE 0 END) AS cover_is_adult
                    FROM media_collections mc
                    JOIN users u ON u.id = mc.user_id
                    LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
                    LEFT JOIN media_items mi ON mi.id = mci.media_id
                     AND mi.deleted_at IS NULL
                     AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
                    WHERE mc.user_id=%s AND (mc.is_public=1 OR mc.user_id=%s)
                    GROUP BY mc.id
                    ORDER BY mc.updated_at DESC, mc.created_at DESC
                    LIMIT %s
                    """,
                    (viewer_id or 0, viewer_id or 0, user_id, viewer_id or 0, max(1, min(limit, 60))),
                )
                return [self._decode_collection(row) for row in await cur.fetchall()]


    async def get_collection(self, collection_id: int, viewer_id: int | None = None) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
                           COUNT(mi.id) AS item_count,
                           MAX(mi.storage_path) AS cover_path,
                           MAX(mi.media_kind) AS cover_media_kind,
                           MAX(mi.id) AS cover_media_id,
                           MAX(CASE WHEN mi.is_adult=1 THEN 1 ELSE 0 END) AS cover_is_adult
                    FROM media_collections mc
                    JOIN users u ON u.id = mc.user_id
                    LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
                    LEFT JOIN media_items mi ON mi.id = mci.media_id
                     AND mi.deleted_at IS NULL
                     AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
                    WHERE mc.id=%s AND (mc.is_public=1 OR mc.user_id=%s)
                    GROUP BY mc.id
                    """,
                    (viewer_id or 0, viewer_id or 0, collection_id, viewer_id or 0),
                )
                row = await cur.fetchone()
                return self._decode_collection(row) if row else None


    async def set_collection_item(self, collection_id: int, media_id: int, user_id: int, saved: bool) -> dict[str, Any] | None:
        collection = await self.get_collection(collection_id, user_id)
        if not collection or int(collection["user_id"]) != int(user_id):
            return None
        media = await self.get_media(media_id, user_id)
        if not media or media.get("deleted_at"):
            return None
        if media.get("visibility") == "private" and int(media.get("user_id") or 0) != int(user_id):
            return None
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if saved:
                    await cur.execute(
                        "INSERT IGNORE INTO media_collection_items (collection_id, media_id) VALUES (%s, %s)",
                        (collection_id, media_id),
                    )
                else:
                    await cur.execute(
                        "DELETE FROM media_collection_items WHERE collection_id=%s AND media_id=%s",
                        (collection_id, media_id),
                    )
                await cur.execute("UPDATE media_collections SET updated_at=CURRENT_TIMESTAMP WHERE id=%s", (collection_id,))
        return await self.get_collection(collection_id, user_id)


    async def list_collection_media(self, collection_id: int, viewer_id: int | None = None) -> list[dict[str, Any]]:
        collection = await self.get_collection(collection_id, viewer_id)
        if not collection:
            return []
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
                    FROM media_collection_items mci
                    JOIN media_items m ON m.id = mci.media_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE mci.collection_id=%s
                      AND m.deleted_at IS NULL
                      AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id, mci.added_at
                    ORDER BY mci.added_at DESC
                    LIMIT 120
                    """,
                    (viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, collection_id, viewer_id or 0),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

