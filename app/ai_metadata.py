from __future__ import annotations

import base64
import io
import json
import mimetypes
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .classification import canonical_category_pair, clean_tokens, infer_category_pair


TOKEN_RE = re.compile(r"[a-z0-9]{2,}")
STOP_TAGS = {
    "the", "and", "for", "with", "from", "fullview", "generated", "image",
    "standard", "lite", "upscayl", "wallpaper", "desktop", "phone",
    "background", "backgrounds", "version", "text", "movie", "poster", "upload",
    "artwork", "fanart", "pic", "photo", "picture",
    "by", "artist", "source", "ai", "enhanced", "upscaled", "upscale", "compressed", "icloud",
}
LOW_SIGNAL_RE = re.compile(
    r"^(?:img|dsc|pxl|mvimg|screenshot|image|photo|video|scan|untitled|temp|"
    r"whatsapp image|snapchat|signal)[ _-]*\d*$",
    re.IGNORECASE,
)
HEXISH_RE = re.compile(r"^[0-9a-f]{8,}$", re.IGNORECASE)
GENERIC_TITLE_RE = re.compile(
    r"^(?:background|backgrounds|wallpaper|wallpapers|image|images|photo|photos|"
    r"picture|pictures|art|artwork|fanart|render|renders|edit|edits|desktop background|"
    r"phone background|desktop wallpaper|phone wallpaper|imported media|imported image|"
    r"imported video|imported gif)\s*$",
    re.IGNORECASE,
)
NOISE_TOKEN_RE = re.compile(
    r"^(?:wp\d+|img[_-]?\d+|dsc[_-]?\d+|pxl[_-]?\d+|mvimg[_-]?\d+|screenshot[_-]?\d+|photo[_-]?\d+|image[_-]?\d+|"
    r"\d{2,}|[a-f0-9]{8,}|\d{3,4}x\d{3,4}|\d{3,4}p|4k|8k|uhd|fhd|qhd|desktop|phone|backgrounds?|wallpapers?|wallpaper)$",
    re.IGNORECASE,
)
KNOWN_CATEGORIES = [
    "My Little Pony",
    "FNAF",
    "GIFs",
    "KPOP Demon Hunters",
    "Videos",
    "Crossovers",
    "Hyperdimension Neptunia",
    "Profile Pictures",
    "Cartoon",
    "Memes",
    "Resident Evil",
    "Final Fantasy",
    "Xenoblade",
    "Sonic",
    "Desktop Backgrounds",
    "Phone Backgrounds",
    "Wallpapers",
]
CHARACTER_RECOGNITION_GUIDE = {
    "My Little Pony / Equestria Girls": [
        "Aria Blaze", "Adagio Dazzle", "Sonata Dusk", "Dazzlings", "Sunset Shimmer",
        "Twilight Sparkle", "Fluttershy", "Rainbow Dash", "Pinkie Pie", "Rarity", "Applejack",
        "Starlight Glimmer", "Trixie", "Princess Celestia", "Princess Luna",
    ],
    "Five Nights at Freddy's": [
        "Freddy Fazbear", "Bonnie", "Chica", "Foxy", "Roxanne Wolf", "Roxy", "Frenni",
    ],
    "Final Fantasy": ["Cloud Strife", "Tifa Lockhart", "Aerith Gainsborough", "Sephiroth"],
    "Resident Evil": ["Leon Kennedy", "Ada Wong", "Jill Valentine", "Claire Redfield", "Ashley Graham", "Albert Wesker"],
    "Sonic": ["Sonic", "Shadow", "Amy Rose", "Tails", "Knuckles", "Rouge"],
    "Xenoblade": ["Pyra", "Mythra", "Nia", "Mio", "Eunie", "Noah"],
    "Hyperdimension Neptunia": ["Neptune", "Nepgear", "Noire", "Blanc", "Vert", "Uzume", "Plutia"],
    "KPOP Demon Hunters": ["Huntrix", "Mira", "Zoey", "Rumi"],
}
VISION_BACKOFF: dict[str, float] = {}

VISUAL_HASH_BITS = 64
VISUAL_PHASH_MAX_DISTANCE = int(os.getenv("GALLERY_VISUAL_PHASH_MAX_DISTANCE", "10") or 10)
VISUAL_DHASH_MAX_DISTANCE = int(os.getenv("GALLERY_VISUAL_DHASH_MAX_DISTANCE", "14") or 14)

DOMAIN_CHARACTER_ALIASES: dict[str, tuple[str, str, str, list[str]]] = {
    "dazzlings": ("The Dazzlings", "My Little Pony", "Equestria Girls", ["dazzlings", "mlp", "equestria girls"]),
    "aria blaze": ("Aria Blaze", "My Little Pony", "Equestria Girls", ["aria blaze", "dazzlings", "mlp", "equestria girls"]),
    "adagio dazzle": ("Adagio Dazzle", "My Little Pony", "Equestria Girls", ["adagio dazzle", "dazzlings", "mlp", "equestria girls"]),
    "sonata dusk": ("Sonata Dusk", "My Little Pony", "Equestria Girls", ["sonata dusk", "dazzlings", "mlp", "equestria girls"]),
    "sunset shimmer": ("Sunset Shimmer", "My Little Pony", "Equestria Girls", ["sunset shimmer", "mlp", "equestria girls"]),
    "twilight sparkle": ("Twilight Sparkle", "My Little Pony", "Equestria Girls", ["twilight sparkle", "mlp", "equestria girls"]),
    "rainbow dash": ("Rainbow Dash", "My Little Pony", "Mane Six", ["rainbow dash", "mlp", "mane six"]),
    "pinkie pie": ("Pinkie Pie", "My Little Pony", "Mane Six", ["pinkie pie", "mlp", "mane six"]),
    "fluttershy": ("Fluttershy", "My Little Pony", "Mane Six", ["fluttershy", "mlp", "mane six"]),
    "applejack": ("Applejack", "My Little Pony", "Mane Six", ["applejack", "mlp", "mane six"]),
    "rarity": ("Rarity", "My Little Pony", "Mane Six", ["rarity", "mlp", "mane six"]),
    "spike": ("Spike", "My Little Pony", "Mane Six", ["spike", "mlp"]),
    "starlight glimmer": ("Starlight Glimmer", "My Little Pony", "Equestria Girls", ["starlight glimmer", "mlp"]),
    "trixie": ("Trixie", "My Little Pony", "Equestria Girls", ["trixie", "mlp"]),
    "derpy": ("Derpy", "My Little Pony", "Mane Six", ["derpy", "mlp"]),
    "huntrix": ("Huntrix", "KPOP Demon Hunters", "Huntrix", ["huntrix", "kpop demon hunters"]),
    "rumi": ("Rumi", "KPOP Demon Hunters", "Huntrix", ["rumi", "huntrix", "kpop demon hunters"]),
    "mira": ("Mira", "KPOP Demon Hunters", "Huntrix", ["mira", "huntrix", "kpop demon hunters"]),
    "zoey": ("Zoey", "KPOP Demon Hunters", "Huntrix", ["zoey", "huntrix", "kpop demon hunters"]),
    "saja boys": ("Saja Boys", "KPOP Demon Hunters", "Saja Boys", ["saja boys", "kpop demon hunters"]),
}



def _local_vision_command() -> Path | None:
    classifier = Path(os.getenv("GALLERY_LOCAL_VISION_COMMAND") or os.path.expanduser("~/.local/bin/ai-enhance"))
    return classifier if classifier.is_file() else None


def _character_guide_text() -> str:
    lines = []
    for franchise, names in CHARACTER_RECOGNITION_GUIDE.items():
        lines.append(f"{franchise}: {', '.join(names)}")
    return " | ".join(lines)


@dataclass
class SmartMediaAnalysis:
    title: str
    suggested_filename: str
    tags: list[str]
    category_name: str | None
    subcategory_name: str | None
    is_adult: bool
    source: str
    confidence: float
    size: tuple[int, int] | None = None
    reason: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "title": self.title,
            "suggested_filename": self.suggested_filename,
            "tags": list(self.tags),
            "category_name": self.category_name,
            "subcategory_name": self.subcategory_name,
            "is_adult": bool(self.is_adult),
            "source": self.source,
            "confidence": round(float(self.confidence), 3),
            "size": list(self.size) if self.size else None,
            "reason": self.reason,
        }


def analyze_media_path(
    path: Path,
    *,
    mime_type: str,
    media_kind: str,
    title_hint: str = "",
    description_hint: str = "",
    tags_hint: list[str] | None = None,
    ai_enabled: bool | None = None,
    ai_api_key: str | None = None,
    ai_base_url: str | None = None,
    ai_model: str | None = None,
    ai_timeout_seconds: int | None = None,
    training_examples: list[dict[str, Any]] | None = None,
) -> SmartMediaAnalysis:
    content = path.read_bytes()
    return analyze_media_bytes(
        content=content,
        filename=path.name,
        mime_type=mime_type,
        media_kind=media_kind,
        title_hint=title_hint,
        description_hint=description_hint,
        tags_hint=tags_hint,
        ai_enabled=ai_enabled,
        ai_api_key=ai_api_key,
        ai_base_url=ai_base_url,
        ai_model=ai_model,
        ai_timeout_seconds=ai_timeout_seconds,
        training_examples=training_examples,
    )


def analyze_media_bytes(
    *,
    content: bytes,
    filename: str,
    mime_type: str,
    media_kind: str,
    title_hint: str = "",
    description_hint: str = "",
    tags_hint: list[str] | None = None,
    ai_enabled: bool | None = None,
    ai_api_key: str | None = None,
    ai_base_url: str | None = None,
    ai_model: str | None = None,
    ai_timeout_seconds: int | None = None,
    training_examples: list[dict[str, Any]] | None = None,
) -> SmartMediaAnalysis:
    size = _media_size(content, filename, mime_type, media_kind)
    fallback = _heuristic_analysis(
        filename=filename,
        mime_type=mime_type,
        media_kind=media_kind,
        title_hint=title_hint,
        description_hint=description_hint,
        tags_hint=tags_hint or [],
        size=size,
    )
    image_fingerprint = _image_fingerprint(content, filename, mime_type, media_kind)
    training_result = _training_lookup_analysis(
        training_examples or [],
        filename=filename,
        title_hint=title_hint,
        description_hint=description_hint,
        tags_hint=tags_hint or [],
        fallback=fallback,
        image_fingerprint=image_fingerprint,
    )
    domain_hint_result = _domain_hint_analysis_from_text(
        filename=filename,
        title_hint=title_hint,
        description_hint=description_hint,
        tags_hint=tags_hint or [],
        fallback=fallback,
    )
    if domain_hint_result and (not training_result or _clamp_float(training_result.get("confidence"), 0.0, 1.0, 0.0) < 0.72):
        training_result = domain_hint_result

    local_classifier = _local_vision_command()
    provider = str(os.getenv("GALLERY_AI_PROVIDER", "")).strip().lower()
    if provider == "google-gemini":
        provider = "gemini"
    if provider not in {"local", "ollama", "openai", "google", "gemini"}:
        if os.getenv("GALLERY_GEMINI_API_KEY") or os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY"):
            provider = "gemini"
        elif local_classifier:
            provider = "local"
        elif os.getenv("GALLERY_OLLAMA_MODEL") or os.getenv("GALLERY_OLLAMA_BASE_URL"):
            provider = "ollama"
        else:
            provider = "openai"
    enabled_default = bool(
        local_classifier
        or os.getenv("GALLERY_OLLAMA_MODEL")
        or os.getenv("GALLERY_OLLAMA_BASE_URL")
        or ai_model
        or ai_api_key
        or os.getenv("GALLERY_AI_API_KEY")
        or os.getenv("GALLERY_GEMINI_API_KEY")
        or os.getenv("GEMINI_API_KEY")
        or os.getenv("GOOGLE_API_KEY")
        or os.getenv("OPENAI_API_KEY")
    )
    enabled = _resolve_bool(ai_enabled, env_name="GALLERY_AI_ENABLED", default=enabled_default)
    if not enabled:
        if training_result:
            return _merge_analysis(
                ai_result=training_result,
                fallback=fallback,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
            )
        return fallback

    preview_image_b64 = _preview_base64(content, filename, mime_type, media_kind)
    if not preview_image_b64:
        if training_result:
            return _merge_analysis(
                ai_result=training_result,
                fallback=fallback,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
            )
        return fallback

    timeout_seconds = max(10, int(ai_timeout_seconds or os.getenv("GALLERY_AI_TIMEOUT_SECONDS") or 45))
    backoff_seconds = max(30, int(os.getenv("GALLERY_VISION_BACKOFF_SECONDS", "600")))
    local_clip_result = None

    if provider == "ollama":
        failed_at = VISION_BACKOFF.get("ollama", 0.0)
        if failed_at and (time.time() - failed_at) < backoff_seconds:
            local_clip_result = _local_clip_analysis(
                content=content,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
                fallback=fallback,
            )
            if local_clip_result:
                local_clip_result["reason"] = "Local CLIP fallback used while Ollama vision is cooling down after a recent failure."
                return _merge_analysis(
                    ai_result=local_clip_result,
                    fallback=fallback,
                    filename=filename,
                    mime_type=mime_type,
                    media_kind=media_kind,
                )

    if provider in {"google", "gemini"}:
        failed_at = VISION_BACKOFF.get("google", 0.0)
        if failed_at and (time.time() - failed_at) < backoff_seconds:
            local_clip_result = _local_clip_analysis(
                content=content,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
                fallback=fallback,
            )
            if local_clip_result:
                local_clip_result["reason"] = "Local CLIP fallback used while Gemini vision is cooling down after a recent failure."
                return _merge_analysis(
                    ai_result=local_clip_result,
                    fallback=fallback,
                    filename=filename,
                    mime_type=mime_type,
                    media_kind=media_kind,
                )

    try:
        if provider == "local":
            local_clip_result = _local_clip_analysis(
                content=content,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
                fallback=fallback,
            )
            if local_clip_result:
                local_clip_result["reason"] = local_clip_result.get("reason") or "Primary local vision classifier matched this image."
                return _merge_analysis(
                    ai_result=local_clip_result,
                    fallback=fallback,
                    filename=filename,
                    mime_type=mime_type,
                    media_kind=media_kind,
                )
            api_key = str(ai_api_key or os.getenv("GALLERY_GEMINI_API_KEY") or os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY") or os.getenv("GALLERY_AI_API_KEY") or os.getenv("OPENAI_API_KEY") or "").strip()
            if os.getenv("GALLERY_GEMINI_API_KEY") or os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY"):
                provider = "gemini"
            elif os.getenv("GALLERY_OLLAMA_MODEL") or os.getenv("GALLERY_OLLAMA_BASE_URL"):
                provider = "ollama"
            elif api_key:
                provider = "openai"
            else:
                    if training_result:
                        training_result["reason"] = training_result.get("reason") or "Learned gallery correction used after local vision failed."
                        return _merge_analysis(
                            ai_result=training_result,
                            fallback=fallback,
                            filename=filename,
                            mime_type=mime_type,
                            media_kind=media_kind,
                        )
                    fallback.reason = "Local vision classifier could not confidently identify this image."
                    return fallback

        if provider == "ollama":
            model = str(os.getenv("GALLERY_OLLAMA_MODEL") or ai_model or "qwen2.5vl:3b").strip()
            base_url = str(os.getenv("GALLERY_OLLAMA_BASE_URL") or ai_base_url or "http://127.0.0.1:11434").rstrip("/")
            ai_result = _ollama_vision_analysis(
                preview_image_b64=preview_image_b64,
                original_image_b64=(base64.b64encode(content).decode("ascii") if media_kind == "image" else None),
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
                title_hint=title_hint,
                description_hint=description_hint,
                tags_hint=tags_hint or [],
                fallback=fallback,
                training_examples=training_examples or [],
                base_url=base_url,
                model=model,
                timeout_seconds=timeout_seconds,
            )
            VISION_BACKOFF.pop("ollama", None)
        elif provider in {"google", "gemini"} or os.getenv("GALLERY_GEMINI_API_KEY") or os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY"):
            api_key = str(ai_api_key or os.getenv("GALLERY_GEMINI_API_KEY") or os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY") or "").strip()
            if not api_key:
                if training_result:
                    return _merge_analysis(
                        ai_result=training_result,
                        fallback=fallback,
                        filename=filename,
                        mime_type=mime_type,
                        media_kind=media_kind,
                    )
                return fallback
            ai_result = _gemini_vision_analysis(
                preview_image_b64=preview_image_b64,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
                title_hint=title_hint,
                description_hint=description_hint,
                tags_hint=tags_hint or [],
                fallback=fallback,
                training_examples=training_examples or [],
                api_key=api_key,
                model=str(os.getenv("GALLERY_GEMINI_MODEL") or os.getenv("GEMINI_MODEL") or ai_model or "gemini-2.5-flash-lite").strip(),
                timeout_seconds=timeout_seconds,
            )
            provider = "google"
            VISION_BACKOFF.pop("google", None)
        else:
            api_key = str(ai_api_key or os.getenv("GALLERY_AI_API_KEY") or os.getenv("OPENAI_API_KEY") or "").strip()
            if not api_key:
                if training_result:
                    return _merge_analysis(
                        ai_result=training_result,
                        fallback=fallback,
                        filename=filename,
                        mime_type=mime_type,
                        media_kind=media_kind,
                    )
                return fallback
            preview_url = _preview_data_url(content, filename, mime_type, media_kind)
            if not preview_url:
                return fallback
            ai_result = _openai_vision_analysis(
                preview_url=preview_url,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
                title_hint=title_hint,
                description_hint=description_hint,
                tags_hint=tags_hint or [],
                fallback=fallback,
                training_examples=training_examples or [],
                api_key=api_key,
                base_url=str(ai_base_url or os.getenv("GALLERY_AI_BASE_URL") or os.getenv("OPENAI_BASE_URL") or "https://api.openai.com/v1").rstrip("/"),
                model=str(ai_model or os.getenv("GALLERY_AI_MODEL") or "gpt-5.4-nano").strip(),
                timeout_seconds=timeout_seconds,
            )
    except Exception as exc:
        if provider == "ollama":
            VISION_BACKOFF["ollama"] = time.time()
        if provider in {"google", "gemini"}:
            VISION_BACKOFF["google"] = time.time()
        safe_exc = _safe_ai_error(exc)
        local_clip_result = local_clip_result or _local_clip_analysis(
            content=content,
            filename=filename,
            mime_type=mime_type,
            media_kind=media_kind,
            fallback=fallback,
        )
        if local_clip_result:
            local_clip_result["reason"] = f"{local_clip_result.get('reason') or 'Local CLIP fallback used.'} Primary AI unavailable: {safe_exc}"
            return _merge_analysis(
                ai_result=local_clip_result,
                fallback=fallback,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
            )
        if training_result:
            training_result["reason"] = f"{training_result.get('reason') or 'Learned gallery correction used.'} Primary AI unavailable: {safe_exc}"
            return _merge_analysis(
                ai_result=training_result,
                fallback=fallback,
                filename=filename,
                mime_type=mime_type,
                media_kind=media_kind,
            )
        fallback.reason = f"AI suggestion unavailable, using local analyzer: {safe_exc}"
        return fallback

    if training_result:
        training_confidence = _clamp_float(training_result.get("confidence"), 0.0, 1.0, 0.0)
        ai_confidence = _clamp_float(ai_result.get("confidence"), 0.0, 1.0, 0.0)
        training_source = str(training_result.get("source") or "").strip().lower()
        if (training_source == "visual-training" and training_confidence >= 0.8) or ai_confidence < 0.55:
            ai_result = training_result

    return _merge_analysis(
        ai_result=ai_result,
        fallback=fallback,
        filename=filename,
        mime_type=mime_type,
        media_kind=media_kind,
    )


def _training_guide_text(
    training_examples: list[dict[str, Any]] | None,
    *,
    limit: int = 12,
    compact: bool = False,
) -> str:
    examples = list(training_examples or [])[: max(1, limit)]
    if not examples:
        return ""
    if compact:
        lines = ["Use these learned gallery examples as hints only when the image visually matches:"]
    else:
        lines = [
            "Learn from these user-approved gallery corrections. Treat them as naming/category style and character/category aliases, but still require visual evidence:"
        ]
    for index, example in enumerate(examples, 1):
        title = _clean_title(example.get("corrected_title") or example.get("title"))
        category = _clean_label(example.get("corrected_category_name") or example.get("category_name")) or ""
        subcategory = _clean_label(example.get("corrected_subcategory_name") or example.get("subcategory_name")) or ""
        tags = ", ".join(_normalize_tags(example.get("corrected_tags") or example.get("tags") or [])[:8])
        filename = _clean_title(example.get("original_filename") or "")
        parts = []
        if compact:
            if title:
                parts.append(f"title={title}")
            if category:
                parts.append(f"category={category}")
            if subcategory:
                parts.append(f"subcategory={subcategory}")
            if tags:
                parts.append(f"tags={tags}")
            if filename:
                parts.append(f"hint={filename}")
        else:
            if filename:
                parts.append(f"file/name hint '{filename}'")
            if title:
                parts.append(f"title '{title}'")
            if category:
                parts.append(f"category '{category}'")
            if subcategory:
                parts.append(f"subcategory '{subcategory}'")
            if tags:
                parts.append(f"tags [{tags}]")
        if parts:
            lines.append(f"{index}. " + "; ".join(parts))
    return "\n".join(lines) + "\n"


def _looks_placeholder_ai_result(payload: dict[str, Any]) -> bool:
    title = _clean_title(payload.get("title")).lower()
    reason = _clean_title(payload.get("reason")).lower()
    category = (_clean_label(payload.get("category_name")) or "").lower()
    subcategory = (_clean_label(payload.get("subcategory_name")) or "").lower()
    filename_base = _clean_filename_base(payload.get("suggested_filename_base")).lower()
    tags = [tag.lower() for tag in _normalize_tags(payload.get("tags"))]
    return any(
        (
            title in {"string", "title"},
            reason in {"string", "reason"},
            category in {"string", "category", "category-name"},
            subcategory in {"string", "subcategory", "subcategory-name"},
            filename_base in {"string", "filename", "suggested-filename", "suggested_filename"},
            bool(tags) and all(tag in {"tag", "tags", "string"} for tag in tags),
        )
    )


def _training_lookup_analysis(
    training_examples: list[dict[str, Any]],
    *,
    filename: str,
    title_hint: str,
    description_hint: str,
    tags_hint: list[str],
    fallback: SmartMediaAnalysis,
    image_fingerprint: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Use prior user corrections as a cautious local memory, not a blind override.

    Exact text matching is weak for image galleries because filenames are often hashes,
    artist credits, or phone-camera IDs.  Visual fingerprint matching lets the gallery
    learn from compressed/resized examples without needing a full model fine-tune.
    """
    visual_match = _visual_training_match(training_examples, image_fingerprint, fallback=fallback)
    if visual_match:
        return visual_match

    query_text = " ".join([_filename_subject_text(filename), title_hint or "", description_hint or "", " ".join(tags_hint or [])])
    query_tokens = set(clean_tokens(query_text))
    query_tokens = {token for token in query_tokens if token not in STOP_TAGS and not _is_noise_token(token)}
    if not query_tokens:
        return None

    best: tuple[float, dict[str, Any]] | None = None
    for example in training_examples or []:
        source_text = " ".join(
            str(example.get(key) or "")
            for key in (
                "original_filename",
                "source_title",
                "source_category_name",
                "source_subcategory_name",
                "corrected_title",
                "corrected_category_name",
                "corrected_subcategory_name",
                "notes",
            )
        )
        example_tags = _normalize_tags(example.get("source_tags") or []) + _normalize_tags(example.get("corrected_tags") or [])
        example_tokens = set(clean_tokens(source_text, " ".join(example_tags)))
        example_tokens = {token for token in example_tokens if token not in STOP_TAGS and not _is_noise_token(token)}
        overlap = query_tokens & example_tokens
        if not overlap:
            continue
        rare_overlap = {token for token in overlap if len(token) >= 5}
        if len(overlap) < 2 and not rare_overlap:
            continue
        score = min(0.88, 0.58 + (0.08 * len(overlap)) + (0.04 * len(rare_overlap)))
        if not best or score > best[0]:
            best = (score, example)

    if not best:
        return None
    score, example = best
    title = _clean_title(example.get("corrected_title")) or fallback.title
    category = _clean_label(example.get("corrected_category_name")) or fallback.category_name or ""
    subcategory = _clean_label(example.get("corrected_subcategory_name")) or fallback.subcategory_name or ""
    tags = _normalize_tags(example.get("corrected_tags") or [])
    return {
        "title": title,
        "suggested_filename_base": "",
        "tags": _merge_tags(tags, fallback.tags),
        "category_name": category,
        "subcategory_name": subcategory,
        "is_adult": bool(example.get("corrected_is_adult")) or fallback.is_adult,
        "confidence": score,
        "reason": "Learned from prior gallery correction with matching metadata hints.",
        "source": "gallery-training",
    }


def _visual_training_match(
    training_examples: list[dict[str, Any]],
    image_fingerprint: dict[str, Any] | None,
    *,
    fallback: SmartMediaAnalysis,
) -> dict[str, Any] | None:
    if not image_fingerprint:
        return None
    current_phash = str(image_fingerprint.get("image_phash") or "")
    current_dhash = str(image_fingerprint.get("image_dhash") or "")
    if not current_phash and not current_dhash:
        return None

    best: tuple[float, dict[str, Any], int | None, int | None] | None = None
    for example in training_examples or []:
        example_phash = str(example.get("image_phash") or example.get("source_image_phash") or "")
        example_dhash = str(example.get("image_dhash") or example.get("source_image_dhash") or "")
        if not example_phash and not example_dhash:
            continue
        pdist = _hex_hamming_distance(current_phash, example_phash) if current_phash and example_phash else None
        ddist = _hex_hamming_distance(current_dhash, example_dhash) if current_dhash and example_dhash else None
        if pdist is None and ddist is None:
            continue
        if pdist is not None and pdist > VISUAL_PHASH_MAX_DISTANCE:
            continue
        if ddist is not None and ddist > VISUAL_DHASH_MAX_DISTANCE:
            continue
        components = []
        if pdist is not None:
            components.append(max(0.0, 1.0 - (pdist / max(1, VISUAL_PHASH_MAX_DISTANCE))))
        if ddist is not None:
            components.append(max(0.0, 1.0 - (ddist / max(1, VISUAL_DHASH_MAX_DISTANCE))))
        similarity = sum(components) / len(components)
        source_conf = _clamp_float(example.get("training_confidence"), 0.0, 1.0, 0.72)
        score = max(0.62, min(0.96, 0.62 + (similarity * 0.30) + (source_conf * 0.08)))
        if not best or score > best[0]:
            best = (score, example, pdist, ddist)

    if not best:
        return None
    score, example, pdist, ddist = best
    title = _clean_title(example.get("corrected_title")) or fallback.title
    category = _clean_label(example.get("corrected_category_name")) or fallback.category_name or ""
    subcategory = _clean_label(example.get("corrected_subcategory_name")) or fallback.subcategory_name or ""
    tags = _normalize_tags(example.get("corrected_tags") or [])
    reason_bits = []
    if pdist is not None:
        reason_bits.append(f"pHash distance {pdist}")
    if ddist is not None:
        reason_bits.append(f"dHash distance {ddist}")
    return {
        "title": title,
        "suggested_filename_base": "",
        "tags": _merge_tags(tags, fallback.tags),
        "category_name": category,
        "subcategory_name": subcategory,
        "is_adult": bool(example.get("corrected_is_adult")) or fallback.is_adult,
        "confidence": score,
        "reason": "Visually matched a learned training image (" + ", ".join(reason_bits) + ").",
        "source": "visual-training",
    }


def _domain_hint_analysis_from_text(
    *,
    filename: str,
    title_hint: str,
    description_hint: str,
    tags_hint: list[str],
    fallback: SmartMediaAnalysis,
) -> dict[str, Any] | None:
    text = " ".join([_filename_subject_text(filename), title_hint or "", description_hint or "", " ".join(tags_hint or [])]).lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    if not text.strip():
        return None

    matches: list[tuple[str, str, str, list[str]]] = []
    for alias, payload in DOMAIN_CHARACTER_ALIASES.items():
        alias_text = alias.lower().replace("_", " ").replace("-", " ")
        if re.search(rf"\b{re.escape(alias_text)}\b", text):
            matches.append(payload)

    # Composite shorthand used in filenames.
    if re.search(r"\baria\b", text) and "dazzlings" in text:
        matches.append(DOMAIN_CHARACTER_ALIASES["aria blaze"])
    if re.search(r"\badagio\b", text) and "dazzlings" in text:
        matches.append(DOMAIN_CHARACTER_ALIASES["adagio dazzle"])
    if re.search(r"\bsonata\b", text) and "dazzlings" in text:
        matches.append(DOMAIN_CHARACTER_ALIASES["sonata dusk"])
    if re.search(r"\bdashie\b", text):
        matches.append(DOMAIN_CHARACTER_ALIASES["rainbow dash"])
    if "kpop demon hunters" in text or "k pop demon hunters" in text:
        matches.append(("KPop Demon Hunters", "KPOP Demon Hunters", "Huntrix", ["kpop demon hunters", "huntrix"]))

    if not matches:
        return None
    # Preserve order but drop duplicate visible names.
    unique: list[tuple[str, str, str, list[str]]] = []
    seen_names: set[str] = set()
    for match in matches:
        if match[0].lower() in seen_names:
            continue
        seen_names.add(match[0].lower())
        unique.append(match)
    names = [match[0] for match in unique[:4]]
    category = unique[0][1]
    subcategory = unique[0][2]
    if {"Aria Blaze", "Adagio Dazzle", "Sonata Dusk"}.issubset(set(names)) or any(name == "The Dazzlings" for name in names):
        title = "The Dazzlings"
        tags = ["the dazzlings", "aria blaze", "adagio dazzle", "sonata dusk", "mlp", "equestria girls"]
        subcategory = "Equestria Girls"
    elif len(names) > 2:
        title = f"{names[0]}, {names[1]}, and {len(names) - 2} more"
        tags = []
        for _, _, _, match_tags in unique[:6]:
            tags.extend(match_tags)
    elif len(names) == 2:
        title = f"{names[0]} and {names[1]}"
        tags = [tag for _, _, _, match_tags in unique[:4] for tag in match_tags]
    else:
        title = names[0]
        tags = list(unique[0][3])
    return {
        "title": title,
        "suggested_filename_base": "",
        "tags": tags,
        "category_name": category,
        "subcategory_name": subcategory,
        "is_adult": fallback.is_adult,
        "confidence": 0.66,
        "reason": "Matched a known franchise/character alias from user-provided metadata hints.",
        "source": "domain-hint",
    }


def _image_fingerprint(content: bytes, filename: str, mime_type: str, media_kind: str) -> dict[str, Any] | None:
    if media_kind != "image":
        return None
    try:
        from PIL import Image, ImageOps
        Image.MAX_IMAGE_PIXELS = None
        with Image.open(io.BytesIO(content)) as image:
            image = ImageOps.exif_transpose(image).convert("RGB")
            width, height = image.size
            return {
                "image_phash": _average_hash(image, hash_size=8),
                "image_dhash": _difference_hash(image, hash_size=8),
                "image_width": int(width),
                "image_height": int(height),
            }
    except Exception:
        return None


def _average_hash(image: Any, *, hash_size: int = 8) -> str:
    gray = image.convert("L").resize((hash_size, hash_size))
    pixels = list(gray.getdata())
    avg = sum(pixels) / max(1, len(pixels))
    bits = 0
    for value in pixels:
        bits = (bits << 1) | (1 if value >= avg else 0)
    return f"{bits:0{(hash_size * hash_size) // 4}x}"


def _difference_hash(image: Any, *, hash_size: int = 8) -> str:
    gray = image.convert("L").resize((hash_size + 1, hash_size))
    pixels = list(gray.getdata())
    bits = 0
    for row in range(hash_size):
        offset = row * (hash_size + 1)
        for col in range(hash_size):
            bits = (bits << 1) | (1 if pixels[offset + col] > pixels[offset + col + 1] else 0)
    return f"{bits:0{(hash_size * hash_size) // 4}x}"


def _hex_hamming_distance(a: str, b: str) -> int | None:
    a = str(a or "").strip().lower()
    b = str(b or "").strip().lower()
    if not a or not b or len(a) != len(b):
        return None
    try:
        return (int(a, 16) ^ int(b, 16)).bit_count()
    except ValueError:
        return None


def _filename_subject_text(filename: str) -> str:
    stem = Path(filename or "").stem
    if not stem:
        return ""
    stem = re.sub(r"__[0-9a-f]{8,}$", "", stem, flags=re.IGNORECASE)
    stem = re.sub(r"\b(?:ai[_ -]?enhanced|upscayl|upscaled|compressed|final|fullview)\b", " ", stem, flags=re.IGNORECASE)
    stem = re.sub(r"\b(?:\d{3,4}x\d{3,4}|\d{3,4}p|4k|8k|uhd|fhd|qhd)\b", " ", stem, flags=re.IGNORECASE)
    # Keep the actual title before common artist/source separators, but discard the credit tail.
    stem = re.split(r"(?:_by_|-by-|\s+by\s+)", stem, maxsplit=1, flags=re.IGNORECASE)[0]
    stem = re.sub(r"[0-9a-f]{8,}(?:[-_][0-9a-f]{4,}){1,}", " ", stem, flags=re.IGNORECASE)
    stem = re.sub(r"\b[0-9a-f]{10,}\b", " ", stem, flags=re.IGNORECASE)
    cleaned = re.sub(r"[^a-zA-Z0-9]+", " ", stem).strip()
    compact = re.sub(r"[^a-z0-9]+", "", cleaned.lower())
    if not cleaned or _looks_low_signal_name(cleaned) or (re.fullmatch(r"[a-f0-9]{8,}", compact or "") is not None):
        return ""
    return cleaned

def is_low_signal_filename(filename: str) -> bool:
    return _looks_low_signal_name(filename)


def _resolve_bool(value: bool | None, *, env_name: str, default: bool) -> bool:
    if value is not None:
        return bool(value)
    raw = str(os.getenv(env_name, "")).strip().lower()
    if raw:
        return raw not in {"0", "false", "no", "off"}
    return default


def _heuristic_analysis(
    *,
    filename: str,
    mime_type: str,
    media_kind: str,
    title_hint: str,
    description_hint: str,
    tags_hint: list[str],
    size: tuple[int, int] | None,
) -> SmartMediaAnalysis:
    clean_hint_title = _clean_title(title_hint)
    category_name, subcategory_name = canonical_category_pair(
        *infer_category_pair(
            filename=filename,
            media_kind=media_kind,
            title=clean_hint_title or filename,
            size=size,
        )
    )
    tags = _build_tags(
        filename=filename,
        title=clean_hint_title or "",
        description=description_hint,
        category_name=category_name,
        subcategory_name=subcategory_name,
        media_kind=media_kind,
        size=size,
        tags_hint=tags_hint,
    )
    title = clean_hint_title if clean_hint_title and not _is_bad_subject_title(clean_hint_title, category_name, subcategory_name) else _compose_specific_title(
        title="",
        filename=filename,
        category_name=category_name,
        subcategory_name=subcategory_name,
        tags=tags,
        media_kind=media_kind,
    )
    suggested_filename = _suggest_filename(
        title=title,
        source_filename=filename,
        mime_type=mime_type,
        category_name=category_name,
        subcategory_name=subcategory_name,
    )
    return SmartMediaAnalysis(
        title=title,
        suggested_filename=suggested_filename,
        tags=tags,
        category_name=category_name,
        subcategory_name=subcategory_name,
        is_adult=_looks_adult(title, description_hint, tags, filename, mime_type),
        source="heuristic",
        confidence=0.45,
        size=size,
    )


def _merge_analysis(
    *,
    ai_result: dict[str, Any],
    fallback: SmartMediaAnalysis,
    filename: str,
    mime_type: str,
    media_kind: str,
) -> SmartMediaAnalysis:
    confidence = _clamp_float(ai_result.get("confidence"), 0.0, 1.0, fallback.confidence)
    ai_title = _clean_title(ai_result.get("title"))
    ai_category = _clean_label(ai_result.get("category_name"))
    ai_subcategory = _clean_label(ai_result.get("subcategory_name"))
    category_name, subcategory_name = canonical_category_pair(
        ai_category or fallback.category_name,
        ai_subcategory or fallback.subcategory_name,
    )
    if confidence < 0.45:
        category_name = fallback.category_name
        subcategory_name = fallback.subcategory_name

    tags = _merge_tags(_normalize_tags(ai_result.get("tags")), fallback.tags)
    if not tags:
        tags = list(fallback.tags)

    raw_title = ai_title or fallback.title
    if _is_bad_subject_title(raw_title, category_name, subcategory_name):
        title = _compose_specific_title(
            title=raw_title,
            filename=filename,
            category_name=category_name,
            subcategory_name=subcategory_name,
            tags=tags,
            media_kind=media_kind,
        )
    else:
        title = raw_title
    if _is_bad_subject_title(title, category_name, subcategory_name):
        title = _compose_specific_title(
            title="",
            filename=filename,
            category_name=category_name,
            subcategory_name=subcategory_name,
            tags=tags,
            media_kind=media_kind,
        )

    suggested_filename = _suggest_filename(
        title=title,
        source_filename=filename,
        mime_type=mime_type,
        category_name=category_name,
        subcategory_name=subcategory_name,
        suggested_base=_clean_filename_base(ai_result.get("suggested_filename_base")),
    )
    inferred_source = (_clean_label(ai_result.get("source")) or "").lower()
    if inferred_source and confidence >= 0.45:
        source = inferred_source
    elif (os.getenv("GALLERY_AI_PROVIDER", "").strip().lower() == "ollama" or os.getenv("GALLERY_OLLAMA_MODEL")) and confidence >= 0.45:
        source = "ollama"
    elif (
        os.getenv("GALLERY_AI_PROVIDER", "").strip().lower() in {"google", "gemini"}
        or os.getenv("GALLERY_GEMINI_API_KEY")
        or os.getenv("GEMINI_API_KEY")
        or os.getenv("GOOGLE_API_KEY")
    ) and confidence >= 0.45:
        source = "google-gemini"
    else:
        source = "openai" if confidence >= 0.45 else fallback.source
    return SmartMediaAnalysis(
        title=title,
        suggested_filename=suggested_filename,
        tags=tags,
        category_name=category_name,
        subcategory_name=subcategory_name,
        is_adult=bool(ai_result.get("is_adult")) or fallback.is_adult,
        source=source,
        confidence=max(confidence, fallback.confidence if confidence < 0.45 else 0.0),
        size=fallback.size,
        reason=_clean_title(ai_result.get("reason")) or fallback.reason,
    )


def _ollama_vision_analysis(
    *,
    preview_image_b64: str,
    original_image_b64: str | None,
    filename: str,
    mime_type: str,
    media_kind: str,
    title_hint: str,
    description_hint: str,
    tags_hint: list[str],
    fallback: SmartMediaAnalysis,
    training_examples: list[dict[str, Any]],
    base_url: str,
    model: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    normalized_model = model.strip().lower()
    compact_model = "moondream" in normalized_model
    if compact_model:
        prompt = (
            "Describe the main subject of this image in one short sentence. "
            "Mention character or franchise names only if you are sure."
        )
        request = urllib.request.Request(
            f"{base_url}/api/generate",
            data=json.dumps(
                {
                    "model": model,
                    "prompt": prompt,
                    "images": [original_image_b64 or preview_image_b64],
                    "stream": False,
                    "options": {"temperature": 0.1, "num_predict": 40},
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                raw = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Ollama API error {exc.code}: {body[:240]}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Ollama API network error: {exc.reason}") from exc

        caption = _clean_title(json.loads(raw or "{}").get("response") or "")
        caption = re.sub(r"^(?:a|an|the)\s+", "", caption, flags=re.IGNORECASE).strip()
        title_candidate = re.split(
            r"\b(?:is|are|was|were|stands|standing|sits|sitting|poses|posing|shown|featured)\b",
            caption,
            maxsplit=1,
            flags=re.IGNORECASE,
        )[0].strip(" ,.-")
        text = title_candidate or caption
        compact_generic_titles = {"image", "artwork", "wallpaper", "background", "photo", "picture", "art"}
        if not text or text.lower() in compact_generic_titles:
            raise RuntimeError("Ollama compact caption was too generic.")
        text = text[:1].upper() + text[1:]

        domain_hint = _domain_hint_analysis_from_text(
            filename=filename,
            title_hint=text,
            description_hint=caption,
            tags_hint=tags_hint or [],
            fallback=fallback,
        )
        inferred_category, inferred_subcategory = infer_category_pair(
            filename=filename,
            media_kind=media_kind,
            title=text,
            current_category=(domain_hint or {}).get("category_name") or fallback.category_name,
            size=fallback.size,
        )
        category_name = _clean_label((domain_hint or {}).get("category_name")) or inferred_category or fallback.category_name or ""
        subcategory_name = _clean_label((domain_hint or {}).get("subcategory_name")) or inferred_subcategory or fallback.subcategory_name or ""
        tags = _normalize_tags([
            *clean_tokens(text),
            *clean_tokens(caption),
            *((domain_hint or {}).get("tags") or []),
            *(tags_hint or []),
            *(fallback.tags[:4] if fallback.tags else []),
        ])
        return {
            "title": (domain_hint or {}).get("title") or text,
            "suggested_filename_base": _clean_filename_base(text),
            "tags": tags[:12],
            "category_name": category_name,
            "subcategory_name": subcategory_name,
            "is_adult": fallback.is_adult,
            "confidence": 0.62,
            "reason": f"Ollama compact caption: {caption}",
            "source": "ollama",
        }

    training_guide = _training_guide_text(training_examples, limit=12, compact=False)
    prompt = (
        "You analyze media uploads for a personal gallery. Return JSON only.\n"
        "IMPORTANT: Never use generic titles like 'Backgrounds', 'Wallpaper', 'Image', 'Art', or 'Artwork'.\n"
        "Never use the filename, a file number, upload number, random code, or numeric ID as the title.\n"
        "Never use titles like '0703', '0721', 'IMG 1234', or 'Wp15784703'.\n"
        "Never copy category_name into title. Category is metadata, not the title.\n"
        "The title must mention the subject, character, franchise, or defining content if visible.\n"
        "If multiple clear named characters appear, title it naturally using both names.\n"
        "If a real person, celebrity, or fictional character is clearly identifiable, include their name in the title and tags.\n"
        "If identity is uncertain, do not guess. Use descriptive visual details instead.\n"
        "Create up to 12 short lowercase tags. Do not include numeric file IDs as tags.\n"
        "Only give a specific character or subcategory if the visual evidence is clear.\n"
        "Prefer these main categories when they fit: " + ", ".join(KNOWN_CATEGORIES) + ".\n"
        "Use this local recognition guide as hints, not proof: " + _character_guide_text() + ".\n"
        + training_guide
        + "If it looks like a phone wallpaper use category 'Phone Backgrounds'. If it looks like a desktop wallpaper use 'Desktop Backgrounds'.\n"
        "If the image is NSFW, set is_adult true.\n"
        "Return exactly this JSON schema:"
        '{"title":"string","suggested_filename_base":"string","tags":["tag"],"category_name":"string","subcategory_name":"string","is_adult":false,"confidence":0.0,"reason":"string"}\n\n'
        f"Filename: {filename}\n"
        f"MIME type: {mime_type}\n"
        f"Media kind: {media_kind}\n"
        f"Existing title hint: {_clean_title(title_hint) or '(none)'}\n"
        f"Existing description hint: {_clean_title(description_hint) or '(none)'}\n"
        f"Existing tags hint: {', '.join(_normalize_tags(tags_hint)) or '(none)'}\n"
        f"Local analyzer fallback title: {fallback.title}\n"
        f"Local analyzer fallback category: {fallback.category_name or 'Wallpapers'}\n"
        f"Local analyzer fallback subcategory: {fallback.subcategory_name or '(none)'}"
    )
    payload = {
        "model": model,
        "prompt": prompt,
        "images": [preview_image_b64],
        "stream": False,
        "format": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "suggested_filename_base": {"type": "string"},
                "tags": {"type": "array", "items": {"type": "string"}},
                "category_name": {"type": "string"},
                "subcategory_name": {"type": "string"},
                "is_adult": {"type": "boolean"},
                "confidence": {"type": "number"},
                "reason": {"type": "string"},
            },
            "required": [
                "title",
                "suggested_filename_base",
                "tags",
                "category_name",
                "subcategory_name",
                "is_adult",
                "confidence",
                "reason",
            ],
        },
        "options": {"temperature": 0.2, "num_ctx": 2048, "num_predict": 160},
    }
    request = urllib.request.Request(
        f"{base_url}/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Ollama API error {exc.code}: {body[:240]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Ollama API network error: {exc.reason}") from exc
    data = json.loads(raw or "{}")
    text = str(data.get("response") or "").strip()
    if not text:
        raise RuntimeError("Ollama response did not include text.")
    result = json.loads(text)
    if _looks_placeholder_ai_result(result):
        raise RuntimeError("Ollama returned placeholder schema values.")
    return result


def _gemini_vision_analysis(
    *,
    preview_image_b64: str,
    filename: str,
    mime_type: str,
    media_kind: str,
    title_hint: str,
    description_hint: str,
    tags_hint: list[str],
    fallback: SmartMediaAnalysis,
    training_examples: list[dict[str, Any]],
    api_key: str,
    model: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    prompt = (
        "You analyze media uploads for a personal gallery. Return JSON only. "
        "Identify visible characters, franchises, subjects, and backgrounds when evidence is strong. "
        "Never use generic titles like Backgrounds, Wallpaper, Image, Art, Artwork, or the filename. "
        "Do not guess a named character if the identity is unclear; describe visible traits instead. "
        "Create up to 12 short lowercase tags, including character/franchise/background tags when reliable. "
        "Use this local recognition guide as hints, not proof: "
        + _character_guide_text()
        + ". "
        + _training_guide_text(training_examples)
        + "Prefer these main categories when they fit: "
        + ", ".join(KNOWN_CATEGORIES)
        + ". If it looks like a phone wallpaper use Phone Backgrounds; desktop wallpaper use Desktop Backgrounds. "
        "Return exactly this JSON schema: "
        '{"title":"string","suggested_filename_base":"string","tags":["tag"],"category_name":"string","subcategory_name":"string","is_adult":false,"confidence":0.0,"reason":"string"}\n\n'
        f"Filename: {filename}\n"
        f"MIME type: {mime_type}\n"
        f"Media kind: {media_kind}\n"
        f"Existing title hint: {_clean_title(title_hint) or '(none)'}\n"
        f"Existing description hint: {_clean_title(description_hint) or '(none)'}\n"
        f"Existing tags hint: {', '.join(_normalize_tags(tags_hint)) or '(none)'}\n"
        f"Local analyzer fallback title: {fallback.title}\n"
        f"Local analyzer fallback category: {fallback.category_name or 'Wallpapers'}\n"
        f"Local analyzer fallback subcategory: {fallback.subcategory_name or '(none)'}"
    )
    payload = {
        "contents": [
            {
                "role": "user",
                "parts": [
                    {"text": prompt},
                    {"inline_data": {"mime_type": "image/jpeg", "data": preview_image_b64}},
                ],
            }
        ],
        "generationConfig": {
            "temperature": 0.15,
            "responseMimeType": "application/json",
        },
    }
    safe_model = urllib.parse.quote(model or "gemini-2.5-flash-lite", safe="")
    request = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{safe_model}:generateContent?key={urllib.parse.quote(api_key, safe='')}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        message = _sanitize_ai_error_text(body)
        raise RuntimeError(f"Gemini API error {exc.code}: {message[:180]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Gemini API network error: {_sanitize_ai_error_text(str(exc.reason))}") from exc
    data = json.loads(raw or "{}")
    candidates = data.get("candidates") or []
    parts = ((candidates[0] if candidates else {}).get("content") or {}).get("parts") or []
    text = "\n".join(str(part.get("text") or "").strip() for part in parts if part.get("text")).strip()
    if not text:
        raise RuntimeError("Gemini response did not include structured text.")
    return json.loads(text)


def _openai_vision_analysis(
    *,
    preview_url: str,
    filename: str,
    mime_type: str,
    media_kind: str,
    title_hint: str,
    description_hint: str,
    tags_hint: list[str],
    fallback: SmartMediaAnalysis,
    training_examples: list[dict[str, Any]],
    api_key: str,
    base_url: str,
    model: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    instructions = (
        "You analyze media uploads for a personal gallery. Return structured JSON only. "
        "Never use generic titles like Backgrounds, Wallpaper, Image, Art, or Artwork. "
        "Make the title natural, concise, and specific to the visible subject. "
        "If a real person, celebrity, or fictional character is clearly identifiable, include their name in the title and tags. "
        "If identity is uncertain, do not guess. Use descriptive details instead. "
        "Create up to 12 short lowercase tags. "
        "Choose a broad category when uncertain. "
        "Only give a specific character or subcategory if the visual evidence is clear. "
        "Use this local recognition guide as hints, not proof: "
        + _character_guide_text()
        + ". "
        + _training_guide_text(training_examples)
        + "Prefer these main categories when they fit: "
        + ", ".join(KNOWN_CATEGORIES)
        + ". If nothing specific fits, use Wallpapers, Desktop Backgrounds, Phone Backgrounds, Videos, or Profile Pictures. "
        "Do not invent lore if the image is ambiguous."
    )
    user_text = (
        f"Filename: {filename}\n"
        f"MIME type: {mime_type}\n"
        f"Media kind: {media_kind}\n"
        f"Existing title hint: {_clean_title(title_hint) or '(none)'}\n"
        f"Existing description hint: {_clean_title(description_hint) or '(none)'}\n"
        f"Existing tags hint: {', '.join(_normalize_tags(tags_hint)) or '(none)'}\n"
        f"Local analyzer fallback title: {fallback.title}\n"
        f"Local analyzer fallback category: {fallback.category_name or 'Wallpapers'}\n"
        f"Local analyzer fallback subcategory: {fallback.subcategory_name or '(none)'}"
    )
    schema = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "title": {"type": "string"},
            "suggested_filename_base": {"type": "string"},
            "tags": {"type": "array", "items": {"type": "string"}, "maxItems": 12},
            "category_name": {"type": "string"},
            "subcategory_name": {"type": "string"},
            "is_adult": {"type": "boolean"},
            "confidence": {"type": "number"},
            "reason": {"type": "string"},
        },
        "required": [
            "title",
            "suggested_filename_base",
            "tags",
            "category_name",
            "subcategory_name",
            "is_adult",
            "confidence",
            "reason",
        ],
    }
    payload = {
        "model": model,
        "store": False,
        "temperature": 0.2,
        "reasoning": {"effort": "low"},
        "text": {"format": {"type": "json_schema", "name": "gallery_media_analysis", "strict": True, "schema": schema}},
        "input": [
            {"role": "system", "content": [{"type": "input_text", "text": instructions}]},
            {
                "role": "user",
                "content": [
                    {"type": "input_text", "text": user_text},
                    {"type": "input_image", "image_url": preview_url, "detail": "low"},
                ],
            },
        ],
    }
    request = urllib.request.Request(
        f"{base_url}/responses",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI API error {exc.code}: {body[:240]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"OpenAI API network error: {exc.reason}") from exc
    data = json.loads(raw or "{}")
    text = _response_text(data)
    if not text:
        raise RuntimeError("OpenAI response did not include structured text.")
    return json.loads(text)


def _response_text(payload: dict[str, Any]) -> str:
    output_text = str(payload.get("output_text") or "").strip()
    if output_text:
        return output_text
    for item in payload.get("output") or []:
        for content in item.get("content") or []:
            text = str(content.get("text") or "").strip()
            if text:
                return text
    return ""


def _local_clip_analysis(
    *,
    content: bytes,
    filename: str,
    mime_type: str,
    media_kind: str,
    fallback: SmartMediaAnalysis,
) -> dict[str, Any] | None:
    if media_kind != "image":
        return None

    classifier = _local_vision_command()
    if not classifier:
        return None

    suffix = Path(filename or "image").suffix or mimetypes.guess_extension(mime_type or "") or ".jpg"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as handle:
        handle.write(content)
        handle.flush()
        try:
            result = subprocess.run(
                [str(classifier), "--vision-classify", handle.name],
                capture_output=True,
                text=True,
                timeout=45,
                check=True,
            )
        except Exception:
            return None

    report = result.stdout or ""
    label_match = re.search(r"^Top label:\s*(.+)$", report, re.MULTILINE)
    score_match = re.search(r"^Confidence:\s*([0-9.]+)$", report, re.MULTILINE)
    guesses_match = re.search(r"^Top guesses:\s*(.+)$", report, re.MULTILINE)
    label = _clean_label(label_match.group(1) if label_match else "")
    if not label:
        return None

    top_guesses = [
        _clean_label(part.split("(", 1)[0])
        for part in str(guesses_match.group(1) if guesses_match else "").split(",")
        if _clean_label(part.split("(", 1)[0])
    ]
    score = _clamp_float(score_match.group(1) if score_match else None, 0.0, 1.0, 0.35)
    confidence = max(0.46, min(0.68, score + 0.12))

    normalized_label = label.lower()
    category_name = fallback.category_name
    if normalized_label in {"anime", "cartoon", "illustration", "painting"}:
        category_name = category_name or "Cartoon"
    elif normalized_label == "portrait photo":
        category_name = category_name or "Profile Pictures"
    elif normalized_label == "landscape photo":
        category_name = category_name or "Wallpapers"

    tags = _normalize_tags([label, *top_guesses, *(fallback.tags[:4] if fallback.tags else [])])
    title = fallback.title
    if normalized_label in {"anime", "cartoon", "illustration", "painting"} and _is_bad_subject_title(title, category_name, fallback.subcategory_name):
        title = "Anime illustration"
    elif normalized_label == "portrait photo" and _is_bad_subject_title(title, category_name, fallback.subcategory_name):
        title = "Portrait photo"
    elif normalized_label == "landscape photo" and _is_bad_subject_title(title, category_name, fallback.subcategory_name):
        title = "Landscape photo"
    elif normalized_label in {"logo", "icon", "sticker"} and _is_bad_subject_title(title, category_name, fallback.subcategory_name):
        title = f"{label.title()} graphic"

    return {
        "title": title,
        "suggested_filename_base": "",
        "tags": tags[:12],
        "category_name": category_name or "",
        "subcategory_name": fallback.subcategory_name or "",
        "is_adult": False,
        "confidence": confidence,
        "reason": f"Local CLIP fallback matched {label} ({score:.2f})",
        "source": "local-clip",
    }


def _media_size(content: bytes, filename: str, mime_type: str, media_kind: str) -> tuple[int, int] | None:
    if media_kind == "image":
        try:
            from PIL import Image
            Image.MAX_IMAGE_PIXELS = None
            with Image.open(io.BytesIO(content)) as image:
                return tuple(int(part) for part in image.size)
        except Exception:
            return None
    return _video_size(content, filename, mime_type) if media_kind == "video" else None


def _video_size(content: bytes, filename: str, mime_type: str) -> tuple[int, int] | None:
    suffix = Path(filename or "video").suffix or mimetypes.guess_extension(mime_type or "") or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as handle:
        handle.write(content)
        handle.flush()
        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v", "error",
                    "-select_streams", "v:0",
                    "-show_entries", "stream=width,height",
                    "-of", "json",
                    handle.name,
                ],
                capture_output=True,
                text=True,
                check=True,
            )
            payload = json.loads(result.stdout or "{}")
            stream = (payload.get("streams") or [{}])[0]
            width = int(stream.get("width") or 0)
            height = int(stream.get("height") or 0)
            return (width, height) if width and height else None
        except Exception:
            return None


def _preview_base64(content: bytes, filename: str, mime_type: str, media_kind: str) -> str | None:
    if media_kind == "image":
        try:
            from PIL import Image, ImageSequence
            Image.MAX_IMAGE_PIXELS = None
            with Image.open(io.BytesIO(content)) as image:
                frame = next(ImageSequence.Iterator(image), image)
                preview = frame.convert("RGB")
                preview.thumbnail((1400, 1400))
                output = io.BytesIO()
                preview.save(output, format="JPEG", quality=84, optimize=True)
                return base64.b64encode(output.getvalue()).decode("ascii")
        except Exception:
            return base64.b64encode(content).decode("ascii")
    if media_kind == "video":
        return _video_preview_base64(content, filename, mime_type)
    return None


def _preview_data_url(content: bytes, filename: str, mime_type: str, media_kind: str) -> str | None:
    preview_b64 = _preview_base64(content, filename, mime_type, media_kind)
    if not preview_b64:
        return None
    return f"data:image/jpeg;base64,{preview_b64}"


def _video_preview_base64(content: bytes, filename: str, mime_type: str) -> str | None:
    suffix = Path(filename or "video").suffix or mimetypes.guess_extension(mime_type or "") or ".mp4"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=True) as handle:
        handle.write(content)
        handle.flush()
        try:
            result = subprocess.run(
                [
                    "ffmpeg",
                    "-v", "error",
                    "-i", handle.name,
                    "-frames:v", "1",
                    "-vf", "scale='min(1400,iw)':-2",
                    "-f", "image2pipe",
                    "-vcodec", "mjpeg",
                    "pipe:1",
                ],
                capture_output=True,
                check=True,
            )
            return base64.b64encode(result.stdout).decode("ascii")
        except Exception:
            return None


def _build_tags(*, filename: str, title: str, description: str, category_name: str | None, subcategory_name: str | None, media_kind: str, size: tuple[int, int] | None, tags_hint: list[str]) -> list[str]:
    tags: list[str] = []
    if category_name:
        tags.extend(_normalize_tokens(category_name))
    if subcategory_name:
        tags.extend(_normalize_tokens(subcategory_name))
    if media_kind == "video":
        tags.append("video")
    if Path(filename).suffix.lower() == ".gif":
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
    for value in [title, description, _filename_subject_text(filename)]:
        tags.extend(_normalize_tokens(value))
    tags.extend(_normalize_tags(tags_hint))
    return _merge_tags(tags, [])


def _normalize_tokens(value: str | None) -> list[str]:
    results: list[str] = []
    for token in clean_tokens(value):
        if token in STOP_TAGS or len(token) < 3 or _is_noise_token(token):
            continue
        results.append(token)
    return results


def _merge_tags(primary: list[str], secondary: list[str]) -> list[str]:
    merged: list[str] = []
    seen: set[str] = set()
    for raw in list(primary) + list(secondary):
        for tag in _normalize_tags([raw]):
            if tag in seen:
                continue
            seen.add(tag)
            merged.append(tag)
            if len(merged) >= 12:
                return merged
    return merged


def _normalize_tags(values: Any) -> list[str]:
    if isinstance(values, str):
        candidates = re.split(r"[,#\s]+", values)
    else:
        candidates = list(values or [])
    normalized: list[str] = []
    seen: set[str] = set()
    for raw in candidates:
        raw_tag = re.sub(r"\s+", "-", str(raw or "").strip().lower())
        tag = re.sub(r"[^a-z0-9_.-]+", "", raw_tag)[:32]
        if not tag or tag in STOP_TAGS or len(tag) < 2 or tag in seen or _is_noise_token(tag):
            continue
        seen.add(tag)
        normalized.append(tag)
    return normalized[:12]


def _clean_title(value: Any) -> str:
    text = " ".join(str(value or "").strip().split())[:160]
    text = re.sub(r"\b(?:\d{3,4}x\d{3,4}|\d{3,4}p|4k|8k|uhd|fhd|qhd)\b", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\b(?:wp\d+|img[_-]?\d+|dsc[_-]?\d+|pxl[_-]?\d+|mvimg[_-]?\d+|screenshot[_-]?\d+|photo[_-]?\d+|image[_-]?\d+)\b", "", text, flags=re.IGNORECASE)
    text = re.sub(r"(?<![a-zA-Z])\d{2,}(?![a-zA-Z])", "", text)
    text = re.sub(r"\s+", " ", text).strip(" -_")
    return text[:160]


def _clean_label(value: Any) -> str | None:
    cleaned = " ".join(str(value or "").strip().split())[:80]
    if not cleaned or _is_noise_token(cleaned):
        return None
    return cleaned


def _clean_filename_base(value: Any) -> str:
    cleaned = re.sub(r"[^a-z0-9-]+", "-", str(value or "").strip().lower())
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip("-")
    return cleaned[:90]


def _suggest_filename(*, title: str, source_filename: str, mime_type: str, category_name: str | None, subcategory_name: str | None, suggested_base: str = "") -> str:
    suffix = Path(source_filename or "upload").suffix.lower()
    if not suffix:
        suffix = mimetypes.guess_extension(mime_type or "") or ""
    if suffix == ".jpe":
        suffix = ".jpg"
    base = suggested_base
    if not base:
        seed = title or subcategory_name or category_name or Path(source_filename).stem or "media"
        base = re.sub(r"[^a-z0-9]+", "-", seed.lower()).strip("-")
    if not base:
        base = "media"
    if _looks_low_signal_name(source_filename) and base in {"imported-media", "media", "upload"}:
        base = f"{base}-{Path(source_filename).stem[:8].lower()}".strip("-")
    return f"{base[:90] or 'media'}{suffix}"


def _looks_low_signal_name(filename: str) -> bool:
    stem = Path(filename or "").stem.strip()
    if not stem:
        return True
    lowered = stem.lower()
    compact = re.sub(r"[^a-z0-9]+", "", lowered)
    if LOW_SIGNAL_RE.match(lowered):
        return True
    if HEXISH_RE.fullmatch(compact):
        return True
    if compact.isdigit() and len(compact) >= 2:
        return True
    if re.fullmatch(r"[0-9a-f-]{16,}", lowered):
        return True
    return False



def _is_noise_token(value: str | None) -> bool:
    token = str(value or "").strip().lower().replace("_", "-")
    if not token:
        return True
    compact = re.sub(r"[^a-z0-9]+", "", token)
    if compact.isdigit() and len(compact) >= 2:
        return True
    if re.fullmatch(r"[a-f0-9]{4,}", compact) and any(ch.isdigit() for ch in compact):
        return True
    if NOISE_TOKEN_RE.fullmatch(token) or NOISE_TOKEN_RE.fullmatch(compact):
        return True
    return False


def _compact_label(value: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _title_is_category_or_subcategory(title: str | None, category_name: str | None, subcategory_name: str | None) -> bool:
    compact_title = _compact_label(title)
    if not compact_title:
        return True
    blocked = {
        _compact_label(category_name),
        _compact_label(subcategory_name),
        _compact_label(str(category_name or "").replace("Backgrounds", "Background")),
        _compact_label(str(category_name or "").replace("Pictures", "Picture")),
    }
    blocked.update({
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
    })
    blocked.discard("")
    return compact_title in blocked


def _is_bad_subject_title(title: str | None, category_name: str | None, subcategory_name: str | None) -> bool:
    if _is_generic_title(title):
        return True
    if _title_is_category_or_subcategory(title, category_name, subcategory_name):
        return True
    return False

def _is_generic_title(value: str | None) -> bool:
    original = " ".join(str(value or "").strip().split())
    cleaned = _clean_title(original)
    if not original or not cleaned:
        return True
    if _is_noise_token(original) or _is_noise_token(cleaned):
        return True
    if GENERIC_TITLE_RE.fullmatch(cleaned):
        return True
    lowered = cleaned.lower().strip()
    if lowered in {"desktop backgrounds", "phone backgrounds", "wallpapers"}:
        return True
    parts = [p for p in re.split(r"\s+", lowered) if p]
    meaningful = [p for p in parts if p not in STOP_TAGS and not _is_noise_token(p)]
    if not meaningful:
        return True
    generic_subject_words = {
        "media", "upload", "background", "backgrounds", "wallpaper", "wallpapers",
        "image", "images", "photo", "photos", "picture", "pictures", "profile",
        "art", "artwork", "render", "renders", "edit", "edits", "graphic", "graphics",
        "illustration", "portrait", "landscape", "desktop", "phone", "uncategorized",
    }
    return len(meaningful) == 1 and meaningful[0] in generic_subject_words


def _category_suffix(category_name: str | None, media_kind: str) -> str:
    if category_name == "Phone Backgrounds":
        return "Phone Background"
    if category_name == "Desktop Backgrounds":
        return "Desktop Background"
    if category_name == "Wallpapers":
        return "Wallpaper"
    if category_name == "Profile Pictures":
        return "Profile Picture"
    if media_kind == "video":
        return "Video"
    return "Artwork"


def _pretty_tag(tag: str) -> str:
    text = str(tag or "").replace("_", " ").replace("-", " ")
    words = [w for w in text.split() if w and w not in STOP_TAGS and not _is_noise_token(w)]
    if not words:
        return ""
    return " ".join(w.upper() if w.lower() in {"mlp", "fnaf", "kpop", "vr", "sfm", "eqg", "ai", "4k"} else w.capitalize() for w in words)


def _compose_specific_title(*, title: str, filename: str, category_name: str | None, subcategory_name: str | None, tags: list[str], media_kind: str) -> str:
    clean_title = _clean_title(title)
    if clean_title and not _is_bad_subject_title(clean_title, category_name, subcategory_name):
        return clean_title[:160]

    subject = _clean_label(subcategory_name)
    if subject and not _is_bad_subject_title(subject, category_name, None):
        base = f"{subject} {_category_suffix(category_name, media_kind)}"
        return base[:160]

    preferred_tags: list[str] = []
    generic_title_tags = {"landscape", "portrait", "square", "1080p", "1440p", "4k", "video", "gif", "profile", "profiles", "picture", "pictures", "desktop", "phone", "background", "backgrounds", "wallpaper", "wallpapers"}
    generic_title_tags.update(_normalize_tokens(category_name or ""))
    generic_title_tags.update(_normalize_tokens(subcategory_name or ""))
    for tag in tags:
        if tag in generic_title_tags:
            continue
        pretty = _pretty_tag(tag)
        if not pretty:
            continue
        if pretty.lower() in {"background", "backgrounds", "wallpaper", "wallpapers", "desktop", "phone"}:
            continue
        if pretty.lower() not in {p.lower() for p in preferred_tags}:
            preferred_tags.append(pretty)
        if len(preferred_tags) >= 2:
            break

    if preferred_tags:
        if len(preferred_tags) >= 2:
            base = f"{preferred_tags[0]} and {preferred_tags[1]} {_category_suffix(category_name, media_kind)}"
        else:
            base = f"{preferred_tags[0]} {_category_suffix(category_name, media_kind)}"
        return base[:160]

    # Do not fall back to numeric filename chunks. If the AI cannot name the subject,
    # use an honest uncategorized visual title instead of showing file IDs like 0703.
    if category_name in {"Phone Backgrounds", "Desktop Backgrounds", "Wallpapers", "Profile Pictures"}:
        return f"Uncategorized {_category_suffix(category_name, media_kind)}"[:160]

    fallback = category_name or ("Video" if media_kind == "video" else "Media")
    if _title_is_category_or_subcategory(fallback, category_name, subcategory_name):
        fallback = "Media"
    return f"Uncategorized {fallback}"[:160]


def _looks_adult(title: str, description: str, tags: list[str], filename: str, mime_type: str) -> bool:
    combined = " ".join([title, description, " ".join(tags), filename, mime_type]).lower()
    normalized = re.sub(r"[^a-z0-9+]+", " ", combined)
    adult_keywords = {
        "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
        "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
        "erotic", "fetish", "onlyfans", "xxx",
    }
    
    # Use word boundaries to prevent 'sex' from flagging 'sussex' or 'sextant'
    return any(re.search(rf"\b{re.escape(word)}\b", normalized) for word in adult_keywords)


def _clamp_float(value: Any, minimum: float, maximum: float, default: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, number))
