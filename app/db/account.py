"""Registration, auth, profile/settings, avatar, password, and rate-limiting."""

import json
import time as _time
from datetime import date
from typing import Any

from . import pg_compat as aiomysql

from ..auth import hash_password, verify_password
from ..discord_webhook import is_valid_discord_webhook_url
from ._shared import DEFAULT_USER_SETTINGS, normalize_email, normalize_username, verification_token_hash

# TTL (seconds) for the in-memory user cache used by get_user().
_USER_CACHE_TTL = 30.0


class AccountMixin:
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
                    RETURNING id
                    """,
                    (username, display_name, hash_password(password), email, token_hash, token_hash),
                )
                new_id = (await cur.fetchone())["id"]
                return await self.get_user(new_id)


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
                           birthdate, age_verified_at, adult_content_consent, totp_enabled_at,
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
            "public_profile": bool(payload.get("public_profile", True)),
            "show_liked_count": bool(payload.get("show_liked_count", True)),
            "show_collections": bool(payload.get("show_collections", True)),
            "show_recent_uploads": bool(payload.get("show_recent_uploads", True)),
            "show_friends": bool(payload.get("show_friends", True)),
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
                    SET birthdate=%s, age_verified_at=CURRENT_TIMESTAMP, adult_content_consent=true
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
            elif key == "discord_webhook_url":
                text = str(value or "").strip()[:300]
                if text and not is_valid_discord_webhook_url(text):
                    raise ValueError("Discord webhook URL must start with https://discord.com/api/webhooks/.")
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
                    ON CONFLICT (user_id, sha256) DO UPDATE SET id=user_avatar_files.id, created_at=CURRENT_TIMESTAMP
                    RETURNING id
                    """,
                    (user_id, sha256, mime_type[:120], original_filename[:255], len(content), content),
                )
                file_id = (await cur.fetchone())["id"]
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
                    ((username or "")[:80] or None, ip_address[:64], bool(successful)),
                )


    async def count_recent_failed_auth(self, username: str | None, ip_address: str, minutes: int = 15) -> int:
        async with self.pool.acquire() as conn:
            async with conn.cursor(aiomysql.DictCursor) as cur:
                await cur.execute(
                    """
                    SELECT COUNT(*) AS n FROM auth_attempts
                    WHERE successful=false AND created_at >= (CURRENT_TIMESTAMP - make_interval(mins => %s))
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
                        SELECT event_count, EXTRACT(EPOCH FROM ((now() AT TIME ZONE 'utc') - window_start)) AS age_seconds
                        FROM api_rate_limits
                        WHERE bucket_key=%s
                        FOR UPDATE
                        """,
                        (bucket_key,),
                    )
                    row = await cur.fetchone()
                    if not row:
                        await cur.execute(
                            "INSERT INTO api_rate_limits (bucket_key, window_start, event_count) VALUES (%s, (now() AT TIME ZONE 'utc'), 1)",
                            (bucket_key,),
                        )
                        await conn.commit()
                        return True
                    age = int(row.get("age_seconds") or 0)
                    count = int(row.get("event_count") or 0)
                    if age >= window_seconds:
                        await cur.execute(
                            "UPDATE api_rate_limits SET window_start=(now() AT TIME ZONE 'utc'), event_count=1 WHERE bucket_key=%s",
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

