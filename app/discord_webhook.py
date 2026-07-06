"""Outbound Discord webhook notifications for per-creator upload alerts.

Mirrors app/telegram.py's pattern of running blocking urllib calls in a thread rather
than pulling in an async HTTP client dependency for one feature.
"""

from __future__ import annotations

import asyncio
import json
import logging
import urllib.request
from typing import Any

logger = logging.getLogger("image_gallery.discord_webhook")

# Only Discord's own webhook endpoints are allowed as a target: this setting lets a
# user configure an arbitrary URL that our server will POST to, so restricting the
# host prevents it from being used as an open server-side request forwarder.
_ALLOWED_PREFIXES = ("https://discord.com/api/webhooks/", "https://discordapp.com/api/webhooks/")


def is_valid_discord_webhook_url(url: str | None) -> bool:
    return isinstance(url, str) and url.startswith(_ALLOWED_PREFIXES)


async def send_discord_webhook(webhook_url: str, *, embeds: list[dict[str, Any]]) -> None:
    """Best-effort delivery — never raises, so a broken/rate-limited webhook can't
    affect the upload request that triggered it."""
    if not is_valid_discord_webhook_url(webhook_url):
        return
    try:
        await asyncio.to_thread(_send_sync, webhook_url, embeds)
    except Exception as exc:
        logger.warning("Discord webhook delivery failed: %s", exc)


def _send_sync(webhook_url: str, embeds: list[dict[str, Any]]) -> None:
    body = json.dumps({"embeds": embeds}).encode("utf-8")
    request = urllib.request.Request(
        webhook_url, data=body, headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=10):
        pass
