"""Module-level constants and free functions used across GalleryDatabase's
mixins. Moved verbatim from the top of the pre-split database.py — this is
the DB-layer analogue of routers/_shared.py: never duplicate these per-mixin,
import them from here."""

import hashlib
import logging
import re
from typing import Any

SLUG_RE = re.compile(r"[^a-z0-9]+")
USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{3,40}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
MEDIA_KINDS = {"image", "video", "mixed"}
DB_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_$]+$")
log = logging.getLogger(__name__)


def quote_identifier(value: str) -> str:
    name = str(value or "").strip()
    if not DB_IDENTIFIER_RE.fullmatch(name):
        raise RuntimeError(f"Unsafe database identifier: {name!r}")
    return f"`{name}`"


def mysql_error_code(exc: Exception) -> int | None:
    try:
        return int(getattr(exc, "args", [None])[0])
    except (TypeError, ValueError):
        return None
DEFAULT_USER_SETTINGS = {
    "theme_mode": "system",
    "accent_color": "#37c9a7",
    "accent_secondary": "",
    "gallery_bg_color": "",
    "grid_density": "comfortable",
    "default_sort": "new",
    "items_per_page": 24,
    "autoplay_previews": False,
    "muted_previews": True,
    "reduce_motion": False,
    "open_original_in_new_tab": False,
    "blur_video_previews": False,
    "profile_show_uploads": True,
    "profile_show_collections": True,
    "profile_show_friends": True,
    "profile_show_follow_counts": True,
    "profile_layout": "spotlight",
    "profile_banner_style": "gradient",
    "profile_card_style": "glass",
    "profile_stat_style": "tiles",
    "profile_content_focus": "balanced",
    "profile_hero_alignment": "split",
    "profile_avatar_shape": "circle",
    "profile_media_shape": "soft",
    "profile_surface_style": "standard",
    "profile_social_layout": "rail",
    "profile_featured_panel": "uploads",
    "profile_backdrop_image_url": "",
    "profile_backdrop_strength": 0.18,
    "profile_show_joined_date": True,
    "profile_name_style": "display",
    "profile_header_style": "solid",
    "profile_bg_color": "",
    "card_hover_effect": "lift",
    "card_aspect_ratio": "free",
    "media_border_style": "none",
    "gallery_font": "system",
    "card_info_display": "below",
    "column_gap": "normal",
    "watermark_text": "",
    "discord_webhook_url": "",
}
USER_COLUMNS = (
    ("email", "VARCHAR(255) NULL"),
    ("email_verified_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("email_verification_token_hash", "CHAR(64) NULL"),
    ("email_verification_sent_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("last_seen_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("bio", "VARCHAR(500) NULL"),
    ("profile_quote", "VARCHAR(200) NULL"),
    ("website_url", "VARCHAR(300) NULL"),
    ("location_label", "VARCHAR(80) NULL"),
    ("profile_headline", "VARCHAR(120) NULL"),
    ("featured_tags", "JSON NULL"),
    ("profile_color", "VARCHAR(20) NOT NULL DEFAULT '#37c9a7'"),
    ("avatar_path", "VARCHAR(500) NULL"),
    ("avatar_file_id", "BIGINT UNSIGNED NULL"),
    ("avatar_mime_type", "VARCHAR(120) NULL"),
    ("avatar_original_filename", "VARCHAR(255) NULL"),
    ("public_profile", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("show_liked_count", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("show_collections", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("show_recent_uploads", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("show_friends", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("birthdate", "DATE NULL"),
    ("age_verified_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("adult_content_consent", "TINYINT(1) NOT NULL DEFAULT 0"),
    ("user_settings", "JSON NULL"),
    ("totp_secret", "VARCHAR(64) NULL"),
    ("totp_enabled_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("totp_recovery_codes", "JSON NULL"),
    ("updated_at", "TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"),
    ("banned_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("banned_until", "TIMESTAMP NULL DEFAULT NULL"),
    ("ban_reason", "VARCHAR(300) NULL"),
    ("banned_by", "BIGINT UNSIGNED NULL"),
)
MEDIA_COLUMNS = (
    ("media_file_id", "BIGINT UNSIGNED NULL"),
    ("subcategory_id", "BIGINT UNSIGNED NULL"),
    ("visibility", "ENUM('public','unlisted','private') NOT NULL DEFAULT 'public'"),
    ("comments_enabled", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("downloads_enabled", "TINYINT(1) NOT NULL DEFAULT 1"),
    ("pinned_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("deleted_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("content_sha256", "CHAR(64) NULL"),
    ("is_adult", "TINYINT(1) NOT NULL DEFAULT 0"),
    ("adult_marked_by_user", "TINYINT(1) NOT NULL DEFAULT 0"),
    ("adult_marked_by_ai", "TINYINT(1) NOT NULL DEFAULT 0"),
    ("moderation_status", "VARCHAR(30) NOT NULL DEFAULT 'clear'"),
    ("moderation_score", "FLOAT NOT NULL DEFAULT 0"),
    ("moderation_reason", "VARCHAR(300) NULL"),
    ("moderated_at", "TIMESTAMP NULL DEFAULT NULL"),
    ("image_width", "INT UNSIGNED NULL"),
    ("image_height", "INT UNSIGNED NULL"),
    ("publish_at", "TIMESTAMP NULL DEFAULT NULL"),
)

AI_TRAINING_COLUMNS = (
    ("dedupe_key", "CHAR(64) NULL"),
    ("image_phash", "CHAR(16) NULL"),
    ("image_dhash", "CHAR(16) NULL"),
    ("image_width", "INT UNSIGNED NULL"),
    ("image_height", "INT UNSIGNED NULL"),
    ("training_origin", "VARCHAR(80) NULL"),
    ("training_confidence", "FLOAT NOT NULL DEFAULT 0.72"),
)
MAX_MEDIA_SUBCATEGORIES = 3
MEDIA_CATEGORY_SELECT = (
    "c.name AS category_name, c.slug AS category_slug, "
    "sc.name AS subcategory_name, sc.slug AS subcategory_slug,"
)
MEDIA_CATEGORY_JOIN = (
    "JOIN categories c ON c.id = m.category_id "
    "LEFT JOIN subcategories sc ON sc.id = m.subcategory_id"
)


def slugify(value: str) -> str:
    slug = SLUG_RE.sub("-", value.lower()).strip("-")
    return slug[:80] or "category"


def clean_subcategory_name(value: Any) -> str:
    return " ".join(str(value or "").strip().split())[:80]


def normalize_subcategory_names(values: Any, *, limit: int = MAX_MEDIA_SUBCATEGORIES) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for raw in values or []:
        cleaned = clean_subcategory_name(raw)
        if not cleaned:
            continue
        key = cleaned.lower()
        if key in seen:
            continue
        seen.add(key)
        names.append(cleaned)
        if len(names) >= max(1, int(limit or MAX_MEDIA_SUBCATEGORIES)):
            break
    return names


def normalize_subcategory_ids(values: Any, *, limit: int = MAX_MEDIA_SUBCATEGORIES) -> list[int]:
    ids: list[int] = []
    seen: set[int] = set()
    for raw in values or []:
        try:
            subcategory_id = int(raw)
        except (TypeError, ValueError):
            continue
        if subcategory_id <= 0 or subcategory_id in seen:
            continue
        seen.add(subcategory_id)
        ids.append(subcategory_id)
        if len(ids) >= max(1, int(limit or MAX_MEDIA_SUBCATEGORIES)):
            break
    return ids


def normalize_username(username: str) -> str:
    username = str(username or "").strip()
    if not USERNAME_RE.fullmatch(username):
        raise ValueError("Username must be 3-40 characters using letters, numbers, dots, dashes, or underscores.")
    return username


def normalize_email(email: str | None) -> str | None:
    value = str(email or "").strip().lower()
    if not value:
        return None
    if len(value) > 255 or not EMAIL_RE.fullmatch(value):
        raise ValueError("Enter a valid email address.")
    return value


def verification_token_hash(token: str) -> str:
    return hashlib.sha256(str(token).encode("utf-8")).hexdigest()
