"""Shared row-decoding and text-cleaning helpers reused across every other mixin. _decode_media/_decode_user/_clean_text/_clean_tags in particular have call sites spanning Media, Feed, Collections, public-profile, and AI-learning domains — never duplicate these, import from here."""

import json
import re
from decimal import Decimal
from typing import Any

import aiomysql

from ._shared import DEFAULT_USER_SETTINGS


class HelpersMixin:
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

