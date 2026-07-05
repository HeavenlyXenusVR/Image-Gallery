"""Direct messages: send/list/decode."""

from typing import Any

import aiomysql


class MessagingMixin:
    async def send_direct_message(self, sender_id: int, recipient_id: int, body: str) -> dict[str, Any]:
        if int(sender_id) == int(recipient_id):
            raise ValueError("You cannot message yourself.")
        cleaned = " ".join(str(body or "").split())
        if not cleaned:
            raise ValueError("Message cannot be empty.")
        if len(cleaned) > 2000:
            raise ValueError("Message must be 2000 characters or fewer.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (recipient_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                await cur.execute(
                    "INSERT INTO user_messages (sender_id, recipient_id, body) VALUES (%s, %s, %s)",
                    (sender_id, recipient_id, cleaned),
                )
                message_id = cur.lastrowid
                await cur.execute(
                    """
                    SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile, u.last_seen_at
                    FROM user_messages msg
                    JOIN users u ON u.id=msg.sender_id
                    WHERE msg.id=%s
                    """,
                    (message_id,),
                )
                return self._decode_message(await cur.fetchone())


    async def list_message_threads(self, user_id: int) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT
                      other_user.id AS id,
                      other_user.id AS user_id,
                      other_user.username,
                      CASE WHEN other_user.public_profile=1 THEN other_user.display_name ELSE other_user.username END AS display_name,
                      CASE WHEN other_user.public_profile=1 THEN other_user.avatar_path ELSE NULL END AS avatar_path,
                      other_user.profile_color,
                      other_user.public_profile,
                      other_user.last_seen_at,
                      latest.id AS last_message_id,
                      latest.body AS last_message,
                      latest.created_at AS last_message_at,
                      latest.sender_id AS last_sender_id,
                      unread.unread_count
                    FROM (
                      SELECT
                        CASE WHEN sender_id=%s THEN recipient_id ELSE sender_id END AS other_id,
                        MAX(id) AS last_id
                      FROM user_messages
                      WHERE sender_id=%s OR recipient_id=%s
                      GROUP BY other_id
                    ) threads
                    JOIN user_messages latest ON latest.id=threads.last_id
                    JOIN users other_user ON other_user.id=threads.other_id
                    LEFT JOIN (
                      SELECT sender_id AS other_id, COUNT(*) AS unread_count
                      FROM user_messages
                      WHERE recipient_id=%s AND read_at IS NULL
                      GROUP BY sender_id
                    ) unread ON unread.other_id=threads.other_id
                    ORDER BY latest.created_at DESC
                    LIMIT 100
                    """,
                    (user_id, user_id, user_id, user_id),
                )
                return [self._decode_message_thread(row) for row in await cur.fetchall()]


    async def list_direct_messages(self, user_id: int, other_user_id: int, limit: int = 80) -> list[dict[str, Any]]:
        if int(user_id) == int(other_user_id):
            raise ValueError("Pick another user to view messages.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (other_user_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                await cur.execute(
                    """
                    UPDATE user_messages
                    SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP)
                    WHERE sender_id=%s AND recipient_id=%s AND read_at IS NULL
                    """,
                    (other_user_id, user_id),
                )
                await cur.execute(
                    """
                    SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile, u.last_seen_at
                    FROM user_messages msg
                    JOIN users u ON u.id=msg.sender_id
                    WHERE (msg.sender_id=%s AND msg.recipient_id=%s)
                       OR (msg.sender_id=%s AND msg.recipient_id=%s)
                    ORDER BY msg.created_at DESC, msg.id DESC
                    LIMIT %s
                    """,
                    (user_id, other_user_id, other_user_id, user_id, max(1, min(limit, 200))),
                )
                rows = list(await cur.fetchall())
                rows.reverse()
                return [self._decode_message(row) for row in rows]


    def _decode_message(self, row: dict[str, Any] | None) -> dict[str, Any]:
        if not row:
            return {}
        item = dict(row)
        for key in ("created_at", "read_at"):
            value = item.get(key)
            if hasattr(value, "isoformat"):
                item[key] = value.isoformat()
        item["public_profile"] = bool(item.get("public_profile"))
        if "last_seen_at" in item:
            item["is_online"] = self._is_recently_seen(item.get("last_seen_at"))
        return item


    def _decode_message_thread(self, row: dict[str, Any]) -> dict[str, Any]:
        item = dict(row)
        if hasattr(item.get("last_message_at"), "isoformat"):
            item["last_message_at"] = item["last_message_at"].isoformat()
        item["public_profile"] = bool(item.get("public_profile"))
        if "last_seen_at" in item:
            item["is_online"] = self._is_recently_seen(item.get("last_seen_at"))
        item["unread_count"] = int(item.get("unread_count") or 0)
        return item

