"""Public profiles, follows, friend requests/friends, and user search."""

import json
from decimal import Decimal
from typing import Any

from . import pg_compat as aiomysql

from ._shared import DEFAULT_USER_SETTINGS, normalize_username


class ProfileFriendsMixin:
    async def get_public_profile(self, username: str, viewer_id: int | None = None) -> dict[str, Any] | None:
        username = normalize_username(username)
        viewer = viewer_id or 0
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.featured_tags ELSE NULL END AS featured_tags,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.website_url ELSE NULL END AS website_url,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.location_label ELSE NULL END AS location_label,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.user_settings ELSE NULL END AS user_settings,
                           u.avatar_file_id, u.profile_color, u.public_profile, u.show_liked_count,
                           u.show_collections, u.show_recent_uploads, u.show_friends, u.created_at,
                           u.last_seen_at,
                           COUNT(DISTINCT m.id) AS media_count,
                           COALESCE(SUM(CASE WHEN m.deleted_at IS NULL AND m.visibility='public' THEN m.downloads ELSE 0 END), 0) AS download_count,
                           COUNT(DISTINCT (ml.user_id, ml.media_id)) AS like_count,
                           COUNT(DISTINCT f1.follower_id) AS follower_count,
                           COUNT(DISTINCT f2.followed_id) AS following_count,
                           COUNT(DISTINCT CASE
                               WHEN fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id)
                               THEN fr.id END) AS friend_count,
                           MAX(CASE WHEN f3.follower_id=%s THEN 1 ELSE 0 END) AS followed_by_me
                    FROM users u
                    LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    LEFT JOIN media_likes ml ON ml.media_id=m.id
                    LEFT JOIN user_follows f1 ON f1.followed_id=u.id
                    LEFT JOIN user_follows f2 ON f2.follower_id=u.id
                    LEFT JOIN user_follows f3 ON f3.followed_id=u.id AND f3.follower_id=%s
                    LEFT JOIN friend_requests fr ON fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id)
                    WHERE u.username=%s
                    GROUP BY u.id
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, username),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                row["public_profile"] = bool(row.get("public_profile"))
                row["show_liked_count"] = bool(row.get("show_liked_count"))
                row["show_collections"] = bool(row.get("show_collections"))
                row["show_recent_uploads"] = bool(row.get("show_recent_uploads"))
                row["show_friends"] = bool(row.get("show_friends"))
                row["followed_by_me"] = bool(row.get("followed_by_me"))
                row["is_online"] = self._is_recently_seen(row.get("last_seen_at"))
                tags = row.get("featured_tags")
                if isinstance(tags, str):
                    try:
                        row["featured_tags"] = json.loads(tags) or []
                    except json.JSONDecodeError:
                        row["featured_tags"] = []
                elif tags is None:
                    row["featured_tags"] = []
                raw_settings = row.get("user_settings")
                settings = dict(DEFAULT_USER_SETTINGS)
                if isinstance(raw_settings, str):
                    try:
                        settings.update(json.loads(raw_settings) or {})
                    except json.JSONDecodeError:
                        pass
                elif isinstance(raw_settings, dict):
                    settings.update(raw_settings)
                row["user_settings"] = settings
                for k in ("media_count", "download_count", "like_count", "follower_count", "following_count", "friend_count"):
                    if isinstance(row.get(k), Decimal):
                        row[k] = int(row[k])
                row["friend_status"] = await self.friend_status(viewer, int(row["id"])) if viewer else "none"
                return row


    async def set_follow(self, follower_id: int, followed_id: int, following: bool) -> dict[str, Any] | None:
        if follower_id == followed_id:
            raise ValueError("You cannot follow yourself.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (followed_id,))
                if not await cur.fetchone():
                    return None
                if following:
                    await cur.execute("INSERT INTO user_follows (follower_id, followed_id) VALUES (%s, %s) ON CONFLICT (follower_id, followed_id) DO NOTHING", (follower_id, followed_id))
                else:
                    await cur.execute("DELETE FROM user_follows WHERE follower_id=%s AND followed_id=%s", (follower_id, followed_id))
                await cur.execute("SELECT COUNT(*) AS n FROM user_follows WHERE followed_id=%s", (followed_id,))
                followers = int((await cur.fetchone())["n"] or 0)
                return {"followed_id": followed_id, "following": bool(following), "follower_count": followers}


    async def friend_status(self, viewer_id: int | None, user_id: int) -> str:
        if not viewer_id:
            return "none"
        if int(viewer_id) == int(user_id):
            return "self"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT requester_id, addressee_id, status
                    FROM friend_requests
                    WHERE (requester_id=%s AND addressee_id=%s)
                       OR (requester_id=%s AND addressee_id=%s)
                    ORDER BY CASE status
                        WHEN 'accepted' THEN 1
                        WHEN 'pending' THEN 2
                        WHEN 'declined' THEN 3
                        WHEN 'cancelled' THEN 4
                        ELSE 5
                    END, created_at DESC
                    LIMIT 1
                    """,
                    (viewer_id, user_id, user_id, viewer_id),
                )
                row = await cur.fetchone()
        if not row or row.get("status") in {"declined", "cancelled"}:
            return "none"
        if row["status"] == "accepted":
            return "friends"
        return "pending_out" if int(row["requester_id"]) == int(viewer_id) else "pending_in"


    async def send_friend_request(self, requester_id: int, addressee_id: int) -> dict[str, Any]:
        if requester_id == addressee_id:
            raise ValueError("You cannot friend yourself.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (addressee_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                await cur.execute(
                    """
                    SELECT * FROM friend_requests
                    WHERE (requester_id=%s AND addressee_id=%s)
                       OR (requester_id=%s AND addressee_id=%s)
                    ORDER BY CASE status
                        WHEN 'accepted' THEN 1
                        WHEN 'pending' THEN 2
                        WHEN 'declined' THEN 3
                        WHEN 'cancelled' THEN 4
                        ELSE 5
                    END, created_at DESC
                    LIMIT 1
                    """,
                    (requester_id, addressee_id, addressee_id, requester_id),
                )
                existing = await cur.fetchone()
                if existing and existing["status"] == "accepted":
                    return {"status": "friends", "request": existing}
                if existing and existing["status"] == "pending":
                    if int(existing["requester_id"]) == int(addressee_id):
                        await cur.execute(
                            "UPDATE friend_requests SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=%s",
                            (existing["id"],),
                        )
                        existing["status"] = "accepted"
                        return {"status": "friends", "request": existing}
                    return {"status": "pending_out", "request": existing}
                if existing:
                    await cur.execute(
                        """
                        UPDATE friend_requests
                        SET requester_id=%s, addressee_id=%s, status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL
                        WHERE id=%s
                        """,
                        (requester_id, addressee_id, existing["id"]),
                    )
                    request_id = existing["id"]
                else:
                    await cur.execute(
                        "INSERT INTO friend_requests (requester_id, addressee_id) VALUES (%s, %s) RETURNING id",
                        (requester_id, addressee_id),
                    )
                    request_id = (await cur.fetchone())["id"]
                await cur.execute("SELECT * FROM friend_requests WHERE id=%s", (request_id,))
                return {"status": "pending_out", "request": await cur.fetchone()}


    async def respond_friend_request(self, user_id: int, request_id: int, action: str) -> dict[str, Any] | None:
        status = {"accept": "accepted", "decline": "declined", "cancel": "cancelled"}.get(action)
        if not status:
            raise ValueError("Action must be accept, decline, or cancel.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                if action == "cancel":
                    await cur.execute(
                        "SELECT * FROM friend_requests WHERE id=%s AND requester_id=%s AND status='pending'",
                        (request_id, user_id),
                    )
                else:
                    await cur.execute(
                        "SELECT * FROM friend_requests WHERE id=%s AND addressee_id=%s AND status='pending'",
                        (request_id, user_id),
                    )
                row = await cur.fetchone()
                if not row:
                    return None
                await cur.execute(
                    "UPDATE friend_requests SET status=%s, responded_at=CURRENT_TIMESTAMP WHERE id=%s",
                    (status, request_id),
                )
                row["status"] = status
                return row


    async def list_friend_requests(self, user_id: int, mode: str = "incoming") -> list[dict[str, Any]]:
        if mode == "outgoing":
            own_col, other_col = "requester_id", "addressee_id"
        else:
            own_col, other_col = "addressee_id", "requester_id"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT fr.*, u.id AS user_id, u.username, u.display_name, u.bio, u.avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at
                    FROM friend_requests fr
                    JOIN users u ON u.id=fr.{other_col}
                    WHERE fr.{own_col}=%s AND fr.status='pending'
                    ORDER BY fr.created_at DESC
                    LIMIT 100
                    """,
                    (user_id,),
                )
                return [self._decode_user_request(row) for row in await cur.fetchall()]


    async def list_friends(self, user_id: int, viewer_id: int | None = None, limit: int = 80) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at, fr.responded_at AS friended_at
                    FROM friend_requests fr
                    JOIN users u ON u.id = CASE WHEN fr.requester_id=%s THEN fr.addressee_id ELSE fr.requester_id END
                    WHERE fr.status='accepted' AND (fr.requester_id=%s OR fr.addressee_id=%s)
                    ORDER BY fr.responded_at DESC, fr.created_at DESC
                    LIMIT %s
                    """,
                    (viewer, viewer, viewer, user_id, user_id, user_id, max(1, min(limit, 200))),
                )
                return [self._decode_user(row) for row in await cur.fetchall()]


    async def search_users(self, query: str, viewer_id: int | None = None, limit: int = 30) -> list[dict[str, Any]]:
        query = " ".join(str(query or "").strip().split())[:80]
        needle = f"%{query}%"
        viewer = int(viewer_id or 0)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
                           CASE WHEN u.public_profile=true OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.show_liked_count, u.show_collections,
                           u.show_recent_uploads, u.show_friends, u.adult_content_consent, u.email_verified_at,
                           u.last_seen_at,
                           COUNT(DISTINCT m.id) AS media_count,
                           COUNT(DISTINCT f.follower_id) AS follower_count,
                           MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me
                    FROM users u
                    LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND m.visibility='public'
                    LEFT JOIN user_follows f ON f.followed_id=u.id
                    LEFT JOIN user_follows mine ON mine.followed_id=u.id AND mine.follower_id=%s
                    WHERE %s = ''
                       OR u.username LIKE %s
                       OR (CASE WHEN u.public_profile=true OR u.id=%s THEN u.display_name ELSE NULL END) LIKE %s
                       OR (CASE WHEN u.public_profile=true OR u.id=%s THEN u.bio ELSE NULL END) LIKE %s
                       OR (CASE WHEN u.public_profile=true OR u.id=%s THEN u.profile_headline ELSE NULL END) LIKE %s
                    GROUP BY u.id
                    ORDER BY (u.username=%s) DESC, follower_count DESC, media_count DESC, u.created_at DESC
                    LIMIT %s
                    """,
                    (
                        viewer,
                        viewer,
                        viewer,
                        viewer,
                        viewer,
                        query,
                        needle,
                        viewer,
                        needle,
                        viewer,
                        needle,
                        viewer,
                        needle,
                        query,
                        max(1, min(limit, 60)),
                    ),
                )
                users = []
                for row in await cur.fetchall():
                    row = self._decode_user(row)
                    row["media_count"] = int(row.get("media_count") or 0)
                    row["follower_count"] = int(row.get("follower_count") or 0)
                    row["followed_by_me"] = bool(row.get("followed_by_me"))
                    row["friend_status"] = await self.friend_status(viewer, int(row["id"])) if viewer else "none"
                    users.append(row)
                return users


    async def set_block(self, actor_id: int, target_id: int, kind: str, active: bool) -> dict[str, Any]:
        if kind not in {"block", "mute"}:
            raise ValueError("kind must be block or mute.")
        if int(actor_id) == int(target_id):
            raise ValueError("You cannot block or mute yourself.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (target_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                if active:
                    await cur.execute(
                        "INSERT INTO user_blocks (blocker_id, blocked_id, kind) VALUES (%s, %s, %s) ON CONFLICT (blocker_id, blocked_id, kind) DO NOTHING",
                        (actor_id, target_id, kind),
                    )
                else:
                    await cur.execute(
                        "DELETE FROM user_blocks WHERE blocker_id=%s AND blocked_id=%s AND kind=%s",
                        (actor_id, target_id, kind),
                    )
                return {"blocked_id": int(target_id), "kind": kind, "active": bool(active)}


    async def list_blocks(self, user_id: int) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT ub.kind, ub.created_at, u.id, u.username, u.display_name, u.avatar_path, u.profile_color
                    FROM user_blocks ub
                    JOIN users u ON u.id = ub.blocked_id
                    WHERE ub.blocker_id=%s
                    ORDER BY ub.created_at DESC
                    """,
                    (user_id,),
                )
                rows = []
                for row in await cur.fetchall():
                    kind = row.pop("kind")
                    created_at = row.pop("created_at")
                    rows.append({"kind": kind, "created_at": created_at, "user": self._decode_user(row)})
                return rows


    async def is_blocked_either_way(self, user_a: int, user_b: int) -> bool:
        if not user_a or not user_b:
            return False
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    SELECT 1 FROM user_blocks
                    WHERE kind='block' AND (
                        (blocker_id=%s AND blocked_id=%s) OR (blocker_id=%s AND blocked_id=%s)
                    )
                    LIMIT 1
                    """,
                    (user_a, user_b, user_b, user_a),
                )
                return bool(await cur.fetchone())


    async def resolve_usernames(self, usernames: list[str]) -> dict[str, int]:
        cleaned = sorted({str(name or "").strip().lower() for name in usernames if str(name or "").strip()})
        if not cleaned:
            return {}
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                placeholders = ", ".join(["%s"] * len(cleaned))
                await cur.execute(
                    f"SELECT id, username FROM users WHERE LOWER(username) IN ({placeholders})",
                    tuple(cleaned),
                )
                return {row["username"].lower(): int(row["id"]) for row in await cur.fetchall()}


    async def is_muted(self, viewer_id: int | None, author_id: int) -> bool:
        if not viewer_id or int(viewer_id) == int(author_id):
            return False
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "SELECT 1 FROM user_blocks WHERE blocker_id=%s AND blocked_id=%s AND kind='mute' LIMIT 1",
                    (viewer_id, author_id),
                )
                return bool(await cur.fetchone())

