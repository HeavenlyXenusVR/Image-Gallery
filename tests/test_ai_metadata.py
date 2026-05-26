from __future__ import annotations

import io
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import ai_metadata


class _FakeResponse:
    def __init__(self, body: str):
        self._body = body.encode("utf-8")

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


def test_analyze_media_bytes_surfaces_gemini_quota_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GALLERY_AI_PROVIDER", "gemini")
    monkeypatch.delenv("GALLERY_LOCAL_VISION_COMMAND", raising=False)

    def fake_urlopen(request: urllib.request.Request, timeout: int = 0):
        body = json.dumps(
            {
                "error": {
                    "code": 429,
                    "message": "Quota exceeded for Gemini free tier.",
                    "status": "RESOURCE_EXHAUSTED",
                    "details": [{"retryDelay": "31s"}],
                }
            }
        )
        raise urllib.error.HTTPError(
            url=request.full_url,
            code=429,
            msg="Too Many Requests",
            hdrs=None,
            fp=io.BytesIO(body.encode("utf-8")),
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    result = ai_metadata.analyze_media_bytes(
        content=b"not-a-real-image",
        filename="aria_search_12.png",
        mime_type="image/png",
        media_kind="image",
        ai_enabled=True,
        ai_api_key="test-gemini-key",
        ai_model="gemini-2.5-flash-lite",
        ai_timeout_seconds=5,
    )

    assert result.source == "heuristic"
    assert result.reason is not None
    assert "Gemini API error 429" in result.reason
    assert "Quota exceeded for Gemini free tier." in result.reason
    assert "retry in about 31s" in result.reason
    assert "_sanitize_ai_error_text" not in result.reason


def test_gemini_analysis_parses_fenced_json(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {
        "candidates": [
            {
                "content": {
                    "parts": [
                        {
                            "text": """```json
{"title":"Aria Blaze","suggested_filename_base":"aria-blaze","tags":["aria-blaze","mlp"],"category_name":"My Little Pony","subcategory_name":"Aria Blaze","is_adult":false,"confidence":0.92,"reason":"Recognized the character visually."}
```"""
                        }
                    ]
                }
            }
        ]
    }

    monkeypatch.setattr(urllib.request, "urlopen", lambda request, timeout=0: _FakeResponse(json.dumps(payload)))

    fallback = ai_metadata.SmartMediaAnalysis(
        title="Fallback Title",
        suggested_filename="fallback-title.png",
        tags=["fallback"],
        category_name="Wallpapers",
        subcategory_name=None,
        is_adult=False,
        source="heuristic",
        confidence=0.45,
        size=(1920, 1080),
    )

    result = ai_metadata._gemini_vision_analysis(
        preview_image_b64="ZmFrZQ==",
        filename="aria_search_12.png",
        mime_type="image/png",
        media_kind="image",
        title_hint="",
        description_hint="",
        tags_hint=[],
        fallback=fallback,
        training_examples=[],
        api_key="test-gemini-key",
        model="gemini-2.5-flash-lite",
        timeout_seconds=5,
    )

    assert result["title"] == "Aria Blaze"
    assert result["category_name"] == "My Little Pony"
    assert result["subcategory_name"] == "Aria Blaze"
    assert result["confidence"] == pytest.approx(0.92)


def test_merge_analysis_preserves_reason_codes() -> None:
    fallback = ai_metadata.SmartMediaAnalysis(
        title="Fallback Title",
        suggested_filename="fallback-title.png",
        tags=["fallback"],
        category_name="Wallpapers",
        subcategory_name=None,
        is_adult=False,
        source="heuristic",
        confidence=0.45,
        size=(1920, 1080),
    )

    result = ai_metadata._merge_analysis(
        ai_result={
            "title": "Rainbow Dash",
            "suggested_filename_base": "rainbow-dash",
            "tags": ["rainbow-dash", "mlp"],
            "category_name": "My Little Pony",
            "subcategory_name": "Mane Six",
            "is_adult": False,
            "confidence": 0.66,
            "reason": "Primary AI unavailable: Gemini API error 429: retry in about 31s",
            "source": "domain-hint",
        },
        fallback=fallback,
        filename="mermaid-dashie.png",
        mime_type="image/png",
        media_kind="image",
    )

    assert result.reason == "Primary AI unavailable: Gemini API error 429: retry in about 31s"
