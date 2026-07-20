#!/usr/bin/env python3
"""One-off backfill: pre-warm a video quality transcode cache for every
existing video on the site, instead of waiting for each to warm lazily on
its first view (see _ensure_video_quality_cache / _queue_video_quality_warmup
in app/routers/media_streaming.py).

Runs sequentially (the live container is capped at 1 CPU, so concurrent
ffmpeg processes would just contend with each other and with real traffic).

Run inside the live container, where the DB/env/ffmpeg are already set up:

    docker exec web_image_gallery python3 scripts/prewarm_video_quality.py [quality]
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from app import main
from app.routers.media_streaming import _ensure_video_quality_cache

BATCH_SIZE = 8


async def run(quality: str) -> None:
    await main.db.connect()
    warmed = 0
    skipped = 0
    failed = 0
    total = 0
    before_id: int | None = None
    try:
        while True:
            rows = await main.db.list_video_thumb_candidates(limit=BATCH_SIZE, before_media_id=before_id)
            if not rows:
                break
            for item in rows:
                media_id = int(item["id"])
                total += 1
                title = str(item.get("title") or "untitled")[:60]
                try:
                    did_warm = await _ensure_video_quality_cache(media_id, item=item, quality=quality)
                except Exception as exc:
                    failed += 1
                    print(f"[{media_id}] FAILED ({title}): {exc}", flush=True)
                    continue
                if did_warm:
                    warmed += 1
                    print(f"[{media_id}] warmed ({title})", flush=True)
                else:
                    skipped += 1
                    print(f"[{media_id}] skipped/already cached ({title})", flush=True)
            before_id = int(rows[-1]["id"])
    finally:
        main.db.pool.close()
        await main.db.pool.wait_closed()
    print(f"Done. total={total} warmed={warmed} skipped={skipped} failed={failed}", flush=True)


if __name__ == "__main__":
    requested_quality = sys.argv[1] if len(sys.argv) > 1 else "720p"
    asyncio.run(run(requested_quality))
