#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.ai_metadata import analyze_media_path  # noqa: E402
from app.config import load_settings  # noqa: E402


def _load_training_jsonl(path: str) -> list[dict[str, Any]]:
    if not path:
        return []
    rows: list[dict[str, Any]] = []
    p = Path(path).expanduser()
    with p.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            rows.append({
                "original_filename": row.get("original_filename"),
                "corrected_title": row.get("title") or row.get("corrected_title"),
                "corrected_category_name": row.get("category_name") or row.get("corrected_category_name"),
                "corrected_subcategory_name": row.get("subcategory_name") or row.get("corrected_subcategory_name"),
                "corrected_tags": row.get("tags") or row.get("corrected_tags") or [],
                "corrected_is_adult": row.get("is_adult") or row.get("corrected_is_adult") or False,
                "image_phash": row.get("image_phash"),
                "image_dhash": row.get("image_dhash"),
                "image_width": row.get("image_width"),
                "image_height": row.get("image_height"),
                "training_confidence": row.get("confidence") or row.get("training_confidence") or 0.72,
            })
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Image Gallery analyzer against local images and print JSON results.")
    parser.add_argument("images", nargs="+")
    parser.add_argument("--training-jsonl", default="", help="Optional review JSONL from seed_ai_vision_training_from_image_zip.py")
    parser.add_argument("--no-ai", action="store_true", help="Disable remote/local model calls and test fallback/training logic only.")
    args = parser.parse_args()
    settings = load_settings()
    training_examples = _load_training_jsonl(args.training_jsonl)
    for raw in args.images:
        path = Path(raw).expanduser().resolve()
        mime_type = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        analysis = analyze_media_path(
            path,
            mime_type=mime_type,
            media_kind="image",
            ai_enabled=False if args.no_ai else settings.ai_enabled,
            ai_api_key=settings.ai_api_key,
            ai_base_url=settings.active_ai_base_url,
            ai_model=settings.active_ai_model,
            ai_timeout_seconds=settings.ai_timeout_seconds,
            training_examples=training_examples,
        )
        print(json.dumps({"file": str(path), "analysis": analysis.to_dict()}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
