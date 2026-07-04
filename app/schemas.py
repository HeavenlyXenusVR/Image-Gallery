"""Pydantic request models for every router. Validation behavior is unchanged
from the pre-split main.py — this is a pure relocation."""

from pydantic import BaseModel


class RegisterRequest(BaseModel):
    username: str
    password: str
    email: str | None = None
    display_name: str | None = None


class LoginRequest(BaseModel):
    username: str
    password: str


class PasswordChangeRequest(BaseModel):
    old_password: str
    new_password: str


class AccountDeleteRequest(BaseModel):
    password: str


class FollowRequest(BaseModel):
    following: bool = True


class FriendActionRequest(BaseModel):
    action: str


class EmailUpdateRequest(BaseModel):
    email: str | None = None


class EmailCodeRequest(BaseModel):
    code: str


class CategoryRequest(BaseModel):
    name: str
    media_kind: str = "mixed"


class LikeRequest(BaseModel):
    liked: bool = True


class CommentRequest(BaseModel):
    body: str


class DirectMessageRequest(BaseModel):
    body: str


class MediaUpdateRequest(BaseModel):
    title: str
    description: str | None = None
    category_id: int
    subcategory_id: int | None = None
    subcategory_name: str | None = None
    subcategory_ids: list[int] = []
    subcategory_names: list[str] = []
    tags: list[str] = []
    is_adult: bool = False
    visibility: str = "public"
    comments_enabled: bool = True
    downloads_enabled: bool = True
    pinned: bool = False


class MediaControlRequest(BaseModel):
    visibility: str | None = None
    comments_enabled: bool | None = None
    downloads_enabled: bool | None = None
    pinned: bool | None = None



class ProfileUpdateRequest(BaseModel):
    display_name: str
    bio: str | None = None
    profile_quote: str | None = None
    website_url: str | None = None
    location_label: str | None = None
    profile_headline: str | None = None
    featured_tags: list[str] = []
    profile_color: str = "#37c9a7"
    public_profile: bool = True
    show_liked_count: bool = True
    show_collections: bool = True
    show_recent_uploads: bool = True
    show_friends: bool = True


class SettingsUpdateRequest(BaseModel):
    theme_mode: str | None = None
    accent_color: str | None = None
    accent_secondary: str | None = None
    gallery_bg_color: str | None = None
    grid_density: str | None = None
    default_sort: str | None = None
    items_per_page: int | None = None
    profile_layout: str | None = None
    profile_banner_style: str | None = None
    profile_card_style: str | None = None
    profile_stat_style: str | None = None
    profile_content_focus: str | None = None
    profile_hero_alignment: str | None = None
    profile_avatar_shape: str | None = None
    profile_media_shape: str | None = None
    profile_surface_style: str | None = None
    profile_social_layout: str | None = None
    profile_featured_panel: str | None = None
    profile_backdrop_image_url: str | None = None
    profile_backdrop_strength: float | None = None
    profile_name_style: str | None = None
    profile_header_style: str | None = None
    profile_bg_color: str | None = None
    card_hover_effect: str | None = None
    card_aspect_ratio: str | None = None
    media_border_style: str | None = None
    gallery_font: str | None = None
    card_info_display: str | None = None
    column_gap: str | None = None
    watermark_text: str | None = None
    autoplay_previews: bool | None = None
    muted_previews: bool | None = None
    reduce_motion: bool | None = None
    open_original_in_new_tab: bool | None = None
    blur_video_previews: bool | None = None
    profile_show_joined_date: bool | None = None
    profile_show_uploads: bool | None = None
    profile_show_collections: bool | None = None
    profile_show_friends: bool | None = None
    profile_show_follow_counts: bool | None = None


class AgeVerifyRequest(BaseModel):
    birthdate: str
    confirm_over_18: bool = False


class BookmarkRequest(BaseModel):
    bookmarked: bool = True


class CollectionRequest(BaseModel):
    name: str
    description: str | None = None
    is_public: bool = True


class CollectionItemRequest(BaseModel):
    media_id: int
    saved: bool = True


class ReportRequest(BaseModel):
    reason: str
    details: str | None = None


class MediaLoadDiagnosticRequest(BaseModel):
    context: str
    outcome: str
    media_kind: str | None = None
    selected_source: str | None = None
    failed_sources: list[str] = []
    source_count: int = 0


class VisionTrainingRequest(BaseModel):
    title: str
    category_name: str | None = None
    subcategory_name: str | None = None
    subcategory_names: list[str] = []
    tags: list[str] = []
    is_adult: bool = False
    notes: str | None = None
