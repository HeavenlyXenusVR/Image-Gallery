-- Server-owned appearance presets, mirroring SwarmPanel's looks.lua. Every
-- field/value below matches user_settings.lua's ALLOWED_CHOICES exactly, so
-- these are just pre-validated bundles of settings a user could otherwise
-- set by hand one field at a time. Exposed via GET /api/appearance/presets.
local M = {}

M.GALLERY_LOOKS = {
  {
    id = "clean_grid", title = "Clean Grid",
    note = "The safe baseline: comfortable density, lift hover, normal gaps.",
    patch = { theme_mode = "system", accent_color = "#37c9a7", grid_density = "comfortable", card_hover_effect = "lift", column_gap = "normal" },
  },
  {
    id = "poster_wall", title = "Poster Wall",
    note = "Wide grid, glow hover, neon borders, overlay captions -- art-wall feel.",
    patch = { theme_mode = "dark", grid_density = "wide", media_border_style = "neon", card_hover_effect = "glow", card_info_display = "overlay" },
  },
  {
    id = "archive_mode", title = "Archive Mode",
    note = "Dense catalog browsing for large collections.",
    patch = { theme_mode = "light", grid_density = "compact", card_info_display = "below", column_gap = "tight", gallery_font = "serif" },
  },
  {
    id = "minimal_mono", title = "Minimal Mono",
    note = "Distraction-free viewing: no borders, no hover motion.",
    patch = { theme_mode = "dark", media_border_style = "none", card_info_display = "minimal", card_hover_effect = "none" },
  },
  {
    id = "studio_light", title = "Studio Light",
    note = "Bright, friendly, portfolio-site feel.",
    patch = { theme_mode = "light", gallery_font = "rounded", card_hover_effect = "reveal", column_gap = "wide" },
  },
}

M.PROFILE_LOOKS = {
  {
    id = "spotlight_creator", title = "Spotlight Creator",
    note = "Puts your own uploads front and center.",
    patch = { profile_layout = "spotlight", profile_hero_alignment = "center", profile_name_style = "glow", profile_featured_panel = "uploads" },
  },
  {
    id = "magazine_layout", title = "Magazine Layout",
    note = "Editorial, image-heavy profile.",
    patch = { profile_layout = "magazine", profile_banner_style = "mesh", profile_card_style = "elevated", profile_content_focus = "gallery" },
  },
  {
    id = "mosaic_wall", title = "Mosaic Wall",
    note = "Dense visual-first tile wall.",
    patch = { profile_layout = "mosaic", profile_media_shape = "poster", profile_banner_style = "poster" },
  },
  {
    id = "aurora_frame", title = "Aurora Frame",
    note = "Glowy, low-effort-to-look-good preset.",
    patch = { profile_banner_style = "aurora", profile_card_style = "glass", profile_avatar_shape = "circle" },
  },
}

return M
