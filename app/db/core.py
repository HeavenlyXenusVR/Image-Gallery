"""Connection lifecycle, schema migrations, and category seeding."""

import asyncio
import json
from typing import Any

import aiomysql

from ..config import Settings
from ._shared import (
    AI_TRAINING_COLUMNS,
    DEFAULT_USER_SETTINGS,
    MEDIA_COLUMNS,
    USER_COLUMNS,
    log,
    mysql_error_code,
    quote_identifier,
)


class CoreMixin:
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
                await ensure_table(
                    "notifications",
                    """
                    CREATE TABLE notifications (
                      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      recipient_id BIGINT UNSIGNED NOT NULL,
                      actor_id BIGINT UNSIGNED NULL,
                      kind ENUM('follow','friend_request','friend_accept','comment','message') NOT NULL,
                      media_id BIGINT UNSIGNED NULL,
                      preview VARCHAR(160) NULL,
                      read_at TIMESTAMP NULL DEFAULT NULL,
                      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                      KEY idx_notifications_recipient (recipient_id, read_at, created_at),
                      CONSTRAINT fk_notifications_recipient FOREIGN KEY (recipient_id) REFERENCES users(id) ON DELETE CASCADE,
                      CONSTRAINT fk_notifications_actor FOREIGN KEY (actor_id) REFERENCES users(id) ON DELETE SET NULL,
                      CONSTRAINT fk_notifications_media FOREIGN KEY (media_id) REFERENCES media_items(id) ON DELETE CASCADE
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

