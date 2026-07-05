"""SPA shell routes: serve the built React index.html for every client-side route."""

from fastapi import APIRouter
from fastapi.responses import FileResponse, Response

from ..config import ROOT_DIR
from ..paths import _app_shell_path

router = APIRouter()


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
async def media_page(media_id: int) -> FileResponse:
    return FileResponse(_app_shell_path())


@router.get("/users/{username}")
async def user_page(username: str) -> FileResponse:
    return FileResponse(_app_shell_path())

