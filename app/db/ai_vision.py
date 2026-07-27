"""AI vision training example CRUD and AI-learning candidate queries."""

import hashlib
import json
from typing import Any

from . import pg_compat as aiomysql

from ._shared import MEDIA_CATEGORY_JOIN, MEDIA_CATEGORY_SELECT


class AIVisionMixin:
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
                            bool(corrected.get("is_adult") or corrected.get("corrected_is_adult")),
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
                        RETURNING id
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
                            bool(corrected.get("is_adult") or corrected.get("corrected_is_adult")),
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
                    training_id = int((await cur.fetchone())["id"])
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
                          AND COALESCE(s.updated_at, s.last_scanned_at) < (CURRENT_TIMESTAMP - make_interval(mins => %s))
                        )
                        OR s.last_scanned_at < (CURRENT_TIMESTAMP - make_interval(mins => %s))
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
                    ON CONFLICT (media_id) DO UPDATE SET
                      user_id=EXCLUDED.user_id,
                      last_scanned_at=CURRENT_TIMESTAMP,
                      last_scan_status=EXCLUDED.last_scan_status,
                      last_scan_source=EXCLUDED.last_scan_source,
                      last_scan_confidence=EXCLUDED.last_scan_confidence,
                      last_scan_title=EXCLUDED.last_scan_title,
                      last_scan_error=EXCLUDED.last_scan_error,
                      last_learned_at=CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE ai_media_learning_state.last_learned_at END,
                      last_autofill_at=CASE WHEN %s=1 THEN CURRENT_TIMESTAMP ELSE ai_media_learning_state.last_autofill_at END
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

