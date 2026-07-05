"""Thin compatibility re-export: GalleryDatabase now lives in app/db/, split
into per-domain mixins (see app/db/__init__.py for the composition and each
app/db/*.py module for what it owns)."""

from .db import (  # noqa: F401
    GalleryDatabase,
    MAX_MEDIA_SUBCATEGORIES,
    normalize_subcategory_names,
)
