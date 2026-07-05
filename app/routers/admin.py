"""Site-owner-only aggregate stats."""

from typing import Any

from fastapi import APIRouter, Request

import app.main as main
from ._shared import _jsonable, _require_site_owner

router = APIRouter()


@router.get("/api/stats")
async def stats(request: Request) -> dict[str, Any]:
    await _require_site_owner(request)
    return {"stats": _jsonable(await main.db.stats())}

