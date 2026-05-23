#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

import pymysql

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


VISUAL_FIXES: dict[int, tuple[str, str, str | None]] = {
    3: ("Aria Blaze Artwork", "My Little Pony", "Aria Blaze"),
    21: ("Aria Blaze Artwork", "My Little Pony", "Aria Blaze"),
    22: ("Bonnie Artwork", "FNAF", "Bonnie"),
    39: ("Aria Blaze Artwork", "My Little Pony", "Aria Blaze"),
    242: ("Mane 6 Artwork", "My Little Pony", "Mane 6"),
    243: ("Equestria Girls Group Artwork", "My Little Pony", "Equestria Girls"),
    244: ("Equestria Girls Collage", "My Little Pony", "Equestria Girls"),
    245: ("Mane 6 Neon Collage", "My Little Pony", "Mane 6"),
    246: ("Rainbow Dash Collage", "My Little Pony", "Rainbow Dash"),
    247: ("Rainbow Dash Sleepy Sky", "My Little Pony", "Rainbow Dash"),
    248: ("Rainbow Dash Neon Outline", "My Little Pony", "Rainbow Dash"),
    249: ("Rainbow Dash and Kitten", "My Little Pony", "Rainbow Dash"),
    250: ("Mane 6 Reflection", "My Little Pony", "Mane 6"),
    251: ("Mane 6 Group Artwork", "My Little Pony", "Mane 6"),
    252: ("Rainbow Dash and Pinkie Forest Path", "My Little Pony", "Mane 6"),
    253: ("Mane 6 Night Street", "My Little Pony", "Mane 6"),
    254: ("Rainbow Dash Poolside", "My Little Pony", "Rainbow Dash"),
    255: ("Mane 6 Doorway Artwork", "My Little Pony", "Mane 6"),
    256: ("Mane 6 Tree Artwork", "My Little Pony", "Mane 6"),
    257: ("Rainbow Dash Cloud Emblem", "My Little Pony", "Rainbow Dash"),
    258: ("Sonata Dusk Portrait", "My Little Pony", "Sonata Dusk"),
    259: ("Rainbow Dash Captain Portrait", "My Little Pony", "Rainbow Dash"),
    260: ("Mane 6 Eye Collage", "My Little Pony", "Mane 6"),
    261: ("Aria Blaze Portrait", "My Little Pony", "Aria Blaze"),
    262: ("Dazzlings Group Poster", "My Little Pony", "Dazzlings"),
    264: ("Adagio Dazzle Portrait", "My Little Pony", "Adagio Dazzle"),
    265: ("Dazzlings Chibi Artwork", "My Little Pony", "Dazzlings"),
    267: ("Adagio Dazzle Hero Pose", "My Little Pony", "Adagio Dazzle"),
    268: ("Adagio Dazzle Selfie", "My Little Pony", "Adagio Dazzle"),
    271: ("Aria Blaze Chibi Portrait", "My Little Pony", "Aria Blaze"),
    272: ("Adagio Dazzle Collage", "My Little Pony", "Adagio Dazzle"),
    273: ("Sonata Dusk Collage", "My Little Pony", "Sonata Dusk"),
    274: ("Dazzlings Bench Artwork", "My Little Pony", "Dazzlings"),
    275: ("Sonata Dusk Pixel Art", "My Little Pony", "Sonata Dusk"),
    276: ("Rainbow Dash Equestria Girls Poster", "My Little Pony", "Rainbow Dash"),
    277: ("Sonata Dusk Portrait", "My Little Pony", "Sonata Dusk"),
    278: ("Sonata Dusk and Pinkie Pie", "My Little Pony", "Sonata Dusk"),
    279: ("Dazzlings Stage Poster", "My Little Pony", "Dazzlings"),
    281: ("Equestria Girls Comic Panel", "My Little Pony", "Equestria Girls"),
    282: ("Adagio Dazzle Hoodie Portrait", "My Little Pony", "Adagio Dazzle"),
    284: ("Dazzlings Winter Trio", "My Little Pony", "Dazzlings"),
    285: ("Rainbow Dash Spotlight", "My Little Pony", "Rainbow Dash"),
    286: ("Mane 6 Banner Set", "My Little Pony", "Mane 6"),
    287: ("Rainbow Dash Forest Portrait", "My Little Pony", "Rainbow Dash"),
    288: ("Rarity Party Portrait", "My Little Pony", "Rarity"),
    290: ("Fluttershy City Cosplay", "My Little Pony", "Fluttershy"),
    291: ("Rarity Forest Portrait", "My Little Pony", "Rarity"),
    292: ("Twilight Sparkle Beach Reading", "My Little Pony", "Twilight Sparkle"),
    293: ("Equestria Girls Vertical Banner", "My Little Pony", "Equestria Girls"),
    294: ("Rainbow Dash Pattern Collage", "My Little Pony", "Rainbow Dash"),
    297: ("Twilight Sparkle Pixel Reaction", "My Little Pony", "Twilight Sparkle"),
    298: ("Mane 6 Crystal Artwork", "My Little Pony", "Mane 6"),
    299: ("Starlight Glimmer Portrait", "My Little Pony", "Starlight Glimmer"),
    300: ("Fluttershy and Hummingbird", "My Little Pony", "Fluttershy"),
    301: ("Fluttershy Portrait", "My Little Pony", "Fluttershy"),
    302: ("Mane 6 Celebration Banner", "My Little Pony", "Mane 6"),
    303: ("Equestria Girls Lineup", "My Little Pony", "Equestria Girls"),
    304: ("Twilight Sparkle Anniversary Collage", "My Little Pony", "Twilight Sparkle"),
    305: ("Dazzlings Water Fight", "My Little Pony", "Dazzlings"),
    307: ("Adagio Dazzle Water Fight", "My Little Pony", "Adagio Dazzle"),
    308: ("Equestria Girls Fluttershy Banner", "My Little Pony", "Equestria Girls"),
    309: ("Fluttershy's Bedroom Banner", "My Little Pony", "Fluttershy"),
    310: ("Sonic and Rainbow Dash Crossover", "Crossovers", "Rainbow Dash"),
    340: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    436: ("Huntrix Battle Poster", "KPOP Demon Hunters", "Huntrix"),
    437: ("Huntrix Moonlight Poster", "KPOP Demon Hunters", "Huntrix"),
    470: ("Huntrix Artwork", "KPOP Demon Hunters", "Huntrix"),
    471: ("Mira Performance Portrait", "KPOP Demon Hunters", "Mira"),
    472: ("Mira Hallway Scene", "KPOP Demon Hunters", "Mira"),
    473: ("Mira Close-Up", "KPOP Demon Hunters", "Mira"),
    474: ("Rumi Portrait", "KPOP Demon Hunters", "Rumi"),
    475: ("Zoey Action Pose", "KPOP Demon Hunters", "Zoey"),
    476: ("Mira Action Pose", "KPOP Demon Hunters", "Mira"),
    477: ("Huntrix Character Collage", "KPOP Demon Hunters", "Huntrix"),
    478: ("Huntrix Duo Portrait", "KPOP Demon Hunters", "Huntrix"),
    479: ("Huntrix Team Portrait", "KPOP Demon Hunters", "Huntrix"),
    480: ("Mira Spear Portrait", "KPOP Demon Hunters", "Mira"),
    481: ("Zoey Snack Portrait", "KPOP Demon Hunters", "Zoey"),
    482: ("Huntrix Selfie", "KPOP Demon Hunters", "Huntrix"),
    483: ("Zoey Pointing Portrait", "KPOP Demon Hunters", "Zoey"),
    484: ("Zoey Night Portrait", "KPOP Demon Hunters", "Zoey"),
    485: ("Zoey Dance Pose", "KPOP Demon Hunters", "Zoey"),
    486: ("Zoey Silhouette Collage", "KPOP Demon Hunters", "Zoey"),
    487: ("Huntrix Dinner Scene", "KPOP Demon Hunters", "Huntrix"),
    489: ("Zoey Magazine Collage", "KPOP Demon Hunters", "Zoey"),
    490: ("Huntrix Studio Portrait", "KPOP Demon Hunters", "Huntrix"),
    491: ("Huntrix Stage Poster", "KPOP Demon Hunters", "Huntrix"),
    492: ("Mira Reaction Portrait", "KPOP Demon Hunters", "Mira"),
    493: ("Rumi Dance Portrait", "KPOP Demon Hunters", "Rumi"),
    494: ("Rumi Jacket Portrait", "KPOP Demon Hunters", "Rumi"),
    495: ("Rumi Close-Up", "KPOP Demon Hunters", "Rumi"),
    496: ("Mira Snack Portrait", "KPOP Demon Hunters", "Mira"),
    497: ("Rumi Thoughtful Portrait", "KPOP Demon Hunters", "Rumi"),
    498: ("FNAF Preview Banner", "FNAF", None),
    499: ("Bonnie and Chica Split Portrait", "FNAF", None),
    500: ("Bonnie Pathetic Portrait", "FNAF", "Bonnie"),
    501: ("Bonnie Moon Pose", "FNAF", "Bonnie"),
    502: ("Bonnie Shadow Portrait", "FNAF", "Bonnie"),
    503: ("Bonnie Hallway Pose", "FNAF", "Bonnie"),
    504: ("Bonnie and Friends Neon Scene", "FNAF", None),
    505: ("Chica Kitchen Portrait", "FNAF", "Chica"),
    506: ("Bonnie Supply Closet", "FNAF", "Bonnie"),
    507: ("Chica Glamour Pose", "FNAF", "Chica"),
    508: ("FNAF Security Camera Collage", "FNAF", None),
    510: ("Chica Camera Collage", "FNAF", "Chica"),
    511: ("Chica Twins Portrait", "FNAF", "Chica"),
    512: ("Chica Close-Up Banner", "FNAF", "Chica"),
    513: ("Bonnie and Chica Garden Scene", "FNAF", None),
    515: ("Bonnie Stage Pose", "FNAF", "Bonnie"),
    516: ("Bonnie Studio Portrait", "FNAF", "Bonnie"),
    517: ("Bonnie Floor Pose", "FNAF", "Bonnie"),
    518: ("Bonnie Milkshake Portrait", "FNAF", "Bonnie"),
    519: ("Bonnie Close-Up", "FNAF", "Bonnie"),
    521: ("Bonnie Library Portrait", "FNAF", "Bonnie"),
    522: ("Chica Moon Portrait", "FNAF", "Chica"),
    523: ("Bonnie Stripe Portrait", "FNAF", "Bonnie"),
    525: ("Chica Pizza Counter", "FNAF", "Chica"),
    526: ("Mira Clean Portrait", "KPOP Demon Hunters", "Mira"),
    527: ("Freddy Poolside Artwork", "FNAF", "Freddy"),
    529: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    530: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    531: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    532: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    533: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    534: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    535: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    536: ("Huntrix Artwork", "KPOP Demon Hunters", "Huntrix"),
    537: ("Mira Artwork", "KPOP Demon Hunters", "Mira"),
    538: ("Rumi Artwork", "KPOP Demon Hunters", "Rumi"),
    539: ("Rumi Artwork", "KPOP Demon Hunters", "Rumi"),
    540: ("Rumi Artwork", "KPOP Demon Hunters", "Rumi"),
    542: ("KPOP Demon Hunters Artwork", "KPOP Demon Hunters", None),
    543: ("Zoey Artwork", "KPOP Demon Hunters", "Zoey"),
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
    parser = argparse.ArgumentParser(description="Repair generic Image Gallery titles and category/subcategory mixups.")
    parser.add_argument("--apply", action="store_true", help="Write the metadata fixes to MariaDB.")
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
    samples: list[str] = []

    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT m.id, m.title, m.media_kind,
                       c.id AS category_id, c.name AS category_name,
                       s.id AS subcategory_id, s.name AS subcategory_name
                FROM media_items m
                JOIN categories c ON c.id = m.category_id
                LEFT JOIN subcategories s ON s.id = m.subcategory_id
                WHERE m.deleted_at IS NULL
                ORDER BY m.id
                """
            )
            rows = cur.fetchall()

            for media_id, title, media_kind, category_id, category_name, subcategory_id, subcategory_name in rows:
                fix = VISUAL_FIXES.get(int(media_id))
                if not fix:
                    unchanged += 1
                    continue

                next_title, next_category, next_subcategory = fix
                next_category_id = ensure_category(cur, next_category, str(media_kind or "image"))
                next_subcategory_id = ensure_subcategory(cur, next_category_id, next_subcategory)

                same_title = str(title or "") == next_title
                same_category = int(category_id) == int(next_category_id)
                same_subcategory = int(subcategory_id or 0) == int(next_subcategory_id or 0)
                if same_title and same_category and same_subcategory:
                    unchanged += 1
                    continue

                changed += 1
                if len(samples) < 30:
                    before = f"{title} :: {category_name}{f' / {subcategory_name}' if subcategory_name else ''}"
                    after = f"{next_title} :: {next_category}{f' / {next_subcategory}' if next_subcategory else ''}"
                    samples.append(f"{media_id}: {before} -> {after}")
                if args.apply:
                    cur.execute(
                        "UPDATE media_items SET title=%s, category_id=%s, subcategory_id=%s WHERE id=%s",
                        (next_title, next_category_id, next_subcategory_id, media_id),
                    )

            if args.apply:
                conn.commit()
            else:
                conn.rollback()
    finally:
        conn.close()

    print(f"Rows changed: {changed}")
    print(f"Rows unchanged: {unchanged}")
    if samples:
        print("Sample updates:")
        for line in samples:
            print(f"  {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
