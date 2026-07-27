"""Category/subcategory CRUD and id/name resolution."""

from typing import Any

from . import pg_compat as aiomysql

from ._shared import (
    MAX_MEDIA_SUBCATEGORIES,
    MEDIA_KINDS,
    clean_subcategory_name,
    normalize_subcategory_ids,
    normalize_subcategory_names,
    slugify,
)


class CategoriesMixin:
    async def create_category(self, name: str, media_kind: str, user_id: int | None) -> dict[str, Any]:
        name = " ".join(str(name or "").strip().split())[:80]
        if not name:
            raise ValueError("Category name is required.")
        if media_kind not in MEDIA_KINDS:
            raise ValueError("Category type must be image, video, or mixed.")
        base_slug = slugify(name)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT * FROM categories WHERE name=%s OR slug=%s", (name, base_slug))
                existing = await cur.fetchone()
                if existing:
                    return existing
                await cur.execute(
                    "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
                    (name, base_slug, media_kind, user_id),
                )
                new_id = (await cur.fetchone())["id"]
                await cur.execute("SELECT * FROM categories WHERE id=%s", (new_id,))
                return await cur.fetchone()


    async def create_subcategory(self, category_id: int, name: str, user_id: int | None) -> dict[str, Any]:
        name = clean_subcategory_name(name)
        if not name:
            raise ValueError("Subcategory name is required.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM categories WHERE id=%s", (category_id,))
                if not await cur.fetchone():
                    raise ValueError("Choose a valid category before creating a subcategory.")
                slug = slugify(name)
                await cur.execute(
                    "SELECT * FROM subcategories WHERE category_id=%s AND (name=%s OR slug=%s) LIMIT 1",
                    (category_id, name, slug),
                )
                existing = await cur.fetchone()
                if existing:
                    return existing
                await cur.execute(
                    """
                    INSERT INTO subcategories (category_id, name, slug, created_by)
                    VALUES (%s, %s, %s, %s)
                    RETURNING id
                    """,
                    (category_id, name, slug, user_id),
                )
                new_id = (await cur.fetchone())["id"]
                await cur.execute("SELECT * FROM subcategories WHERE id=%s", (new_id,))
                return await cur.fetchone()


    async def resolve_subcategory_ids(
        self,
        *,
        category_id: int,
        subcategory_ids: list[int] | None = None,
        subcategory_names: list[str] | None = None,
        user_id: int | None = None,
    ) -> list[int]:
        normalized_category_id = int(category_id or 0)
        if normalized_category_id <= 0:
            raise ValueError("Choose a valid category.")
        resolved_ids = normalize_subcategory_ids(subcategory_ids)
        pending_names = normalize_subcategory_names(subcategory_names)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM categories WHERE id=%s", (normalized_category_id,))
                if not await cur.fetchone():
                    raise ValueError("Category does not exist.")
                validated_ids: list[int] = []
                for subcategory_id in resolved_ids:
                    await cur.execute(
                        "SELECT id FROM subcategories WHERE id=%s AND category_id=%s",
                        (subcategory_id, normalized_category_id),
                    )
                    if not await cur.fetchone():
                        raise ValueError("Subcategory does not belong to that category.")
                    validated_ids.append(int(subcategory_id))
        resolved_ids = validated_ids
        if pending_names:
            for name in pending_names:
                subcategory = await self.create_subcategory(normalized_category_id, name, user_id)
                candidate_id = int(subcategory["id"])
                if candidate_id not in resolved_ids:
                    resolved_ids.append(candidate_id)
                if len(resolved_ids) >= MAX_MEDIA_SUBCATEGORIES:
                    break
        return resolved_ids[:MAX_MEDIA_SUBCATEGORIES]


    async def resolve_category_ids(
        self,
        *,
        category_id: int,
        subcategory_id: int | None = None,
        subcategory_name: str | None = None,
        user_id: int | None = None,
    ) -> tuple[int, int | None]:
        normalized_category_id = int(category_id or 0)
        if normalized_category_id <= 0:
            raise ValueError("Choose a valid category.")
        subcategory_ids = await self.resolve_subcategory_ids(
            category_id=normalized_category_id,
            subcategory_ids=[subcategory_id] if subcategory_id else [],
            subcategory_names=[subcategory_name] if subcategory_name else [],
            user_id=user_id,
        )
        return normalized_category_id, (subcategory_ids[0] if subcategory_ids else None)


    async def set_media_dimensions(self, media_id: int, width: int, height: int) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE media_items SET image_width=%s, image_height=%s WHERE id=%s",
                    (int(width), int(height), int(media_id)),
                )
                await conn.commit()


    async def set_media_subcategories(self, media_id: int, subcategory_ids: list[int] | None) -> None:
        normalized_ids = normalize_subcategory_ids(subcategory_ids)
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await conn.begin()
                try:
                    await self._write_media_subcategories(cur, int(media_id), normalized_ids)
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise


    async def _write_media_subcategories(self, cur: aiomysql.Cursor, media_id: int, subcategory_ids: list[int] | None) -> None:
        normalized_ids = normalize_subcategory_ids(subcategory_ids)
        primary_subcategory_id = normalized_ids[0] if normalized_ids else None
        await cur.execute("UPDATE media_items SET subcategory_id=%s WHERE id=%s", (primary_subcategory_id, int(media_id)))
        await cur.execute("DELETE FROM media_item_subcategories WHERE media_id=%s", (int(media_id),))
        for position, subcategory_id in enumerate(normalized_ids, 1):
            await cur.execute(
                """
                INSERT INTO media_item_subcategories (media_id, subcategory_id, position)
                VALUES (%s, %s, %s)
                """,
                (int(media_id), int(subcategory_id), position),
            )


    async def list_categories(self) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT c.*, COUNT(m.id) AS media_count
                    FROM categories c
                    LEFT JOIN media_items m ON m.category_id = c.id AND m.deleted_at IS NULL
                    GROUP BY c.id
                    ORDER BY c.name
                    """
                )
                categories = list(await cur.fetchall())
                await cur.execute(
                    """
                    SELECT s.*, COUNT(m.id) AS media_count
                    FROM subcategories s
                    LEFT JOIN media_item_subcategories ms ON ms.subcategory_id = s.id
                    LEFT JOIN media_items m ON m.id = ms.media_id AND m.deleted_at IS NULL
                    GROUP BY s.id
                    ORDER BY s.name
                    """
                )
                subcategories = list(await cur.fetchall())
        grouped: dict[int, list[dict[str, Any]]] = {}
        for row in subcategories:
            grouped.setdefault(int(row["category_id"]), []).append(row)
        for row in categories:
            row["subcategories"] = grouped.get(int(row["id"]), [])
        return categories

