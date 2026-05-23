#!/usr/bin/env python3
import argparse
import hashlib
import json
import mimetypes
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

import magic
import pymysql
from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from app.ai_metadata import analyze_media_path
from app.classification import canonical_category_pair, infer_category_pair

Image.MAX_IMAGE_PIXELS = None


SAFE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp",
    ".mp4", ".webm", ".mov", ".m4v", ".ogg",
}
ADULT_KEYWORDS = {
    "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
    "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
    "erotic", "fetish", "onlyfans", "camgirl", "cam boy", "xxx",
}
STOP_TAGS = {
    "the", "and", "for", "with", "from", "pre", "fullview", "generated",
    "image", "standard", "lite", "upscayl", "wallpaper", "desktop",
    "phone", "background", "version", "text", "movie", "poster",
}
TOKEN_RE = re.compile(r"[a-z0-9]{2,}")
ARTIST_RE = re.compile(r"(?:^|[_\-\s])by[_\-\s]+([a-z0-9_.-]+)", re.IGNORECASE)


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


def clean_tokens(path: Path) -> list[str]:
    raw = re.sub(r"[^a-z0-9]+", " ", path.stem.lower())
    return TOKEN_RE.findall(raw)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def detect_media(path: Path) -> tuple[str, str]:
    detected = magic.detect_from_filename(str(path))
    mime_type = str(getattr(detected, "mime_type", "") or "")
    if mime_type.startswith("image/"):
        return mime_type, "image"
    if mime_type.startswith("video/"):
        return mime_type, "video"
    guessed = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    if guessed.startswith("image/"):
        return guessed, "image"
    if guessed.startswith("video/"):
        return guessed, "video"
    raise ValueError(f"Unsupported file type: {path}")


def image_size(path: Path) -> tuple[int, int] | None:
    try:
        with Image.open(path) as img:
            return img.size
    except Exception:
        return None


def video_size(path: Path) -> tuple[int, int] | None:
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height",
                "-of", "json",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        payload = json.loads(result.stdout or "{}")
        stream = (payload.get("streams") or [{}])[0]
        width = int(stream.get("width") or 0)
        height = int(stream.get("height") or 0)
        if width and height:
            return width, height
    except Exception:
        return None
    return None


def title_case_token(token: str) -> str:
    special = {
        "mlp": "MLP",
        "fnaf": "FNAF",
        "sfm": "SFM",
        "eqg": "EQG",
        "ai": "AI",
        "pmv": "PMV",
        "atg": "ATG",
        "vid": "VID",
        "img": "IMG",
        "kpop": "KPOP",
        "xmas": "XMas",
        "vr": "VR",
        "3d": "3D",
        "4k": "4K",
        "1080p": "1080p",
        "1440p": "1440p",
    }
    lower = token.lower()
    if lower in special:
        return special[lower]
    if lower.isdigit():
        return lower
    return lower.capitalize()


def build_title(path: Path, category: str | None = None, subcategory: str | None = None) -> str:
    stem = path.stem
    if re.fullmatch(r"[0-9A-Fa-f-]{16,}", stem):
        label = subcategory or category or "Imported Media"
        return f"{label} Artwork {stem.replace('-', '')[:12]}".strip()[:160]
    stem = re.sub(r"[_\-]+", " ", stem)
    stem = re.sub(r"\s+", " ", stem).strip()
    tokens = stem.split()
    if not tokens:
        label = subcategory or category or path.name
        return str(label)[:160]
    alpha_tokens = [token for token in tokens if re.search(r"[A-Za-z]{3,}", token)]
    hexish_tokens = [token for token in tokens if re.fullmatch(r"[0-9A-Fa-f]{6,}", token)]
    if not alpha_tokens or len(hexish_tokens) == len(tokens):
        label = subcategory or category or "Imported Media"
        suffix = (tokens[0] if tokens else path.stem)[:12]
        if path.suffix.lower() == ".gif":
            label = subcategory or category or "Imported GIF"
        elif path.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm", ".ogg"}:
            label = subcategory or category or "Imported Video"
        return f"{label} {suffix}".strip()[:160]
    title = " ".join(title_case_token(token) for token in tokens)
    title = re.sub(r"\s+", " ", title).strip()
    return title[:160]


def moderation(title: str, filename: str, tags: list[str]) -> dict[str, object]:
    combined = " ".join([title, filename, " ".join(tags)]).lower()
    normalized = re.sub(r"[^a-z0-9+]+", " ", combined)
    hits = sorted({word for word in ADULT_KEYWORDS if word in normalized or word in combined})
    adult_by_ai = bool(hits)
    return {
        "is_adult": adult_by_ai,
        "adult_marked_by_user": False,
        "adult_marked_by_ai": adult_by_ai,
        "moderation_status": "adult" if adult_by_ai else "clear",
        "moderation_score": 0.96 if adult_by_ai else 0.0,
        "moderation_reason": (f"Automatic moderation matched: {', '.join(hits[:5])}." if hits else None),
    }


def extract_tags(path: Path, category: str, media_kind: str, size: tuple[int, int] | None, subcategory: str | None = None) -> list[str]:
    tags: list[str] = []
    tokens = clean_tokens(path)
    artist_match = ARTIST_RE.search(path.stem.lower())
    if category == "My Little Pony":
        tags.extend(["mlp", "pony"])
    elif category == "Dazzlings":
        tags.extend(["dazzlings", "equestria_girls"])
    elif category == "Aria Blaze (Solo)":
        tags.extend(["aria_blaze", "dazzlings"])
    elif category == "Sonata Dusk":
        tags.extend(["sonata_dusk", "dazzlings"])
    elif category == "FNAF":
        tags.append("fnaf")
    elif category == "Xenoblade":
        tags.append("xenoblade")
    elif category == "Hyperdimension Neptunia":
        tags.append("neptunia")
    elif category == "Sonic":
        tags.append("sonic")
    elif category == "Crossovers":
        tags.append("crossover")
    elif category == "Cartoon":
        tags.append("cartoon")
    elif category == "Memes":
        tags.append("meme")
    if subcategory:
        tags.extend(token for token in clean_tokens(Path(subcategory)) if token not in STOP_TAGS)
    if media_kind == "video":
        tags.append("video")
    if path.suffix.lower() == ".gif":
        tags.append("gif")
    if size:
        width, height = size
        if width > height:
            tags.append("landscape")
        elif height > width:
            tags.append("portrait")
        else:
            tags.append("square")
        if width >= 3840 or height >= 2160:
            tags.append("4k")
        elif width >= 2560 or height >= 1440:
            tags.append("1440p")
        elif width >= 1920 or height >= 1080:
            tags.append("1080p")
    if artist_match:
        tags.append(artist_match.group(1).replace(".", "_"))
    for token in tokens:
        if token in STOP_TAGS or token.isdigit():
            continue
        if len(token) < 3:
            continue
        tag = token.replace(".", "_")
        if tag.lower() not in {existing.lower() for existing in tags}:
            tags.append(tag)
        if len(tags) >= 12:
            break
    return tags[:12]


def ensure_category(cur: pymysql.cursors.Cursor, category_name: str, media_kind: str) -> int:
    cur.execute("SELECT id FROM categories WHERE name=%s LIMIT 1", (category_name,))
    row = cur.fetchone()
    if row:
        return int(row[0])
    slug = re.sub(r"[^a-z0-9]+", "-", category_name.lower()).strip("-")[:90] or "category"
    stored_kind = "video" if media_kind == "video" else "image"
    cur.execute(
        "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, NULL)",
        (category_name, slug, stored_kind),
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
    slug = re.sub(r"[^a-z0-9]+", "-", normalized.lower()).strip("-")[:90] or "subcategory"
    cur.execute(
        "INSERT INTO subcategories (category_id, name, slug, created_by) VALUES (%s, %s, %s, NULL)",
        (category_id, normalized, slug),
    )
    return int(cur.lastrowid)


def main() -> int:
    parser = argparse.ArgumentParser(description="Import iCloud Photos into the Image Gallery database.")
    parser.add_argument("--folder", default="/home/desmond/Pictures/iCloud Photos")
    parser.add_argument("--limit", type=int, default=0, help="Only process the first N importable files.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    gallery_root = Path(__file__).resolve().parents[1]
    env_file = load_env_file(gallery_root / ".env")

    db_host = env_or_file("GALLERY_DB_HOST", env_file, "127.0.0.1")
    db_port = int(env_or_file("GALLERY_DB_PORT", env_file, "3306"))
    db_user = env_or_file("GALLERY_DB_USER", env_file, "botuser")
    db_password = env_or_file("GALLERY_DB_PASSWORD", env_file, "")
    db_name = env_or_file("GALLERY_DB_SCHEMA", env_file, "image_gallery")
    source_dir = Path(args.folder).expanduser()
    ai_provider = env_or_file("GALLERY_AI_PROVIDER", env_file, "").lower()
    gemini_key = env_or_file("GALLERY_GEMINI_API_KEY", env_file, env_or_file("GEMINI_API_KEY", env_file, env_or_file("GOOGLE_API_KEY", env_file, "")))
    if ai_provider in {"google", "google-gemini"}:
        ai_provider = "gemini"
    if ai_provider not in {"ollama", "openai", "gemini"}:
        ai_provider = "gemini" if (gemini_key or env_or_file("GALLERY_GEMINI_MODEL", env_file, "") or env_or_file("GEMINI_MODEL", env_file, "")) else ("ollama" if (env_or_file("GALLERY_OLLAMA_MODEL", env_file, "") or env_or_file("GALLERY_OLLAMA_BASE_URL", env_file, "")) else "openai")
    ai_api_key = gemini_key if ai_provider == "gemini" else env_or_file("GALLERY_AI_API_KEY", env_file, env_or_file("OPENAI_API_KEY", env_file, ""))
    ai_enabled_default = "true" if (ai_api_key or ai_provider in {"ollama", "gemini"}) else "false"
    ai_enabled = env_or_file("GALLERY_AI_ENABLED", env_file, ai_enabled_default).lower() not in {"0", "false", "no", "off"}
    if ai_provider == "ollama":
        ai_base_url = env_or_file("GALLERY_OLLAMA_BASE_URL", env_file, "http://127.0.0.1:11434").rstrip("/")
        ai_model = env_or_file("GALLERY_OLLAMA_MODEL", env_file, "qwen2.5vl:3b")
    elif ai_provider == "gemini":
        ai_base_url = ""
        ai_model = env_or_file("GALLERY_GEMINI_MODEL", env_file, env_or_file("GEMINI_MODEL", env_file, "gemini-2.5-flash-lite"))
    else:
        ai_base_url = env_or_file("GALLERY_AI_BASE_URL", env_file, env_or_file("OPENAI_BASE_URL", env_file, "https://api.openai.com/v1")).rstrip("/")
        ai_model = env_or_file("GALLERY_AI_MODEL", env_file, "gpt-5.4-nano")
    ai_timeout_seconds = int(env_or_file("GALLERY_AI_TIMEOUT_SECONDS", env_file, "45"))

    if not source_dir.is_dir():
        raise SystemExit(f"Folder not found: {source_dir}")

    conn = pymysql.connect(
        host=db_host,
        port=db_port,
        user=db_user,
        password=db_password,
        database=db_name,
        charset="utf8mb4",
        autocommit=False,
    )
    imported = 0
    skipped = 0
    failed = 0
    category_counts: Counter[str] = Counter()
    error_paths: list[str] = []

    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM users ORDER BY id LIMIT 1")
            user_row = cur.fetchone()
            if not user_row:
                raise SystemExit("No gallery user exists yet.")
            user_id = int(user_row[0])

            cur.execute("SELECT content_sha256 FROM media_items WHERE content_sha256 IS NOT NULL AND deleted_at IS NULL")
            existing_media_shas = {row[0] for row in cur.fetchall() if row[0]}

            cur.execute("SELECT sha256, id FROM media_files")
            existing_file_ids = {row[0]: int(row[1]) for row in cur.fetchall() if row[0]}

            files = sorted(
                [
                    path for path in source_dir.rglob("*")
                    if path.is_file() and path.suffix.lower() in SAFE_EXTENSIONS
                ],
                key=lambda path: path.name.lower(),
            )

            planned: list[dict[str, object]] = []
            for path in files:
                try:
                    sha = sha256_file(path)
                    if sha in existing_media_shas:
                        skipped += 1
                        continue
                    mime_type, media_kind = detect_media(path)
                    analysis = analyze_media_path(
                        path,
                        mime_type=mime_type,
                        media_kind=media_kind,
                        ai_enabled=ai_enabled,
                        ai_api_key=ai_api_key,
                        ai_base_url=ai_base_url,
                        ai_model=ai_model,
                        ai_timeout_seconds=ai_timeout_seconds,
                    )
                    category, subcategory = canonical_category_pair(analysis.category_name, analysis.subcategory_name)
                    planned.append(
                        {
                            "path": path,
                            "sha": sha,
                            "mime_type": mime_type,
                            "media_kind": media_kind,
                            "category": category,
                            "subcategory": subcategory,
                            "title": analysis.title,
                            "tags": list(analysis.tags),
                            "stored_filename": analysis.suggested_filename[:255] if analysis.suggested_filename else path.name[:255],
                            "source": analysis.source,
                        }
                    )
                except Exception as exc:
                    failed += 1
                    error_paths.append(f"{path}: {exc}")

            if args.limit > 0:
                planned = planned[:args.limit]

            preview_counts = Counter(item["category"] for item in planned)
            print(json.dumps(
                {
                    "source_folder": str(source_dir),
                    "already_in_gallery": skipped,
                    "failed_to_prepare": failed,
                    "planned_imports": len(planned),
                    "category_breakdown": dict(preview_counts.most_common()),
                },
                indent=2,
            ))

            if args.dry_run:
                if error_paths:
                    print("\nPreparation errors:")
                    for line in error_paths[:20]:
                        print(line)
                return 0

            for index, item in enumerate(planned, start=1):
                path = item["path"]
                sha = str(item["sha"])
                mime_type = str(item["mime_type"])
                media_kind = str(item["media_kind"])
                category_name = str(item["category"])
                subcategory_name = str(item.get("subcategory") or "").strip() or None
                title = str(item["title"])
                tags = list(item["tags"])
                stored_filename = str(item.get("stored_filename") or path.name)[:255]
                file_size = path.stat().st_size
                moderation_bits = moderation(title, stored_filename, tags)
                category_id = ensure_category(cur, category_name, media_kind)
                subcategory_id = ensure_subcategory(cur, category_id, subcategory_name)

                try:
                    if sha in existing_file_ids:
                        media_file_id = int(existing_file_ids[sha])
                    else:
                        cur.execute(
                            """
                            INSERT INTO media_files
                              (sha256, mime_type, original_filename, media_kind, file_size, content, created_by)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)
                            """,
                            (sha, mime_type[:120], stored_filename, media_kind, file_size, b"", user_id),
                        )
                        media_file_id = int(cur.lastrowid)
                        existing_file_ids[sha] = media_file_id
                        chunk_index = 0
                        with path.open("rb") as handle:
                            while True:
                                chunk = handle.read(8 * 1024 * 1024)
                                if not chunk:
                                    break
                                cur.execute(
                                    """
                                    INSERT INTO media_file_chunks (file_id, chunk_index, content)
                                    VALUES (%s, %s, %s)
                                    """,
                                    (media_file_id, chunk_index, chunk),
                                )
                                chunk_index += 1

                    cur.execute(
                        """
                        INSERT INTO media_items
                          (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename,
                           storage_path, file_size, media_file_id, content_sha256, visibility, comments_enabled,
                           downloads_enabled, pinned_at, is_adult, adult_marked_by_user, adult_marked_by_ai,
                           moderation_status, moderation_score, moderation_reason, moderated_at)
                        VALUES (%s, %s, %s, %s, NULL, %s, %s, %s, %s, %s, %s, %s, %s, 'public', 1, 1, NULL, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)
                        """,
                        (
                            user_id,
                            category_id,
                            subcategory_id,
                            title[:160],
                            json.dumps(tags),
                            media_kind,
                            mime_type[:120],
                            stored_filename,
                            f"db://media/{media_file_id}",
                            file_size,
                            media_file_id,
                            sha,
                            1 if moderation_bits["is_adult"] else 0,
                            1 if moderation_bits["adult_marked_by_user"] else 0,
                            1 if moderation_bits["adult_marked_by_ai"] else 0,
                            str(moderation_bits["moderation_status"])[:30],
                            float(moderation_bits["moderation_score"]),
                            moderation_bits["moderation_reason"],
                        ),
                    )
                    conn.commit()
                    imported += 1
                    existing_media_shas.add(sha)
                    category_counts[category_name] += 1
                    print(f"[{index}/{len(planned)}] imported {path.name} -> {category_name} ({item.get('source', 'heuristic')})")
                except Exception as exc:
                    conn.rollback()
                    failed += 1
                    error_paths.append(f"{path}: {exc}")
                    print(f"[{index}/{len(planned)}] failed {path.name}: {exc}")

            print(json.dumps(
                {
                    "imported": imported,
                    "skipped_duplicates": skipped,
                    "failed": failed,
                    "imported_by_category": dict(category_counts.most_common()),
                },
                indent=2,
            ))
            if error_paths:
                print("\nErrors:")
                for line in error_paths[:50]:
                    print(line)
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
