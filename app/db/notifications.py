"""In-app notifications: follows, friend requests/accepts, comments, and messages."""

from typing import Any

import aiomysql

NOTIFICATION_KINDS = {
    "follow", "friend_request", "friend_accept", "comment", "message",
    "mention", "reply", "reaction", "saved_search",
}


class NotificationsMixin:
    async def create_notification(
        self,
        recipient_id: int,
        actor_id: int | None,
        kind: str,
        *,
        media_id: int | None = None,
        preview: str | None = None,
    ) -> None:
        if kind not in NOTIFICATION_KINDS:
            raise ValueError(f"Invalid notification kind: {kind}")
        if actor_id is not None and int(actor_id) == int(recipient_id):
            return  # never notify a user about their own action
        preview = (preview or "").strip()[:160] or None
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "INSERT INTO notifications (recipient_id, actor_id, kind, media_id, preview) VALUES (%s, %s, %s, %s, %s)",
                    (recipient_id, actor_id, kind, media_id, preview),
                )

    async def list_notifications(self, user_id: int, limit: int = 30, offset: int = 0) -> list[dict[str, Any]]:
        limit = max(1, min(100, int(limit)))
        offset = max(0, int(offset))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT n.id, n.kind, n.media_id, n.preview, n.read_at, n.created_at,
                           n.actor_id, a.username AS actor_username,
                           COALESCE(a.display_name, a.username) AS actor_display_name,
                           a.avatar_path AS actor_avatar_path, a.avatar_file_id AS actor_avatar_file_id,
                           m.title AS media_title
                    FROM notifications n
                    LEFT JOIN users a ON a.id = n.actor_id
                    LEFT JOIN media_items m ON m.id = n.media_id
                    WHERE n.recipient_id = %s
                    ORDER BY n.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (user_id, limit, offset),
                )
                return list(await cur.fetchall())

    async def count_unread_notifications(self, user_id: int) -> int:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "SELECT COUNT(*) FROM notifications WHERE recipient_id = %s AND read_at IS NULL",
                    (user_id,),
                )
                row = await cur.fetchone()
                return int(row[0]) if row else 0

    async def mark_notification_read(self, notification_id: int, user_id: int) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE notifications SET read_at = CURRENT_TIMESTAMP WHERE id = %s AND recipient_id = %s AND read_at IS NULL",
                    (notification_id, user_id),
                )

    async def mark_all_notifications_read(self, user_id: int) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE notifications SET read_at = CURRENT_TIMESTAMP WHERE recipient_id = %s AND read_at IS NULL",
                    (user_id,),
                )
