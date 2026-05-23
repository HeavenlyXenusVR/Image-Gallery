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
from typing import Any

import magic
import pymysql
from PIL import Image

DEFAULT_PROJECTS_ROOT = Path(os.getenv("DISCORD_PROJECTS_ROOT", "/home/desmond/Documents/Discord Bots")).expanduser()


def looks_like_gallery_root(path: Path) -> bool:
    return (
        path.is_dir()
        and (path / "app" / "ai_metadata.py").is_file()
        and (path / "app" / "classification.py").is_file()
    )


def resolve_project_root() -> Path:
    """
    Find the Image Gallery backend root.
    """
    script_path = Path(__file__).resolve()
    candidates: list[Path] = []

    for env_name in ("GALLERY_PROJECT_ROOT", "IMAGE_GALLERY_ROOT"):
        value = os.getenv(env_name)
        if value and value.strip():
            candidates.append(Path(value).expanduser())

    candidates.extend([script_path.parent, script_path.parent.parent, DEFAULT_PROJECTS_ROOT])

    if DEFAULT_PROJECTS_ROOT.is_dir():
        candidates.extend(child for child in DEFAULT_PROJECTS_ROOT.iterdir() if child.is_dir())
        candidates.extend(path.parent.parent for path in DEFAULT_PROJECTS_ROOT.glob("*/app/ai_metadata.py"))
        candidates.extend(path.parent.parent for path in DEFAULT_PROJECTS_ROOT.glob("*/*/app/ai_metadata.py"))

    seen: set[Path] = set()
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        if looks_like_gallery_root(candidate):
            return candidate

    checked = "\n  - ".join(str(path) for path in sorted(seen))
    raise SystemExit(
        "Could not find the Image Gallery backend root.\n"
        "Expected a project folder containing app/ai_metadata.py and app/classification.py.\n\n"
        "Fix one of these ways:\n"
        "  1. Put this file in: <image-gallery-project>/scripts/import_icloud_photos.py\n"
        "  2. Export the exact project root first, for example:\n"
        "     export GALLERY_PROJECT_ROOT=\"/home/desmond/Documents/Discord Bots/<your-image-gallery-folder>\"\n"
        "  3. Export the parent projects folder if different:\n"
        "     export DISCORD_PROJECTS_ROOT=\"/home/desmond/Documents/Discord Bots\"\n\n"
        f"Checked:\n  - {checked}"
    )


PROJECT_ROOT = resolve_project_root()
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from app.ai_metadata import analyze_media_path, analyze_media_bytes
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
    "image", "images", "standard", "lite", "upscayl", "wallpaper", "wallpapers",
    "desktop", "phone", "background", "version", "text", "movie", "poster",
    "download", "downloads", "photo", "photos", "picture", "pictures", "pic", "pics",
    "copy", "edited", "edit", "scaled", "resized", "compressed", "final", "new",
    "old", "raw", "sample", "unknown", "file", "media", "artwork", "screenshot",
}
TOKEN_RE = re.compile(r"[a-z0-9]{2,}")
ARTIST_RE = re.compile(r"(?:^|[_\-\s])by[_\-\s]+([a-z0-9_.-]+)", re.IGNORECASE)
RESOLUTION_RE = re.compile(r"(?:^|[^0-9])([1-9][0-9]{2,4})\s*[x×]\s*([1-9][0-9]{2,4})(?:$|[^0-9])", re.IGNORECASE)

KPOP_DEMON_HUNTERS_CATEGORY = "KPOP Demon Hunters (Huntrix)"
KPOP_DEMON_HUNTERS_CHARACTERS: dict[str, tuple[str, ...]] = {
    "Rumi": ("rumi",),
    "Zoey": ("zoey", "zoi", "zoye"),
    "Mira": ("mira",),
    "Jinu": ("jinu",),
    "Celine": ("celine",),
}
KPOP_DEMON_HUNTERS_MARKERS = (
    "kpop demon hunters",
    "k pop demon hunters",
    "k-pop demon hunters",
    "huntrix",
    "h-untrix",
)

CATEGORY_TAGS: dict[str, list[str]] = {
    KPOP_DEMON_HUNTERS_CATEGORY: ["kpop_demon_hunters", "huntrix", "kpop", "demon_hunters"],
    "My Little Pony": ["mlp", "pony"],
    "Dazzlings": ["dazzlings", "equestria_girls"],
    "Aria Blaze (Solo)": ["aria_blaze", "dazzlings"],
    "Sonata Dusk": ["sonata_dusk", "dazzlings"],
    "FNAF": ["fnaf"],
    "Xenoblade": ["xenoblade"],
    "Hyperdimension Neptunia": ["neptunia"],
    "Sonic": ["sonic"],
    "Crossovers": ["crossover"],
    "Cartoon": ["cartoon"],
    "Memes": ["meme"],
}
TRAINING_RECOGNIZED_SOURCES = {"visual-training", "gallery-training"}


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        # Fix: Safely remove surrounding quotes if present to avoid API key auth errors
        if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        values[key] = value
    return values


def apply_env_file(env_file: dict[str, str]) -> None:
    for key, value in env_file.items():
        if key and value and key not in os.environ:
            os.environ[key] = value


def env_or_file(name: str, env_file: dict[str, str], default: str) -> str:
    value = os.getenv(name)
    if value is not None and str(value).strip():
        return str(value).strip()
    return env_file.get(name, default).strip()


def normalize_text(value: object) -> str:
    text = str(value or "").lower()
    text = text.replace("&", " and ")
    text = re.sub(r"[_\-.]+", " ", text)
    text = re.sub(r"[^a-z0-9+×x\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def token_list(value: object) -> list[str]:
    return TOKEN_RE.findall(normalize_text(value))


def is_noise_token(token: str) -> bool:
    token = token.lower().strip("._- ")
    if not token or token in STOP_TAGS:
        return True
    if re.fullmatch(r"wp\d{4,}", token):
        return True
    if re.fullmatch(r"wallhaven\d+", token):
        return True
    if re.fullmatch(r"(?:img|vid|dsc|dscn|screenshot)\d*", token):
        return True
    if re.fullmatch(r"\d{3,5}x\d{3,5}", token):
        return True
    if re.fullmatch(r"\d{3,5}p", token):
        return True
    if re.fullmatch(r"[0-9a-f]{8,}", token):
        return True
    if re.fullmatch(r"\d{2,}", token):
        return True
    if re.fullmatch(r"20\d{6,8}", token):
        return True
    return False


def clean_tokens(path: Path | str) -> list[str]:
    value = path.stem if isinstance(path, Path) else str(path)
    return [token for token in token_list(value) if not is_noise_token(token)]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def detect_media(path: Path) -> tuple[str, str]:
    mime_type = ""
    # Fix: Safely support both pip versions of python-magic/file-magic
    try:
        if hasattr(magic, "detect_from_filename"):
            detected = magic.detect_from_filename(str(path))
            mime_type = str(getattr(detected, "mime_type", "") or "")
        elif hasattr(magic, "from_file"):
            mime_type = str(magic.from_file(str(path), mime=True) or "")
    except Exception:
        pass

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
        "2160p": "2160p",
    }
    lower = token.lower()
    if lower in special:
        return special[lower]
    if lower.isdigit():
        return lower
    return lower.capitalize()


def clean_title_text(text: str) -> str:
    text = re.sub(r"\bwp\d{4,}\b", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"\b(?:img|vid|dsc|dscn|screenshot)[-_ ]?\d+\b", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"\b\d{3,5}\s*[x×]\s*\d{3,5}\b", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"\b\d{3,5}p\b", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"\b(?:4k|8k|uhd|fhd|fullhd|hd)\b", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"[_\-]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" -_.,")
    words = [word for word in text.split() if not is_noise_token(word.lower())]
    if not words:
        return ""
    return " ".join(title_case_token(word) for word in words).strip()[:160]


def is_generic_title(title: str) -> bool:
    normalized = normalize_text(title)
    if not normalized:
        return True
    generic = {
        "imported media", "imported image", "imported video", "imported gif",
        "media", "image", "video", "artwork", "photo", "picture",
        "background", "backgrounds", "wallpaper", "wallpapers",
        "phone background", "phone backgrounds", "desktop background", "desktop backgrounds",
        "profile", "profile picture", "profile pictures",
    }
    if normalized in generic:
        return True
    tokens = token_list(normalized)
    return bool(tokens) and all(is_noise_token(token) for token in tokens)


def compact_label(value: object) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def is_category_as_title(title: object, category: object = "", subcategory: object = "") -> bool:
    compact_title = compact_label(title)
    if not compact_title:
        return True
    blocked = {
        compact_label(category),
        compact_label(subcategory),
        compact_label(str(category or "").replace("Backgrounds", "Background")),
        compact_label(str(category or "").replace("Pictures", "Picture")),
        "phonebackground",
        "phonebackgrounds",
        "desktopbackground",
        "desktopbackgrounds",
        "profile",
        "profilepicture",
        "profilepictures",
        "wallpaper",
        "wallpapers",
        "background",
        "backgrounds",
        "image",
        "images",
        "artwork",
        "media",
        "upload",
    }
    blocked.discard("")
    return compact_title in blocked


def is_bad_subject_title(title: object, category: object = "", subcategory: object = "") -> bool:
    cleaned = clean_title_text(str(title or ""))
    if not cleaned:
        return True
    if is_generic_title(cleaned):
        return True
    if is_category_as_title(cleaned, category, subcategory):
        return True
    return False


def safe_uncategorized_title(category: str | None, media_kind: str) -> str:
    if category == "Phone Backgrounds":
        return "Uncategorized Phone Background"
    if category == "Desktop Backgrounds":
        return "Uncategorized Desktop Background"
    if category == "Profile Pictures":
        return "Uncategorized Profile Picture"
    if category == "Wallpapers":
        return "Uncategorized Wallpaper"
    if media_kind == "video":
        return "Uncategorized Video"
    return "Uncategorized Media"


def build_title(path: Path, category: str | None = None, subcategory: str | None = None) -> str:
    cleaned = clean_title_text(path.stem)
    if cleaned and not is_bad_subject_title(cleaned, category, subcategory):
        return cleaned[:160]
    if subcategory and not is_bad_subject_title(subcategory, category, None):
        return f"{subcategory} - {category or 'Media'}"[:160]
    media_kind = "video" if path.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm", ".ogg"} else "image"
    return safe_uncategorized_title(category, media_kind)


def moderation(title: str, filename: str, tags: list[str]) -> dict[str, object]:
    combined = " ".join([title, filename, " ".join(tags)]).lower()
    normalized = re.sub(r"[^a-z0-9+]+", " ", combined)
    
    # Fix: Ensure whole-word matches so 'sex' doesn't flag 'sussex' or 'sextant'
    hits = sorted({word for word in ADULT_KEYWORDS if re.search(rf"\b{re.escape(word)}\b", normalized)})
    
    adult_by_ai = bool(hits)
    return {
        "is_adult": adult_by_ai,
        "adult_marked_by_user": False,
        "adult_marked_by_ai": adult_by_ai,
        "moderation_status": "adult" if adult_by_ai else "clear",
        "moderation_score": 0.96 if adult_by_ai else 0.0,
        "moderation_reason": (f"Automatic moderation matched: {', '.join(hits[:5])}." if hits else None),
    }


def add_tag(tags: list[str], value: object) -> None:
    text = str(value or "").strip().lower()
    if not text:
        return
    text = re.sub(r"[^a-z0-9+]+", "_", text).strip("_")
    if not text or is_noise_token(text):
        return
    if text not in tags:
        tags.append(text)


def extract_tags(path: Path, category: str, media_kind: str, size: tuple[int, int] | None, subcategory: str | None = None) -> list[str]:
    tags: list[str] = []
    artist_match = ARTIST_RE.search(path.stem.lower())

    for tag in CATEGORY_TAGS.get(category, []):
        add_tag(tags, tag)

    if subcategory:
        for token in clean_tokens(subcategory):
            add_tag(tags, token)
        add_tag(tags, subcategory)

    if media_kind == "video":
        add_tag(tags, "video")
    else:
        add_tag(tags, "image")
    if path.suffix.lower() == ".gif":
        add_tag(tags, "gif")
    if size:
        width, height = size
        if width > height:
            add_tag(tags, "landscape")
        elif height > width:
            add_tag(tags, "portrait")
        else:
            add_tag(tags, "square")
        if width >= 3840 or height >= 2160:
            add_tag(tags, "4k")
        elif width >= 2560 or height >= 1440:
            add_tag(tags, "1440p")
        elif width >= 1920 or height >= 1080:
            add_tag(tags, "1080p")
    if artist_match:
        add_tag(tags, artist_match.group(1).replace(".", "_"))
    for token in clean_tokens(path):
        add_tag(tags, token)
    return tags[:24]


def contains_phrase(haystack: str, phrase: str) -> bool:
    return bool(re.search(rf"(?<![a-z0-9]){re.escape(phrase.lower())}(?![a-z0-9])", haystack))


def detect_kpop_demon_hunters(haystack: str) -> tuple[str | None, str | None, list[str]]:
    normalized = normalize_text(haystack)
    
    # Fix: Ensure the markers are normalized the same way as the haystack (which lacks hyphens)
    marker_hit = any(normalize_text(marker) in normalized for marker in KPOP_DEMON_HUNTERS_MARKERS)
    
    matched_characters: list[str] = []
    for character, aliases in KPOP_DEMON_HUNTERS_CHARACTERS.items():
        if any(contains_phrase(normalized, alias) for alias in aliases):
            matched_characters.append(character)

    should_classify = marker_hit or "Rumi" in matched_characters or len(matched_characters) >= 2
    if not should_classify:
        return None, None, []

    subcategory = " & ".join(matched_characters) if matched_characters else None
    return KPOP_DEMON_HUNTERS_CATEGORY, subcategory, matched_characters


def build_description(
    *,
    title: str,
    category: str,
    subcategory: str | None,
    tags: list[str],
    source: str,
    analysis_reason: str | None,
) -> str:
    lines = [title.strip().rstrip(".") or "Imported media"]
    if subcategory and subcategory.lower() not in title.lower():
        lines.append(f"Featuring {subcategory}.")
    elif category and category.lower() not in title.lower() and category not in {"Uncategorized", "Other", "Misc"}:
        lines.append(f"Category: {category}.")

    source_line = {
        "visual-training": "Matched against the gallery's learned visual training memory.",
        "gallery-training": "Matched against the gallery's learned correction memory.",
        "ollama": "Analyzed by the gallery's local Ollama vision model.",
        "local-clip": "Analyzed by the gallery's local visual fallback model.",
        "domain-hint": "Matched by strong character or series hints already present in the metadata.",
    }.get(source, "")
    if source_line:
        lines.append(source_line)

    reason = " ".join(str(analysis_reason or "").strip().split())
    if reason:
        lines.append(reason.rstrip(".") + ".")
    if tags:
        lines.append("Tags: " + ", ".join(tags[:10]) + ".")
    return " ".join(part for part in lines if part).strip()[:2000]


def merge_analysis_and_rules(
    path: Path,
    media_kind: str,
    size: tuple[int, int] | None,
    analysis: object,
    base_category: str | None,
    base_subcategory: str | None,
) -> dict[str, object]:
    analysis_title = str(getattr(analysis, "title", "") or "")
    analysis_tags = list(getattr(analysis, "tags", []) or [])
    analysis_filename = str(getattr(analysis, "suggested_filename", "") or "")
    source = str(getattr(analysis, "source", "heuristic") or "heuristic")
    analysis_reason = str(getattr(analysis, "reason", "") or "")
    confidence = float(getattr(analysis, "confidence", 0.0) or 0.0)

    haystack = " ".join(
        [
            str(path),
            path.stem,
            analysis_title,
            " ".join(str(tag) for tag in analysis_tags),
            str(base_category or ""),
            str(base_subcategory or ""),
        ]
    )

    smart_category, smart_subcategory, matched_characters = detect_kpop_demon_hunters(haystack)

    category = smart_category or base_category or "Uncategorized"
    subcategory = smart_subcategory or base_subcategory

    if category != KPOP_DEMON_HUNTERS_CATEGORY:
        try:
            category, subcategory = canonical_category_pair(category, subcategory)
        except Exception:
            pass

    category = str(category or "Uncategorized").strip()
    subcategory = str(subcategory or "").strip() or None

    cleaned_ai_title = clean_title_text(analysis_title)
    if category == KPOP_DEMON_HUNTERS_CATEGORY and subcategory and not is_bad_subject_title(subcategory, category, None):
        title = f"{subcategory} - {KPOP_DEMON_HUNTERS_CATEGORY}"
    elif cleaned_ai_title and not is_bad_subject_title(cleaned_ai_title, category, subcategory):
        title = cleaned_ai_title
    elif subcategory and category and category not in {"Uncategorized", "Other", "Misc"} and not is_bad_subject_title(subcategory, category, None):
        title = f"{subcategory} - {category}"
    else:
        title = safe_uncategorized_title(category, media_kind)

    title = re.sub(r"\s+", " ", title).strip(" -")[:160]
    if is_bad_subject_title(title, category, subcategory):
        title = safe_uncategorized_title(category, media_kind)
    stored_filename = smart_filename(title, path, analysis_filename)

    tags = extract_tags(path, category, media_kind, size, subcategory)
    for character in matched_characters:
        add_tag(tags, character)
    for tag in analysis_tags:
        add_tag(tags, tag)
    for token in clean_tokens(analysis_title):
        add_tag(tags, token)
    for tag in CATEGORY_TAGS.get(category, []):
        add_tag(tags, tag)

    return {
        "category": category,
        "subcategory": subcategory,
        "title": title,
        "description": build_description(
            title=title,
            category=category,
            subcategory=subcategory,
            tags=tags[:24],
            source=source,
            analysis_reason=analysis_reason,
        ),
        "tags": tags[:24],
        "stored_filename": stored_filename,
        "source": source,
        "confidence": confidence,
        "analysis_reason": analysis_reason,
        "matched_characters": matched_characters,
    }


def smart_filename(title: str, path: Path, suggested_filename: str | None = None) -> str:
    ext = path.suffix.lower() or Path(str(suggested_filename or "")).suffix.lower() or ".bin"
    base = clean_title_text(title)
    if is_bad_subject_title(base, "", ""):
        base = clean_title_text(Path(str(suggested_filename or "")).stem)
    if is_bad_subject_title(base, "", ""):
        base = build_title(path)
    base = base.replace("/", "-").replace("\\", "-")
    base = re.sub(r"[:*?\"<>|]", "", base)
    base = re.sub(r"\s+", " ", base).strip(" ._-") or "Imported Media"
    max_base = max(20, 255 - len(ext))
    return f"{base[:max_base].rstrip()}{ext}"[:255]


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


def get_table_columns(cur: pymysql.cursors.Cursor, table_name: str) -> set[str]:
    cur.execute(f"SHOW COLUMNS FROM `{table_name}`")
    return {str(row[0]) for row in cur.fetchall()}


def update_row_dynamic(
    cur: pymysql.cursors.Cursor,
    table_name: str,
    key_column: str,
    key_value: object,
    values: dict[str, object],
    columns: set[str],
    raw_values: dict[str, str] | None = None,
) -> None:
    assignments: list[str] = []
    params: list[object] = []
    for column, value in values.items():
        if column not in columns:
            continue
        assignments.append(f"`{column}`=%s")
        params.append(value)
    for column, expression in (raw_values or {}).items():
        if column not in columns:
            continue
        assignments.append(f"`{column}`={expression}")
    if not assignments:
        return
    params.append(key_value)
    cur.execute(
        f"UPDATE `{table_name}` SET {', '.join(assignments)} WHERE `{key_column}`=%s",
        tuple(params),
    )


def prepare_media_item(
    path: Path,
    sha: str,
    ai_enabled: bool,
    ai_api_key: str,
    ai_base_url: str,
    ai_model: str,
    ai_timeout_seconds: int,
    training_examples: list[dict[str, Any]] | None = None,
) -> dict[str, object]:
    mime_type, media_kind = detect_media(path)
    size = image_size(path) if media_kind == "image" else video_size(path)
    analysis = analyze_media_path(
        path,
        mime_type=mime_type,
        media_kind=media_kind,
        ai_enabled=ai_enabled,
        ai_api_key=ai_api_key,
        ai_base_url=ai_base_url,
        ai_model=ai_model,
        ai_timeout_seconds=ai_timeout_seconds,
        training_examples=training_examples or [],
    )
    base_category, base_subcategory = canonical_category_pair(
        getattr(analysis, "category_name", None),
        getattr(analysis, "subcategory_name", None),
    )
    smart = merge_analysis_and_rules(path, media_kind, size, analysis, base_category, base_subcategory)
    return {
        "path": path,
        "sha": sha,
        "mime_type": mime_type,
        "media_kind": media_kind,
        "size": size,
        **smart,
    }


def fetch_existing_media_by_sha(cur: pymysql.cursors.Cursor, media_item_columns: set[str]) -> dict[str, list[dict[str, object]]]:
    where_deleted = " AND deleted_at IS NULL" if "deleted_at" in media_item_columns else ""
    fields = ["id", "content_sha256"]
    if "media_file_id" in media_item_columns:
        fields.append("media_file_id")
    if "title" in media_item_columns:
        fields.append("title")
    if "original_filename" in media_item_columns:
        fields.append("original_filename")
    cur.execute(
        f"SELECT {', '.join('`' + field + '`' for field in fields)} "
        f"FROM media_items WHERE content_sha256 IS NOT NULL{where_deleted}"
    )
    result: dict[str, list[dict[str, object]]] = {}
    for row in cur.fetchall():
        record = dict(zip(fields, row))
        sha = str(record.get("content_sha256") or "")
        if sha:
            result.setdefault(sha, []).append(record)
    return result


def update_existing_media(
    cur: pymysql.cursors.Cursor,
    item: dict[str, object],
    existing_rows: list[dict[str, object]],
    media_item_columns: set[str],
    media_file_columns: set[str],
    existing_file_ids: dict[str, int],
) -> int:
    category_id = ensure_category(cur, str(item["category"]), str(item["media_kind"]))
    subcategory_id = ensure_subcategory(cur, category_id, str(item.get("subcategory") or "").strip() or None)
    title = str(item["title"])[:160]
    tags = list(item.get("tags") or [])
    stored_filename = str(item.get("stored_filename") or Path(str(item["path"])).name)[:255]
    moderation_bits = moderation(title, stored_filename, tags)

    common_values: dict[str, object] = {
        "category_id": category_id,
        "subcategory_id": subcategory_id,
        "title": title,
        "description": str(item.get("description") or "")[:2000] or None,
        "tags": json.dumps(tags),
        "media_kind": str(item["media_kind"]),
        "mime_type": str(item["mime_type"])[:120],
        "original_filename": stored_filename,
        "is_adult": 1 if moderation_bits["is_adult"] else 0,
        "adult_marked_by_user": 1 if moderation_bits["adult_marked_by_user"] else 0,
        "adult_marked_by_ai": 1 if moderation_bits["adult_marked_by_ai"] else 0,
        "moderation_status": str(moderation_bits["moderation_status"])[:30],
        "moderation_score": float(moderation_bits["moderation_score"]),
        "moderation_reason": moderation_bits["moderation_reason"],
    }
    raw_values = {"moderated_at": "CURRENT_TIMESTAMP", "updated_at": "CURRENT_TIMESTAMP"}

    updated = 0
    for row in existing_rows:
        update_row_dynamic(
            cur,
            "media_items",
            "id",
            row["id"],
            common_values,
            media_item_columns,
            raw_values=raw_values,
        )
        updated += 1

        media_file_id = row.get("media_file_id") or existing_file_ids.get(str(item["sha"]))
        if media_file_id and "original_filename" in media_file_columns:
            update_row_dynamic(
                cur,
                "media_files",
                "id",
                media_file_id,
                {"original_filename": stored_filename, "mime_type": str(item["mime_type"])[:120], "media_kind": str(item["media_kind"])},
                media_file_columns,
            )
    return updated


def insert_new_media(
    cur: pymysql.cursors.Cursor,
    item: dict[str, object],
    user_id: int,
    existing_file_ids: dict[str, int],
) -> int:
    path = Path(str(item["path"]))
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
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'public', 1, 1, NULL, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)
        """,
        (
            user_id,
            category_id,
            subcategory_id,
            title[:160],
            str(item.get("description") or "")[:2000] or None,
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
    return int(cur.lastrowid)


def _decode_json_list(value: object) -> list[str]:
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value or "").strip()
    if not text:
        return []
    try:
        payload = json.loads(text)
    except Exception:
        return []
    if not isinstance(payload, list):
        return []
    return [str(item).strip() for item in payload if str(item).strip()]


def load_training_examples(
    cur: pymysql.cursors.Cursor,
    user_id: int,
    *,
    limit: int = 500,
) -> list[dict[str, Any]]:
    cur.execute(
        """
        SELECT id, media_id, original_filename, source_title, source_category_name, source_subcategory_name,
               source_tags, corrected_title, corrected_category_name, corrected_subcategory_name,
               corrected_tags, corrected_is_adult, notes, image_phash, image_dhash, image_width, image_height,
               training_origin, training_confidence, created_at
        FROM ai_vision_training_examples
        WHERE user_id=%s
        ORDER BY created_at DESC
        LIMIT %s
        """,
        (int(user_id), max(1, min(int(limit or 500), 5000))),
    )
    rows = cur.fetchall()
    examples: list[dict[str, Any]] = []
    for row in rows:
        examples.append(
            {
                "id": row[0],
                "media_id": row[1],
                "original_filename": row[2],
                "source_title": row[3],
                "source_category_name": row[4],
                "source_subcategory_name": row[5],
                "source_tags": _decode_json_list(row[6]),
                "corrected_title": row[7],
                "corrected_category_name": row[8],
                "corrected_subcategory_name": row[9],
                "corrected_tags": _decode_json_list(row[10]),
                "corrected_is_adult": bool(row[11]),
                "notes": row[12],
                "image_phash": row[13],
                "image_dhash": row[14],
                "image_width": row[15],
                "image_height": row[16],
                "training_origin": row[17],
                "training_confidence": float(row[18] or 0.0),
                "created_at": row[19].isoformat() if hasattr(row[19], "isoformat") else row[19],
            }
        )
    return examples


def main() -> int:
    parser = argparse.ArgumentParser(description="Import iCloud Photos into the Image Gallery database and smart-retag existing uploads.")
    parser.add_argument("--folder", default="/home/desmond/Pictures/iCloud Photos")
    parser.add_argument("--limit", type=int, default=0, help="Only process the first N importable files from the source folder.")
    parser.add_argument("--dry-run", action="store_true", help="Preview imports/updates without writing to MariaDB.")
    parser.add_argument("--no-update-existing", action="store_true", help="Do not update existing database media matched by SHA256.")
    parser.add_argument("--no-import-new", action="store_true", help="Only retag/update existing uploads; do not import new files.")
    parser.add_argument("--sample", type=int, default=12, help="Number of planned changes to print during dry-run.")
    parser.add_argument("--force-ai", action="store_true", help="Force AI analysis on even if .env says GALLERY_AI_ENABLED=false.")
    parser.add_argument("--only-training-recognized", action="store_true", help="Only import/update files the gallery training memory recognized directly.")
    parser.add_argument("--min-confidence", type=float, default=0.0, help="Skip prepared items below this confidence threshold.")
    parser.add_argument("--training-limit", type=int, default=500, help="How many gallery training examples to preload from MariaDB.")
    args = parser.parse_args()

    gallery_root = PROJECT_ROOT
    env_file = load_env_file(gallery_root / ".env")
    apply_env_file(env_file)

    db_host = env_or_file("GALLERY_DB_HOST", env_file, "127.0.0.1")
    db_port = int(env_or_file("GALLERY_DB_PORT", env_file, "3306"))
    db_user = env_or_file("GALLERY_DB_USER", env_file, "botuser")
    db_password = env_or_file("GALLERY_DB_PASSWORD", env_file, "")
    db_name = env_or_file("GALLERY_DB_SCHEMA", env_file, "image_gallery")
    source_dir = Path(args.folder).expanduser()
    ai_enabled = args.force_ai or (env_or_file("GALLERY_AI_ENABLED", env_file, "false").lower() not in {"0", "false", "no", "off"})
    ai_provider = env_or_file("GALLERY_AI_PROVIDER", env_file, "ollama" if env_or_file("GALLERY_OLLAMA_MODEL", env_file, "") else "openai").lower()
    ai_api_key = env_or_file("GALLERY_AI_API_KEY", env_file, env_or_file("OPENAI_API_KEY", env_file, ""))
    if ai_provider == "ollama":
        ai_base_url = env_or_file("GALLERY_OLLAMA_BASE_URL", env_file, "http://127.0.0.1:11434").rstrip("/")
        ai_model = env_or_file("GALLERY_OLLAMA_MODEL", env_file, "qwen2.5vl:3b")
    else:
        ai_base_url = env_or_file("GALLERY_AI_BASE_URL", env_file, env_or_file("OPENAI_BASE_URL", env_file, "https://api.openai.com/v1")).rstrip("/")
        ai_model = env_or_file("GALLERY_AI_MODEL", env_file, "gpt-5.4-nano")
    ai_timeout_seconds = int(env_or_file("GALLERY_AI_TIMEOUT_SECONDS", env_file, "120"))

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
    updated = 0
    skipped_existing = 0
    skipped_new = 0
    failed = 0
    import_counts: Counter[str] = Counter()
    update_counts: Counter[str] = Counter()
    error_paths: list[str] = []

    try:
        with conn.cursor() as cur:
            media_item_columns = get_table_columns(cur, "media_items")
            media_file_columns = get_table_columns(cur, "media_files")

            cur.execute("SELECT id FROM users ORDER BY id LIMIT 1")
            user_row = cur.fetchone()
            if not user_row and not args.no_import_new:
                raise SystemExit("No gallery user exists yet.")
            user_id = int(user_row[0]) if user_row else 0
            training_examples = load_training_examples(cur, user_id, limit=args.training_limit) if user_id else []

            existing_media_by_sha = fetch_existing_media_by_sha(cur, media_item_columns)

            cur.execute("SELECT sha256, id FROM media_files")
            existing_file_ids = {row[0]: int(row[1]) for row in cur.fetchall() if row[0]}

            files = sorted(
                [
                    path for path in source_dir.rglob("*")
                    if path.is_file() and path.suffix.lower() in SAFE_EXTENSIONS
                ],
                key=lambda path: path.name.lower(),
            )
            if args.limit > 0:
                files = files[:args.limit]

            planned_imports: list[dict[str, object]] = []
            planned_updates: list[dict[str, object]] = []
            prepared_shas: set[str] = set()

            for path in files:
                try:
                    sha = sha256_file(path)
                    if sha in prepared_shas:
                        continue
                    prepared_shas.add(sha)
                    item = prepare_media_item(
                        path,
                        sha,
                        ai_enabled=ai_enabled,
                        ai_api_key=ai_api_key,
                        ai_base_url=ai_base_url,
                        ai_model=ai_model,
                        ai_timeout_seconds=ai_timeout_seconds,
                        training_examples=training_examples,
                    )
                    confidence = float(item.get("confidence") or 0.0)
                    source = str(item.get("source") or "").strip().lower()
                    if args.only_training_recognized and source not in TRAINING_RECOGNIZED_SOURCES:
                        continue
                    if confidence < float(args.min_confidence or 0.0):
                        continue
                    existing_rows = existing_media_by_sha.get(sha, [])
                    if existing_rows:
                        if args.no_update_existing:
                            skipped_existing += len(existing_rows)
                            continue
                        item["existing_rows"] = existing_rows
                        planned_updates.append(item)
                    else:
                        if args.no_import_new:
                            skipped_new += 1
                            continue
                        planned_imports.append(item)
                except Exception as exc:
                    failed += 1
                    error_paths.append(f"{path}: {exc}")

            print(json.dumps(
                {
                    "project_root": str(gallery_root),
                    "source_folder": str(source_dir),
                    "ai_enabled": ai_enabled,
                    "ai_provider": ai_provider,
                    "ai_base_url": ai_base_url,
                    "ai_model": ai_model,
                    "loaded_training_examples": len(training_examples),
                    "only_training_recognized": bool(args.only_training_recognized),
                    "min_confidence": float(args.min_confidence or 0.0),
                    "planned_new_imports": len(planned_imports),
                    "planned_existing_updates": sum(len(item.get("existing_rows", [])) for item in planned_updates),
                    "skipped_existing": skipped_existing,
                    "skipped_new_due_to_no_import_new": skipped_new,
                    "failed_to_prepare": failed,
                    "planned_new_by_source": dict(Counter(str(item.get("source") or "unknown") for item in planned_imports).most_common()),
                    "planned_updates_by_source": dict(Counter(str(item.get("source") or "unknown") for item in planned_updates).most_common()),
                    "new_import_category_breakdown": dict(Counter(str(item["category"]) for item in planned_imports).most_common()),
                    "update_category_breakdown": dict(Counter(str(item["category"]) for item in planned_updates).most_common()),
                },
                indent=2,
            ))

            if args.dry_run:
                examples = planned_updates[: args.sample] + planned_imports[: max(0, args.sample - len(planned_updates[: args.sample]))]
                if examples:
                    print("\nSample planned smart names/tags:")
                    for item in examples:
                        action = "UPDATE" if item in planned_updates else "IMPORT"
                        print(
                            f"- {action}: {Path(str(item['path'])).name} -> "
                            f"title={item['title']!r}, category={item['category']!r}, "
                            f"subcategory={item.get('subcategory')!r}, source={item.get('source')!r}, "
                            f"confidence={float(item.get('confidence') or 0.0):.3f}, tags={item.get('tags', [])[:10]}"
                        )
                if error_paths:
                    print("\nPreparation errors:")
                    for line in error_paths[:20]:
                        print(line)
                return 0

            for index, item in enumerate(planned_updates, start=1):
                try:
                    count = update_existing_media(
                        cur,
                        item,
                        list(item.get("existing_rows") or []),
                        media_item_columns,
                        media_file_columns,
                        existing_file_ids,
                    )
                    conn.commit()
                    updated += count
                    update_counts[str(item["category"])] += count
                    print(f"[update {index}/{len(planned_updates)}] updated {count} row(s): {Path(str(item['path'])).name} -> {item['title']}")
                except Exception as exc:
                    conn.rollback()
                    failed += 1
                    error_paths.append(f"{item.get('path')}: {exc}")
                    print(f"[update {index}/{len(planned_updates)}] failed {Path(str(item.get('path'))).name}: {exc}")

            for index, item in enumerate(planned_imports, start=1):
                try:
                    insert_new_media(cur, item, user_id, existing_file_ids)
                    conn.commit()
                    imported += 1
                    import_counts[str(item["category"])] += 1
                    existing_media_by_sha.setdefault(str(item["sha"]), [])
                    print(f"[import {index}/{len(planned_imports)}] imported {Path(str(item['path'])).name} -> {item['title']} ({item['category']})")
                except Exception as exc:
                    conn.rollback()
                    failed += 1
                    error_paths.append(f"{item.get('path')}: {exc}")
                    print(f"[import {index}/{len(planned_imports)}] failed {Path(str(item.get('path'))).name}: {exc}")

            print(json.dumps(
                {
                    "updated_existing_rows": updated,
                    "imported_new": imported,
                    "failed": failed,
                    "updated_by_category": dict(update_counts.most_common()),
                    "imported_by_category": dict(import_counts.most_common()),
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
