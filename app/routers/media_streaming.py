"""Byte-serving routes: thumbnails, file/preview/download streaming, avatar serving, and the ffmpeg-backed video transcode/thumbnail-warm machinery behind them."""

import asyncio
import hashlib
import hmac
import html
import io
import mimetypes
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, AsyncGenerator
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import FileResponse, StreamingResponse

import app.main as main
from ._shared import (
    MAX_IMAGE_PIXELS,
    _auth_optional,
    _etag_matches,
    _legacy_upload_path,
    _media_access_token,
    _user_id,
    _viewer_can_open_adult,
)

VIDEO_THUMB_WARM_INTERVAL_SECONDS = max(45.0, float(os.getenv("GALLERY_VIDEO_THUMB_WARM_INTERVAL_SECONDS", "240") or "240"))
VIDEO_THUMB_WARM_BATCH_SIZE = max(1, min(24, int(os.getenv("GALLERY_VIDEO_THUMB_WARM_BATCH_SIZE", "6") or "6")))
VIDEO_THUMB_WARM_WIDTHS = tuple(sorted({420, 640}))
PREVIEW_CACHE_MAX_ITEMS = 256

_NIXOS_FFMPEG = "/run/current-system/sw/bin/ffmpeg"
FFMPEG_BIN: str = (
    _NIXOS_FFMPEG
    if os.path.isfile(_NIXOS_FFMPEG) and os.access(_NIXOS_FFMPEG, os.X_OK)
    else (shutil.which("ffmpeg") or "ffmpeg")
)

THUMB_CACHE_DIR = main.settings.uploads_dir / "_thumb_cache"
THUMB_CACHE_DIR.mkdir(parents=True, exist_ok=True)
VIDEO_CACHE_DIR = main.settings.uploads_dir / "_video_cache"
VIDEO_CACHE_DIR.mkdir(parents=True, exist_ok=True)
VIDEO_QUALITY_PROFILES = {
    "1080p": {"max_width": 1920, "crf": 22, "audio_bitrate": "320k", "preset": "fast", "profile": "high"},
    "720p":  {"max_width": 1280, "crf": 25, "audio_bitrate": "256k", "preset": "fast", "profile": "high"},
    "480p":  {"max_width": 854,  "crf": 28, "audio_bitrate": "192k", "preset": "fast", "profile": "high"},
    "144p":  {"max_width": 256,  "crf": 36, "audio_bitrate": "64k",  "preset": "ultrafast", "profile": "baseline"},
}
_BROWSER_SAFE_VIDEO_MIME: frozenset[str] = frozenset({"video/mp4", "video/webm", "video/ogg"})

router = APIRouter()


def _download_filename(value: str | None, fallback: str = "download") -> str:
    filename = (Path(str(value or fallback)).name or fallback).replace("\r", "").replace("\n", "").strip()
    filename = filename[:180] or fallback
    return f"attachment; filename*=UTF-8''{quote(filename)}"


def _valid_media_access_token(media_id: int, token: str | None) -> bool:
    return bool(token) and hmac.compare_digest(str(token), _media_access_token(media_id))


def _normalized_preview_size(size: str | None) -> str:
    normalized = str(size or "card").strip().lower()
    return normalized if normalized in {"mini", "card", "detail"} else "card"


def _preview_options(size: str | None) -> tuple[str, int, int]:
    normalized = _normalized_preview_size(size)
    if normalized == "mini":
        return normalized, 360, 78
    if normalized == "detail":
        return normalized, 1920, 92
    return normalized, 880, 86


def _preview_etag(digest: str, size: str | None) -> str:
    return f"\"{digest}:{_normalized_preview_size(size)}\""


def _cached_preview(cache_key: tuple[str, str]) -> tuple[bytes, str] | None:
    cached = main._preview_cache.get(cache_key)
    if cached is None:
        return None
    main._preview_cache.move_to_end(cache_key)
    return cached


def _store_preview(cache_key: tuple[str, str], payload: tuple[bytes, str]) -> tuple[bytes, str]:
    main._preview_cache[cache_key] = payload
    main._preview_cache.move_to_end(cache_key)
    while len(main._preview_cache) > PREVIEW_CACHE_MAX_ITEMS:
        main._preview_cache.popitem(last=False)
    return payload


def _render_image_preview(content: bytes, mime_type: str | None, digest: str, *, size: str | None) -> tuple[bytes, str]:
    variant, max_edge, quality = _preview_options(size)
    cache_key = (digest, variant)
    cached = _cached_preview(cache_key)
    if cached is not None:
        return cached

    try:
        from PIL import Image, ImageOps, ImageSequence

        Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS
        resampling = getattr(Image, "Resampling", Image)
        with Image.open(io.BytesIO(content)) as image:
            frame = next(ImageSequence.Iterator(image), image)
            preview = ImageOps.exif_transpose(frame)
            has_alpha = "A" in preview.getbands()
            preview = preview.convert("RGBA" if has_alpha else "RGB")
            if max(preview.size) > max_edge:
                preview.thumbnail((max_edge, max_edge), resample=resampling.LANCZOS)
            output = io.BytesIO()
            try:
                preview.save(output, format="WEBP", quality=quality, method=6)
                preview_bytes = output.getvalue()
                if variant == "detail" and len(content) <= len(preview_bytes) and len(content) <= 2_500_000 and (mime_type or "").startswith("image/"):
                    return _store_preview(cache_key, (content, mime_type or "image/jpeg"))
                return _store_preview(cache_key, (preview_bytes, "image/webp"))
            except OSError:
                output = io.BytesIO()
                preview.convert("RGB").save(output, format="JPEG", quality=min(quality + 2, 94), optimize=True)
                preview_bytes = output.getvalue()
                return _store_preview(cache_key, (preview_bytes, "image/jpeg"))
    except Exception:
        return _store_preview(cache_key, (content, mime_type or "application/octet-stream"))


def _render_video_placeholder_thumb(item: dict[str, Any], width: int) -> tuple[bytes, str]:
    cache_key = (f"video:{item.get('id')}:{item.get('updated_at') or item.get('created_at')}", f"w{width}")
    cached = _cached_preview(cache_key)
    if cached is not None:
        return cached
    try:
        from PIL import Image, ImageDraw, ImageFilter

        height = max(120, int(width * 9 / 16))
        base = Image.new("RGB", (width, height), "#18212d")
        draw = ImageDraw.Draw(base)
        for y in range(height):
            shade = int(24 + (y / max(1, height)) * 34)
            draw.line([(0, y), (width, y)], fill=(shade, min(70, shade + 18), min(92, shade + 30)))
        for x in range(-width, width * 2, max(24, width // 9)):
            draw.line([(x, 0), (x + width // 2, height)], fill=(72, 94, 114), width=max(2, width // 120))
        base = base.filter(ImageFilter.GaussianBlur(radius=max(6, width // 80)))
        overlay = Image.new("RGBA", (width, height), (0, 0, 0, 74))
        base = Image.alpha_composite(base.convert("RGBA"), overlay)
        draw = ImageDraw.Draw(base)
        cx, cy = width // 2, height // 2
        radius = max(28, width // 13)
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), outline=(255, 255, 255, 150), width=max(2, width // 180))
        draw.polygon(
            [(cx - radius // 3, cy - radius // 2), (cx - radius // 3, cy + radius // 2), (cx + radius // 2, cy)],
            fill=(255, 255, 255, 170),
        )
        output = io.BytesIO()
        base.convert("RGB").save(output, format="WEBP", quality=84, method=5)
        return _store_preview(cache_key, (output.getvalue(), "image/webp"))
    except Exception:
        svg = (
            f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{max(120, int(width * 9 / 16))}' viewBox='0 0 {width} {max(120, int(width * 9 / 16))}'>"
            "<rect width='100%' height='100%' fill='#18212d'/><circle cx='50%' cy='50%' r='48' fill='none' stroke='rgba(255,255,255,.62)' stroke-width='4'/>"
            "<path d='M48% 42%v16l14-8z' fill='rgba(255,255,255,.72)'/></svg>"
        ).encode("utf-8")
        return _store_preview(cache_key, (svg, "image/svg+xml"))


def _render_video_frame_thumb(source_path: Path, cache_path: Path, width: int) -> bool:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = cache_path.with_suffix(".tmp.webp")
    if tmp_path.exists():
        tmp_path.unlink()
    command = [
        FFMPEG_BIN,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        "0.35",
        "-i",
        str(source_path),
        "-frames:v",
        "1",
        "-vf",
        f"scale='min({int(width)},iw)':-2:flags=lanczos",
        "-c:v",
        "libwebp",
        "-compression_level",
        "5",
        "-quality",
        "88",
        str(tmp_path),
    ]
    try:
        subprocess.run(command, check=True, timeout=60, capture_output=True, text=True)
        if tmp_path.exists() and tmp_path.stat().st_size > 0:
            tmp_path.replace(cache_path)
            return True
    except subprocess.CalledProcessError as exc:
        main.logger.debug("Video thumbnail ffmpeg error for %s: %s", source_path, (exc.stderr or "").strip()[-500:])
    except subprocess.TimeoutExpired:
        main.logger.debug("Video thumbnail ffmpeg timed out for %s", source_path)
    except FileNotFoundError:
        main.logger.warning("ffmpeg not found — cannot generate video thumbnails")
    except Exception:
        main.logger.debug("Video thumbnail extraction failed for %s", source_path, exc_info=True)
    finally:
        try:
            if tmp_path.exists():
                tmp_path.unlink()
        except Exception:
            pass
    return False


def _fallback_avatar_svg(user_id: int) -> str:
    initials = f"U{int(user_id)}"[:3]
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">'
        '<rect width="128" height="128" rx="64" fill="#202832"/>'
        '<text x="64" y="74" text-anchor="middle" font-family="Inter,Arial,sans-serif" '
        'font-size="34" font-weight="800" fill="#9ba8b7">' + html.escape(initials) + '</text></svg>'
    )


async def _video_thumb_warm_loop() -> None:
    await asyncio.sleep(18)
    cursor: int | None = None
    while True:
        try:
            scanned, cursor = await _run_video_thumb_warm_pass(cursor)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            main.logger.exception("Video thumbnail warm loop paused after failure: %s", exc)
            scanned, cursor = 0, None
        if not scanned:
            cursor = None
            await asyncio.sleep(VIDEO_THUMB_WARM_INTERVAL_SECONDS)
        else:
            await asyncio.sleep(2.0)


@router.get("/api/uploads/{path:path}", name="serve_legacy_upload")
async def serve_legacy_upload(path: str) -> FileResponse:
    legacy = _legacy_upload_path(path)
    if not legacy:
        raise HTTPException(status_code=404, detail="Legacy upload not found.")
    media_type = mimetypes.guess_type(str(legacy))[0] or "application/octet-stream"
    return FileResponse(legacy, media_type=media_type, headers={"Cache-Control": "public, max-age=86400"})


async def _adult_file_allowed(request: Request, media_id: int, access: str | None) -> bool:
    # Browser <img>/<video> requests do not carry Authorization headers.
    # Age-verified API responses include this signed token in adult media URLs.
    return _valid_media_access_token(media_id, access) or await _viewer_can_open_adult(request)


def _parse_range_header(range_header: str | None, file_size: int) -> tuple[int, int] | None:
    if not range_header or not range_header.startswith("bytes=") or file_size <= 0:
        return None
    first_range = range_header[6:].split(",", 1)[0].strip()
    if "-" not in first_range:
        return None
    start_raw, end_raw = first_range.split("-", 1)
    try:
        if start_raw == "":
            suffix = int(end_raw)
            if suffix <= 0:
                return None
            start = max(0, file_size - suffix)
            end = file_size - 1
        else:
            start = int(start_raw)
            end = int(end_raw) if end_raw else file_size - 1
    except ValueError:
        return None
    if start < 0 or start >= file_size or end < start:
        raise HTTPException(
            status_code=416,
            detail="Requested range is not satisfiable.",
            headers={"Content-Range": f"bytes */{file_size}"},
        )
    return start, min(end, file_size - 1)


def _normalize_video_quality(value: str | None) -> str:
    quality = str(value or "high").strip().lower()
    # Map legacy names so old cached links and API calls still work
    _LEGACY = {"medium": "720p", "low": "480p", "high": "original", "original": "original"}
    quality = _LEGACY.get(quality, quality)
    return quality if quality in {"original", "1080p", "720p", "480p", "144p"} else "original"


async def _stream_transcode_and_cache(
    source: Path,
    cache_file: Path,
    profile: dict[str, Any],
    tmp_dir: "tempfile.TemporaryDirectory[str] | None",
    stream_key: tuple[int, str],
) -> "AsyncGenerator[bytes, None]":
    """
    Stream a fragmented MP4 transcode directly from ffmpeg stdout while
    simultaneously writing the output to `cache_file`.  This lets the browser
    start playing within a second instead of waiting for the full transcode.
    Subsequent requests for the same quality hit the cache and get FileResponse
    (which supports HTTP Range / seek).
    """
    scale_filter = f"scale='min({int(profile['max_width'])},iw)':-2:flags=lanczos"
    command = [
        FFMPEG_BIN,
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(source),
        "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", scale_filter,
        "-c:v", "libx264",
        "-preset", str(profile.get("preset") or "ultrafast"),
        "-crf", str(int(profile["crf"])),
        "-profile:v", str(profile.get("profile") or "high"),
        "-level", "4.1",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", str(profile["audio_bitrate"]),
        "-movflags", "frag_keyframe+default_base_moof",
        "-f", "mp4", "pipe:1",
    ]
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_cache = cache_file.with_suffix(".stream.tmp")
    try:
        tmp_cache.unlink(missing_ok=True)
    except Exception:
        pass

    # Initialise stderr_task to None so the finally block is safe even if
    # create_subprocess_exec raises before the variable is assigned.
    stderr_task: "asyncio.Task[bytes] | None" = None
    process = await asyncio.create_subprocess_exec(
        *command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    # Drain stderr concurrently so it never blocks stdout.
    stderr_task = asyncio.create_task(process.stderr.read(4096))
    succeeded = False
    try:
        with open(tmp_cache, "wb") as fh:
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                fh.write(chunk)
                yield chunk
        await process.wait()
        succeeded = process.returncode == 0
        if succeeded:
            tmp_cache.replace(cache_file)
        else:
            stderr_bytes = await stderr_task if not stderr_task.done() else stderr_task.result()
            err_tail = stderr_bytes.decode(errors="replace")[-400:]
            main.logger.error("Live transcode rc=%s for cache_file=%s: %s", process.returncode, cache_file, err_tail)
    except Exception:
        if process.returncode is None:
            try:
                process.kill()
            except Exception:
                pass
        main.logger.exception("Live transcode stream interrupted, cache_file=%s", cache_file)
        raise
    finally:
        main._video_active_streams.discard(stream_key)
        if not succeeded:
            try:
                tmp_cache.unlink(missing_ok=True)
            except Exception:
                pass
        if tmp_dir is not None:
            try:
                tmp_dir.cleanup()
            except Exception:
                pass
        if stderr_task is not None and not stderr_task.done():
            stderr_task.cancel()


def _needs_video_transcode(mime_type: str | None) -> bool:
    """Return True when the MIME type is a video that browsers cannot play natively."""
    if not mime_type:
        return False
    return mime_type.startswith("video/") and mime_type.lower() not in _BROWSER_SAFE_VIDEO_MIME


def _stdin_transcode_compatible(header: bytes) -> bool:
    """Return True when the file's container can be demuxed from non-seekable stdin.

    * WebM/MKV: starts with EBML magic (0x1A 0x45 0xDF 0xA3) — always streamable.
    * MP4/MOV/M4V: first box is 'ftyp' or 'moov' — fast-start layout, seekable
      from the start.  Files whose first box is 'mdat' have moov at the end and
      require a seekable (file-backed) input.
    """
    if len(header) < 4:
        return False
    if header[:4] == b"\x1a\x45\xdf\xa3":
        return True
    if len(header) >= 8 and header[4:8] in (b"ftyp", b"moov"):
        return True
    return False


async def _stdin_transcode_and_cache(
    file_id: int,
    cache_file: Path,
    profile: dict[str, Any],
    stream_key: tuple[int, str],
):
    """Transcode a DB-backed video by piping chunks directly to ffmpeg stdin.

    Sending ffmpeg input via stdin means the transcode starts immediately with
    no temp-file round-trip.  ffmpeg produces its first output chunk within a
    few seconds (after the first keyframe interval), so HTTP response headers
    and the first video bytes reach the browser almost immediately.

    Only call this for containers that don't require random-access seeking
    (WebM, MKV, fast-start MP4).  Use _db_backed_transcode_and_cache for the
    router that detects the right path automatically.
    """
    scale_filter = f"scale='min({int(profile['max_width'])},iw)':-2:flags=lanczos"
    command = [
        FFMPEG_BIN,
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", "pipe:0",
        "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", scale_filter,
        "-c:v", "libx264",
        "-preset", str(profile.get("preset") or "ultrafast"),
        "-crf", str(int(profile["crf"])),
        "-profile:v", str(profile.get("profile") or "high"),
        "-level", "4.1",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", str(profile["audio_bitrate"]),
        "-movflags", "frag_keyframe+default_base_moof",
        "-f", "mp4", "pipe:1",
    ]
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    tmp_cache = cache_file.with_suffix(".stream.tmp")
    try:
        tmp_cache.unlink(missing_ok=True)
    except Exception:
        pass

    stderr_task: asyncio.Task | None = None
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stderr_task = asyncio.create_task(process.stderr.read(8192))

    async def _feed_stdin() -> None:
        try:
            async for chunk in main.db.stream_media_file_content(file_id):
                try:
                    process.stdin.write(chunk)
                    await process.stdin.drain()
                except (BrokenPipeError, ConnectionResetError):
                    break
        except Exception:
            main.logger.debug("stdin feed interrupted for stream_key=%s", stream_key, exc_info=True)
        finally:
            try:
                process.stdin.close()
            except Exception:
                pass

    stdin_task = asyncio.create_task(_feed_stdin())
    succeeded = False
    try:
        with open(tmp_cache, "wb") as fh:
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                fh.write(chunk)
                yield chunk
        await process.wait()
        succeeded = process.returncode == 0
        if succeeded:
            tmp_cache.replace(cache_file)
        else:
            if stderr_task.done():
                err = stderr_task.result()
            else:
                err = b""
            main.logger.error(
                "stdin transcode rc=%s cache_file=%s: %s",
                process.returncode,
                cache_file,
                err.decode(errors="replace")[-400:],
            )
    except Exception:
        if process.returncode is None:
            try:
                process.kill()
            except Exception:
                pass
        main.logger.exception("stdin transcode stream interrupted cache_file=%s", cache_file)
        raise
    finally:
        stdin_task.cancel()
        main._video_active_streams.discard(stream_key)
        if not succeeded:
            try:
                tmp_cache.unlink(missing_ok=True)
            except Exception:
                pass
        if stderr_task is not None and not stderr_task.done():
            stderr_task.cancel()


async def _db_backed_transcode_and_cache(
    file_id: int,
    original_filename: str,
    cache_file: Path,
    profile: dict[str, Any],
    stream_key: tuple[int, str],
):
    """Router for DB-backed live transcodes.

    Probes the first 8 bytes of the source file to decide the transcode path:

    * Fast-start MP4 / MOV (moov/ftyp at offset 4) and WebM/MKV (EBML magic):
      Use stdin piping.  ffmpeg starts immediately and yields the first fragment
      within ~2 s, so TTFB is fast and the browser shows a responsive buffering
      state.

    * All other layouts (moov-at-end MP4, unknown containers):
      Fall back to writing a temp file first, then running ffmpeg.  TTFB is
      slower (full DB read + disk write before first output byte) but the
      connection stays alive and the browser eventually plays the video.
    """
    header = await main.db.get_file_header_bytes(file_id, size=8)
    if _stdin_transcode_compatible(header):
        async for data in _stdin_transcode_and_cache(file_id, cache_file, profile, stream_key):
            yield data
        return

    # Temp-file fallback for moov-at-end and unknown containers.
    tmp_dir_obj: tempfile.TemporaryDirectory | None = None
    entered_stream_transcode = False
    try:
        tmp_dir_obj = tempfile.TemporaryDirectory(prefix="gallery-video-")
        safe_name = Path(original_filename or "source.video").name or "source.video"
        source_path = Path(tmp_dir_obj.name) / safe_name
        with open(source_path, "wb") as fh:
            async for chunk in main.db.stream_media_file_content(file_id):
                fh.write(chunk)
        if not source_path.exists() or source_path.stat().st_size == 0:
            return
        entered_stream_transcode = True
        async for data in main._stream_transcode_and_cache(source_path, cache_file, profile, tmp_dir_obj, stream_key):
            yield data
    except Exception:
        main.logger.exception("DB-backed transcode failed for stream_key=%s", stream_key)
        raise
    finally:
        if not entered_stream_transcode:
            # _stream_transcode_and_cache owns cleanup once entered; only clean
            # up here if we never reached it.
            main._video_active_streams.discard(stream_key)
            if tmp_dir_obj is not None:
                try:
                    tmp_dir_obj.cleanup()
                except Exception:
                    pass


async def _ensure_video_quality_cache(
    media_id: int,
    *,
    item: dict[str, Any] | None = None,
    quality: str = "720p",
) -> bool:
    """Runs the same live-transcode-and-cache path `_video_variant_response`
    uses for an interactive request, but to completion in the background with
    no client to stream to. Lets a real playback request for this quality hit
    the cache (a plain, Range-capable `FileResponse`) instead of triggering a
    live transcode that has to outrun the requester's own timeout — which for
    a moov-at-end source file (the slow temp-file-fallback path in
    `_db_backed_transcode_and_cache`) it often can't.
    """
    quality = _normalize_video_quality(quality)
    profile = VIDEO_QUALITY_PROFILES.get(quality)
    if not profile:
        return False

    item = item or await main.db.get_media(media_id, None)
    if not item or str(item.get("media_kind") or "").lower() != "video":
        return False

    file_info = await main.db.get_media_file_info(media_id)
    if not file_info:
        return False

    # Matches _video_variant_response's own guard — large DB-backed files skip
    # the transcode entirely rather than risk the container's memory limit.
    _TRANSCODE_SIZE_LIMIT = 500 * 1024 * 1024
    if int(file_info.get("file_size") or 0) > _TRANSCODE_SIZE_LIMIT:
        return False

    digest = str(file_info.get("sha256") or item.get("content_sha256") or item.get("updated_at") or item.get("created_at") or media_id)
    cache_file = main.VIDEO_CACHE_DIR / f"{int(media_id)}_{quality}_{hashlib.sha256(digest.encode('utf-8')).hexdigest()[:16]}.mp4"
    if cache_file.exists() and cache_file.stat().st_size > 0:
        return False

    # An interactive request for the same media+quality is already doing this
    # transcode (or another warm-up beat us to it) — nothing to do here.
    stream_key = (int(media_id), quality)
    if stream_key in main._video_active_streams:
        return False
    main._video_active_streams.add(stream_key)
    try:
        safe_name = Path(str(file_info.get("original_filename") or f"{media_id}.video")).name or f"{media_id}.video"
        # _db_backed_transcode_and_cache owns discarding stream_key from
        # main._video_active_streams in every one of its own cleanup paths —
        # draining it here (there's no client to stream the yielded chunks
        # to) is enough to populate cache_file.
        async for _chunk in _db_backed_transcode_and_cache(int(file_info["id"]), safe_name, cache_file, profile, stream_key):
            pass
    except Exception:
        main.logger.debug("Video quality pre-warm failed for media_id=%s quality=%s", media_id, quality, exc_info=True)
        return False
    return cache_file.exists() and cache_file.stat().st_size > 0


def _queue_video_quality_warmup(
    media_id: int,
    *,
    item: dict[str, Any] | None = None,
    quality: str = "720p",
) -> asyncio.Task[Any]:
    normalized_quality = _normalize_video_quality(quality)
    key = (int(media_id), normalized_quality)
    existing = main._video_quality_warm_tasks.get(key)
    if existing and not existing.done():
        return existing

    async def _runner() -> None:
        try:
            warmed = await _ensure_video_quality_cache(int(media_id), item=item, quality=normalized_quality)
            if warmed:
                main.logger.info("Warmed %s video quality cache for media %s.", normalized_quality, media_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            main.logger.debug("Video quality warmup failed for media %s.", media_id, exc_info=True)
        finally:
            main._video_quality_warm_tasks.pop(key, None)

    task = asyncio.create_task(_runner())
    main._video_quality_warm_tasks[key] = task
    return task


async def _video_variant_response(media_id: int, item: dict[str, Any], file_info: dict[str, Any] | None, legacy: Path | None, quality: str) -> Response | None:
    quality = _normalize_video_quality(quality)
    profile = VIDEO_QUALITY_PROFILES.get(quality)
    if not profile or item.get("media_kind") != "video":
        return None
    digest = str((file_info or {}).get("sha256") or item.get("content_sha256") or item.get("updated_at") or item.get("created_at") or media_id)
    cache_file = main.VIDEO_CACHE_DIR / f"{int(media_id)}_{quality}_{hashlib.sha256(digest.encode('utf-8')).hexdigest()[:16]}.mp4"

    # Cache hit — FileResponse supports HTTP Range so the browser can seek.
    if cache_file.exists() and cache_file.stat().st_size > 0:
        return FileResponse(
            cache_file,
            media_type="video/mp4",
            headers={
                "Cache-Control": "public, max-age=86400",
                "X-Video-Quality": quality,
                "X-Video-Codec": "h264/aac",
            },
        )

    # Large DB-backed files: skip transcode entirely and let the caller fall through
    # to range-based streaming of the original.  Loading hundreds of MB into memory
    # to write a temp file before ffmpeg can start would saturate the container's
    # memory limit and stall the entire event loop.
    _TRANSCODE_SIZE_LIMIT = 500 * 1024 * 1024  # 500 MB
    if file_info and int(file_info.get("file_size") or 0) > _TRANSCODE_SIZE_LIMIT:
        main.logger.info(
            "Skipping transcode for large DB-backed file media_id=%s size=%s quality=%s",
            media_id,
            file_info.get("file_size"),
            quality,
        )
        return None

    # Cache miss — if a transcode is already running for this (media_id, quality),
    # wait for it to finish rather than spawning a second competing ffmpeg process.
    # Both would write to the same .stream.tmp file, corrupting the output.
    stream_key = (int(media_id), quality)
    if stream_key in main._video_active_streams:
        for _ in range(60):  # poll up to 30 s (60 × 0.5 s)
            await asyncio.sleep(0.5)
            if cache_file.exists() and cache_file.stat().st_size > 0:
                return FileResponse(
                    cache_file,
                    media_type="video/mp4",
                    headers={
                        "Cache-Control": "public, max-age=86400",
                        "X-Video-Quality": quality,
                        "X-Video-Codec": "h264/aac",
                    },
                )
        # Transcode is stalled or very slow — fall through to serve the original.
        return None

    # Resolve the source file for the transcode.
    if file_info:
        # For DB-backed files, start streaming immediately so HTTP headers reach
        # the browser before the temp-file write begins.  Waiting for the full
        # DB read to complete before returning the response caused the connection
        # to appear stalled (no headers at all) for the entire write duration,
        # which looks like a timeout for large videos (50-300 MB).
        main._video_active_streams.add(stream_key)
        safe_name = (Path(str(file_info.get("original_filename") or f"{media_id}.video")).name or f"{media_id}.video")
        return StreamingResponse(
            _db_backed_transcode_and_cache(
                int(file_info["id"]),
                safe_name,
                cache_file,
                profile,
                stream_key,
            ),
            media_type="video/mp4",
            headers={
                "Cache-Control": "no-store",
                "Accept-Ranges": "none",
                "X-Video-Quality": quality,
                "X-Video-Codec": "h264/aac",
                "X-Transcode": "live",
            },
        )
    elif legacy:
        pass
    else:
        return None

    main._video_active_streams.add(stream_key)
    return StreamingResponse(
        main._stream_transcode_and_cache(legacy, cache_file, profile, None, stream_key),
        media_type="video/mp4",
        headers={
            "Cache-Control": "no-store",
            "Accept-Ranges": "none",
            "X-Video-Quality": quality,
            "X-Video-Codec": "h264/aac",
            "X-Transcode": "live",
        },
    )


async def _serve_media_content(media_id: int, request: Request, *, access: str | None, as_download: bool, quality: str | None = None) -> Response:
    auth = _auth_optional(request)
    viewer_id = _user_id(auth)
    item = await main.db.get_media(media_id, viewer_id)
    if not item or item.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Media not found.")
    owner = int(item.get("user_id")) == int(viewer_id or 0)
    if item.get("visibility") == "private" and not owner:
        raise HTTPException(status_code=403, detail="This post is private.")
    if as_download and not item.get("downloads_enabled", True) and not owner:
        raise HTTPException(status_code=403, detail="Downloads are disabled for this post.")
    if item.get("is_adult"):
        adult_ok = await _adult_file_allowed(request, media_id, access)
        if not adult_ok:
            raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")

    requested_quality = _normalize_video_quality(quality)
    file_info = await main.db.get_media_file_info(media_id)
    if file_info:
        # If the stored MIME type is browser-incompatible (e.g. MKV, MOV, AVI)
        # and the caller asked for the original/high quality, redirect through the
        # medium transcode profile so Firefox and Safari can play it.
        effective_quality = requested_quality
        if not as_download and _needs_video_transcode(file_info.get("mime_type")) and effective_quality not in VIDEO_QUALITY_PROFILES:
            effective_quality = "720p"
        variant = None if as_download else await _video_variant_response(media_id, item, file_info, None, effective_quality)
        if variant:
            return variant
        file_size = int(file_info.get("file_size") or 0) or int(file_info.get("inline_size") or 0)
        requested_range = None if as_download else _parse_range_header(request.headers.get("range"), file_size)
        headers = {
            "X-Content-SHA256": str(file_info.get("sha256") or ""),
            "Accept-Ranges": "bytes",
        }
        if file_size > 0:
            headers["Content-Length"] = str(file_size)
        if as_download:
            await main.db.increment_counter(media_id, "downloads")
            headers["Content-Disposition"] = _download_filename(file_info.get("original_filename"))
            headers["Cache-Control"] = "private, max-age=0, no-cache"
        else:
            headers["Cache-Control"] = "public, max-age=86400"
        if requested_range:
            start, end = requested_range
            headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
            headers["Content-Length"] = str(end - start + 1)
            return StreamingResponse(
                main.db.stream_media_file_content(int(file_info["id"]), start=start, end=end),
                status_code=206,
                media_type=file_info.get("mime_type") or "application/octet-stream",
                headers=headers,
            )
        return StreamingResponse(
            main.db.stream_media_file_content(int(file_info["id"])),
            media_type=file_info.get("mime_type") or "application/octet-stream",
            headers=headers,
        )

    legacy = _legacy_upload_path(item.get("storage_path"))
    if legacy:
        # Same browser-compatibility check for legacy on-disk files.
        legacy_mime = item.get("mime_type") or mimetypes.guess_type(str(legacy))[0]
        legacy_quality = requested_quality
        if not as_download and _needs_video_transcode(legacy_mime) and legacy_quality not in VIDEO_QUALITY_PROFILES:
            legacy_quality = "720p"
        variant = None if as_download else await _video_variant_response(media_id, item, None, legacy, legacy_quality)
        if variant:
            return variant
        if as_download:
            await main.db.increment_counter(media_id, "downloads")
        return FileResponse(
            legacy,
            media_type=item.get("mime_type") or mimetypes.guess_type(str(legacy))[0] or "application/octet-stream",
            filename=None,
            headers=(
                {"Cache-Control": "public, max-age=86400"}
                if not as_download
                else {"Content-Disposition": _download_filename(item.get("original_filename"))}
            ),
        )

    raise HTTPException(
        status_code=404,
        detail="File is missing. Re-upload this post once so it can be saved into the new DB-backed file store.",
    )




# Resolve the ffmpeg binary once at startup.  On NixOS, ffmpeg lives under
# /run/current-system/sw/bin and is NOT on the default PATH used by the
# FastAPI process.  We try the NixOS well-known path first, then fall back to
# whatever `which` finds, and finally to the bare name so the error message
# from subprocess is at least meaningful.


def _video_thumb_cache_file(media_id: int, width: int) -> Path:
    # Shard into sub-directories by the last two hex digits of the media_id to avoid
    # huge flat directories when there are many videos.
    shard = f"{int(media_id) % 256:02x}"
    return main.THUMB_CACHE_DIR / shard / f"{int(media_id)}_{int(width)}.webp"


def _normalize_video_thumb_widths(widths: tuple[int, ...] | list[int] | None = None) -> tuple[int, ...]:
    raw = widths or VIDEO_THUMB_WARM_WIDTHS
    cleaned = sorted({max(160, min(int(width or 0), 1440)) for width in raw if int(width or 0) > 0})
    return tuple(cleaned or VIDEO_THUMB_WARM_WIDTHS)


async def _ensure_video_thumb_cache(
    media_id: int,
    *,
    item: dict[str, Any] | None = None,
    widths: tuple[int, ...] | list[int] | None = None,
) -> int:
    normalized_widths = _normalize_video_thumb_widths(widths)
    pending = [
        width
        for width in normalized_widths
        if not _video_thumb_cache_file(media_id, width).exists()
        or _video_thumb_cache_file(media_id, width).stat().st_size <= 0
    ]
    if not pending:
        return 0

    item = item or await main.db.get_media(media_id, None)
    if not item or str(item.get("media_kind") or "").lower() != "video":
        return 0

    async def _extract_from_source(source_path: Path) -> int:
        generated = 0
        for width in pending:
            cache_file = _video_thumb_cache_file(media_id, width)
            lock_key = f"video:{int(media_id)}:{width}"
            lock = main._thumb_generation_locks.setdefault(lock_key, asyncio.Lock())
            async with lock:
                if cache_file.exists() and cache_file.stat().st_size > 0:
                    continue
                success = await asyncio.to_thread(_render_video_frame_thumb, source_path, cache_file, width)
                if success:
                    generated += 1
        return generated

    # Use get_media_file_info (no BLOB) then stream chunks to avoid loading the
    # entire video into Python memory — critical for files over a few hundred MB.
    file_info = await main.db.get_media_file_info(media_id)
    if file_info:
        with tempfile.TemporaryDirectory(prefix="gallery-video-thumb-") as tmp_dir:
            safe_name = Path(str(file_info.get("original_filename") or f"{media_id}.video")).name or f"{media_id}.video"
            source_path = Path(tmp_dir) / safe_name
            async def _stream_to_file(fid: int, dest: Path) -> None:
                with open(dest, "wb") as fh:
                    async for chunk in main.db.stream_media_file_content(fid):
                        fh.write(chunk)
            await _stream_to_file(int(file_info["id"]), source_path)
            if source_path.stat().st_size > 0:
                return await _extract_from_source(source_path)

    legacy = _legacy_upload_path(item.get("storage_path"))
    if legacy:
        return await _extract_from_source(legacy)
    return 0


def _queue_video_thumb_warmup(
    media_id: int,
    *,
    item: dict[str, Any] | None = None,
    widths: tuple[int, ...] | list[int] | None = None,
) -> asyncio.Task[Any]:
    normalized_widths = _normalize_video_thumb_widths(widths)
    key = (int(media_id), normalized_widths)
    existing = main._video_thumb_warm_tasks.get(key)
    if existing and not existing.done():
        return existing

    async def _runner() -> None:
        try:
            generated = await _ensure_video_thumb_cache(int(media_id), item=item, widths=normalized_widths)
            if generated:
                main.logger.info("Warmed %s video thumbnail(s) for media %s.", generated, media_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            main.logger.debug("Video thumbnail warmup failed for media %s.", media_id, exc_info=True)
        finally:
            main._video_thumb_warm_tasks.pop(key, None)

    task = asyncio.create_task(_runner())
    main._video_thumb_warm_tasks[key] = task
    return task


async def _run_video_thumb_warm_pass(before_media_id: int | None = None) -> tuple[int, int | None]:
    rows = await main.db.list_video_thumb_candidates(limit=VIDEO_THUMB_WARM_BATCH_SIZE, before_media_id=before_media_id)
    if not rows:
        return 0, None
    next_cursor = int(rows[-1].get("id") or 0) or None
    scanned = 0
    for item in rows:
        media_id = int(item.get("id") or 0)
        if not media_id:
            continue
        await _ensure_video_thumb_cache(media_id, item=item, widths=VIDEO_THUMB_WARM_WIDTHS)
        scanned += 1
    return scanned, next_cursor


def _thumb_file_response(request: Request, cache_file: Path, headers: dict[str, str]) -> Response | None:
    if not cache_file.exists() or cache_file.stat().st_size <= 0:
        return None
    stat = cache_file.stat()
    etag = f"\"thumb:{cache_file.stem}:{stat.st_mtime_ns}:{stat.st_size}\""
    response_headers = {**headers, "ETag": etag}
    if _etag_matches(request, etag):
        return Response(status_code=304, headers=response_headers)
    return FileResponse(cache_file, media_type="image/webp", headers=response_headers)


@router.get("/api/media/{media_id}/thumb", name="serve_media_thumb")
async def serve_media_thumb(media_id: int, request: Request, access: str | None = None, w: int = 520) -> Response:
    viewer_id = _user_id(_auth_optional(request))
    item = await main.db.get_media(media_id, viewer_id)
    if not item:
        raise HTTPException(status_code=404, detail="Media not found.")

    if item.get("is_adult") and not await _adult_file_allowed(request, media_id, access):
        raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")

    width = max(160, min(int(w or 520), 1440))
    # Flat (non-sharded) cache path used for image thumbnails.
    cache_file = main.THUMB_CACHE_DIR / f"{int(media_id)}_{width}.webp"

    headers = {
        "Cache-Control": "public, max-age=604800, immutable",
        "X-Xenus-Thumb": "1",
    }

    if str(item.get("media_kind") or "").lower() == "video":
        # Video thumbnails are stored in sharded subdirectories via _video_thumb_cache_file.
        # Always use the sharded path so generation and serving agree on the file location.
        video_cache_file = _video_thumb_cache_file(int(media_id), width)
        video_headers = {**headers, "X-Xenus-Video-Thumb": "frame"}
        # Serve from cache if already generated (handles both fresh and pre-existing entries).
        cached = _thumb_file_response(request, video_cache_file, video_headers)
        if cached:
            return cached
        # Not cached yet — generate now, then re-check.
        await _ensure_video_thumb_cache(int(media_id), item=item, widths=(width,))
        cached = _thumb_file_response(request, video_cache_file, video_headers)
        if cached:
            return cached
        preview_bytes, preview_mime = await asyncio.to_thread(_render_video_placeholder_thumb, item, width)
        etag = f"\"video-thumb:{int(media_id)}:{width}:{hashlib.sha256(preview_bytes).hexdigest()[:16]}\""
        fallback_headers = {**headers, "ETag": etag, "X-Xenus-Video-Thumb": "placeholder"}
        main.logger.info(
            "Video thumbnail placeholder served for media_id=%s width=%s request_id=%s",
            media_id,
            width,
            getattr(request.state, "request_id", "") or "none",
        )
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=fallback_headers)
        return Response(content=preview_bytes, media_type=preview_mime, headers=fallback_headers)

    if str(item.get("media_kind") or "").lower() != "image":
        return await main._serve_media_content(media_id, request, access=access, as_download=False)

    lock_key = f"img:{int(media_id)}:{width}"
    lock = main._thumb_generation_locks.setdefault(lock_key, asyncio.Lock())
    # Prune stale unlocked entries to prevent unbounded growth (images are
    # generated once and then served from disk, so the lock is only needed once).
    if len(main._thumb_generation_locks) > 2048:
        stale = [k for k, lk in list(main._thumb_generation_locks.items()) if not lk.locked() and k != lock_key]
        for k in stale[:512]:
            main._thumb_generation_locks.pop(k, None)
    async with lock:
        cached = _thumb_file_response(request, cache_file, headers)
        if cached:
            return cached

        file_row = await main.db.get_media_file(media_id)
        if not file_row:
            legacy = _legacy_upload_path(item.get("storage_path"))
            if legacy:
                return FileResponse(
                    legacy,
                    media_type=item.get("mime_type") or mimetypes.guess_type(str(legacy))[0] or "application/octet-stream",
                    headers=headers,
                )
            raise HTTPException(status_code=404, detail="File missing from database.")

        try:
            from PIL import Image, ImageSequence
            Image.MAX_IMAGE_PIXELS = 90_000_000

            raw_content = bytes(file_row.get("content") or b"")
            if not raw_content:
                raise HTTPException(status_code=404, detail="File content is empty.")

            with Image.open(io.BytesIO(raw_content)) as image:
                frame = next(ImageSequence.Iterator(image), image)
                frame = frame.convert("RGB")
                frame.thumbnail((width, width), Image.Resampling.LANCZOS)

                tmp = cache_file.with_suffix(".tmp")
                frame.save(tmp, format="WEBP", quality=84, method=5)
                tmp.replace(cache_file)

            cached = _thumb_file_response(request, cache_file, headers)
            if cached:
                return cached
            return FileResponse(cache_file, media_type="image/webp", headers=headers)
        except Exception:
            # If thumbnailing fails, fall back to the original instead of breaking the UI.
            main.logger.warning(
                "Image thumbnail generation failed; serving original for media_id=%s width=%s request_id=%s",
                media_id,
                width,
                getattr(request.state, "request_id", "") or "none",
                exc_info=True,
            )
            return await main._serve_media_content(media_id, request, access=access, as_download=False)


@router.get("/api/media/{media_id}/file", name="serve_media_file")
async def serve_media_file(media_id: int, request: Request, access: str | None = None, quality: str | None = None) -> Response:
    return await main._serve_media_content(media_id, request, access=access, as_download=False, quality=quality)


@router.get("/api/media/{media_id}/preview", name="serve_media_preview")
async def serve_media_preview(media_id: int, request: Request, access: str | None = None, size: str = "card") -> Response:
    auth = _auth_optional(request)
    viewer_id = _user_id(auth)
    item = await main.db.get_media(media_id, viewer_id)
    if not item or item.get("deleted_at"):
        raise HTTPException(status_code=404, detail="Media not found.")
    owner = int(item.get("user_id")) == int(viewer_id or 0)
    if item.get("visibility") == "private" and not owner:
        raise HTTPException(status_code=403, detail="This post is private.")
    if item.get("is_adult") and not await _adult_file_allowed(request, media_id, access):
        raise HTTPException(status_code=403, detail="Age verification required for this 18+ post.")
    if item.get("media_kind") != "image":
        return await main._serve_media_content(media_id, request, access=access, as_download=False, quality=size)

    file_row = await main.db.get_media_file(media_id)
    if file_row:
        # Use the stored SHA-256 for the ETag; only verify content integrity after loading.
        digest = str(file_row.get("sha256") or "")
        etag = _preview_etag(digest, size)
        headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=headers)
        content_bytes = bytes(file_row.get("content") or b"")
        if digest and hashlib.sha256(content_bytes).hexdigest() != digest:
            raise HTTPException(status_code=500, detail="Stored file failed hash verification.")
        preview_bytes, preview_mime = await asyncio.to_thread(
            _render_image_preview,
            content_bytes,
            file_row.get("mime_type"),
            digest,
            size=size,
        )
        return Response(content=preview_bytes, media_type=preview_mime, headers=headers)

    legacy = _legacy_upload_path(item.get("storage_path"))
    if not legacy:
        raise HTTPException(
            status_code=404,
            detail="Preview is missing. Re-upload this post once so it can be saved into the new DB-backed file store.",
        )
    content = legacy.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    etag = _preview_etag(digest, size)
    headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
    if _etag_matches(request, etag):
        return Response(status_code=304, headers=headers)
    preview_bytes, preview_mime = await asyncio.to_thread(
        _render_image_preview,
        content,
        item.get("mime_type") or mimetypes.guess_type(str(legacy))[0] or "image/jpeg",
        digest,
        size=size,
    )
    return Response(content=preview_bytes, media_type=preview_mime, headers=headers)


@router.get("/api/users/{user_id}/avatar", name="serve_user_avatar")
async def serve_user_avatar(user_id: int, request: Request) -> Response:
    file_row = await main.db.get_avatar_file(user_id)
    if file_row:
        digest = str(file_row.get("sha256") or "")
        etag = f"\"avatar:{digest}\""
        headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=headers)
        content_bytes = bytes(file_row.get("content") or b"")
        if digest and hashlib.sha256(content_bytes).hexdigest() != digest:
            raise HTTPException(status_code=500, detail="Stored avatar failed hash verification.")
        return Response(content=content_bytes, media_type=file_row.get("mime_type") or "image/jpeg", headers=headers)

    user = await main.db.get_user(user_id)
    legacy = _legacy_upload_path((user or {}).get("avatar_path"))
    if legacy:
        content = legacy.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        etag = f"\"avatar:{digest}\""
        headers = {"Cache-Control": "public, max-age=86400", "ETag": etag, "X-Content-SHA256": digest}
        if _etag_matches(request, etag):
            return Response(status_code=304, headers=headers)
        return FileResponse(
            legacy,
            media_type=(user.get("avatar_mime_type") if user else None) or mimetypes.guess_type(str(legacy))[0] or "image/jpeg",
            headers=headers,
        )

    # Avoid repeated browser 404 spam for accounts that have no uploaded avatar yet.
    return Response(content=_fallback_avatar_svg(user_id), media_type="image/svg+xml", headers={"Cache-Control": "public, max-age=3600"})


@router.get("/api/media/{media_id}/download", name="download_media")
async def download_media(media_id: int, request: Request, access: str | None = None) -> Response:
    return await main._serve_media_content(media_id, request, access=access, as_download=True)

