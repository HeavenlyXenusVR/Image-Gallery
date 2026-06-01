import json
import logging
import asyncio
import re
import hashlib
import mimetypes
import random
from pathlib import Path
from datetime import date
from decimal import Decimal
from typing import Any

import aiomysql

from .auth import hash_password, verify_password
from .config import Settings


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
    ("updated_at", "TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"),
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


import time as _time

# TTL (seconds) for the in-memory user cache used by get_user().
_USER_CACHE_TTL = 30.0


class GalleryDatabase:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.pool: aiomysql.Pool | None = None
        self._connect_lock = asyncio.Lock()
        self._blob_lock = asyncio.Lock()
        configured_chunk = int(getattr(settings, "db_blob_chunk_bytes", 8 * 1024 * 1024) or 0)
        self.media_chunk_bytes = max(1024 * 1024, min(configured_chunk, 16 * 1024 * 1024))
        # {user_id: (expires_at, user_dict)} — avoids a DB round-trip on every /api/me poll
        self._user_cache: dict[int, tuple[float, dict[str, Any] | None]] = {}

    async def connect(self) -> None:
        async with self._connect_lock:
            if self.pool and not getattr(self.pool, "closed", False):
                return
            await self._ensure_schema()
            await self.ensure_packet_limit()
            self.pool = await aiomysql.create_pool(
                host=self.settings.db_host,
                port=self.settings.db_port,
                user=self.settings.db_user,
                password=self.settings.db_password,
                db=self.settings.db_schema,
                autocommit=True,
                init_command="SET time_zone = '+00:00'",
                minsize=int(getattr(self.settings, "db_pool_min_size", 1) or 1),
                maxsize=int(getattr(self.settings, "db_pool_max_size", 8) or 8),
                pool_recycle=int(getattr(self.settings, "db_pool_recycle_seconds", 180) or 180),
                connect_timeout=int(getattr(self.settings, "db_connect_timeout_seconds", 10) or 10),
            )
            await self.ensure_tables()

    async def close(self) -> None:
        if self.pool:
            self.pool.close()
            await self.pool.wait_closed()
            self.pool = None

    async def reconnect(self) -> None:
        await self.close()
        await self.connect()

    async def get_max_allowed_packet(self) -> int:
        async with self.pool.acquire() as conn:
            await conn.ping(reconnect=True)
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SHOW VARIABLES LIKE 'max_allowed_packet'")
                row = await cur.fetchone() or {}
                return int(row.get("Value") or row.get("value") or 0)

    async def ensure_packet_limit(self) -> None:
        """Best-effort MariaDB packet bump for 500MB uploads."""
        required = int(getattr(self.settings, "required_db_packet_bytes", 512 * 1024 * 1024) or 0)
        if required <= 0:
            return
        conn = await aiomysql.connect(
            host=self.settings.db_host,
            port=self.settings.db_port,
            user=self.settings.db_user,
            password=self.settings.db_password,
            autocommit=True,
            connect_timeout=int(getattr(self.settings, "db_connect_timeout_seconds", 10) or 10),
        )
        try:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SHOW GLOBAL VARIABLES LIKE 'max_allowed_packet'")
                row = await cur.fetchone() or {}
                current = int(row.get("Value") or row.get("value") or 0)
                if current >= required:
                    return
                try:
                    await cur.execute(f"SET GLOBAL max_allowed_packet={required}")
                    log.warning("Raised MariaDB max_allowed_packet from %s to %s for gallery uploads.", current, required)
                except Exception as exc:
                    log.warning("Could not auto-raise MariaDB max_allowed_packet from %s to %s: %s", current, required, exc)
        finally:
            conn.close()

    async def _ensure_schema(self) -> None:
        conn = await aiomysql.connect(
            host=self.settings.db_host,
            port=self.settings.db_port,
            user=self.settings.db_user,
            password=self.settings.db_password,
            autocommit=True,
            connect_timeout=int(getattr(self.settings, "db_connect_timeout_seconds", 10) or 10),
        )
        try:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    SELECT 1
                    FROM information_schema.schemata
                    WHERE schema_name = %s
                    LIMIT 1
                    """,
                    (self.settings.db_schema,),
                )
                if not await cur.fetchone():
                    await cur.execute(
                        f"CREATE DATABASE {quote_identifier(self.settings.db_schema)} "
                        "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                    )
        finally:
            conn.close()

    async def ensure_tables(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                async def ensure_table(name: str, ddl: str) -> None:
                    await cur.execute(
                        """
                        SELECT 1
                        FROM information_schema.tables
                        WHERE table_schema = %s AND table_name = %s
                        LIMIT 1
                        """,
                        (self.settings.db_schema, name),
                    )
                    if not await cur.fetchone():
                        await cur.execute(ddl)

                await ensure_table(
                    "users",
                    """
                    CREATE TABLE users (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      username VARCHAR(40) NOT NULL UNIQUE,
                      display_name VARCHAR(80) NOT NULL,
                      password_hash VARCHAR(255) NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      last_login_at TIMESTAMP NULL DEFAULT NULL
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "categories",
                    """
                    CREATE TABLE categories (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      name VARCHAR(80) NOT NULL UNIQUE,
                      slug VARCHAR(90) NOT NULL UNIQUE,
                      media_kind ENUM('image','video','mixed') NOT NULL DEFAULT 'mixed',
                      created_by BIGINT UNSIGNED NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      CONSTRAINT fk_categories_user FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_items",
                    """
                    CREATE TABLE media_items (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      user_id BIGINT UNSIGNED NOT NULL,
                      category_id BIGINT UNSIGNED NOT NULL,
                      title VARCHAR(160) NOT NULL,
                      description TEXT NULL,
                      tags JSON NULL,
                      media_kind ENUM('image','video') NOT NULL,
                      mime_type VARCHAR(120) NOT NULL,
                      original_filename VARCHAR(255) NOT NULL,
                      storage_path VARCHAR(500) NOT NULL,
                      file_size BIGINT UNSIGNED NOT NULL,
                      views BIGINT UNSIGNED NOT NULL DEFAULT 0,
                      downloads BIGINT UNSIGNED NOT NULL DEFAULT 0,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                      FULLTEXT KEY ft_media_text (title, description),
                      KEY idx_media_created (created_at),
                      KEY idx_media_kind (media_kind),
                      KEY idx_media_category (category_id),
                      CONSTRAINT fk_media_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_media_category FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE RESTRICT
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )

                await ensure_table(
                    "media_files",
                    """
                    CREATE TABLE media_files (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      sha256 CHAR(64) NOT NULL UNIQUE,
                      mime_type VARCHAR(120) NOT NULL,
                      original_filename VARCHAR(255) NOT NULL,
                      media_kind ENUM('image','video') NOT NULL,
                      file_size BIGINT UNSIGNED NOT NULL,
                      content LONGBLOB NOT NULL,
                      created_by BIGINT UNSIGNED NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      KEY idx_media_files_kind (media_kind),
                      KEY idx_media_files_user (created_by),
                      CONSTRAINT fk_media_files_user FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_file_chunks",
                    """
                    CREATE TABLE media_file_chunks (
                      file_id BIGINT UNSIGNED NOT NULL,
                      chunk_index INT UNSIGNED NOT NULL,
                      content LONGBLOB NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      PRIMARY KEY (file_id, chunk_index),
                      CONSTRAINT fk_media_file_chunks_file FOREIGN KEY (file_id) REFERENCES media_files(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "user_avatar_files",
                    """
                    CREATE TABLE user_avatar_files (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      user_id BIGINT UNSIGNED NOT NULL,
                      sha256 CHAR(64) NOT NULL,
                      mime_type VARCHAR(120) NOT NULL,
                      original_filename VARCHAR(255) NOT NULL,
                      file_size BIGINT UNSIGNED NOT NULL,
                      content LONGBLOB NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      KEY idx_avatar_user (user_id, created_at),
                      UNIQUE KEY uniq_avatar_user_hash (user_id, sha256),
                      CONSTRAINT fk_avatar_files_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "user_follows",
                    """
                    CREATE TABLE user_follows (
                      follower_id BIGINT UNSIGNED NOT NULL,
                      followed_id BIGINT UNSIGNED NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      PRIMARY KEY (follower_id, followed_id),
                      KEY idx_followed (followed_id, created_at),
                      CONSTRAINT fk_follows_follower FOREIGN KEY (follower_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_follows_followed FOREIGN KEY (followed_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT chk_no_self_follow CHECK (follower_id <> followed_id)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "friend_requests",
                    """
                    CREATE TABLE friend_requests (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      requester_id BIGINT UNSIGNED NOT NULL,
                      addressee_id BIGINT UNSIGNED NOT NULL,
                      status ENUM('pending','accepted','declined','cancelled') NOT NULL DEFAULT 'pending',
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      responded_at TIMESTAMP NULL DEFAULT NULL,
                      UNIQUE KEY uniq_friend_pair (requester_id, addressee_id),
                      KEY idx_friend_addressee_status (addressee_id, status, created_at),
                      KEY idx_friend_requester_status (requester_id, status, created_at),
                      CONSTRAINT fk_friend_requester FOREIGN KEY (requester_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_friend_addressee FOREIGN KEY (addressee_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT chk_no_self_friend CHECK (requester_id <> addressee_id)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "user_messages",
                    """
                    CREATE TABLE user_messages (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      sender_id BIGINT UNSIGNED NOT NULL,
                      recipient_id BIGINT UNSIGNED NOT NULL,
                      body VARCHAR(2000) NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      read_at TIMESTAMP NULL DEFAULT NULL,
                      KEY idx_messages_sender (sender_id, created_at),
                      KEY idx_messages_recipient (recipient_id, read_at, created_at),
                      KEY idx_messages_thread (sender_id, recipient_id, created_at),
                      CONSTRAINT fk_messages_sender FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_messages_recipient FOREIGN KEY (recipient_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT chk_no_self_message CHECK (sender_id <> recipient_id)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "auth_attempts",
                    """
                    CREATE TABLE auth_attempts (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      username VARCHAR(80) NULL,
                      ip_address VARCHAR(64) NOT NULL,
                      successful TINYINT(1) NOT NULL DEFAULT 0,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      KEY idx_auth_attempts_ip_time (ip_address, created_at),
                      KEY idx_auth_attempts_user_time (username, created_at)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "api_rate_limits",
                    """
                    CREATE TABLE api_rate_limits (
                      bucket_key VARCHAR(190) NOT NULL PRIMARY KEY,
                      window_start TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      event_count INT UNSIGNED NOT NULL DEFAULT 0,
                      updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                      KEY idx_api_rate_limits_updated (updated_at)
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )

                await ensure_table(
                    "media_likes",
                    """
                    CREATE TABLE media_likes (
                      user_id BIGINT UNSIGNED NOT NULL,
                      media_id BIGINT UNSIGNED NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      PRIMARY KEY (user_id, media_id),
                      CONSTRAINT fk_likes_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_likes_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_comments",
                    """
                    CREATE TABLE media_comments (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      media_id BIGINT UNSIGNED NOT NULL,
                      user_id BIGINT UNSIGNED NOT NULL,
                      body VARCHAR(500) NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      KEY idx_comments_media (media_id, created_at),
                      CONSTRAINT fk_comments_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE,
                      CONSTRAINT fk_comments_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_bookmarks",
                    """
                    CREATE TABLE media_bookmarks (
                      user_id BIGINT UNSIGNED NOT NULL,
                      media_id BIGINT UNSIGNED NOT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      PRIMARY KEY (user_id, media_id),
                      CONSTRAINT fk_bookmarks_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_bookmarks_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_collections",
                    """
                    CREATE TABLE media_collections (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      user_id BIGINT UNSIGNED NOT NULL,
                      name VARCHAR(100) NOT NULL,
                      description VARCHAR(500) NULL,
                      is_public TINYINT(1) NOT NULL DEFAULT 1,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                      KEY idx_collections_user (user_id, created_at),
                      CONSTRAINT fk_collections_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_collection_items",
                    """
                    CREATE TABLE media_collection_items (
                      collection_id BIGINT UNSIGNED NOT NULL,
                      media_id BIGINT UNSIGNED NOT NULL,
                      added_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      PRIMARY KEY (collection_id, media_id),
                      CONSTRAINT fk_collection_items_collection FOREIGN KEY (collection_id) REFERENCES media_collections(id) ON DELETE CASCADE,
                      CONSTRAINT fk_collection_items_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "media_reports",
                    """
                    CREATE TABLE media_reports (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      media_id BIGINT UNSIGNED NOT NULL,
                      user_id BIGINT UNSIGNED NOT NULL,
                      reason VARCHAR(80) NOT NULL,
                      details VARCHAR(500) NULL,
                      status ENUM('open','reviewed','dismissed') NOT NULL DEFAULT 'open',
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      UNIQUE KEY uniq_report_once (media_id, user_id),
                      KEY idx_reports_media (media_id, created_at),
                      CONSTRAINT fk_reports_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE,
                      CONSTRAINT fk_reports_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "ai_vision_training_examples",
                    """
                    CREATE TABLE ai_vision_training_examples (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      user_id BIGINT UNSIGNED NOT NULL,
                      media_id BIGINT UNSIGNED NULL,
                      original_filename VARCHAR(255) NULL,
                      source_title VARCHAR(160) NULL,
                      source_category_name VARCHAR(80) NULL,
                      source_subcategory_name VARCHAR(80) NULL,
                      source_tags JSON NULL,
                      corrected_title VARCHAR(160) NOT NULL,
                      corrected_category_name VARCHAR(80) NULL,
                      corrected_subcategory_name VARCHAR(80) NULL,
                      corrected_tags JSON NULL,
                      corrected_is_adult TINYINT(1) NOT NULL DEFAULT 0,
                      notes VARCHAR(500) NULL,
                      dedupe_key CHAR(64) NULL,
                      image_phash CHAR(16) NULL,
                      image_dhash CHAR(16) NULL,
                      image_width INT UNSIGNED NULL,
                      image_height INT UNSIGNED NULL,
                      training_origin VARCHAR(80) NULL,
                      training_confidence FLOAT NOT NULL DEFAULT 0.72,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      KEY idx_ai_training_user_time (user_id, created_at),
                      KEY idx_ai_training_phash (image_phash),
                      KEY idx_ai_training_media (media_id),
                      UNIQUE KEY uniq_ai_training_dedupe (dedupe_key),
                      CONSTRAINT fk_ai_training_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_ai_training_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE SET NULL
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
                await ensure_table(
                    "ai_media_learning_state",
                    """
                    CREATE TABLE ai_media_learning_state (
                      media_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
                      user_id BIGINT UNSIGNED NOT NULL,
                      last_scanned_at TIMESTAMP NULL DEFAULT NULL,
                      last_scan_status VARCHAR(30) NOT NULL DEFAULT 'pending',
                      last_scan_source VARCHAR(40) NULL,
                      last_scan_confidence FLOAT NULL,
                      last_scan_title VARCHAR(160) NULL,
                      last_scan_error VARCHAR(300) NULL,
                      last_learned_at TIMESTAMP NULL DEFAULT NULL,
                      last_autofill_at TIMESTAMP NULL DEFAULT NULL,
                      updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                      KEY idx_ai_media_learning_status (last_scan_status, last_scanned_at),
                      KEY idx_ai_media_learning_user (user_id, updated_at),
                      CONSTRAINT fk_ai_media_learning_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE,
                      CONSTRAINT fk_ai_media_learning_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """,
                )
        await self.ensure_user_columns()
        await self.ensure_subcategory_tables()
        await self.ensure_media_columns()
        await self.ensure_media_indexes()
        await self.ensure_media_subcategory_links()
        await self.ensure_ai_training_columns()
        await self.ensure_ai_media_learning_tables()
        await self.seed_default_categories()

    async def ensure_user_columns(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT COLUMN_NAME FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA=%s AND TABLE_NAME='users'
                    """,
                    (self.settings.db_schema,),
                )
                existing = {row["COLUMN_NAME"] for row in await cur.fetchall()}
                for name, definition in USER_COLUMNS:
                    if name not in existing:
                        await cur.execute(f"ALTER TABLE users ADD COLUMN {name} {definition}")
                await cur.execute("UPDATE users SET user_settings=%s WHERE user_settings IS NULL", (json.dumps(DEFAULT_USER_SETTINGS),))
                try:
                    await cur.execute("CREATE UNIQUE INDEX uniq_users_email ON users (email)")
                except Exception as exc:
                    code = mysql_error_code(exc)
                    if code == 1061:
                        pass  # Index already exists — expected on repeat startups.
                    elif code == 1062:
                        log.warning("Could not create uniq_users_email: duplicate email values in existing data. Run a deduplication query before the index can be added: %s", exc)
                    else:
                        log.warning("Could not create uniq_users_email: %s", exc)

    async def ensure_subcategory_tables(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    SELECT 1
                    FROM information_schema.tables
                    WHERE table_schema = %s AND table_name = 'subcategories'
                    LIMIT 1
                    """,
                    (self.settings.db_schema,),
                )
                if await cur.fetchone():
                    return
                await cur.execute(
                    """
                    CREATE TABLE subcategories (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      category_id BIGINT UNSIGNED NOT NULL,
                      name VARCHAR(80) NOT NULL,
                      slug VARCHAR(90) NOT NULL,
                      created_by BIGINT UNSIGNED NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      UNIQUE KEY uniq_subcategories_name (category_id, name),
                      UNIQUE KEY uniq_subcategories_slug (category_id, slug),
                      KEY idx_subcategories_category (category_id, created_at),
                      CONSTRAINT fk_subcategories_category FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE,
                      CONSTRAINT fk_subcategories_user FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """
                )

    async def ensure_media_columns(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT COLUMN_NAME FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA=%s AND TABLE_NAME='media_items'
                    """,
                    (self.settings.db_schema,),
                )
                existing = {row["COLUMN_NAME"] for row in await cur.fetchall()}
                for name, definition in MEDIA_COLUMNS:
                    if name not in existing:
                        await cur.execute(f"ALTER TABLE media_items ADD COLUMN {name} {definition}")
                if "is_adult" not in existing:
                    await cur.execute("CREATE INDEX idx_media_adult ON media_items (is_adult, created_at)")
                try:
                    await cur.execute("CREATE INDEX idx_media_subcategory ON media_items (subcategory_id)")
                except Exception as exc:
                    if mysql_error_code(exc) != 1061:
                        log.warning("Could not create idx_media_subcategory: %s", exc)
                await cur.execute(
                    """
                    SELECT CONSTRAINT_NAME
                    FROM information_schema.KEY_COLUMN_USAGE
                    WHERE TABLE_SCHEMA=%s AND TABLE_NAME='media_items' AND COLUMN_NAME='subcategory_id'
                      AND REFERENCED_TABLE_NAME='subcategories'
                    LIMIT 1
                    """,
                    (self.settings.db_schema,),
                )
                if not await cur.fetchone():
                    await cur.execute(
                        """
                        ALTER TABLE media_items
                        ADD CONSTRAINT fk_media_subcategory
                        FOREIGN KEY (subcategory_id) REFERENCES subcategories(id) ON DELETE SET NULL
                        """
                    )

    async def ensure_media_indexes(self) -> None:
        """Idempotently add composite performance indexes to media_items and media_likes.

        These cover the hot query paths in list_media (deleted_at + visibility +
        pinned_at + created_at, kind + created_at, category + created_at,
        user + created_at, file_size filters) and the liked-by-me lookup on media_likes.
        Error code 1061 = ER_DUP_KEYNAME (index already exists) — silently ignored.
        """
        index_ddls = [
            ("idx_media_items_perf_main",
             "CREATE INDEX idx_media_items_perf_main ON media_items (deleted_at, visibility, pinned_at, created_at)"),
            ("idx_media_items_perf_kind_created",
             "CREATE INDEX idx_media_items_perf_kind_created ON media_items (media_kind, created_at)"),
            ("idx_media_items_perf_category_created",
             "CREATE INDEX idx_media_items_perf_category_created ON media_items (category_id, created_at)"),
            ("idx_media_items_perf_user_created",
             "CREATE INDEX idx_media_items_perf_user_created ON media_items (user_id, created_at)"),
            ("idx_media_items_perf_size",
             "CREATE INDEX idx_media_items_perf_size ON media_items (file_size)"),
            ("idx_media_items_perf_adult",
             "CREATE INDEX idx_media_items_perf_adult ON media_items (is_adult, created_at)"),
            ("idx_media_items_user_deleted",
             "CREATE INDEX idx_media_items_user_deleted ON media_items (user_id, deleted_at, created_at)"),
            ("idx_media_likes_media_user",
             "CREATE INDEX idx_media_likes_media_user ON media_likes (media_id, user_id)"),
        ]
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                for _name, ddl in index_ddls:
                    try:
                        await cur.execute(ddl)
                    except Exception as exc:
                        if mysql_error_code(exc) != 1061:
                            log.warning("Could not create index (%s): %s", _name, exc)

    async def ensure_media_subcategory_links(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT 1
                    FROM information_schema.tables
                    WHERE table_schema=%s AND table_name='media_item_subcategories'
                    LIMIT 1
                    """,
                    (self.settings.db_schema,),
                )
                if not await cur.fetchone():
                    await cur.execute(
                        """
                        CREATE TABLE media_item_subcategories (
                          media_id BIGINT UNSIGNED NOT NULL,
                          subcategory_id BIGINT UNSIGNED NOT NULL,
                          position TINYINT UNSIGNED NOT NULL,
                          created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                          PRIMARY KEY (media_id, position),
                          UNIQUE KEY uniq_media_item_subcategory (media_id, subcategory_id),
                          KEY idx_media_item_subcategories_subcategory (subcategory_id, media_id),
                          CONSTRAINT fk_media_item_subcategories_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE,
                          CONSTRAINT fk_media_item_subcategories_subcategory FOREIGN KEY (subcategory_id) REFERENCES subcategories(id) ON DELETE CASCADE,
                          CONSTRAINT chk_media_item_subcategories_position CHECK (position BETWEEN 1 AND 3)
                        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                        """
                    )
                try:
                    await cur.execute(
                        """
                        INSERT INTO media_item_subcategories (media_id, subcategory_id, position)
                        SELECT m.id, m.subcategory_id, 1
                        FROM media_items m
                        LEFT JOIN media_item_subcategories ms
                          ON ms.media_id = m.id AND ms.position = 1
                        WHERE m.subcategory_id IS NOT NULL
                          AND ms.media_id IS NULL
                        """
                    )
                except Exception as exc:
                    log.warning("Could not backfill primary media subcategories into media_item_subcategories: %s", exc)

    async def ensure_ai_training_columns(self) -> None:
        """Add visual-fingerprint training columns to existing installations."""
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT COLUMN_NAME FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA=%s AND TABLE_NAME='ai_vision_training_examples'
                    """,
                    (self.settings.db_schema,),
                )
                existing = {row["COLUMN_NAME"] for row in await cur.fetchall()}
                for name, definition in AI_TRAINING_COLUMNS:
                    if name not in existing:
                        await cur.execute(f"ALTER TABLE ai_vision_training_examples ADD COLUMN {name} {definition}")
                try:
                    await cur.execute("CREATE INDEX idx_ai_training_phash ON ai_vision_training_examples (image_phash)")
                except Exception as exc:
                    if mysql_error_code(exc) != 1061:
                        log.warning("Could not create idx_ai_training_phash: %s", exc)
                try:
                    await cur.execute("CREATE UNIQUE INDEX uniq_ai_training_dedupe ON ai_vision_training_examples (dedupe_key)")
                except Exception as exc:
                    if mysql_error_code(exc) != 1061:
                        log.warning("Could not create uniq_ai_training_dedupe; duplicate dedupe keys may need cleanup: %s", exc)

    async def ensure_ai_media_learning_tables(self) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    SELECT 1
                    FROM information_schema.tables
                    WHERE table_schema = %s AND table_name = 'ai_media_learning_state'
                    LIMIT 1
                    """,
                    (self.settings.db_schema,),
                )
                if await cur.fetchone():
                    return
                await cur.execute(
                    """
                    CREATE TABLE ai_media_learning_state (
                      media_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
                      user_id BIGINT UNSIGNED NOT NULL,
                      last_scanned_at TIMESTAMP NULL DEFAULT NULL,
                      last_scan_status VARCHAR(30) NOT NULL DEFAULT 'pending',
                      last_scan_source VARCHAR(40) NULL,
                      last_scan_confidence FLOAT NULL,
                      last_scan_title VARCHAR(160) NULL,
                      last_scan_error VARCHAR(300) NULL,
                      last_learned_at TIMESTAMP NULL DEFAULT NULL,
                      last_autofill_at TIMESTAMP NULL DEFAULT NULL,
                      updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                      KEY idx_ai_media_learning_status (last_scan_status, last_scanned_at),
                      KEY idx_ai_media_learning_user (user_id, updated_at),
                      CONSTRAINT fk_ai_media_learning_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE,
                      CONSTRAINT fk_ai_media_learning_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
                    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
                    """
                )

    async def seed_default_categories(self) -> None:
        defaults = [
            ("Wallpapers", "image"),
            ("Profile Pictures", "image"),
            ("Memes", "mixed"),
            ("GIFs", "image"),
            ("Videos", "video"),
            ("Final Fantasy", "image"),
            ("Reaction Images", "image"),
            ("Phone Backgrounds", "image"),
            ("Desktop Backgrounds", "image"),
        ]
        for name, kind in defaults:
            await self.create_category(name, kind, None)

    async def register_user(
        self,
        username: str,
        password: str,
        display_name: str | None = None,
        email: str | None = None,
        email_verification_token: str | None = None,
    ) -> dict[str, Any]:
        username = normalize_username(username)
        email = normalize_email(email)
        if len(password or "") < 8:
            raise ValueError("Password must be at least 8 characters.")
        display_name = (display_name or username).strip()[:80] or username
        token_hash = verification_token_hash(email_verification_token) if email and email_verification_token else None
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    INSERT INTO users (username, display_name, password_hash, email, email_verification_token_hash, email_verification_sent_at)
                    VALUES (%s, %s, %s, %s, %s, CASE WHEN %s IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END)
                    """,
                    (username, display_name, hash_password(password), email, token_hash, token_hash),
                )
                return await self.get_user(cur.lastrowid)

    async def verify_email_by_token(self, token: str) -> dict[str, Any] | None:
        token_hash = verification_token_hash(token)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await conn.begin()
                try:
                    # SELECT … FOR UPDATE prevents a double-verification race.
                    await cur.execute(
                        "SELECT id FROM users WHERE email_verification_token_hash=%s LIMIT 1 FOR UPDATE",
                        (token_hash,),
                    )
                    row = await cur.fetchone()
                    if not row:
                        await conn.rollback()
                        return None
                    await cur.execute(
                        """
                        UPDATE users
                        SET email_verified_at=CURRENT_TIMESTAMP, email_verification_token_hash=NULL
                        WHERE id=%s AND email_verification_token_hash=%s
                        """,
                        (row["id"], token_hash),
                    )
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise
                return await self.get_user(row["id"])

    async def issue_email_verification_token(self, user_id: int, token: str) -> dict[str, Any] | None:
        token_hash = verification_token_hash(token)
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    UPDATE users
                    SET email_verification_token_hash=%s, email_verification_sent_at=CURRENT_TIMESTAMP
                    WHERE id=%s AND email IS NOT NULL AND email_verified_at IS NULL
                    """,
                    (token_hash, user_id),
                )
        return await self.get_user(user_id)

    async def update_user_email(self, user_id: int, email: str | None) -> dict[str, Any] | None:
        normalized = normalize_email(email)
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    UPDATE users
                    SET email=%s, email_verified_at=NULL, email_verification_token_hash=NULL, email_verification_sent_at=NULL
                    WHERE id=%s
                    """,
                    (normalized, user_id),
                )
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)

    async def verify_email_code(self, user_id: int, code: str) -> dict[str, Any] | None:
        token_hash = verification_token_hash(code)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT id FROM users
                    WHERE id=%s AND email IS NOT NULL AND email_verification_token_hash=%s
                    LIMIT 1
                    """,
                    (user_id, token_hash),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                await cur.execute(
                    """
                    UPDATE users
                    SET email_verified_at=CURRENT_TIMESTAMP, email_verification_token_hash=NULL
                    WHERE id=%s
                    """,
                    (user_id,),
                )
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)

    async def authenticate_user(self, username: str, password: str) -> dict[str, Any] | None:
        username = normalize_username(username)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT * FROM users WHERE username=%s", (username,))
                user = await cur.fetchone()
                if not user or not verify_password(password, user["password_hash"]):
                    return None
                await cur.execute("UPDATE users SET last_login_at=CURRENT_TIMESTAMP, last_seen_at=CURRENT_TIMESTAMP WHERE id=%s", (user["id"],))
                return await self.get_user(user["id"])

    async def touch_user_seen(self, user_id: int, min_interval_seconds: int = 30) -> None:
        min_interval = max(0, int(min_interval_seconds or 0))
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if min_interval:
                    await cur.execute(
                        """
                        UPDATE users
                        SET last_seen_at=CURRENT_TIMESTAMP
                        WHERE id=%s
                          AND (last_seen_at IS NULL OR last_seen_at < TIMESTAMPADD(SECOND, -%s, CURRENT_TIMESTAMP))
                        """,
                        (user_id, min_interval),
                    )
                else:
                    await cur.execute("UPDATE users SET last_seen_at=CURRENT_TIMESTAMP WHERE id=%s", (user_id,))

    def _invalidate_user_cache(self, user_id: int) -> None:
        self._user_cache.pop(user_id, None)

    async def get_user(self, user_id: int, *, bypass_cache: bool = False) -> dict[str, Any] | None:
        now = _time.monotonic()
        if not bypass_cache:
            cached = self._user_cache.get(user_id)
            if cached and cached[0] > now:
                return dict(cached[1]) if cached[1] is not None else None

        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT id, username, display_name, bio, website_url, location_label, profile_headline,
                           featured_tags, profile_color,
                           email, email_verified_at, avatar_path, avatar_file_id, avatar_mime_type, avatar_original_filename, public_profile,
                           show_liked_count, show_collections, show_recent_uploads, show_friends,
                           birthdate, age_verified_at, adult_content_consent,
                           user_settings, created_at, updated_at, last_seen_at
                    FROM users WHERE id=%s
                    """,
                    (user_id,),
                )
                user = await cur.fetchone()
                result = self._decode_user(user) if user else None
        self._user_cache[user_id] = (now + _USER_CACHE_TTL, dict(result) if result is not None else None)
        return result

    async def update_user_profile(self, user_id: int, payload: dict[str, Any]) -> dict[str, Any]:
        fields = {
            "display_name": self._clean_text(payload.get("display_name"), 80, required=True),
            "bio": self._clean_text(payload.get("bio"), 500),
            "profile_quote": self._clean_text(payload.get("profile_quote"), 200),
            "website_url": self._clean_text(payload.get("website_url"), 300),
            "location_label": self._clean_text(payload.get("location_label"), 80),
            "profile_headline": self._clean_text(payload.get("profile_headline"), 120),
            "featured_tags": json.dumps(self._clean_tags(payload.get("featured_tags") or [])),
            "profile_color": self._clean_color(payload.get("profile_color")),
            "public_profile": 1 if payload.get("public_profile", True) else 0,
            "show_liked_count": 1 if payload.get("show_liked_count", True) else 0,
            "show_collections": 1 if payload.get("show_collections", True) else 0,
            "show_recent_uploads": 1 if payload.get("show_recent_uploads", True) else 0,
            "show_friends": 1 if payload.get("show_friends", True) else 0,
        }
        if fields["website_url"] and not fields["website_url"].startswith(("http://", "https://")):
            raise ValueError("Website must start with http:// or https://.")
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    UPDATE users
                    SET display_name=%s, bio=%s, profile_quote=%s, website_url=%s, location_label=%s,
                        profile_headline=%s, featured_tags=%s, profile_color=%s,
                        public_profile=%s, show_liked_count=%s, show_collections=%s,
                        show_recent_uploads=%s, show_friends=%s
                    WHERE id=%s
                    """,
                    (
                        fields["display_name"],
                        fields["bio"],
                        fields["profile_quote"],
                        fields["website_url"],
                        fields["location_label"],
                        fields["profile_headline"],
                        fields["featured_tags"],
                        fields["profile_color"],
                        fields["public_profile"],
                        fields["show_liked_count"],
                        fields["show_collections"],
                        fields["show_recent_uploads"],
                        fields["show_friends"],
                        user_id,
                    ),
                )
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)

    async def verify_user_age(self, user_id: int, birthdate: date) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    UPDATE users
                    SET birthdate=%s, age_verified_at=CURRENT_TIMESTAMP, adult_content_consent=1
                    WHERE id=%s
                    """,
                    (birthdate.isoformat(), user_id),
                )
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)

    async def update_user_settings(self, user_id: int, payload: dict[str, Any]) -> dict[str, Any]:
        user = await self.get_user(user_id)
        if not user:
            raise ValueError("Account not found.")
        settings = dict(DEFAULT_USER_SETTINGS)
        settings.update(user.get("user_settings") or {})
        allowed_choices = {
            "theme_mode": {"system", "dark", "light"},
            "grid_density": {"compact", "comfortable", "wide"},
            "default_sort": {"new", "popular", "downloads", "views", "old"},
            "profile_layout": {"spotlight", "magazine", "stack", "split", "mosaic", "timeline"},
            "profile_banner_style": {"gradient", "mesh", "frame", "aurora", "spotlight", "poster"},
            "profile_card_style": {"glass", "solid", "outline", "elevated", "soft", "edge"},
            "profile_stat_style": {"tiles", "ribbon", "minimal"},
            "profile_content_focus": {"balanced", "gallery", "collections", "social"},
            "profile_hero_alignment": {"split", "start", "center"},
            "profile_avatar_shape": {"circle", "rounded", "square"},
            "profile_media_shape": {"soft", "crisp", "poster"},
            "profile_surface_style": {"standard", "quiet", "contrast", "editorial"},
            "profile_social_layout": {"rail", "cards", "compact"},
            "profile_featured_panel": {"uploads", "collections", "friends"},
            "profile_name_style": {"display", "gradient", "glow", "outline"},
            "profile_header_style": {"solid", "glass", "blur", "transparent", "gradient"},
            "card_hover_effect": {"lift", "zoom", "reveal", "glow", "none"},
            "card_aspect_ratio": {"16:9", "4:3", "1:1", "3:4", "free"},
            "media_border_style": {"none", "soft", "crisp", "glow", "neon"},
            "gallery_font": {"system", "serif", "mono", "rounded"},
            "card_info_display": {"overlay", "below", "hidden", "minimal"},
            "column_gap": {"tight", "normal", "wide", "none"},
        }
        color_fields = {"accent_color", "accent_secondary", "gallery_bg_color", "profile_bg_color"}
        url_fields = {"profile_backdrop_image_url"}
        for key in DEFAULT_USER_SETTINGS:
            if key not in payload:
                continue
            value = payload[key]
            if key in allowed_choices:
                if value not in allowed_choices[key]:
                    raise ValueError(f"Invalid {key}.")
                settings[key] = value
            elif key in color_fields:
                settings[key] = self._clean_color(value) if value else ""
            elif key == "items_per_page":
                settings[key] = max(12, min(int(value or 24), 60))
            elif key in url_fields:
                settings[key] = self._clean_optional_url(value, max_length=500) or ""
            elif key == "profile_backdrop_strength":
                try:
                    settings[key] = max(0.0, min(float(value if value is not None else 0.18), 0.55))
                except (TypeError, ValueError):
                    raise ValueError("Backdrop strength must be a number.") from None
            elif key == "watermark_text":
                text = str(value or "").strip()[:40]
                settings[key] = text
            else:
                settings[key] = bool(value)
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("UPDATE users SET user_settings=%s WHERE id=%s", (json.dumps(settings), user_id))
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)

    async def save_avatar_file(self, user_id: int, *, content: bytes, sha256: str, mime_type: str, original_filename: str) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    INSERT INTO user_avatar_files (user_id, sha256, mime_type, original_filename, file_size, content)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id), created_at=CURRENT_TIMESTAMP
                    """,
                    (user_id, sha256, mime_type[:120], original_filename[:255], len(content), content),
                )
                file_id = cur.lastrowid
                await cur.execute(
                    """
                    UPDATE users
                    SET avatar_file_id=%s, avatar_path=%s, avatar_mime_type=%s, avatar_original_filename=%s
                    WHERE id=%s
                    """,
                    (file_id, f"avatar-db://{file_id}", mime_type[:120], original_filename[:255], user_id),
                )
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)

    async def update_user_avatar(self, user_id: int, storage_path: str, mime_type: str, original_filename: str) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    UPDATE users
                    SET avatar_path=%s, avatar_mime_type=%s, avatar_original_filename=%s
                    WHERE id=%s
                    """,
                    (storage_path, mime_type[:120], original_filename[:255], user_id),
                )
        self._invalidate_user_cache(user_id)
        return await self.get_user(user_id)


    async def create_category(self, name: str, media_kind: str, user_id: int | None) -> dict[str, Any]:
        name = " ".join(str(name or "").strip().split())[:80]
        if not name:
            raise ValueError("Category name is required.")
        if media_kind not in MEDIA_KINDS:
            raise ValueError("Category type must be image, video, or mixed.")
        base_slug = slugify(name)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT * FROM categories WHERE name=%s OR slug=%s", (name, base_slug))
                existing = await cur.fetchone()
                if existing:
                    return existing
                await cur.execute(
                    "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, %s)",
                    (name, base_slug, media_kind, user_id),
                )
                await cur.execute("SELECT * FROM categories WHERE id=%s", (cur.lastrowid,))
                return await cur.fetchone()

    async def create_subcategory(self, category_id: int, name: str, user_id: int | None) -> dict[str, Any]:
        name = clean_subcategory_name(name)
        if not name:
            raise ValueError("Subcategory name is required.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM categories WHERE id=%s", (category_id,))
                if not await cur.fetchone():
                    raise ValueError("Choose a valid category before creating a subcategory.")
                slug = slugify(name)
                await cur.execute(
                    "SELECT * FROM subcategories WHERE category_id=%s AND (name=%s OR slug=%s) LIMIT 1",
                    (category_id, name, slug),
                )
                existing = await cur.fetchone()
                if existing:
                    return existing
                await cur.execute(
                    """
                    INSERT INTO subcategories (category_id, name, slug, created_by)
                    VALUES (%s, %s, %s, %s)
                    """,
                    (category_id, name, slug, user_id),
                )
                await cur.execute("SELECT * FROM subcategories WHERE id=%s", (cur.lastrowid,))
                return await cur.fetchone()

    async def resolve_subcategory_ids(
        self,
        *,
        category_id: int,
        subcategory_ids: list[int] | None = None,
        subcategory_names: list[str] | None = None,
        user_id: int | None = None,
    ) -> list[int]:
        normalized_category_id = int(category_id or 0)
        if normalized_category_id <= 0:
            raise ValueError("Choose a valid category.")
        resolved_ids = normalize_subcategory_ids(subcategory_ids)
        pending_names = normalize_subcategory_names(subcategory_names)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM categories WHERE id=%s", (normalized_category_id,))
                if not await cur.fetchone():
                    raise ValueError("Category does not exist.")
                validated_ids: list[int] = []
                for subcategory_id in resolved_ids:
                    await cur.execute(
                        "SELECT id FROM subcategories WHERE id=%s AND category_id=%s",
                        (subcategory_id, normalized_category_id),
                    )
                    if not await cur.fetchone():
                        raise ValueError("Subcategory does not belong to that category.")
                    validated_ids.append(int(subcategory_id))
        resolved_ids = validated_ids
        if pending_names:
            for name in pending_names:
                subcategory = await self.create_subcategory(normalized_category_id, name, user_id)
                candidate_id = int(subcategory["id"])
                if candidate_id not in resolved_ids:
                    resolved_ids.append(candidate_id)
                if len(resolved_ids) >= MAX_MEDIA_SUBCATEGORIES:
                    break
        return resolved_ids[:MAX_MEDIA_SUBCATEGORIES]

    async def resolve_category_ids(
        self,
        *,
        category_id: int,
        subcategory_id: int | None = None,
        subcategory_name: str | None = None,
        user_id: int | None = None,
    ) -> tuple[int, int | None]:
        normalized_category_id = int(category_id or 0)
        if normalized_category_id <= 0:
            raise ValueError("Choose a valid category.")
        subcategory_ids = await self.resolve_subcategory_ids(
            category_id=normalized_category_id,
            subcategory_ids=[subcategory_id] if subcategory_id else [],
            subcategory_names=[subcategory_name] if subcategory_name else [],
            user_id=user_id,
        )
        return normalized_category_id, (subcategory_ids[0] if subcategory_ids else None)

    async def set_media_subcategories(self, media_id: int, subcategory_ids: list[int] | None) -> None:
        normalized_ids = normalize_subcategory_ids(subcategory_ids)
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await conn.begin()
                try:
                    await self._write_media_subcategories(cur, int(media_id), normalized_ids)
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise

    async def _write_media_subcategories(self, cur: aiomysql.Cursor, media_id: int, subcategory_ids: list[int] | None) -> None:
        normalized_ids = normalize_subcategory_ids(subcategory_ids)
        primary_subcategory_id = normalized_ids[0] if normalized_ids else None
        await cur.execute("UPDATE media_items SET subcategory_id=%s WHERE id=%s", (primary_subcategory_id, int(media_id)))
        await cur.execute("DELETE FROM media_item_subcategories WHERE media_id=%s", (int(media_id),))
        for position, subcategory_id in enumerate(normalized_ids, 1):
            await cur.execute(
                """
                INSERT INTO media_item_subcategories (media_id, subcategory_id, position)
                VALUES (%s, %s, %s)
                """,
                (int(media_id), int(subcategory_id), position),
            )

    async def list_categories(self) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT c.*, COUNT(m.id) AS media_count
                    FROM categories c
                    LEFT JOIN media_items m ON m.category_id = c.id AND m.deleted_at IS NULL
                    GROUP BY c.id
                    ORDER BY c.name
                    """
                )
                categories = list(await cur.fetchall())
                await cur.execute(
                    """
                    SELECT s.*, COUNT(m.id) AS media_count
                    FROM subcategories s
                    LEFT JOIN media_item_subcategories ms ON ms.subcategory_id = s.id
                    LEFT JOIN media_items m ON m.id = ms.media_id AND m.deleted_at IS NULL
                    GROUP BY s.id
                    ORDER BY s.name
                    """
                )
                subcategories = list(await cur.fetchall())
        grouped: dict[int, list[dict[str, Any]]] = {}
        for row in subcategories:
            grouped.setdefault(int(row["category_id"]), []).append(row)
        for row in categories:
            row["subcategories"] = grouped.get(int(row["id"]), [])
        return categories

    async def _subcategory_map_for_media_ids(self, media_ids: list[int]) -> dict[int, list[dict[str, Any]]]:
        normalized_ids = [int(media_id) for media_id in media_ids if int(media_id or 0) > 0]
        if not normalized_ids:
            return {}
        placeholders = ", ".join(["%s"] * len(normalized_ids))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT ms.media_id, ms.position, s.id, s.category_id, s.name, s.slug
                    FROM media_item_subcategories ms
                    JOIN subcategories s ON s.id = ms.subcategory_id
                    WHERE ms.media_id IN ({placeholders})
                    ORDER BY ms.media_id ASC, ms.position ASC
                    """,
                    tuple(normalized_ids),
                )
                rows = await cur.fetchall()
        grouped: dict[int, list[dict[str, Any]]] = {}
        for row in rows:
            media_id = int(row["media_id"])
            grouped.setdefault(media_id, []).append(
                {
                    "id": int(row["id"]),
                    "category_id": int(row["category_id"]),
                    "name": row["name"],
                    "slug": row["slug"],
                    "position": int(row["position"]),
                }
            )
        return grouped

    async def _attach_media_subcategories(self, items: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not items:
            return items
        subcategory_map = await self._subcategory_map_for_media_ids([int(item.get("id") or 0) for item in items])
        for item in items:
            media_id = int(item.get("id") or 0)
            subcategories = list(subcategory_map.get(media_id, []))
            item["subcategories"] = subcategories
            item["subcategory_ids"] = [int(subcategory["id"]) for subcategory in subcategories]
            item["subcategory_names"] = [str(subcategory["name"]) for subcategory in subcategories]
            if subcategories:
                primary = subcategories[0]
                item["subcategory_id"] = int(primary["id"])
                item["subcategory_name"] = primary["name"]
                item["subcategory_slug"] = primary["slug"]
            else:
                item["subcategory_ids"] = []
                item["subcategory_names"] = []
        return items

    async def save_media_file(self, *, user_id: int, content: bytes, sha256: str, mime_type: str, original_filename: str, media_kind: str, file_size: int | None = None) -> dict[str, Any]:
        # Large BLOB writes are serialized and chunked so uploads do not depend on
        # one huge max_allowed_packet-sized INSERT.
        async with self._blob_lock:
            async with self.pool.acquire() as conn:
                await conn.ping(reconnect=True)
                async with conn.cursor(aiomysql.DictCursor) as cur:
                    await conn.begin()
                    media_file_id = 0
                    await cur.execute(
                        "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE sha256=%s",
                        (sha256,),
                    )
                    existing = await cur.fetchone()
                    if existing:
                        await conn.rollback()
                        return dict(existing, duplicate=True)
                    try:
                        await cur.execute(
                            """
                            INSERT INTO media_files (sha256, mime_type, original_filename, media_kind, file_size, content, created_by)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)
                            """,
                            (sha256, mime_type[:120], original_filename[:255], media_kind, file_size or len(content), b"", user_id),
                        )
                        media_file_id = int(cur.lastrowid)
                        for chunk_index, offset in enumerate(range(0, len(content), self.media_chunk_bytes)):
                            await cur.execute(
                                """
                                INSERT INTO media_file_chunks (file_id, chunk_index, content)
                                VALUES (%s, %s, %s)
                                """,
                                (media_file_id, chunk_index, content[offset:offset + self.media_chunk_bytes]),
                            )
                        await cur.execute(
                            "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE id=%s",
                            (media_file_id,),
                        )
                        row = await cur.fetchone()
                        await conn.commit()
                        return dict(row, duplicate=False)
                    except Exception:
                        await conn.rollback()
                        if media_file_id:
                            try:
                                await cur.execute("DELETE FROM media_files WHERE id=%s", (media_file_id,))
                            except Exception as cleanup_exc:
                                log.warning("Failed to cleanup incomplete media_file row %s after failed chunk write: %s", media_file_id, cleanup_exc)
                        raise

    async def get_media_file_info(self, media_id: int) -> dict[str, Any] | None:
        """Return DB-backed file metadata without loading the BLOB into Python memory."""
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size,
                           OCTET_LENGTH(f.content) AS inline_size
                    FROM media_files f
                    JOIN media_items m ON m.media_file_id=f.id
                    WHERE m.id=%s
                    """,
                    (media_id,),
                )
                row = await cur.fetchone()
                return dict(row) if row else None

    async def get_media_file_prefix(self, media_id: int, limit: int = 1048576) -> bytes:
        """Read only the first bytes needed for cheap dimension sniffing."""
        return (await self.get_media_file_prefixes([int(media_id)], limit=limit)).get(int(media_id), b"")

    async def get_media_file_prefixes(self, media_ids: list[int], limit: int = 1048576) -> dict[int, bytes]:
        """Read cheap file prefixes for many media rows without one query per item."""
        normalized_ids: list[int] = []
        seen: set[int] = set()
        for media_id in media_ids or []:
            normalized_id = int(media_id or 0)
            if normalized_id <= 0 or normalized_id in seen:
                continue
            seen.add(normalized_id)
            normalized_ids.append(normalized_id)
        if not normalized_ids:
            return {}
        max_bytes = max(4096, min(int(limit or 1048576), 2 * 1024 * 1024))
        prefixes: dict[int, bytes] = {}
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                for offset in range(0, len(normalized_ids), 120):
                    batch = normalized_ids[offset:offset + 120]
                    placeholders = ", ".join(["%s"] * len(batch))
                    await cur.execute(
                        f"""
                        SELECT m.id AS media_id, f.id AS file_id, OCTET_LENGTH(f.content) AS inline_size,
                               SUBSTRING(f.content, 1, %s) AS content
                        FROM media_items m
                        JOIN media_files f ON m.media_file_id=f.id
                        WHERE m.id IN ({placeholders})
                        """,
                        (max_bytes, *batch),
                    )
                    chunk_file_map: dict[int, int] = {}
                    for row in await cur.fetchall():
                        media_id = int(row.get("media_id") or 0)
                        file_id = int(row.get("file_id") or 0)
                        if int(row.get("inline_size") or 0) > 0:
                            prefixes[media_id] = bytes(row.get("content") or b"")
                        elif file_id > 0:
                            chunk_file_map[file_id] = media_id
                    if not chunk_file_map:
                        continue
                    file_ids = list(chunk_file_map)
                    file_placeholders = ", ".join(["%s"] * len(file_ids))
                    await cur.execute(
                        f"""
                        SELECT c.file_id, SUBSTRING(c.content, 1, %s) AS content
                        FROM media_file_chunks c
                        JOIN (
                            SELECT file_id, MIN(chunk_index) AS chunk_index
                            FROM media_file_chunks
                            WHERE file_id IN ({file_placeholders})
                            GROUP BY file_id
                        ) first_chunk
                          ON first_chunk.file_id=c.file_id AND first_chunk.chunk_index=c.chunk_index
                        """,
                        (max_bytes, *file_ids),
                    )
                    for row in await cur.fetchall():
                        media_id = chunk_file_map.get(int(row.get("file_id") or 0))
                        if media_id:
                            prefixes[media_id] = bytes(row.get("content") or b"")
        return prefixes

    async def stream_media_file_content(self, file_id: int, start: int | None = None, end: int | None = None):
        """Yield DB-backed media content in chunks for StreamingResponse."""
        start = max(0, int(start or 0))
        end = int(end) if end is not None else None
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                # Use SUBSTRING to avoid loading the full BLOB when only a range is needed.
                if end is not None:
                    length = end - start + 1
                    await cur.execute(
                        "SELECT SUBSTRING(content, %s, %s) AS content, OCTET_LENGTH(content) AS inline_size FROM media_files WHERE id=%s",
                        (start + 1, length, file_id),  # MySQL SUBSTRING is 1-indexed
                    )
                else:
                    await cur.execute(
                        "SELECT SUBSTRING(content, %s) AS content, OCTET_LENGTH(content) AS inline_size FROM media_files WHERE id=%s",
                        (start + 1, file_id),
                    )
                row = await cur.fetchone() or {}
                inline_size = int(row.get("inline_size") or 0)
                inline = row.get("content")
                if inline_size > 0:
                    if inline:
                        yield bytes(inline)
                    return
                await cur.execute(
                    "SELECT content FROM media_file_chunks WHERE file_id=%s ORDER BY chunk_index ASC",
                    (file_id,),
                )
                offset = 0
                while True:
                    rows = await cur.fetchmany(16)
                    if not rows:
                        break
                    for chunk in rows:
                        payload = chunk.get("content") or b""
                        if payload:
                            payload = bytes(payload)
                            chunk_start = offset
                            chunk_end = offset + len(payload) - 1
                            offset += len(payload)
                            if chunk_end < start:
                                continue
                            if end is not None and chunk_start > end:
                                return
                            slice_start = max(0, start - chunk_start)
                            slice_end = len(payload) if end is None else min(len(payload), end - chunk_start + 1)
                            if slice_start < slice_end:
                                yield payload[slice_start:slice_end]

    async def get_media_file(self, media_id: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size, f.content
                    FROM media_files f
                    JOIN media_items m ON m.media_file_id=f.id
                    WHERE m.id=%s
                    """,
                    (media_id,),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                content = row.get("content") or b""
                if len(content) == int(row.get("file_size") or 0):
                    return row
                await cur.execute(
                    """
                    SELECT content
                    FROM media_file_chunks
                    WHERE file_id=%s
                    ORDER BY chunk_index ASC
                    """,
                    (row["id"],),
                )
                chunks = await cur.fetchall()
                if chunks:
                    row["content"] = b"".join(chunk["content"] for chunk in chunks)
                return row

    async def get_avatar_file(self, user_id: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.file_size, f.content
                    FROM user_avatar_files f
                    JOIN users u ON u.avatar_file_id=f.id
                    WHERE u.id=%s
                    """,
                    (user_id,),
                )
                return await cur.fetchone()

    async def add_media(self, item: dict[str, Any]) -> dict[str, Any]:
        tags_json = json.dumps(item.get("tags") or [])
        subcategory_ids = normalize_subcategory_ids(item.get("subcategory_ids"))
        primary_subcategory_id = subcategory_ids[0] if subcategory_ids else item.get("subcategory_id")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await conn.begin()
                try:
                    await cur.execute(
                        """
                        INSERT INTO media_items
                          (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename,
                           storage_path, file_size, media_file_id, content_sha256, visibility, comments_enabled, downloads_enabled, pinned_at,
                           is_adult, adult_marked_by_user, adult_marked_by_ai,
                           moderation_status, moderation_score, moderation_reason, moderated_at)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE NULL END, %s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP)
                        """,
                        (
                            item["user_id"], item["category_id"], primary_subcategory_id, item["title"], item.get("description"), tags_json,
                            item["media_kind"], item["mime_type"], item["original_filename"],
                            item.get("storage_path") or f"db://media/{item.get('media_file_id')}", item["file_size"],
                            item.get("media_file_id"), item.get("content_sha256"),
                            item.get("visibility") if item.get("visibility") in {"public", "unlisted", "private"} else "public",
                            1 if item.get("comments_enabled", True) else 0,
                            1 if item.get("downloads_enabled", True) else 0,
                            1 if item.get("pinned") else 0,
                            1 if item.get("is_adult") else 0,
                            1 if item.get("adult_marked_by_user") else 0,
                            1 if item.get("adult_marked_by_ai") else 0,
                            item.get("moderation_status") or "clear",
                            float(item.get("moderation_score") or 0),
                            item.get("moderation_reason"),
                        ),
                    )
                    media_id = int(cur.lastrowid)
                    await self._write_media_subcategories(cur, media_id, subcategory_ids or ([primary_subcategory_id] if primary_subcategory_id else []))
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise
                return await self.get_media(media_id, item["user_id"])

    @staticmethod
    def _escape_like(value: str) -> str:
        """Escape LIKE wildcard characters so user input is treated as a literal string."""
        return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    async def list_media(
        self,
        *,
        viewer_id: int | None,
        media_kind: str | None = None,
        category_id: int | None = None,
        subcategory_id: int | None = None,
        query: str | None = None,
        uploader: str | None = None,
        min_size: int | None = None,
        max_size: int | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        adult: str | None = None,
        sort: str = "new",
        limit: int = 60,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        viewer = viewer_id or 0
        clauses = ["m.deleted_at IS NULL", "(m.visibility='public' OR m.user_id=%s)"]
        params: list[Any] = [viewer]
        if media_kind in {"image", "video"}:
            clauses.append("m.media_kind=%s")
            params.append(media_kind)
        if category_id:
            clauses.append("m.category_id=%s")
            params.append(category_id)
        if subcategory_id:
            clauses.append("EXISTS (SELECT 1 FROM media_item_subcategories ms WHERE ms.media_id=m.id AND ms.subcategory_id=%s)")
            params.append(subcategory_id)
        if query:
            clauses.append("(m.title LIKE %s ESCAPE '\\\\' OR m.description LIKE %s ESCAPE '\\\\' OR m.tags LIKE %s ESCAPE '\\\\')")
            needle = f"%{self._escape_like(query)}%"
            params.extend([needle, needle, needle])
        if uploader:
            clauses.append("(u.username LIKE %s ESCAPE '\\\\' OR u.display_name LIKE %s ESCAPE '\\\\')")
            needle = f"%{self._escape_like(uploader)}%"
            params.extend([needle, needle])
        if min_size is not None:
            clauses.append("m.file_size >= %s")
            params.append(max(0, int(min_size)))
        if max_size is not None:
            clauses.append("m.file_size <= %s")
            params.append(max(0, int(max_size)))
        if date_from:
            clauses.append("DATE(m.created_at) >= %s")
            params.append(date_from)
        if date_to:
            clauses.append("DATE(m.created_at) <= %s")
            params.append(date_to)
        if adult == "only":
            clauses.append("m.is_adult=1")
        elif adult == "hide":
            clauses.append("m.is_adult=0")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        order = {
            "popular": "m.pinned_at DESC, like_count DESC, m.views DESC, m.created_at DESC",
            "downloads": "m.pinned_at DESC, m.downloads DESC, m.created_at DESC",
            "views": "m.pinned_at DESC, m.views DESC, m.created_at DESC",
            "old": "m.created_at ASC",
        }.get(sort, "m.pinned_at DESC, m.created_at DESC")
        sql_params = [viewer, viewer, viewer, viewer, viewer, viewer, *params, max(1, min(limit, 100)), max(0, offset)]
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    {where}
                    GROUP BY m.id
                    ORDER BY {order}
                    LIMIT %s OFFSET %s
                    """,
                    tuple(sql_params),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def list_user_media(self, user_id: int, limit: int = 100, include_deleted: bool = False) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.user_id=%s AND (%s=1 OR m.deleted_at IS NULL)
                    GROUP BY m.id
                    ORDER BY m.created_at DESC
                    LIMIT %s
                    """,
                    (user_id, user_id, user_id, 1 if include_deleted else 0, max(1, min(limit, 200))),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def random_media(self, viewer_id: int | None = None) -> dict[str, Any] | None:
        # Use ORDER BY RAND() with a small LIMIT to avoid loading 100 rows just to pick one.
        viewer = viewer_id or 0
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.deleted_at IS NULL AND m.visibility='public'
                    GROUP BY m.id
                    ORDER BY RAND()
                    LIMIT 1
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                item = self._decode_media(row)
        rows = await self._attach_media_subcategories([item])
        return rows[0] if rows else None

    async def list_public_background_candidates(self, limit: int = 600) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.id, m.user_id, m.title, m.storage_path, m.mime_type, m.original_filename,
                           m.media_kind, m.file_size, m.is_adult, m.visibility, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           u.profile_color, u.public_profile
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    WHERE m.deleted_at IS NULL
                      AND m.visibility='public'
                      AND m.media_kind='image'
                      AND m.is_adult=0
                    ORDER BY COALESCE(m.pinned_at, m.created_at) DESC, m.created_at DESC
                    LIMIT %s
                    """,
                    (max(1, min(limit, 1200)),),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def tag_cloud(self, limit: int = 30) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT tags FROM media_items WHERE tags IS NOT NULL AND deleted_at IS NULL AND visibility='public' ORDER BY created_at DESC LIMIT 500")
                rows = await cur.fetchall()
        counts: dict[str, int] = {}
        for row in rows:
            tags = row.get("tags")
            if isinstance(tags, str):
                try:
                    tags = json.loads(tags)
                except json.JSONDecodeError:
                    tags = []
            for tag in tags or []:
                normalized = str(tag).strip()[:32]
                if normalized:
                    counts[normalized] = counts.get(normalized, 0) + 1
        return [
            {"tag": tag, "count": count}
            for tag, count in sorted(counts.items(), key=lambda item: (-item[1], item[0].lower()))[:limit]
        ]

    async def get_media(self, media_id: int, viewer_id: int | None = None) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.id=%s
                    GROUP BY m.id
                    """,
                    (viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, media_id),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                item = self._decode_media(row)
        rows = await self._attach_media_subcategories([item])
        return rows[0] if rows else None

    async def increment_counter(self, media_id: int, column: str) -> None:
        if column not in {"views", "downloads"}:
            raise ValueError("Invalid counter")
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(f"UPDATE media_items SET {column}={column}+1 WHERE id=%s", (media_id,))

    async def set_like(self, media_id: int, user_id: int, liked: bool) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if liked:
                    await cur.execute("INSERT IGNORE INTO media_likes (user_id, media_id) VALUES (%s, %s)", (user_id, media_id))
                else:
                    await cur.execute("DELETE FROM media_likes WHERE user_id=%s AND media_id=%s", (user_id, media_id))
        return await self.get_media(media_id, user_id)

    async def add_comment(self, media_id: int, user_id: int, body: str) -> dict[str, Any]:
        body = " ".join(str(body or "").strip().split())[:500]
        if not body:
            raise ValueError("Comment cannot be empty.")
        media = await self.get_media(media_id, user_id)
        if not media or media.get("deleted_at"):
            raise ValueError("Media not found.")
        if not media.get("comments_enabled", True) and int(media.get("user_id")) != int(user_id):
            raise PermissionError("Comments are disabled for this post.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "INSERT INTO media_comments (media_id, user_id, body) VALUES (%s, %s, %s)",
                    (media_id, user_id, body),
                )
                await cur.execute(
                    """
                    SELECT cm.*, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS user_avatar_path
                    FROM media_comments cm JOIN users u ON u.id = cm.user_id
                    WHERE cm.id=%s
                    """,
                    (cur.lastrowid,),
                )
                return await cur.fetchone()

    async def list_comments(self, media_id: int, limit: int = 80, offset: int = 0) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 80), 200))
        offset = max(0, int(offset or 0))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT cm.*, u.username,
                           CASE WHEN u.public_profile=1 THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 THEN u.avatar_path ELSE NULL END AS user_avatar_path
                    FROM media_comments cm JOIN users u ON u.id = cm.user_id
                    WHERE cm.media_id=%s
                    ORDER BY cm.created_at ASC
                    LIMIT %s OFFSET %s
                    """,
                    (media_id, limit, offset),
                )
                return list(await cur.fetchall())


    async def update_media(self, media_id: int, user_id: int, payload: dict[str, Any]) -> dict[str, Any] | None:
        title = self._clean_text(payload.get("title"), 160, required=True)
        description = self._clean_text(payload.get("description"), 2000)
        tags = payload.get("tags") or []
        if not isinstance(tags, list):
            tags = []
        clean_tags = []
        for raw in tags:
            tag = re.sub(r"[^A-Za-z0-9_.-]+", "", str(raw).strip())[:32]
            if tag and tag.lower() not in {existing.lower() for existing in clean_tags}:
                clean_tags.append(tag)
        clean_tags = clean_tags[:12]
        category_id = int(payload.get("category_id") or 0)
        subcategory_ids = await self.resolve_subcategory_ids(
            category_id=category_id,
            subcategory_ids=(payload.get("subcategory_ids") or ([payload.get("subcategory_id")] if payload.get("subcategory_id") else [])),
            subcategory_names=(payload.get("subcategory_names") or ([payload.get("subcategory_name")] if payload.get("subcategory_name") else [])),
            user_id=user_id,
        )
        subcategory_id = subcategory_ids[0] if subcategory_ids else None
        visibility = str(payload.get("visibility") or "public").lower()
        if visibility not in {"public", "unlisted", "private"}:
            raise ValueError("Visibility must be public, unlisted, or private.")
        is_adult = 1 if payload.get("is_adult") else 0
        comments_enabled = 1 if payload.get("comments_enabled", True) else 0
        downloads_enabled = 1 if payload.get("downloads_enabled", True) else 0
        pinned = 1 if payload.get("pinned") else 0
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await conn.begin()
                try:
                    await cur.execute("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL FOR UPDATE", (media_id,))
                    row = await cur.fetchone()
                    if not row:
                        await conn.rollback()
                        return None
                    if int(row["user_id"]) != int(user_id):
                        await conn.rollback()
                        raise PermissionError("Only the uploader can edit this post.")
                    await cur.execute(
                        """
                        UPDATE media_items
                        SET title=%s, description=%s, tags=%s, category_id=%s, subcategory_id=%s,
                            visibility=%s, comments_enabled=%s, downloads_enabled=%s,
                            pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END,
                            is_adult=%s, adult_marked_by_user=%s,
                            moderation_status=CASE WHEN %s=1 THEN 'adult' ELSE moderation_status END,
                            moderation_reason=CASE WHEN %s=1 THEN 'Uploader marked this post as 18+.' ELSE moderation_reason END,
                            moderated_at=CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE moderated_at END
                        WHERE id=%s AND user_id=%s
                        """,
                        (title, description, json.dumps(clean_tags), category_id, subcategory_id, visibility, comments_enabled, downloads_enabled,
                         pinned, is_adult, is_adult, is_adult, is_adult, is_adult, media_id, user_id),
                    )
                    await self._write_media_subcategories(cur, media_id, subcategory_ids)
                    await conn.commit()
                except Exception:
                    await conn.rollback()
                    raise
        return await self.get_media(media_id, user_id)

    async def set_media_controls(self, media_id: int, user_id: int, payload: dict[str, Any]) -> dict[str, Any] | None:
        allowed_visibility = {"public", "unlisted", "private"}
        visibility = payload.get("visibility")
        updates = []
        params: list[Any] = []
        if visibility is not None:
            visibility = str(visibility).lower()
            if visibility not in allowed_visibility:
                raise ValueError("Visibility must be public, unlisted, or private.")
            updates.append("visibility=%s")
            params.append(visibility)
        # Enumerate explicitly — never build column names from user-supplied keys.
        for key in ("comments_enabled", "downloads_enabled"):
            if key in payload:
                updates.append(f"{key}=%s")
                params.append(1 if payload.get(key) else 0)
        if "pinned" in payload:
            updates.append("pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END")
            params.append(1 if payload.get("pinned") else 0)
        if not updates:
            return await self.get_media(media_id, user_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", (media_id,))
                row = await cur.fetchone()
                if not row:
                    return None
                if int(row["user_id"]) != int(user_id):
                    raise PermissionError("Only the uploader can change post controls.")
                await cur.execute(f"UPDATE media_items SET {', '.join(updates)} WHERE id=%s AND user_id=%s", (*params, media_id, user_id))
        return await self.get_media(media_id, user_id)

    async def delete_comment(self, comment_id: int, user_id: int) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT cm.id, cm.user_id AS comment_user_id, m.user_id AS media_user_id
                    FROM media_comments cm
                    JOIN media_items m ON m.id=cm.media_id
                    WHERE cm.id=%s
                    """,
                    (comment_id,),
                )
                row = await cur.fetchone()
                if not row:
                    return False
                if int(row["comment_user_id"]) != int(user_id) and int(row["media_user_id"]) != int(user_id):
                    raise PermissionError("Only the commenter or post owner can delete this comment.")
                await cur.execute("DELETE FROM media_comments WHERE id=%s", (comment_id,))
                return True

    async def following_feed(self, user_id: int, limit: int = 60, offset: int = 0) -> list[dict[str, Any]]:
        viewer = int(user_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM user_follows f
                    JOIN media_items m ON m.user_id=f.followed_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id=m.user_id
                    LEFT JOIN media_likes l ON l.media_id=m.id
                    LEFT JOIN media_likes l2 ON l2.media_id=m.id AND l2.user_id=%s
                    LEFT JOIN media_bookmarks b ON b.media_id=m.id AND b.user_id=%s
                    LEFT JOIN media_comments cm ON cm.media_id=m.id
                    WHERE f.follower_id=%s AND m.deleted_at IS NULL AND m.visibility='public'
                    GROUP BY m.id
                    ORDER BY m.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (viewer, viewer, viewer, max(1, min(limit, 100)), max(0, offset)),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def list_liked_media(self, user_id: int, limit: int = 80, offset: int = 0) -> list[dict[str, Any]]:
        viewer = int(user_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l_all.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           1 AS liked_by_me
                    FROM media_likes liked
                    JOIN media_items m ON m.id=liked.media_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id=m.user_id
                    LEFT JOIN media_likes l_all ON l_all.media_id=m.id
                    LEFT JOIN media_bookmarks b ON b.media_id=m.id AND b.user_id=%s
                    LEFT JOIN media_comments cm ON cm.media_id=m.id
                    WHERE liked.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id
                    ORDER BY liked.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (viewer, viewer, viewer, max(1, min(limit, 100)), max(0, offset)),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def list_profile_media(self, user_id: int, viewer_id: int | None = None, limit: int = 24, offset: int = 0) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE m.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id
                    ORDER BY m.pinned_at DESC, m.created_at DESC
                    LIMIT %s OFFSET %s
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer, user_id, viewer, max(1, min(limit, 100)), max(0, offset)),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def list_user_follows(self, user_id: int, mode: str = "followers", viewer_id: int | None = None) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        if mode == "following":
            join_col, user_col = "followed_id", "follower_id"
        else:
            join_col, user_col = "follower_id", "followed_id"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at, f.created_at AS followed_at,
                           MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me
                    FROM user_follows f
                    JOIN users u ON u.id=f.{join_col}
                    LEFT JOIN user_follows mine ON mine.follower_id=%s AND mine.followed_id=u.id
                    WHERE f.{user_col}=%s
                    GROUP BY u.id, f.created_at
                    ORDER BY f.created_at DESC
                    LIMIT 200
                    """,
                    (viewer, viewer, viewer, viewer, user_id),
                )
                return [self._decode_user(row) for row in await cur.fetchall()]

    async def stats(self) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT COUNT(*) AS users FROM users")
                users = (await cur.fetchone())["users"]
                await cur.execute("SELECT COUNT(*) AS categories FROM categories")
                categories = (await cur.fetchone())["categories"]
                await cur.execute("SELECT COUNT(*) AS media, COALESCE(SUM(file_size), 0) AS bytes FROM media_items")
                media = await cur.fetchone()
                await cur.execute("SELECT COUNT(*) AS likes FROM media_likes")
                likes = (await cur.fetchone())["likes"]
                return {"users": users, "categories": categories, "media": media["media"], "bytes": media["bytes"], "likes": likes}

    async def set_bookmark(self, media_id: int, user_id: int, bookmarked: bool) -> dict[str, Any]:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if bookmarked:
                    await cur.execute("INSERT IGNORE INTO media_bookmarks (user_id, media_id) VALUES (%s, %s)", (user_id, media_id))
                else:
                    await cur.execute("DELETE FROM media_bookmarks WHERE user_id=%s AND media_id=%s", (user_id, media_id))
        return await self.get_media(media_id, user_id)

    async def delete_media(self, media_id: int, user_id: int) -> dict[str, Any] | None:
        item = await self.get_media(media_id, user_id)
        if not item or int(item["user_id"]) != int(user_id):
            return None
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute("UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND user_id=%s AND deleted_at IS NULL", (media_id, user_id))
        return item

    async def restore_media(self, media_id: int, user_id: int) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT user_id FROM media_items WHERE id=%s", (media_id,))
                row = await cur.fetchone()
                if not row:
                    return None
                if int(row["user_id"]) != int(user_id):
                    raise PermissionError("Only the uploader can restore this post.")
                await cur.execute("UPDATE media_items SET deleted_at=NULL, visibility='private' WHERE id=%s AND user_id=%s", (media_id, user_id))
        return await self.get_media(media_id, user_id)

    async def list_bookmarks(self, user_id: int, limit: int = 80) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username, u.display_name, u.bio AS user_bio, u.website_url AS user_website_url,
                           u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           1 AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_bookmarks bm
                    JOIN media_items m ON m.id = bm.media_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE bm.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id, bm.created_at
                    ORDER BY bm.created_at DESC
                    LIMIT %s
                    """,
                    (user_id, user_id, user_id, max(1, min(limit, 100))),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def create_collection(self, user_id: int, name: str, description: str | None, is_public: bool) -> dict[str, Any]:
        name = self._clean_text(name, 100, required=True)
        description = self._clean_text(description, 500)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    "INSERT INTO media_collections (user_id, name, description, is_public) VALUES (%s, %s, %s, %s)",
                    (user_id, name, description, 1 if is_public else 0),
                )
                return await self.get_collection(cur.lastrowid, user_id)

    async def list_collections(self, viewer_id: int | None = None, mine: bool = False) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        clauses = []
        params: list[Any] = [viewer, viewer]
        if mine:
            clauses.append("mc.user_id=%s")
            params.append(viewer)
        else:
            clauses.append("(mc.is_public=1 OR mc.user_id=%s)")
            params.append(viewer)
        where = f"WHERE {' AND '.join(clauses)}"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
                           COUNT(mi.id) AS item_count,
                           MAX(mi.storage_path) AS cover_path,
                           MAX(mi.media_kind) AS cover_media_kind,
                           MAX(mi.id) AS cover_media_id,
                           MAX(CASE WHEN mi.is_adult=1 THEN 1 ELSE 0 END) AS cover_is_adult
                    FROM media_collections mc
                    JOIN users u ON u.id = mc.user_id
                    LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
                    LEFT JOIN media_items mi ON mi.id = mci.media_id
                     AND mi.deleted_at IS NULL
                     AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
                    {where}
                    GROUP BY mc.id
                    ORDER BY mc.updated_at DESC, mc.created_at DESC
                    LIMIT 100
                    """,
                    tuple(params),
                )
                return [self._decode_collection(row) for row in await cur.fetchall()]

    async def list_user_collections(self, user_id: int, viewer_id: int | None = None, limit: int = 12) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
                           COUNT(mi.id) AS item_count,
                           MAX(mi.storage_path) AS cover_path,
                           MAX(mi.media_kind) AS cover_media_kind,
                           MAX(mi.id) AS cover_media_id,
                           MAX(CASE WHEN mi.is_adult=1 THEN 1 ELSE 0 END) AS cover_is_adult
                    FROM media_collections mc
                    JOIN users u ON u.id = mc.user_id
                    LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
                    LEFT JOIN media_items mi ON mi.id = mci.media_id
                     AND mi.deleted_at IS NULL
                     AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
                    WHERE mc.user_id=%s AND (mc.is_public=1 OR mc.user_id=%s)
                    GROUP BY mc.id
                    ORDER BY mc.updated_at DESC, mc.created_at DESC
                    LIMIT %s
                    """,
                    (viewer_id or 0, viewer_id or 0, user_id, viewer_id or 0, max(1, min(limit, 60))),
                )
                return [self._decode_collection(row) for row in await cur.fetchall()]

    async def get_collection(self, collection_id: int, viewer_id: int | None = None) -> dict[str, Any] | None:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
                           COUNT(mi.id) AS item_count,
                           MAX(mi.storage_path) AS cover_path,
                           MAX(mi.media_kind) AS cover_media_kind,
                           MAX(mi.id) AS cover_media_id,
                           MAX(CASE WHEN mi.is_adult=1 THEN 1 ELSE 0 END) AS cover_is_adult
                    FROM media_collections mc
                    JOIN users u ON u.id = mc.user_id
                    LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
                    LEFT JOIN media_items mi ON mi.id = mci.media_id
                     AND mi.deleted_at IS NULL
                     AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
                    WHERE mc.id=%s AND (mc.is_public=1 OR mc.user_id=%s)
                    GROUP BY mc.id
                    """,
                    (viewer_id or 0, viewer_id or 0, collection_id, viewer_id or 0),
                )
                row = await cur.fetchone()
                return self._decode_collection(row) if row else None

    async def set_collection_item(self, collection_id: int, media_id: int, user_id: int, saved: bool) -> dict[str, Any] | None:
        collection = await self.get_collection(collection_id, user_id)
        if not collection or int(collection["user_id"]) != int(user_id):
            return None
        media = await self.get_media(media_id, user_id)
        if not media or media.get("deleted_at"):
            return None
        if media.get("visibility") == "private" and int(media.get("user_id") or 0) != int(user_id):
            return None
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                if saved:
                    await cur.execute(
                        "INSERT IGNORE INTO media_collection_items (collection_id, media_id) VALUES (%s, %s)",
                        (collection_id, media_id),
                    )
                else:
                    await cur.execute(
                        "DELETE FROM media_collection_items WHERE collection_id=%s AND media_id=%s",
                        (collection_id, media_id),
                    )
                await cur.execute("UPDATE media_collections SET updated_at=CURRENT_TIMESTAMP WHERE id=%s", (collection_id,))
        return await self.get_collection(collection_id, user_id)

    async def list_collection_media(self, collection_id: int, viewer_id: int | None = None) -> list[dict[str, Any]]:
        collection = await self.get_collection(collection_id, viewer_id)
        if not collection:
            return []
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, {MEDIA_CATEGORY_SELECT}
                           u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS user_bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS user_website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
                           u.profile_color, u.public_profile,
                           COUNT(DISTINCT l.user_id) AS like_count,
                           COUNT(DISTINCT cm.id) AS comment_count,
                           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
                           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
                    FROM media_collection_items mci
                    JOIN media_items m ON m.id = mci.media_id
                    {MEDIA_CATEGORY_JOIN}
                    JOIN users u ON u.id = m.user_id
                    LEFT JOIN media_likes l ON l.media_id = m.id
                    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id = %s
                    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id = %s
                    LEFT JOIN media_comments cm ON cm.media_id = m.id
                    WHERE mci.collection_id=%s
                      AND m.deleted_at IS NULL
                      AND (m.visibility='public' OR m.user_id=%s)
                    GROUP BY m.id, mci.added_at
                    ORDER BY mci.added_at DESC
                    LIMIT 120
                    """,
                    (viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, viewer_id or 0, collection_id, viewer_id or 0),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def get_public_profile(self, username: str, viewer_id: int | None = None) -> dict[str, Any] | None:
        username = normalize_username(username)
        viewer = viewer_id or 0
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.featured_tags ELSE NULL END AS featured_tags,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.website_url ELSE NULL END AS website_url,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.location_label ELSE NULL END AS location_label,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.user_settings ELSE NULL END AS user_settings,
                           u.avatar_file_id, u.profile_color, u.public_profile, u.show_liked_count,
                           u.show_collections, u.show_recent_uploads, u.show_friends, u.created_at,
                           u.last_seen_at,
                           COUNT(DISTINCT m.id) AS media_count,
                           COALESCE(SUM(CASE WHEN m.deleted_at IS NULL AND m.visibility='public' THEN m.downloads ELSE 0 END), 0) AS download_count,
                           COUNT(DISTINCT ml.user_id, ml.media_id) AS like_count,
                           COUNT(DISTINCT f1.follower_id) AS follower_count,
                           COUNT(DISTINCT f2.followed_id) AS following_count,
                           COUNT(DISTINCT CASE
                               WHEN fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id)
                               THEN fr.id END) AS friend_count,
                           MAX(CASE WHEN f3.follower_id=%s THEN 1 ELSE 0 END) AS followed_by_me
                    FROM users u
                    LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id=%s)
                    LEFT JOIN media_likes ml ON ml.media_id=m.id
                    LEFT JOIN user_follows f1 ON f1.followed_id=u.id
                    LEFT JOIN user_follows f2 ON f2.follower_id=u.id
                    LEFT JOIN user_follows f3 ON f3.followed_id=u.id AND f3.follower_id=%s
                    LEFT JOIN friend_requests fr ON fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id)
                    WHERE u.username=%s
                    GROUP BY u.id
                    """,
                    (viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, viewer, username),
                )
                row = await cur.fetchone()
                if not row:
                    return None
                row["public_profile"] = bool(row.get("public_profile"))
                row["show_liked_count"] = bool(row.get("show_liked_count"))
                row["show_collections"] = bool(row.get("show_collections"))
                row["show_recent_uploads"] = bool(row.get("show_recent_uploads"))
                row["show_friends"] = bool(row.get("show_friends"))
                row["followed_by_me"] = bool(row.get("followed_by_me"))
                row["is_online"] = self._is_recently_seen(row.get("last_seen_at"))
                tags = row.get("featured_tags")
                if isinstance(tags, str):
                    try:
                        row["featured_tags"] = json.loads(tags) or []
                    except json.JSONDecodeError:
                        row["featured_tags"] = []
                elif tags is None:
                    row["featured_tags"] = []
                raw_settings = row.get("user_settings")
                settings = dict(DEFAULT_USER_SETTINGS)
                if isinstance(raw_settings, str):
                    try:
                        settings.update(json.loads(raw_settings) or {})
                    except json.JSONDecodeError:
                        pass
                elif isinstance(raw_settings, dict):
                    settings.update(raw_settings)
                row["user_settings"] = settings
                for k in ("media_count", "download_count", "like_count", "follower_count", "following_count", "friend_count"):
                    if isinstance(row.get(k), Decimal):
                        row[k] = int(row[k])
                row["friend_status"] = await self.friend_status(viewer, int(row["id"])) if viewer else "none"
                return row

    async def set_follow(self, follower_id: int, followed_id: int, following: bool) -> dict[str, Any] | None:
        if follower_id == followed_id:
            raise ValueError("You cannot follow yourself.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (followed_id,))
                if not await cur.fetchone():
                    return None
                if following:
                    await cur.execute("INSERT IGNORE INTO user_follows (follower_id, followed_id) VALUES (%s, %s)", (follower_id, followed_id))
                else:
                    await cur.execute("DELETE FROM user_follows WHERE follower_id=%s AND followed_id=%s", (follower_id, followed_id))
                await cur.execute("SELECT COUNT(*) AS n FROM user_follows WHERE followed_id=%s", (followed_id,))
                followers = int((await cur.fetchone())["n"] or 0)
                return {"followed_id": followed_id, "following": bool(following), "follower_count": followers}

    async def friend_status(self, viewer_id: int | None, user_id: int) -> str:
        if not viewer_id:
            return "none"
        if int(viewer_id) == int(user_id):
            return "self"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT requester_id, addressee_id, status
                    FROM friend_requests
                    WHERE (requester_id=%s AND addressee_id=%s)
                       OR (requester_id=%s AND addressee_id=%s)
                    ORDER BY FIELD(status, 'accepted', 'pending', 'declined', 'cancelled'), created_at DESC
                    LIMIT 1
                    """,
                    (viewer_id, user_id, user_id, viewer_id),
                )
                row = await cur.fetchone()
        if not row or row.get("status") in {"declined", "cancelled"}:
            return "none"
        if row["status"] == "accepted":
            return "friends"
        return "pending_out" if int(row["requester_id"]) == int(viewer_id) else "pending_in"

    async def send_friend_request(self, requester_id: int, addressee_id: int) -> dict[str, Any]:
        if requester_id == addressee_id:
            raise ValueError("You cannot friend yourself.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (addressee_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                await cur.execute(
                    """
                    SELECT * FROM friend_requests
                    WHERE (requester_id=%s AND addressee_id=%s)
                       OR (requester_id=%s AND addressee_id=%s)
                    ORDER BY FIELD(status, 'accepted', 'pending', 'declined', 'cancelled'), created_at DESC
                    LIMIT 1
                    """,
                    (requester_id, addressee_id, addressee_id, requester_id),
                )
                existing = await cur.fetchone()
                if existing and existing["status"] == "accepted":
                    return {"status": "friends", "request": existing}
                if existing and existing["status"] == "pending":
                    if int(existing["requester_id"]) == int(addressee_id):
                        await cur.execute(
                            "UPDATE friend_requests SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=%s",
                            (existing["id"],),
                        )
                        existing["status"] = "accepted"
                        return {"status": "friends", "request": existing}
                    return {"status": "pending_out", "request": existing}
                if existing:
                    await cur.execute(
                        """
                        UPDATE friend_requests
                        SET requester_id=%s, addressee_id=%s, status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL
                        WHERE id=%s
                        """,
                        (requester_id, addressee_id, existing["id"]),
                    )
                    request_id = existing["id"]
                else:
                    await cur.execute(
                        "INSERT INTO friend_requests (requester_id, addressee_id) VALUES (%s, %s)",
                        (requester_id, addressee_id),
                    )
                    request_id = cur.lastrowid
                await cur.execute("SELECT * FROM friend_requests WHERE id=%s", (request_id,))
                return {"status": "pending_out", "request": await cur.fetchone()}

    async def respond_friend_request(self, user_id: int, request_id: int, action: str) -> dict[str, Any] | None:
        status = {"accept": "accepted", "decline": "declined", "cancel": "cancelled"}.get(action)
        if not status:
            raise ValueError("Action must be accept, decline, or cancel.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                if action == "cancel":
                    await cur.execute(
                        "SELECT * FROM friend_requests WHERE id=%s AND requester_id=%s AND status='pending'",
                        (request_id, user_id),
                    )
                else:
                    await cur.execute(
                        "SELECT * FROM friend_requests WHERE id=%s AND addressee_id=%s AND status='pending'",
                        (request_id, user_id),
                    )
                row = await cur.fetchone()
                if not row:
                    return None
                await cur.execute(
                    "UPDATE friend_requests SET status=%s, responded_at=CURRENT_TIMESTAMP WHERE id=%s",
                    (status, request_id),
                )
                row["status"] = status
                return row

    async def list_friend_requests(self, user_id: int, mode: str = "incoming") -> list[dict[str, Any]]:
        if mode == "outgoing":
            own_col, other_col = "requester_id", "addressee_id"
        else:
            own_col, other_col = "addressee_id", "requester_id"
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT fr.*, u.id AS user_id, u.username, u.display_name, u.bio, u.avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at
                    FROM friend_requests fr
                    JOIN users u ON u.id=fr.{other_col}
                    WHERE fr.{own_col}=%s AND fr.status='pending'
                    ORDER BY fr.created_at DESC
                    LIMIT 100
                    """,
                    (user_id,),
                )
                return [self._decode_user_request(row) for row in await cur.fetchall()]

    async def list_friends(self, user_id: int, viewer_id: int | None = None, limit: int = 80) -> list[dict[str, Any]]:
        viewer = int(viewer_id or 0)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.last_seen_at, fr.responded_at AS friended_at
                    FROM friend_requests fr
                    JOIN users u ON u.id = CASE WHEN fr.requester_id=%s THEN fr.addressee_id ELSE fr.requester_id END
                    WHERE fr.status='accepted' AND (fr.requester_id=%s OR fr.addressee_id=%s)
                    ORDER BY fr.responded_at DESC, fr.created_at DESC
                    LIMIT %s
                    """,
                    (viewer, viewer, viewer, user_id, user_id, user_id, max(1, min(limit, 200))),
                )
                return [self._decode_user(row) for row in await cur.fetchall()]

    async def search_users(self, query: str, viewer_id: int | None = None, limit: int = 30) -> list[dict[str, Any]]:
        query = " ".join(str(query or "").strip().split())[:80]
        needle = f"%{query}%"
        viewer = int(viewer_id or 0)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT u.id, u.username,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE u.username END AS display_name,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END AS bio,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
                           CASE WHEN u.public_profile=1 OR u.id=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
                           u.profile_color, u.public_profile, u.show_liked_count, u.show_collections,
                           u.show_recent_uploads, u.show_friends, u.adult_content_consent, u.email_verified_at,
                           u.last_seen_at,
                           COUNT(DISTINCT m.id) AS media_count,
                           COUNT(DISTINCT f.follower_id) AS follower_count,
                           MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me
                    FROM users u
                    LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND m.visibility='public'
                    LEFT JOIN user_follows f ON f.followed_id=u.id
                    LEFT JOIN user_follows mine ON mine.followed_id=u.id AND mine.follower_id=%s
                    WHERE %s = ''
                       OR u.username LIKE %s
                       OR (CASE WHEN u.public_profile=1 OR u.id=%s THEN u.display_name ELSE NULL END) LIKE %s
                       OR (CASE WHEN u.public_profile=1 OR u.id=%s THEN u.bio ELSE NULL END) LIKE %s
                       OR (CASE WHEN u.public_profile=1 OR u.id=%s THEN u.profile_headline ELSE NULL END) LIKE %s
                    GROUP BY u.id
                    ORDER BY (u.username=%s) DESC, follower_count DESC, media_count DESC, u.created_at DESC
                    LIMIT %s
                    """,
                    (
                        viewer,
                        viewer,
                        viewer,
                        viewer,
                        viewer,
                        query,
                        needle,
                        viewer,
                        needle,
                        viewer,
                        needle,
                        viewer,
                        needle,
                        query,
                        max(1, min(limit, 60)),
                    ),
                )
                users = []
                for row in await cur.fetchall():
                    row = self._decode_user(row)
                    row["media_count"] = int(row.get("media_count") or 0)
                    row["follower_count"] = int(row.get("follower_count") or 0)
                    row["followed_by_me"] = bool(row.get("followed_by_me"))
                    row["friend_status"] = await self.friend_status(viewer, int(row["id"])) if viewer else "none"
                    users.append(row)
                return users

    async def send_direct_message(self, sender_id: int, recipient_id: int, body: str) -> dict[str, Any]:
        if int(sender_id) == int(recipient_id):
            raise ValueError("You cannot message yourself.")
        cleaned = " ".join(str(body or "").split())
        if not cleaned:
            raise ValueError("Message cannot be empty.")
        if len(cleaned) > 2000:
            raise ValueError("Message must be 2000 characters or fewer.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (recipient_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                await cur.execute(
                    "INSERT INTO user_messages (sender_id, recipient_id, body) VALUES (%s, %s, %s)",
                    (sender_id, recipient_id, cleaned),
                )
                message_id = cur.lastrowid
                await cur.execute(
                    """
                    SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile, u.last_seen_at
                    FROM user_messages msg
                    JOIN users u ON u.id=msg.sender_id
                    WHERE msg.id=%s
                    """,
                    (message_id,),
                )
                return self._decode_message(await cur.fetchone())

    async def list_message_threads(self, user_id: int) -> list[dict[str, Any]]:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT
                      other_user.id AS id,
                      other_user.id AS user_id,
                      other_user.username,
                      CASE WHEN other_user.public_profile=1 THEN other_user.display_name ELSE other_user.username END AS display_name,
                      CASE WHEN other_user.public_profile=1 THEN other_user.avatar_path ELSE NULL END AS avatar_path,
                      other_user.profile_color,
                      other_user.public_profile,
                      other_user.last_seen_at,
                      latest.id AS last_message_id,
                      latest.body AS last_message,
                      latest.created_at AS last_message_at,
                      latest.sender_id AS last_sender_id,
                      unread.unread_count
                    FROM (
                      SELECT
                        CASE WHEN sender_id=%s THEN recipient_id ELSE sender_id END AS other_id,
                        MAX(id) AS last_id
                      FROM user_messages
                      WHERE sender_id=%s OR recipient_id=%s
                      GROUP BY other_id
                    ) threads
                    JOIN user_messages latest ON latest.id=threads.last_id
                    JOIN users other_user ON other_user.id=threads.other_id
                    LEFT JOIN (
                      SELECT sender_id AS other_id, COUNT(*) AS unread_count
                      FROM user_messages
                      WHERE recipient_id=%s AND read_at IS NULL
                      GROUP BY sender_id
                    ) unread ON unread.other_id=threads.other_id
                    ORDER BY latest.created_at DESC
                    LIMIT 100
                    """,
                    (user_id, user_id, user_id, user_id),
                )
                return [self._decode_message_thread(row) for row in await cur.fetchall()]

    async def list_direct_messages(self, user_id: int, other_user_id: int, limit: int = 80) -> list[dict[str, Any]]:
        if int(user_id) == int(other_user_id):
            raise ValueError("Pick another user to view messages.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT id FROM users WHERE id=%s", (other_user_id,))
                if not await cur.fetchone():
                    raise ValueError("User not found.")
                await cur.execute(
                    """
                    UPDATE user_messages
                    SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP)
                    WHERE sender_id=%s AND recipient_id=%s AND read_at IS NULL
                    """,
                    (other_user_id, user_id),
                )
                await cur.execute(
                    """
                    SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile, u.last_seen_at
                    FROM user_messages msg
                    JOIN users u ON u.id=msg.sender_id
                    WHERE (msg.sender_id=%s AND msg.recipient_id=%s)
                       OR (msg.sender_id=%s AND msg.recipient_id=%s)
                    ORDER BY msg.created_at DESC, msg.id DESC
                    LIMIT %s
                    """,
                    (user_id, other_user_id, other_user_id, user_id, max(1, min(limit, 200))),
                )
                rows = list(await cur.fetchall())
                rows.reverse()
                return [self._decode_message(row) for row in rows]

    def _decode_message(self, row: dict[str, Any] | None) -> dict[str, Any]:
        if not row:
            return {}
        item = dict(row)
        for key in ("created_at", "read_at"):
            value = item.get(key)
            if hasattr(value, "isoformat"):
                item[key] = value.isoformat()
        item["public_profile"] = bool(item.get("public_profile"))
        if "last_seen_at" in item:
            item["is_online"] = self._is_recently_seen(item.get("last_seen_at"))
        return item

    def _decode_message_thread(self, row: dict[str, Any]) -> dict[str, Any]:
        item = dict(row)
        if hasattr(item.get("last_message_at"), "isoformat"):
            item["last_message_at"] = item["last_message_at"].isoformat()
        item["public_profile"] = bool(item.get("public_profile"))
        if "last_seen_at" in item:
            item["is_online"] = self._is_recently_seen(item.get("last_seen_at"))
        item["unread_count"] = int(item.get("unread_count") or 0)
        return item

    async def change_password(self, user_id: int, old_password: str, new_password: str) -> bool:
        if len(new_password or "") < 8:
            raise ValueError("New password must be at least 8 characters.")
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT password_hash FROM users WHERE id=%s", (user_id,))
                row = await cur.fetchone()
                if not row or not verify_password(old_password, row["password_hash"]):
                    return False
                await cur.execute("UPDATE users SET password_hash=%s WHERE id=%s", (hash_password(new_password), user_id))
                return True

    async def delete_account(self, user_id: int, password: str) -> bool:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute("SELECT password_hash FROM users WHERE id=%s", (user_id,))
                row = await cur.fetchone()
                if not row or not verify_password(password, row["password_hash"]):
                    return False
                await cur.execute("DELETE FROM users WHERE id=%s", (user_id,))
                return True

    async def record_auth_attempt(self, username: str | None, ip_address: str, successful: bool) -> None:
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    "INSERT INTO auth_attempts (username, ip_address, successful) VALUES (%s, %s, %s)",
                    ((username or "")[:80] or None, ip_address[:64], 1 if successful else 0),
                )

    async def count_recent_failed_auth(self, username: str | None, ip_address: str, minutes: int = 15) -> int:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT COUNT(*) AS n FROM auth_attempts
                    WHERE successful=0 AND created_at >= (CURRENT_TIMESTAMP - INTERVAL %s MINUTE)
                      AND (ip_address=%s OR username=%s)
                    """,
                    (minutes, ip_address[:64], (username or "")[:80]),
                )
                row = await cur.fetchone()
                return int(row["n"] or 0)

    async def check_rate_limit(self, key: str, *, limit: int, window_seconds: int) -> bool:
        """DB-backed fixed-window rate limiter shared across workers/restarts."""
        bucket_key = str(key or "unknown")[:190]
        limit = max(1, int(limit or 1))
        window_seconds = max(1, int(window_seconds or 1))
        async with self.pool.acquire() as conn:
            await conn.ping(reconnect=True)
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await conn.begin()
                try:
                    await cur.execute(
                        """
                        SELECT event_count, TIMESTAMPDIFF(SECOND, window_start, UTC_TIMESTAMP()) AS age_seconds
                        FROM api_rate_limits
                        WHERE bucket_key=%s
                        FOR UPDATE
                        """,
                        (bucket_key,),
                    )
                    row = await cur.fetchone()
                    if not row:
                        await cur.execute(
                            "INSERT INTO api_rate_limits (bucket_key, window_start, event_count) VALUES (%s, UTC_TIMESTAMP(), 1)",
                            (bucket_key,),
                        )
                        await conn.commit()
                        return True
                    age = int(row.get("age_seconds") or 0)
                    count = int(row.get("event_count") or 0)
                    if age >= window_seconds:
                        await cur.execute(
                            "UPDATE api_rate_limits SET window_start=UTC_TIMESTAMP(), event_count=1 WHERE bucket_key=%s",
                            (bucket_key,),
                        )
                        await conn.commit()
                        return True
                    if count >= limit:
                        await conn.rollback()
                        return False
                    await cur.execute(
                        "UPDATE api_rate_limits SET event_count=event_count+1 WHERE bucket_key=%s",
                        (bucket_key,),
                    )
                    await conn.commit()
                    return True
                except Exception:
                    await conn.rollback()
                    raise

    async def report_media(self, media_id: int, user_id: int, reason: str, details: str | None) -> dict[str, Any]:
        reason = self._clean_text(reason, 80, required=True)
        details = self._clean_text(details, 500)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    INSERT INTO media_reports (media_id, user_id, reason, details)
                    VALUES (%s, %s, %s, %s)
                    ON DUPLICATE KEY UPDATE reason=VALUES(reason), details=VALUES(details), status='open', created_at=CURRENT_TIMESTAMP
                    """,
                    (media_id, user_id, reason, details),
                )
                await cur.execute(
                    "SELECT * FROM media_reports WHERE media_id=%s AND user_id=%s",
                    (media_id, user_id),
                )
                return await cur.fetchone()

    async def record_ai_vision_training_example(
        self,
        *,
        user_id: int,
        media_id: int | None = None,
        source: dict[str, Any] | None = None,
        corrected: dict[str, Any] | None = None,
        notes: str | None = None,
    ) -> dict[str, Any] | None:
        """Store a user-approved correction as gallery-specific AI training data."""
        corrected = dict(corrected or {})
        source = dict(source or {})
        title = self._clean_text(corrected.get("title") or corrected.get("corrected_title"), 160, required=True)
        category_name = self._clean_text(corrected.get("category_name") or corrected.get("corrected_category_name"), 80)
        subcategory_name = self._clean_text(corrected.get("subcategory_name") or corrected.get("corrected_subcategory_name"), 80)
        corrected_tags = self._clean_tags(corrected.get("tags") or corrected.get("corrected_tags") or [])
        source_tags = self._clean_tags(source.get("tags") or source.get("source_tags") or [])
        dedupe_key = self._ai_training_dedupe_key(
            user_id=int(user_id),
            media_id=media_id,
            original_filename=source.get("original_filename"),
            corrected_title=title,
            corrected_category_name=category_name,
            corrected_subcategory_name=subcategory_name,
            corrected_tags=corrected_tags,
            image_phash=source.get("image_phash") or source.get("source_image_phash"),
            image_dhash=source.get("image_dhash") or source.get("source_image_dhash"),
        )
        if media_id is not None:
            media_id = int(media_id)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                if media_id is not None:
                    await cur.execute("SELECT id, user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", (media_id,))
                    row = await cur.fetchone()
                    if not row:
                        return None
                    if int(row["user_id"]) != int(user_id):
                        raise PermissionError("You can only train AI using your own media.")
                original_filename = self._clean_text(source.get("original_filename"), 255)
                source_title = self._clean_text(source.get("title"), 160)
                source_category_name = self._clean_text(source.get("category_name"), 80)
                source_subcategory_name = self._clean_text(source.get("subcategory_name"), 80)
                notes_text = self._clean_text(notes, 500)
                image_phash = self._clean_text(source.get("image_phash") or source.get("source_image_phash"), 16)
                image_dhash = self._clean_text(source.get("image_dhash") or source.get("source_image_dhash"), 16)
                image_width = int(source.get("image_width") or 0) or None
                image_height = int(source.get("image_height") or 0) or None
                training_origin = self._clean_text(source.get("training_origin") or source.get("origin"), 80)
                training_confidence = max(0.0, min(float(source.get("training_confidence") or corrected.get("training_confidence") or 0.72), 1.0))
                await cur.execute("SELECT id FROM ai_vision_training_examples WHERE dedupe_key=%s LIMIT 1", (dedupe_key,))
                existing = await cur.fetchone()
                if existing:
                    await cur.execute(
                        """
                        UPDATE ai_vision_training_examples
                        SET source_title=COALESCE(%s, source_title),
                            source_category_name=COALESCE(%s, source_category_name),
                            source_subcategory_name=COALESCE(%s, source_subcategory_name),
                            source_tags=%s,
                            corrected_title=%s,
                            corrected_category_name=COALESCE(%s, corrected_category_name),
                            corrected_subcategory_name=COALESCE(%s, corrected_subcategory_name),
                            corrected_tags=%s,
                            corrected_is_adult=%s,
                            notes=COALESCE(%s, notes),
                            original_filename=COALESCE(%s, original_filename),
                            image_phash=COALESCE(%s, image_phash),
                            image_dhash=COALESCE(%s, image_dhash),
                            image_width=COALESCE(%s, image_width),
                            image_height=COALESCE(%s, image_height),
                            training_origin=COALESCE(%s, training_origin),
                            training_confidence=GREATEST(training_confidence, %s)
                        WHERE id=%s
                        """,
                        (
                            source_title,
                            source_category_name,
                            source_subcategory_name,
                            json.dumps(source_tags),
                            title,
                            category_name,
                            subcategory_name,
                            json.dumps(corrected_tags),
                            1 if bool(corrected.get("is_adult") or corrected.get("corrected_is_adult")) else 0,
                            notes_text,
                            original_filename,
                            image_phash,
                            image_dhash,
                            image_width,
                            image_height,
                            training_origin,
                            training_confidence,
                            int(existing["id"]),
                        ),
                    )
                    training_id = int(existing["id"])
                else:
                    await cur.execute(
                        """
                        INSERT INTO ai_vision_training_examples
                        (user_id, media_id, original_filename, source_title, source_category_name, source_subcategory_name,
                         source_tags, corrected_title, corrected_category_name, corrected_subcategory_name, corrected_tags,
                         corrected_is_adult, notes, dedupe_key, image_phash, image_dhash, image_width, image_height, training_origin, training_confidence)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                        """,
                        (
                            user_id,
                            media_id,
                            original_filename,
                            source_title,
                            source_category_name,
                            source_subcategory_name,
                            json.dumps(source_tags),
                            title,
                            category_name,
                            subcategory_name,
                            json.dumps(corrected_tags),
                            1 if bool(corrected.get("is_adult") or corrected.get("corrected_is_adult")) else 0,
                            notes_text,
                            dedupe_key,
                            image_phash,
                            image_dhash,
                            image_width,
                            image_height,
                            training_origin,
                            training_confidence,
                        ),
                    )
                    training_id = int(cur.lastrowid)
                await cur.execute("SELECT * FROM ai_vision_training_examples WHERE id=%s", (training_id,))
                row = await cur.fetchone()
                return self._decode_ai_training_example(row)

    async def list_ai_vision_training_examples(self, user_id: int | None = None, limit: int = 24) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 24), 80))
        where = ""
        params: list[Any] = []
        if user_id is not None:
            where = "WHERE user_id=%s"
            params.append(int(user_id))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT * FROM ai_vision_training_examples
                    {where}
                    ORDER BY created_at DESC
                    LIMIT %s
                    """,
                    (*params, limit),
                )
                return [self._decode_ai_training_example(row) for row in await cur.fetchall()]

    async def export_ai_vision_training_examples(self, user_id: int, limit: int = 500) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 500), 5000))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT t.*, m.media_kind, m.mime_type
                    FROM ai_vision_training_examples t
                    LEFT JOIN media_items m ON m.id=t.media_id
                    WHERE t.user_id=%s
                    ORDER BY t.created_at DESC
                    LIMIT %s
                    """,
                    (int(user_id), limit),
                )
                return [self._decode_ai_training_example(row) for row in await cur.fetchall()]

    async def list_ai_media_learning_candidates(
        self,
        limit: int = 8,
        stale_minutes: int = 720,
        error_retry_minutes: int = 30,
    ) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 8), 50))
        stale_minutes = max(10, int(stale_minutes or 720))
        error_retry_minutes = max(5, int(error_retry_minutes or 30))
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.id, m.user_id, m.title, m.description, m.tags, m.media_kind, m.mime_type,
                           m.original_filename, m.storage_path, m.file_size, m.visibility, m.is_adult,
                           m.created_at, m.updated_at, {MEDIA_CATEGORY_SELECT}
                           s.last_scanned_at, s.last_scan_status, s.last_scan_source, s.last_scan_confidence,
                           s.last_scan_title, s.last_scan_error, s.last_learned_at, s.last_autofill_at
                    FROM media_items m
                    {MEDIA_CATEGORY_JOIN}
                    LEFT JOIN ai_media_learning_state s ON s.media_id = m.id
                    WHERE m.deleted_at IS NULL
                      AND m.media_kind='image'
                      AND (
                        s.media_id IS NULL
                        OR s.last_scanned_at IS NULL
                        OR m.updated_at > s.last_scanned_at
                        OR (
                          s.last_scan_status='error'
                          AND COALESCE(s.updated_at, s.last_scanned_at) < (CURRENT_TIMESTAMP - INTERVAL %s MINUTE)
                        )
                        OR s.last_scanned_at < (CURRENT_TIMESTAMP - INTERVAL %s MINUTE)
                      )
                    ORDER BY
                      CASE
                        WHEN s.media_id IS NULL OR s.last_scanned_at IS NULL THEN 0
                        WHEN m.updated_at > s.last_scanned_at THEN 1
                        ELSE 2
                      END ASC,
                      COALESCE(s.last_scanned_at, '1970-01-01 00:00:00') ASC,
                      m.updated_at DESC
                    LIMIT %s
                    """,
                    (error_retry_minutes, stale_minutes, limit),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def list_video_thumb_candidates(
        self,
        limit: int = 8,
        before_media_id: int | None = None,
    ) -> list[dict[str, Any]]:
        limit = max(1, min(int(limit or 8), 32))
        clauses = ["m.deleted_at IS NULL", "m.media_kind='video'"]
        params: list[Any] = []
        if before_media_id:
            clauses.append("m.id < %s")
            params.append(int(before_media_id))
        where_sql = " AND ".join(clauses)
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    f"""
                    SELECT m.*, c.name AS category_name, sc.name AS subcategory_name
                    FROM media_items m
                    JOIN categories c ON c.id = m.category_id
                    LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
                    WHERE {where_sql}
                    ORDER BY m.id DESC
                    LIMIT %s
                    """,
                    (*params, limit),
                )
                rows = [self._decode_media(row) for row in await cur.fetchall()]
        return await self._attach_media_subcategories(rows)

    async def upsert_ai_media_learning_state(
        self,
        *,
        media_id: int,
        user_id: int,
        status: str,
        source: str | None = None,
        confidence: float | None = None,
        title: str | None = None,
        error: str | None = None,
        learned: bool = False,
        autofilled: bool = False,
    ) -> None:
        clean_status = self._clean_text(status, 30, required=True) or "pending"
        async with self.pool.acquire() as conn:
            async with conn.cursor() as cur:
                await cur.execute(
                    """
                    INSERT INTO ai_media_learning_state
                      (media_id, user_id, last_scanned_at, last_scan_status, last_scan_source,
                       last_scan_confidence, last_scan_title, last_scan_error, last_learned_at, last_autofill_at)
                    VALUES
                      (%s, %s, CURRENT_TIMESTAMP, %s, %s, %s, %s, %s,
                       CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE NULL END,
                       CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE NULL END)
                    ON DUPLICATE KEY UPDATE
                      user_id=VALUES(user_id),
                      last_scanned_at=CURRENT_TIMESTAMP,
                      last_scan_status=VALUES(last_scan_status),
                      last_scan_source=VALUES(last_scan_source),
                      last_scan_confidence=VALUES(last_scan_confidence),
                      last_scan_title=VALUES(last_scan_title),
                      last_scan_error=VALUES(last_scan_error),
                      last_learned_at=CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE last_learned_at END,
                      last_autofill_at=CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE last_autofill_at END
                    """,
                    (
                        int(media_id),
                        int(user_id),
                        clean_status,
                        self._clean_text(source, 40),
                        None if confidence is None else max(0.0, min(float(confidence), 1.0)),
                        self._clean_text(title, 160),
                        self._clean_text(error, 300),
                        1 if learned else 0,
                        1 if autofilled else 0,
                        1 if learned else 0,
                        1 if autofilled else 0,
                    ),
                )

    def _decode_ai_training_example(self, row: dict[str, Any] | None) -> dict[str, Any] | None:
        if not row:
            return None
        item = dict(row)
        for key in ("source_tags", "corrected_tags"):
            value = item.get(key)
            if isinstance(value, str):
                try:
                    item[key] = json.loads(value or "[]")
                except json.JSONDecodeError:
                    item[key] = []
            elif value is None:
                item[key] = []
        item["corrected_is_adult"] = bool(item.get("corrected_is_adult"))
        return item

    async def migrate_legacy_media_files(self, limit: int = 10) -> dict[str, Any]:
        """Copy old disk-backed uploads into media_files and link media_items safely."""
        migrated = 0
        missing = 0
        async with self._blob_lock:
            async with self.pool.acquire() as conn:
                await conn.ping(reconnect=True)
                async with conn.cursor(aiomysql.DictCursor) as cur:
                    await cur.execute(
                        """
                        SELECT id, user_id, storage_path, mime_type, original_filename, media_kind
                        FROM media_items
                        WHERE deleted_at IS NULL AND (media_file_id IS NULL OR media_file_id=0)
                        ORDER BY id ASC
                        LIMIT %s
                        """,
                        (max(1, min(int(limit or 10), 25)),),
                    )
                    rows = list(await cur.fetchall())
                    uploads_root = Path(self.settings.uploads_dir).resolve()
                    for row in rows:
                        raw = str(row.get("storage_path") or "")
                        if raw.startswith("db://"):
                            missing += 1
                            continue
                        raw = raw.replace("\\", "/").lstrip("/")
                        if raw.startswith("uploads/"):
                            raw = raw.split("/", 1)[1]
                        path = (uploads_root / raw).resolve()
                        try:
                            path.relative_to(uploads_root)
                        except ValueError:
                            missing += 1
                            continue
                        if not path.is_file():
                            missing += 1
                            continue
                        content = path.read_bytes()
                        sha256 = hashlib.sha256(content).hexdigest()
                        mime_type = (row.get("mime_type") or mimetypes.guess_type(str(path))[0] or "application/octet-stream")[:120]
                        media_kind = row.get("media_kind") if row.get("media_kind") in {"image", "video"} else ("video" if mime_type.startswith("video/") else "image")
                        original = (row.get("original_filename") or path.name)[:255]
                        await conn.begin()
                        await cur.execute(
                            """
                            INSERT INTO media_files (sha256, mime_type, original_filename, media_kind, file_size, content, created_by)
                            VALUES (%s, %s, %s, %s, %s, %s, %s)
                            ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)
                            """,
                            (sha256, mime_type, original, media_kind, len(content), b"", row.get("user_id")),
                        )
                        file_id = int(cur.lastrowid)
                        await cur.execute("SELECT COUNT(*) AS n FROM media_file_chunks WHERE file_id=%s", (file_id,))
                        chunk_count = int((await cur.fetchone() or {}).get("n") or 0)
                        if chunk_count == 0:
                            for chunk_index, offset in enumerate(range(0, len(content), self.media_chunk_bytes)):
                                await cur.execute(
                                    """
                                    INSERT INTO media_file_chunks (file_id, chunk_index, content)
                                    VALUES (%s, %s, %s)
                                    """,
                                    (file_id, chunk_index, content[offset:offset + self.media_chunk_bytes]),
                                )
                        await cur.execute(
                            "UPDATE media_items SET media_file_id=%s, content_sha256=%s, file_size=%s, storage_path=%s WHERE id=%s",
                            (file_id, sha256, len(content), f"db://media/{file_id}", row["id"]),
                        )
                        await conn.commit()
                        migrated += 1
        return {"migrated": migrated, "missing": missing}


    async def site_checks(self) -> dict[str, Any]:
        """Lightweight operational checks used by the live site status panel.

        These checks avoid touching BLOB contents so the endpoint stays cheap.
        All counts are gathered in a single round-trip.
        """
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT
                        CURRENT_TIMESTAMP AS db_time,
                        (SELECT COUNT(*) FROM users) AS users,
                        (SELECT COUNT(*) FROM media_items) AS media_total,
                        (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NULL) AS media_active,
                        (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NOT NULL) AS media_archived,
                        (SELECT COUNT(*) FROM media_files) AS db_files,
                        (SELECT COUNT(*) FROM media_items
                            WHERE deleted_at IS NULL AND (media_file_id IS NULL OR media_file_id=0)) AS missing_db_files,
                        (SELECT COUNT(*) FROM media_items WHERE visibility='private' AND deleted_at IS NULL) AS private_posts,
                        (SELECT COUNT(*) FROM media_items WHERE comments_enabled=0 AND deleted_at IS NULL) AS comments_disabled,
                        (SELECT COUNT(*) FROM media_items WHERE downloads_enabled=0 AND deleted_at IS NULL) AS downloads_disabled,
                        (SELECT COUNT(*) FROM media_reports WHERE status='open') AS open_reports
                    """
                )
                row = (await cur.fetchone()) or {}
                return {
                    "db_time": row.get("db_time"),
                    "users": int(row.get("users") or 0),
                    "media_total": int(row.get("media_total") or 0),
                    "media_active": int(row.get("media_active") or 0),
                    "media_archived": int(row.get("media_archived") or 0),
                    "db_files": int(row.get("db_files") or 0),
                    "missing_db_files": int(row.get("missing_db_files") or 0),
                    "private_posts": int(row.get("private_posts") or 0),
                    "comments_disabled": int(row.get("comments_disabled") or 0),
                    "downloads_disabled": int(row.get("downloads_disabled") or 0),
                    "open_reports": int(row.get("open_reports") or 0),
                }

    def _decode_media(self, row: dict[str, Any]) -> dict[str, Any]:
        tags = row.get("tags")
        if isinstance(tags, str):
            try:
                row["tags"] = json.loads(tags)
            except json.JSONDecodeError:
                row["tags"] = []
        elif tags is None:
            row["tags"] = []
        row["liked_by_me"] = bool(row.get("liked_by_me"))
        row["bookmarked_by_me"] = bool(row.get("bookmarked_by_me"))
        row["is_adult"] = bool(row.get("is_adult"))
        row["adult_marked_by_user"] = bool(row.get("adult_marked_by_user"))
        row["adult_marked_by_ai"] = bool(row.get("adult_marked_by_ai"))
        for key in ("subcategory_id", "like_count", "comment_count", "views", "downloads", "file_size"):
            if isinstance(row.get(key), Decimal):
                row[key] = int(row[key])
        return row

    def _decode_user(self, user: dict[str, Any]) -> dict[str, Any]:
        raw_settings = user.get("user_settings")
        settings = dict(DEFAULT_USER_SETTINGS)
        if isinstance(raw_settings, str):
            try:
                settings.update(json.loads(raw_settings) or {})
            except json.JSONDecodeError:
                pass
        elif isinstance(raw_settings, dict):
            settings.update(raw_settings)
        user["user_settings"] = settings
        user["public_profile"] = bool(user.get("public_profile"))
        user["show_liked_count"] = bool(user.get("show_liked_count"))
        user["show_collections"] = bool(user.get("show_collections"))
        user["show_recent_uploads"] = bool(user.get("show_recent_uploads"))
        user["show_friends"] = bool(user.get("show_friends"))
        user["adult_content_consent"] = bool(user.get("adult_content_consent"))
        user["age_verified"] = bool(user.get("age_verified_at"))
        user["email_verified"] = bool(user.get("email_verified_at"))
        user["is_online"] = self._is_recently_seen(user.get("last_seen_at"))
        tags = user.get("featured_tags")
        if isinstance(tags, str):
            try:
                user["featured_tags"] = json.loads(tags) or []
            except json.JSONDecodeError:
                user["featured_tags"] = []
        elif tags is None:
            user["featured_tags"] = []
        return user

    @staticmethod
    def _is_recently_seen(value: Any) -> bool:
        if not value:
            return False
        try:
            from datetime import datetime, timezone

            if isinstance(value, str):
                seen = datetime.fromisoformat(value.replace("Z", "+00:00"))
            else:
                seen = value
            if seen.tzinfo is None:
                seen = seen.replace(tzinfo=timezone.utc)
            return (datetime.now(timezone.utc) - seen.astimezone(timezone.utc)).total_seconds() <= 180
        except Exception:
            return False

    def _decode_collection(self, row: dict[str, Any]) -> dict[str, Any]:
        row["is_public"] = bool(row.get("is_public"))
        row["cover_is_adult"] = bool(row.get("cover_is_adult"))
        for key in ("item_count",):
            if isinstance(row.get(key), Decimal):
                row[key] = int(row[key])
        return row

    def _decode_user_request(self, row: dict[str, Any]) -> dict[str, Any]:
        user = {
            "id": row.get("user_id"),
            "username": row.get("username"),
            "display_name": row.get("display_name"),
            "bio": row.get("bio") if row.get("public_profile") else None,
            "avatar_path": row.get("avatar_path") if row.get("public_profile") else None,
            "profile_color": row.get("profile_color"),
            "public_profile": row.get("public_profile"),
            "last_seen_at": row.get("last_seen_at"),
        }
        return {
            "id": row.get("id"),
            "requester_id": row.get("requester_id"),
            "addressee_id": row.get("addressee_id"),
            "status": row.get("status"),
            "created_at": row.get("created_at"),
            "responded_at": row.get("responded_at"),
            "user": self._decode_user(user),
        }

    def _clean_text(self, value: Any, max_length: int, required: bool = False, field_name: str = "Field") -> str | None:
        text = " ".join(str(value or "").strip().split())
        if not text:
            if required:
                raise ValueError(f"{field_name} is required.")
            return None
        return text[:max_length]

    def _clean_color(self, value: Any) -> str:
        color = str(value or "#37c9a7").strip()
        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
            raise ValueError("Color must be a hex value like #37c9a7.")
        return color.lower()

    def _clean_optional_url(self, value: Any, max_length: int = 300) -> str | None:
        text = self._clean_text(value, max_length)
        if not text:
            return None
        if not text.startswith(("http://", "https://")):
            raise ValueError("URL must start with http:// or https://.")
        return text

    def _clean_tags(self, values: Any) -> list[str]:
        clean = []
        if isinstance(values, str):
            iterable = re.split(r"[,#\s]+", values)
        else:
            iterable = list(values or [])
        for raw in iterable:
            tag = re.sub(r"[^A-Za-z0-9_.-]+", "", str(raw).strip())[:32]
            if tag and tag.lower() not in {existing.lower() for existing in clean}:
                clean.append(tag)
        return clean[:12]

    def _ai_training_dedupe_key(
        self,
        *,
        user_id: int,
        media_id: int | None,
        original_filename: Any,
        corrected_title: Any,
        corrected_category_name: Any,
        corrected_subcategory_name: Any,
        corrected_tags: list[str] | None,
        image_phash: Any,
        image_dhash: Any,
    ) -> str:
        payload = {
            "user_id": int(user_id),
            "media_id": int(media_id) if media_id is not None else None,
            "original_filename": self._clean_text(original_filename, 255),
            "corrected_title": self._clean_text(corrected_title, 160),
            "corrected_category_name": self._clean_text(corrected_category_name, 80),
            "corrected_subcategory_name": self._clean_text(corrected_subcategory_name, 80),
            "corrected_tags": [tag.lower() for tag in self._clean_tags(corrected_tags or [])],
            "image_phash": self._clean_text(image_phash, 16),
            "image_dhash": self._clean_text(image_dhash, 16),
        }
        return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
