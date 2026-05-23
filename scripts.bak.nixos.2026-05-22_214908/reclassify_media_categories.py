#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter
from pathlib import Path

import pymysql

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from app.classification import infer_category_pair


MANUAL_OVERRIDES: dict[int, tuple[str, str | None]] = {
    # Reviewed from DB-backed visual contact sheets where titles/filenames were too generic.
    45: ("My Little Pony", "Mane 6"),
    48: ("My Little Pony", "Fluttershy"),
    91: ("My Little Pony", "Mane 6"),
    94: ("My Little Pony", "Equestria Girls"),
    95: ("My Little Pony", "Mane 6"),
    98: ("My Little Pony", "Equestria Girls"),
}


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def env_or_file(name: str, env_file: dict[str, str], default: str) -> str:
    value = os.getenv(name)
    if value is not None and str(value).strip():
        return str(value).strip()
    return env_file.get(name, default).strip()


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:90] or "category"


def ensure_category(cur: pymysql.cursors.Cursor, category_name: str, media_kind: str) -> int:
    cur.execute("SELECT id FROM categories WHERE name=%s LIMIT 1", (category_name,))
    row = cur.fetchone()
    if row:
        return int(row[0])
    cur.execute(
        "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, NULL)",
        (category_name, slugify(category_name), "video" if media_kind == "video" else "image"),
    )
    return int(cur.lastrowid)


def ensure_subcategory(cur: pymysql.cursors.Cursor, category_id: int, subcategory_name: str | None) -> int | None:
    normalized = " ".join(str(subcategory_name or "").strip().split())[:80]
    if not normalized:
        return None
    cur.execute("SELECT id FROM subcategories WHERE category_id=%s AND name=%s LIMIT 1", (category_id, normalized))
    row = cur.fetchone()
    if row:
        return int(row[0])
    cur.execute(
        "INSERT INTO subcategories (category_id, name, slug, created_by) VALUES (%s, %s, %s, NULL)",
        (category_id, normalized, slugify(normalized)),
    )
    return int(cur.lastrowid)


def main() -> int:
    parser = argparse.ArgumentParser(description="Reclassify Image Gallery media into main categories and subcategories.")
    parser.add_argument("--limit", type=int, default=0, help="Only inspect the first N active rows.")
    parser.add_argument("--apply", action="store_true", help="Write the category and subcategory fixes to MariaDB.")
    args = parser.parse_args()

    env_file = load_env_file(PROJECT_ROOT / ".env")
    conn = pymysql.connect(
        host=env_or_file("GALLERY_DB_HOST", env_file, "127.0.0.1"),
        port=int(env_or_file("GALLERY_DB_PORT", env_file, "3306")),
        user=env_or_file("GALLERY_DB_USER", env_file, "botuser"),
        password=env_or_file("GALLERY_DB_PASSWORD", env_file, ""),
        database=env_or_file("GALLERY_DB_SCHEMA", env_file, "image_gallery"),
        charset="utf8mb4",
        autocommit=False,
    )

    changed = 0
    unchanged = 0
    by_main: Counter[str] = Counter()
    by_subcategory: Counter[str] = Counter()
    samples: list[str] = []

    try:
        with conn.cursor() as cur:
            sql = """
                SELECT m.id, m.title, m.original_filename, m.media_kind,
                       c.id AS category_id, c.name AS category_name,
                       s.id AS subcategory_id, s.name AS subcategory_name
                FROM media_items m
                JOIN categories c ON c.id = m.category_id
                LEFT JOIN subcategories s ON s.id = m.subcategory_id
                WHERE m.deleted_at IS NULL
                ORDER BY m.id
            """
            if args.limit > 0:
                sql += " LIMIT %s"
                cur.execute(sql, (args.limit,))
            else:
                cur.execute(sql)
            rows = cur.fetchall()

            for row in rows:
                media_id, title, filename, media_kind, category_id, category_name, subcategory_id, subcategory_name = row
                next_category, next_subcategory = MANUAL_OVERRIDES.get(
                    int(media_id),
                    infer_category_pair(
                        filename=str(filename or title or f"media-{media_id}"),
                        media_kind=str(media_kind or "image"),
                        title=str(title or ""),
                        current_category=str(category_name or ""),
                    ),
                )
                next_category_id = ensure_category(cur, next_category, str(media_kind or "image"))
                next_subcategory_id = ensure_subcategory(cur, next_category_id, next_subcategory)

                same_category = int(category_id) == int(next_category_id)
                same_subcategory = int(subcategory_id or 0) == int(next_subcategory_id or 0)
                if same_category and same_subcategory:
                    unchanged += 1
                    continue

                changed += 1
                by_main[next_category] += 1
                if next_subcategory:
                    by_subcategory[next_subcategory] += 1
                if len(samples) < 25:
                    before = f"{category_name}{f' / {subcategory_name}' if subcategory_name else ''}"
                    after = f"{next_category}{f' / {next_subcategory}' if next_subcategory else ''}"
                    samples.append(f"{media_id}: {title} :: {before} -> {after}")
                if args.apply:
                    cur.execute(
                        "UPDATE media_items SET category_id=%s, subcategory_id=%s WHERE id=%s",
                        (next_category_id, next_subcategory_id, media_id),
                    )

            if args.apply:
                conn.commit()
            else:
                conn.rollback()
    finally:
        conn.close()

    print(f"Rows changed: {changed}")
    print(f"Rows unchanged: {unchanged}")
    if by_main:
        print("Main category changes:")
        for label, count in by_main.most_common():
            print(f"  {label}: {count}")
    if by_subcategory:
        print("Top subcategories assigned:")
        for label, count in by_subcategory.most_common(20):
            print(f"  {label}: {count}")
    if samples:
        print("Sample updates:")
        for line in samples:
            print(f"  {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
