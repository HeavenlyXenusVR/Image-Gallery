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


SUBCATEGORY_FIXES: dict[int, str] = {
    4: "Cloud Strife",
    5: "Cloud Strife",
    6: "Cloud Strife",
    10: "Sonata Dusk",
    11: "Rainbow Dash",
    14: "Dazzlings",
    38: "Neptune",
    46: "Mane 6",
    47: "Twilight Sparkle",
    48: "Fluttershy",
    53: "Dazzlings",
    55: "Equestria Girls",
    56: "Dazzlings",
    57: "Dazzlings",
    58: "Adagio Dazzle",
    59: "Aria Blaze",
    60: "Dazzlings",
    61: "Dazzlings",
    62: "Dazzlings",
    64: "Dazzlings",
    65: "Adagio Dazzle",
    66: "Aria Blaze",
    67: "Dazzlings",
    69: "Dazzlings",
    71: "Aria Blaze",
    72: "Sonata Dusk",
    73: "Dazzlings",
    74: "Dazzlings",
    76: "Mane 6",
    77: "Mane 6",
    78: "Mane 6",
    79: "Mane 6",
    80: "Dazzlings",
    84: "Twilight Sparkle",
    88: "Princess Luna",
    90: "Equestria Girls",
    92: "Dazzlings",
    94: "Equestria Girls",
    95: "Equestria Girls",
    96: "Dazzlings",
    98: "Equestria Girls",
    99: "Dazzlings",
    100: "Dazzlings",
    101: "Fluttershy",
    102: "Dazzlings",
    103: "Dazzlings",
    104: "Mane 6",
    105: "Equestria Girls",
    106: "Dazzlings",
    107: "Rainbow Dash",
    108: "Sunset Shimmer",
    110: "Twilight Sparkle",
    112: "Dazzlings",
    113: "Mane 6",
    114: "Sunset Shimmer",
    115: "Sunset Shimmer",
    116: "Sunset Shimmer",
    117: "Sunset Shimmer",
    119: "Rainbow Dash",
    120: "Mane 6",
    121: "Equestria Girls",
    128: "Fluttershy",
    143: "Dazzlings",
    152: "Dazzlings",
    154: "Dazzlings",
    155: "Mane 6",
    156: "Equestria Girls",
    157: "Rainbow Dash",
    158: "Mane 6",
    159: "Mane 6",
    160: "Equestria Girls",
    161: "Cutie Mark Crusaders",
    162: "Mane 6",
    164: "Apple Bloom",
    166: "Rainbow Dash",
    168: "Equestria Girls",
    169: "Rainbow Dash",
    179: "Rainbow Dash",
    180: "Rainbow Dash",
    182: "Twilight Sparkle",
    186: "Mane 6",
    187: "Mane 6",
    190: "Equestria Girls",
    191: "Equestria Girls",
    195: "Rainbow Dash",
    196: "Equestria Girls",
    197: "Mane 6",
    198: "Dazzlings",
    206: "Equestria Girls",
    209: "Dazzlings",
    210: "Twilight Sparkle",
    212: "Equestria Girls",
    213: "Dazzlings",
    214: "Mane 6",
    215: "Equestria Girls",
    217: "Twilight Sparkle",
    220: "Fluttershy",
    223: "Fluttershy",
    224: "Twilight Sparkle",
    226: "Mane 6",
    227: "Mane 6",
    228: "Fluttershy",
    234: "Equestria Girls",
    235: "Mane 6",
    236: "Rainbow Dash",
    237: "Rainbow Dash",
    239: "Mane 6",
    241: "Mane 6",
    263: "Adagio Dazzle",
    266: "Dazzlings",
    269: "Dazzlings",
    270: "Equestria Girls",
    280: "Equestria Girls",
    283: "Dazzlings",
    289: "Rarity",
    295: "Rainbow Dash",
    296: "Rainbow Dash",
    306: "Equestria Girls",
    311: "Twilight Sparkle",
    312: "Mane 6",
    314: "Mane 6",
    315: "Dazzlings",
    317: "Twilight Sparkle",
    318: "Mane 6",
    321: "Fluttershy",
    322: "Mane 6",
    323: "Mane 6",
    326: "Equestria Girls",
    327: "Rainbow Dash",
    328: "Rainbow Dash",
    331: "Equestria Girls",
    334: "Rumi",
    335: "Fluttershy",
    336: "Twilight Sparkle",
    337: "Mane 6",
    338: "Equestria Girls",
    339: "Pinkie Pie",
    344: "Scootaloo",
    349: "Twilight Sparkle",
    350: "Trixie",
    351: "Mane 6",
    354: "Mane 6",
    358: "Dazzlings",
    366: "Rainbow Dash",
    368: "Rainbow Dash",
    369: "Twilight Sparkle",
    370: "Mane 6",
    375: "Rainbow Dash",
    376: "Rainbow Dash",
    377: "Equestria Girls",
    378: "Twilight Sparkle",
    379: "Mane 6",
    381: "Rainbow Dash",
    382: "Fluttershy",
    386: "Applejack",
    388: "Dazzlings",
    389: "Mane 6",
    391: "Equestria Girls",
    394: "Rarity",
    395: "Fluttershy",
    397: "Rainbow Dash",
    398: "Mane 6",
    400: "Twilight Sparkle",
    401: "Equestria Girls",
    402: "Mane 6",
    403: "Twilight Sparkle",
    404: "Twilight Sparkle",
    408: "Rainbow Dash",
    411: "Vinyl Scratch",
    414: "Dazzlings",
    418: "Huntrix",
    419: "Huntrix",
    420: "Huntrix",
    426: "Neptune",
    427: "Neptune",
    428: "Neptune",
    429: "Mira",
    430: "Huntrix",
    431: "Huntrix",
    432: "Huntrix",
    433: "Huntrix",
    434: "Mira",
    435: "Huntrix",
    438: "Rumi",
    439: "Huntrix",
    440: "Mira",
    441: "Huntrix",
    442: "Huntrix",
    443: "Huntrix",
    445: "Huntrix",
    446: "Mira",
    451: "Zoey",
    453: "Rumi",
    454: "Saja Boys",
    455: "Huntrix",
    456: "Rumi",
    457: "Saja Boys",
    458: "Huntrix",
    459: "Huntrix",
    461: "Rumi",
    462: "Huntrix",
    463: "Mira",
    464: "Mira",
    465: "Mira",
    467: "Huntrix",
    468: "Saja Boys",
    469: "Huntrix",
    504: "Bonnie",
    509: "Chica",
    528: "Huntrix",
    529: "Huntrix",
    530: "Huntrix",
    531: "Huntrix",
    532: "Huntrix",
    533: "Huntrix",
    534: "Huntrix",
    541: "Saja Boys",
    542: "Huntrix",
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
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")[:90] or "subcategory"


def ensure_subcategory(cur: pymysql.cursors.Cursor, category_id: int, subcategory_name: str) -> int:
    normalized = " ".join(str(subcategory_name or "").strip().split())[:80]
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
    parser = argparse.ArgumentParser(description="Fill trusted character subcategories for Image Gallery media.")
    parser.add_argument("--apply", action="store_true", help="Write the subcategory fixes to MariaDB.")
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
                SELECT m.id, m.title, c.id AS category_id, c.name AS category_name,
                       s.id AS subcategory_id, s.name AS subcategory_name
                FROM media_items m
                JOIN categories c ON c.id = m.category_id
                LEFT JOIN subcategories s ON s.id = m.subcategory_id
                WHERE m.deleted_at IS NULL
                ORDER BY m.id
                """
            )
            rows = cur.fetchall()

            for media_id, title, category_id, category_name, subcategory_id, subcategory_name in rows:
                next_subcategory = SUBCATEGORY_FIXES.get(int(media_id))
                if not next_subcategory:
                    unchanged += 1
                    continue
                next_subcategory_id = ensure_subcategory(cur, int(category_id), next_subcategory)
                if int(subcategory_id or 0) == int(next_subcategory_id):
                    unchanged += 1
                    continue

                changed += 1
                if len(samples) < 30:
                    samples.append(
                        f"{media_id}: {title} :: {category_name} / {subcategory_name or '(none)'} -> {category_name} / {next_subcategory}"
                    )
                if args.apply:
                    cur.execute("UPDATE media_items SET subcategory_id=%s WHERE id=%s", (next_subcategory_id, media_id))

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
