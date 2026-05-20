#!/usr/bin/env python3
from __future__ import annotations
import aiomysql

import argparse
import asyncio
import json
from pathlib import Path
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import load_settings
from app.database import GalleryDatabase


async def _resolve_user_id(db: GalleryDatabase, *, user_id: int | None, username: str | None) -> int:
    if user_id:
        return int(user_id)
    if not username:
        raise SystemExit("Provide --user-id or --username.")
    async with db.pool.acquire() as conn:
        async with conn.cursor(aiomysql.DictCursor) as cur:
            await cur.execute("SELECT id FROM users WHERE username=%s LIMIT 1", (username,))
            row = await cur.fetchone()
            if not row:
                raise SystemExit(f"No user found for username {username!r}.")
            if isinstance(row, dict):
                return int(row["id"])
            return int(row[0])


async def seed_training(*, user_id: int | None, username: str | None, limit: int, dry_run: bool) -> None:
    db = GalleryDatabase(load_settings())
    await db.connect()
    try:
        resolved_user_id = await _resolve_user_id(db, user_id=user_id, username=username)
        async with db.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT m.id, m.original_filename, m.title, m.tags, m.is_adult,
                           c.name AS category_name, sc.name AS subcategory_name
                    FROM media_items m
                    JOIN categories c ON c.id=m.category_id
                    LEFT JOIN subcategories sc ON sc.id=m.subcategory_id
                    WHERE m.user_id=%s AND m.deleted_at IS NULL
                    ORDER BY m.updated_at DESC, m.id DESC
                    LIMIT %s
                    """,
                    (resolved_user_id, max(1, min(int(limit or 500), 5000))),
                )
                rows = list(await cur.fetchall())

        created = 0
        for raw in rows:
            row: dict[str, Any] = dict(raw)
            tags = row.get("tags") or []
            if isinstance(tags, str):
                try:
                    tags = json.loads(tags or "[]")
                except json.JSONDecodeError:
                    tags = []
            corrected = {
                "title": row.get("title"),
                "category_name": row.get("category_name"),
                "subcategory_name": row.get("subcategory_name"),
                "tags": tags,
                "is_adult": bool(row.get("is_adult")),
            }
            source = {
                "original_filename": row.get("original_filename"),
                "title": row.get("title"),
                "category_name": row.get("category_name"),
                "subcategory_name": row.get("subcategory_name"),
                "tags": tags,
            }
            if dry_run:
                print(f"would_seed media_id={row.get('id')} title={row.get('title')!r}")
                continue
            example = await db.record_ai_vision_training_example(
                user_id=resolved_user_id,
                media_id=int(row["id"]),
                source=source,
                corrected=corrected,
                notes="Seeded from existing curated gallery metadata.",
            )
            if example:
                created += 1
        print(f"ai_vision_training_seeded={created} scanned={len(rows)} user_id={resolved_user_id} dry_run={dry_run}")
    finally:
        await db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed Image Gallery AI vision training examples from existing curated media metadata.")
    parser.add_argument("--user-id", type=int, default=None)
    parser.add_argument("--username", default=None)
    parser.add_argument("--limit", type=int, default=500)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(seed_training(user_id=args.user_id, username=args.username, limit=args.limit, dry_run=args.dry_run))


if __name__ == "__main__":
    main()
