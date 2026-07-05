"""SPA shell routes: serve the built React index.html for every client-side route.

Media/profile pages inject per-page Open Graph tags into the shell so links shared in
Discord and other social apps render a real title/description/image instead of the
bare site name — the SPA itself can't do this since crawlers don't run its JS.
"""

import html as html_lib
import re

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, HTMLResponse, Response

import app.main as main
from ..config import ROOT_DIR
from ..paths import _app_shell_path
from ._shared import (
    _auth_optional,
    _avatar_revision_token,
    _avatar_url,
    _user_id,
    _viewer_can_open_adult,
    _with_urls,
)

router = APIRouter()

_TITLE_RE = re.compile(r"<title>.*?</title>", re.IGNORECASE | re.DOTALL)
_HEAD_CLOSE_RE = re.compile(r"</head>", re.IGNORECASE)


def _render_shell_with_og(request: Request, *, title: str, description: str, image: str | None) -> HTMLResponse:
    shell_html = _app_shell_path().read_text(encoding="utf-8")
    safe_title = html_lib.escape(title)[:200]
    safe_description = html_lib.escape(description)[:300]
    safe_url = html_lib.escape(str(request.url))
    tags = [
        '<meta property="og:type" content="website">',
        f'<meta property="og:title" content="{safe_title}">',
        f'<meta property="og:description" content="{safe_description}">',
        f'<meta property="og:url" content="{safe_url}">',
        f'<meta name="twitter:card" content="{"summary_large_image" if image else "summary"}">',
    ]
    if image:
        safe_image = html_lib.escape(image)
        tags.append(f'<meta property="og:image" content="{safe_image}">')
        tags.append(f'<meta name="twitter:image" content="{safe_image}">')
    shell_html = _TITLE_RE.sub(f"<title>{safe_title}</title>", shell_html, count=1)
    shell_html = _HEAD_CLOSE_RE.sub("\n".join(tags) + "\n</head>", shell_html, count=1)
    return HTMLResponse(shell_html)


@router.get("/")
async def index() -> FileResponse:
    return FileResponse(_app_shell_path())


@router.get("/favicon.ico", include_in_schema=False)
async def favicon() -> FileResponse:
    return FileResponse(
        ROOT_DIR / "app" / "static" / "favicon.ico",
        media_type="image/vnd.microsoft.icon",
        headers={"Cache-Control": "public, max-age=604800"},
    )


@router.get("/robots.txt", include_in_schema=False)
async def robots_txt() -> Response:
    return Response(
        content="User-agent: *\nAllow: /\n",
        media_type="text/plain",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/collections")
@router.get("/following")
@router.get("/liked")
@router.get("/users")
@router.get("/friends")
@router.get("/messages")
@router.get("/studio")
@router.get("/profile")
@router.get("/upload")
@router.get("/settings")
@router.get("/login")
async def app_page() -> FileResponse:
    return FileResponse(_app_shell_path())


@router.get("/media/{media_id:int}")
async def media_page(media_id: int, request: Request) -> Response:
    try:
        viewer_id = _user_id(_auth_optional(request))
        item = await main.db.get_media(media_id, viewer_id)
        if not item or item.get("deleted_at") or item.get("visibility") != "public":
            return FileResponse(_app_shell_path())
        adult_allowed = await _viewer_can_open_adult(request)
        item = _with_urls(request, item, adult_allowed)
    except Exception:
        return FileResponse(_app_shell_path())

    uploader = item.get("display_name") or item.get("username") or "a creator"
    if item.get("locked"):
        return _render_shell_with_og(
            request,
            title="18+ content on Image Gallery",
            description="Sign in and verify your age to view this post.",
            image=None,
        )
    description = (item.get("description") or "").strip() or f"Shared by {uploader} on Image Gallery."
    return _render_shell_with_og(
        request,
        title=item.get("title") or f"Post by {uploader}",
        description=description,
        image=item.get("thumb_url") or item.get("preview_url") or item.get("url"),
    )


@router.get("/users/{username}")
async def user_page(username: str, request: Request) -> Response:
    try:
        viewer_id = _user_id(_auth_optional(request))
        profile = await main.db.get_public_profile(username, viewer_id)
        if not profile or not profile.get("public_profile"):
            return FileResponse(_app_shell_path())
    except Exception:
        return FileResponse(_app_shell_path())

    display_name = profile.get("display_name") or profile.get("username")
    bio = (profile.get("bio") or "").strip()
    avatar_url = None
    if profile.get("avatar_path"):
        avatar_url = _avatar_url(
            request,
            profile.get("id"),
            revision=_avatar_revision_token(profile, path_key="avatar_path"),
        )
    return _render_shell_with_og(
        request,
        title=f"{display_name} on Image Gallery",
        description=bio or f"View {display_name}'s uploads and profile.",
        image=avatar_url,
    )

