"""Composes GalleryDatabase from its domain mixins.

Each mixin owns one domain (see the individual modules for a description);
GalleryDatabase itself adds no behavior — CoreMixin is the only one that
defines __init__, and every other mixin's methods operate on the attributes
it sets up (self.pool, self._user_cache, etc.) once composed.
"""

from ._shared import (
    AI_TRAINING_COLUMNS,
    DB_IDENTIFIER_RE,
    DEFAULT_USER_SETTINGS,
    EMAIL_RE,
    MAX_MEDIA_SUBCATEGORIES,
    MEDIA_CATEGORY_JOIN,
    MEDIA_CATEGORY_SELECT,
    MEDIA_COLUMNS,
    MEDIA_KINDS,
    SLUG_RE,
    USER_COLUMNS,
    USERNAME_RE,
    clean_subcategory_name,
    log,
    mysql_error_code,
    normalize_email,
    normalize_subcategory_ids,
    normalize_subcategory_names,
    normalize_username,
    quote_identifier,
    slugify,
    verification_token_hash,
)
from .account import AccountMixin
from .admin import AdminMixin
from .ai_vision import AIVisionMixin
from .categories import CategoriesMixin
from .core import CoreMixin
from .feed_collections import FeedSocialMixin
from .helpers import HelpersMixin
from .media import MediaMixin
from .media_storage import MediaBlobMixin
from .messages import MessagingMixin
from .notifications import NotificationsMixin
from .social import ProfileFriendsMixin

__all__ = [
    "GalleryDatabase",
    "AI_TRAINING_COLUMNS",
    "DB_IDENTIFIER_RE",
    "DEFAULT_USER_SETTINGS",
    "EMAIL_RE",
    "MAX_MEDIA_SUBCATEGORIES",
    "MEDIA_CATEGORY_JOIN",
    "MEDIA_CATEGORY_SELECT",
    "MEDIA_COLUMNS",
    "MEDIA_KINDS",
    "SLUG_RE",
    "USER_COLUMNS",
    "USERNAME_RE",
    "clean_subcategory_name",
    "log",
    "mysql_error_code",
    "normalize_email",
    "normalize_subcategory_ids",
    "normalize_subcategory_names",
    "normalize_username",
    "quote_identifier",
    "slugify",
    "verification_token_hash",
]


class GalleryDatabase(
    CoreMixin,
    HelpersMixin,
    AccountMixin,
    CategoriesMixin,
    MediaBlobMixin,
    MediaMixin,
    FeedSocialMixin,
    ProfileFriendsMixin,
    MessagingMixin,
    NotificationsMixin,
    AIVisionMixin,
    AdminMixin,
):
    pass
