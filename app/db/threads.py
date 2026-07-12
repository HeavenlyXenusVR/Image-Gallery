"""Group messaging: threads with 2+ members, membership checks, and thread messages.

Additive only — these tables sit alongside user_messages (1:1 DMs) and never touch it.
Every read/write here must verify the caller is a member of the thread before returning
or mutating anything.
"""

from typing import Any

import aiomysql


class ThreadsMixin:
    async def _is_thread_member(self, thread_id: int, user_id: int) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "SELECT 1 FROM message_thread_members WHERE thread_id=%s AND user_id=%s",
                    (thread_id, user_id),
                )
                return bool(await cur.fetchone())


    async def create_thread(self, creator_id: int, member_ids: list[int], name: str | None) -> dict[str, Any]:
        clean_name = self._clean_text(name, 120) if name else None
        members = {int(creator_id)}
        for raw in member_ids or []:
            try:
                members.add(int(raw))
            except (TypeError, ValueError):
                continue
        if len(members) < 2:
            raise ValueError("A group needs at least one other member.")
        if len(members) > 50:
            raise ValueError("A group can have at most 50 members.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                placeholders = ", ".join(["%s"] * len(members))
                await cur.execute(f"SELECT id FROM users WHERE id IN ({placeholders})", tuple(members))
                found_ids = {int(row["id"]) for row in await cur.fetchall()}
                missing = members - found_ids
                if missing:
                    raise ValueError("One or more members were not found.")
                await conn.begin()
                try:
                    await cur.execute(
                        "INSERT INTO message_threads (name, created_by) VALUES (%s, %s)",
                        (clean_name, creator_id),
                    )
                    thread_id = int(cur.lastrowid)
                    await cur.executemany(
                        "INSERT INTO message_thread_members (thread_id, user_id) VALUES (%s, %s)",
                        [(thread_id, member_id) for member_id in members],
                    )
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise
        return await self.get_thread(thread_id, creator_id)


    async def get_thread(self, thread_id: int, user_id: int) -> dict[str, Any] | None:
        if not await self._is_thread_member(thread_id, user_id):
            return None
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT t.id, t.name, t.created_by, t.created_at
                    FROM message_threads t
                    WHERE t.id=%s
                    """,
                    (thread_id,),
                )
                thread = await cur.fetchone()
                if not thread:
                    return None
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at
                    FROM message_thread_members mtm
                    JOIN users u ON u.id = mtm.user_id
                    WHERE mtm.thread_id=%s
                    ORDER BY mtm.joined_at ASC
                    """,
                    (thread_id,),
                )
                members = [self._decode_user(row) for row in await cur.fetchall()]
        item = dict(thread)
        item["members"] = members
        return item


    async def list_my_threads(self, user_id: int) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT t.id, t.name, t.created_by, t.created_at,
                           latest.body AS last_message, latest.created_at AS last_message_at, latest.sender_id AS last_sender_id
                    FROM message_thread_members mine
                    JOIN message_threads t ON t.id = mine.thread_id
                    LEFT JOIN (
                        SELECT tm1.thread_id, tm1.body, tm1.created_at, tm1.sender_id
                        FROM thread_messages tm1
                        JOIN (SELECT thread_id, MAX(id) AS max_id FROM thread_messages GROUP BY thread_id) latest_ids
                          ON latest_ids.thread_id = tm1.thread_id AND latest_ids.max_id = tm1.id
                    ) latest ON latest.thread_id = t.id
                    WHERE mine.user_id=%s
                    ORDER BY COALESCE(latest.created_at, t.created_at) DESC
                    LIMIT 100
                    """,
                    (user_id,),
                )
                threads = list(await cur.fetchall())
                if not threads:
                    return []
                thread_ids = [int(row["id"]) for row in threads]
                placeholders = ", ".join(["%s"] * len(thread_ids))
                await cur.execute(
                    f"""
                    SELECT mtm.thread_id, u.id, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at
                    FROM message_thread_members mtm
                    JOIN users u ON u.id = mtm.user_id
                    WHERE mtm.thread_id IN ({placeholders})
                    ORDER BY mtm.joined_at ASC
                    """,
                    tuple(thread_ids),
                )
                members_by_thread: dict[int, list[dict[str, Any]]] = {}
                for row in await cur.fetchall():
                    thread_id = int(row.pop("thread_id"))
                    members_by_thread.setdefault(thread_id, []).append(self._decode_user(dict(row)))
        results = []
        for row in threads:
            item = dict(row)
            if hasattr(item.get("last_message_at"), "isoformat"):
                item["last_message_at"] = item["last_message_at"].isoformat()
            if hasattr(item.get("created_at"), "isoformat"):
                item["created_at"] = item["created_at"].isoformat()
            members = members_by_thread.get(int(item["id"]), [])
            item["members"] = members
            other_members = [member for member in members if int(member["id"]) != int(user_id)]
            item["display_name"] = item.get("name") or ", ".join(
                member.get("display_name") or member.get("username") or "Someone" for member in other_members
            ) or "Group"
            results.append(item)
        return results


    async def list_thread_messages(self, thread_id: int, user_id: int, limit: int = 80) -> list[dict[str, Any]]:
        if not await self._is_thread_member(thread_id, user_id):
            raise PermissionError("You are not a member of this group.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT tm.*, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS user_avatar_path
                    FROM thread_messages tm
                    JOIN users u ON u.id = tm.sender_id
                    WHERE tm.thread_id=%s
                    ORDER BY tm.created_at DESC, tm.id DESC
                    LIMIT %s
                    """,
                    (thread_id, max(1, min(int(limit or 80), 200))),
                )
                rows = list(await cur.fetchall())
                rows.reverse()
        for row in rows:
            if hasattr(row.get("created_at"), "isoformat"):
                row["created_at"] = row["created_at"].isoformat()
        return rows


    async def post_thread_message(self, thread_id: int, user_id: int, body: str) -> dict[str, Any]:
        if not await self._is_thread_member(thread_id, user_id):
            raise PermissionError("You are not a member of this group.")
        cleaned = " ".join(str(body or "").split())
        if not cleaned:
            raise ValueError("Message cannot be empty.")
        if len(cleaned) > 2000:
            raise ValueError("Message must be 2000 characters or fewer.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "INSERT INTO thread_messages (thread_id, sender_id, body) VALUES (%s, %s, %s)",
                    (thread_id, user_id, cleaned),
                )
                message_id = cur.lastrowid
                await cur.execute(
                    """
                    SELECT tm.*, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS user_avatar_path
                    FROM thread_messages tm
                    JOIN users u ON u.id = tm.sender_id
                    WHERE tm.id=%s
                    """,
                    (message_id,),
                )
                row = await cur.fetchone()
        if row and hasattr(row.get("created_at"), "isoformat"):
            row["created_at"] = row["created_at"].isoformat()
        return row


    async def list_thread_member_ids(self, thread_id: int) -> list[int]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SELECT user_id FROM message_thread_members WHERE thread_id=%s", (thread_id,))
                return [int(row[0]) for row in await cur.fetchall()]
