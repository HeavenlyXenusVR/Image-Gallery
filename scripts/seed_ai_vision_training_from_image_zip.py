#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import mimetypes
import sys
import tempfile
from pathlib import Path
from typing import Any
from zipfile import ZipFile

import aiomysql

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.ai_metadata import (  # noqa: E402
    analyze_media_path,
    _domain_hint_analysis_from_text,
    _filename_subject_text,
    _image_fingerprint,
    _merge_tags,
    _normalize_tags,
    _clean_title,
    _clean_label,
    SmartMediaAnalysis,
)
from app.config import load_settings  # noqa: E402
from app.database import GalleryDatabase  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".tif", ".tiff", ".heic", ".heif"}
SKIP_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".flv", ".3gp", ".mpeg", ".mpg"}


KNOWN_IMAGE_FILENAME_OVERRIDES: dict[str, dict[str, Any]] = {
    # Hand-labeled from the user-provided test images in this debugging session.
    "wp15784703-kpop-demon-hunters-huntrx-wallpapers": {
        "title": "Mira, Rumi, and Zoey",
        "category_name": "KPOP Demon Hunters",
        "subcategory_name": "Huntrix",
        "tags": ["mira", "rumi", "zoey", "huntrix", "kpop demon hunters", "ramen"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Huntrix ramen reference image.",
        "source": "manual-dataset-label",
    },
    "winter_s_warmth_by_helmie_art_dc05svj-pre": {
        "title": "Mane Six Winter Warmth",
        "category_name": "My Little Pony",
        "subcategory_name": "Mane Six",
        "tags": ["mane six", "twilight sparkle", "rainbow dash", "fluttershy", "pinkie pie", "rarity", "applejack", "winter", "fireplace"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Mane Six fireplace reference image.",
        "source": "manual-dataset-label",
    },
    "vinyl_scratch_mlp_the_movie_vector_by_theretroart88_dd1fuay-pre": {
        "title": "Vinyl Scratch",
        "category_name": "My Little Pony",
        "subcategory_name": "Vinyl Scratch",
        "tags": ["vinyl scratch", "dj pon-3", "mlp", "my little pony", "music"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Vinyl Scratch reference image.",
        "source": "manual-dataset-label",
    },
    "twiggles_by_xenia_amata_ddfw6pl-pre": {
        "title": "Twilight Sparkle",
        "category_name": "My Little Pony",
        "subcategory_name": "Twilight Sparkle",
        "tags": ["twilight sparkle", "alicorn", "mlp", "my little pony", "wings"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Twilight Sparkle portrait reference image.",
        "source": "manual-dataset-label",
    },
    "the_spark_from_the_past_by_sourcerabbit_d92g94g-pre": {
        "title": "Mane Six Group Hug",
        "category_name": "My Little Pony",
        "subcategory_name": "Mane Six",
        "tags": ["mane six", "twilight sparkle", "rainbow dash", "fluttershy", "pinkie pie", "rarity", "applejack", "group hug"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Mane Six cuddle reference image.",
        "source": "manual-dataset-label",
    },
    "the_new_cafeteria_song_by_cmnieto_dk1wbrl": {
        "title": "Equestria Girls Group",
        "category_name": "My Little Pony",
        "subcategory_name": "Equestria Girls",
        "tags": ["equestria girls", "twilight sparkle", "sunset shimmer", "rainbow dash", "applejack", "fluttershy", "pinkie pie", "rarity", "mlp"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Equestria Girls group reference image.",
        "source": "manual-dataset-label",
    },
    "the_little_planet_by_powdan_dbc7zj7-pre": {
        "title": "Mane Six and Spike",
        "category_name": "My Little Pony",
        "subcategory_name": "Mane Six",
        "tags": ["mane six", "spike", "twilight sparkle", "rainbow dash", "fluttershy", "pinkie pie", "rarity", "applejack", "earth"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Mane Six and Spike planet reference image.",
        "source": "manual-dataset-label",
    },
    "the_dazzlings___mlp_eg_by_minusclass_dg84kn0": {
        "title": "The Dazzlings",
        "category_name": "My Little Pony",
        "subcategory_name": "Equestria Girls",
        "tags": ["the dazzlings", "aria blaze", "adagio dazzle", "sonata dusk", "mlp", "equestria girls"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Dazzlings bat-wing reference image.",
        "source": "manual-dataset-label",
    },
    "reindeer_dash_by_psfmer_dfjvwor-pre": {
        "title": "Rainbow Dash",
        "category_name": "My Little Pony",
        "subcategory_name": "Rainbow Dash",
        "tags": ["rainbow dash", "mlp", "my little pony", "winter", "reindeer", "snow"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Rainbow Dash winter reference image.",
        "source": "manual-dataset-label",
    },
    "mira-huntrix-5120x2880-33629": {
        "title": "Mira",
        "category_name": "KPOP Demon Hunters",
        "subcategory_name": "Mira",
        "tags": ["mira", "huntrix", "kpop demon hunters", "sword", "neon"],
        "confidence": 0.95,
        "reason": "Hand-labeled from the uploaded Mira promo reference image.",
        "source": "manual-dataset-label",
    },
    "two_wheeled_rainbow_by_sourcerabbit_d8iutaz-pre": {
        "title": "Rainbow Dash",
        "category_name": "My Little Pony",
        "subcategory_name": "Equestria Girls",
        "tags": ["rainbow dash", "mlp", "equestria girls", "motorcycle", "rainbow hair"],
        "confidence": 0.94,
        "reason": "Hand-labeled from the uploaded Rainbow Dash motorcycle reference image.",
        "source": "manual-dataset-label",
    },
    "0a512b46-bb67-4cdc-a911-b9b2989abe9e": {
        "title": "The Dazzlings",
        "category_name": "My Little Pony",
        "subcategory_name": "Equestria Girls",
        "tags": ["the dazzlings", "aria blaze", "adagio dazzle", "sonata dusk", "mlp", "equestria girls"],
        "confidence": 0.90,
        "reason": "Hand-labeled from the uploaded Dazzlings reference image.",
        "source": "manual-dataset-label",
    },
    "71d4751efa2c41fec0cd6d4135b9efd1": {
        "title": "Equestria Girls Group",
        "category_name": "My Little Pony",
        "subcategory_name": "Equestria Girls",
        "tags": ["equestria girls", "pinkie pie", "sunset shimmer", "twilight sparkle", "spike", "fluttershy", "applejack", "mlp"],
        "confidence": 0.82,
        "reason": "Hand-labeled from the uploaded Equestria Girls group reference image.",
        "source": "manual-dataset-label",
    },
}


def _fallback_for(path: Path, size: tuple[int, int] | None = None) -> SmartMediaAnalysis:
    width, height = size or (0, 0)
    if width and height and width > height:
        category = "Desktop Backgrounds"
    elif width and height and height > width:
        category = "Phone Backgrounds"
    else:
        category = "Wallpapers"
    return SmartMediaAnalysis(
        title="Uncategorized Wallpaper",
        suggested_filename="uncategorized-wallpaper.jpg",
        tags=["wallpaper"],
        category_name=category,
        subcategory_name=None,
        subcategory_names=[],
        is_adult=False,
        source="dataset-seed",
        confidence=0.40,
        size=size,
    )


def _iter_images(input_path: Path) -> tuple[list[Path], tempfile.TemporaryDirectory[str] | None]:
    if input_path.is_dir():
        files = [p for p in input_path.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS]
        return sorted(files), None
    if input_path.is_file() and input_path.suffix.lower() == ".zip":
        tmp = tempfile.TemporaryDirectory(prefix="gallery-ai-seed-")
        root = Path(tmp.name)
        with ZipFile(input_path) as z:
            safe_members = []
            for info in z.infolist():
                name = info.filename.replace("\\", "/")
                if name.startswith("/") or ".." in Path(name).parts:
                    continue
                if Path(name).suffix.lower() in IMAGE_EXTS:
                    safe_members.append(info)
            z.extractall(root, safe_members)
        files = [p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in IMAGE_EXTS]
        return sorted(files), tmp
    raise SystemExit(f"Input must be an image folder or .zip file: {input_path}")


def _mime_for(path: Path) -> str:
    return mimetypes.guess_type(path.name)[0] or "image/jpeg"


def _candidate_from_image(path: Path, *, include_weak: bool = False, use_ai: bool = False, settings: Any | None = None) -> dict[str, Any] | None:
    content = path.read_bytes()
    fingerprint = _image_fingerprint(content, path.name, _mime_for(path), "image") or {}
    size = None
    if fingerprint.get("image_width") and fingerprint.get("image_height"):
        size = (int(fingerprint["image_width"]), int(fingerprint["image_height"]))
    fallback = _fallback_for(path, size=size)
    lowered_name = path.name.lower()
    result = None
    for key, override in KNOWN_IMAGE_FILENAME_OVERRIDES.items():
        if key in lowered_name:
            result = dict(override)
            break
    if not result:
        result = _domain_hint_analysis_from_text(
            filename=path.name,
            title_hint="",
            description_hint="",
            tags_hint=[],
            fallback=fallback,
        )
    subject_text = _filename_subject_text(path.name)
    if not result and use_ai and settings is not None:
        try:
            analysis = analyze_media_path(
                path,
                mime_type=_mime_for(path),
                media_kind="image",
                title_hint="",
                description_hint="",
                tags_hint=[],
                ai_enabled=True,
                ai_api_key=settings.ai_api_key,
                ai_base_url=settings.active_ai_base_url,
                ai_model=settings.active_ai_model,
                ai_timeout_seconds=settings.ai_timeout_seconds,
                training_examples=[],
            )
            payload = analysis.to_dict()
            if payload.get("source") not in {"heuristic", "domain-hint"} and float(payload.get("confidence") or 0.0) >= 0.55:
                result = {
                    "title": payload.get("title"),
                    "tags": payload.get("tags") or [],
                    "category_name": payload.get("category_name"),
                    "subcategory_name": payload.get("subcategory_name"),
                    "is_adult": payload.get("is_adult"),
                    "confidence": payload.get("confidence"),
                    "reason": payload.get("reason") or "Seeded by configured vision model.",
                    "source": payload.get("source") or "vision-model-seed",
                }
        except Exception as exc:
            if include_weak:
                print(f"vision_seed_warning file={path.name!r} error={str(exc)[:180]}", flush=True)

    if not result and include_weak and subject_text:
        pretty = _clean_title(subject_text.replace("_", " ").replace("-", " "))
        if pretty:
            result = {
                "title": pretty,
                "tags": _normalize_tags(pretty.split()),
                "category_name": fallback.category_name or "Wallpapers",
                "subcategory_name": fallback.subcategory_name or "",
                "is_adult": False,
                "confidence": 0.52,
                "reason": "Weak filename subject seed; review recommended.",
                "source": "weak-filename-seed",
            }
    if not result:
        return None

    title = _clean_title(result.get("title"))
    if not title:
        return None
    tags = _merge_tags(_normalize_tags(result.get("tags") or []), [])
    if result.get("category_name"):
        tags = _merge_tags(tags, _normalize_tags([str(result["category_name"])]))
    if result.get("subcategory_name"):
        tags = _merge_tags(tags, _normalize_tags([str(result["subcategory_name"])]))

    return {
        "path": str(path),
        "original_filename": path.name,
        "title": title,
        "category_name": _clean_label(result.get("category_name")) or fallback.category_name or "Wallpapers",
        "subcategory_name": _clean_label(result.get("subcategory_name")) or fallback.subcategory_name or "",
        "tags": tags,
        "is_adult": bool(result.get("is_adult")),
        "confidence": float(result.get("confidence") or 0.66),
        "source": result.get("source") or "dataset-seed",
        "reason": result.get("reason") or "Seeded from known gallery character/franchise aliases.",
        **fingerprint,
    }


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
            return int(row["id"])


async def seed_dataset(args: argparse.Namespace) -> None:
    input_path = Path(args.input).expanduser().resolve()
    files, tmp = _iter_images(input_path)
    try:
        files = files[: max(1, int(args.limit or len(files)))]
        settings = load_settings()
        db = GalleryDatabase(settings)
        await db.connect()
        try:
            user_id = await _resolve_user_id(db, user_id=args.user_id, username=args.username)
            created = 0
            skipped = 0
            candidates: list[dict[str, Any]] = []
            for index, path in enumerate(files, 1):
                candidate = _candidate_from_image(path, include_weak=bool(args.include_weak), use_ai=bool(args.use_ai), settings=settings)
                if not candidate or float(candidate.get("confidence") or 0.0) < float(args.min_confidence):
                    skipped += 1
                    continue
                candidates.append(candidate)
                if args.dry_run:
                    continue
                source = {
                    "original_filename": candidate["original_filename"],
                    "title": candidate["title"],
                    "category_name": candidate["category_name"],
                    "subcategory_name": candidate["subcategory_name"],
                    "tags": candidate["tags"],
                    "image_phash": candidate.get("image_phash"),
                    "image_dhash": candidate.get("image_dhash"),
                    "image_width": candidate.get("image_width"),
                    "image_height": candidate.get("image_height"),
                    "training_origin": "image-zip-seed",
                    "training_confidence": candidate.get("confidence"),
                }
                corrected = {
                    "title": candidate["title"],
                    "category_name": candidate["category_name"],
                    "subcategory_name": candidate["subcategory_name"],
                    "tags": candidate["tags"],
                    "is_adult": candidate["is_adult"],
                    "training_confidence": candidate.get("confidence"),
                }
                example = await db.record_ai_vision_training_example(
                    user_id=user_id,
                    media_id=None,
                    source=source,
                    corrected=corrected,
                    notes=f"Seeded from image dataset: {candidate.get('reason')}",
                )
                if example:
                    created += 1
                if index % 100 == 0:
                    print(f"processed={index} candidates={len(candidates)} created={created} skipped={skipped}", flush=True)

            if args.review_jsonl:
                out = Path(args.review_jsonl).expanduser().resolve()
                out.parent.mkdir(parents=True, exist_ok=True)
                with out.open("w", encoding="utf-8") as handle:
                    for candidate in candidates:
                        handle.write(json.dumps(candidate, ensure_ascii=False) + "\n")
                print(f"review_jsonl={out}")
            print(
                f"ai_vision_image_seeded={created} candidates={len(candidates)} scanned={len(files)} skipped={skipped} user_id={user_id} dry_run={bool(args.dry_run)}"
            )
        finally:
            await db.close()
    finally:
        if tmp is not None:
            tmp.cleanup()


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed Image Gallery AI vision training from a compressed image folder/zip using visual hashes and known character aliases.")
    parser.add_argument("input", help="Image folder or .zip file")
    parser.add_argument("--user-id", type=int, default=None)
    parser.add_argument("--username", default=None)
    parser.add_argument("--limit", type=int, default=5000)
    parser.add_argument("--min-confidence", type=float, default=0.60)
    parser.add_argument("--include-weak", action="store_true", help="Also seed weak filename-derived titles. Leave off for cleaner training.")
    parser.add_argument("--use-ai", action="store_true", help="Use the configured Ollama/Gemini/OpenAI vision model to label low-signal images before seeding.")
    parser.add_argument("--review-jsonl", default="", help="Write proposed training rows to JSONL for review.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    asyncio.run(seed_dataset(args))


if __name__ == "__main__":
    main()
