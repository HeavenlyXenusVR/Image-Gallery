"""Base filesystem paths shared by main.py and the pages/health routers.

THUMB_CACHE_DIR/VIDEO_CACHE_DIR deliberately stay in main.py rather than here:
they're derived from settings.uploads_dir at module-execution time, and
main.py is the one place settings-dependent constants should be materialized
(see main.py's own docstring note on the settings-rebind trap the test suite
relies on)."""

from pathlib import Path

from .config import ROOT_DIR

APP_SHELL_PATHS = {
    "/",
    "/collections",
    "/following",
    "/liked",
    "/users",
    "/friends",
    "/messages",
    "/studio",
    "/profile",
    "/upload",
    "/settings",
    "/login",
}
REACT_SHELL_PATH = ROOT_DIR / "app" / "static" / "react" / "index.html"
_LIVE_CONFIG_PATH = ROOT_DIR / "live-config.json"


def _app_shell_path() -> Path:
    return REACT_SHELL_PATH if REACT_SHELL_PATH.exists() else ROOT_DIR / "index.html"
