export const PAGE_SIZE = 24;
export const FALLBACK_MAX_UPLOAD_BYTES = 500 * 1024 * 1024;
export let MAX_UPLOAD_BYTES = FALLBACK_MAX_UPLOAD_BYTES;

export function setRuntimeMaxUploadBytes(value) {
  const parsed = Number(value);
  if (Number.isFinite(parsed) && parsed > 0) MAX_UPLOAD_BYTES = parsed;
  return MAX_UPLOAD_BYTES;
}


export const DEFAULT_SETTINGS = {
  theme_mode: "system",
  accent_color: "#37c9a7",
  grid_density: "comfortable",
  default_sort: "new",
  items_per_page: PAGE_SIZE,
  autoplay_previews: false,
  muted_previews: true,
  reduce_motion: false,
  open_original_in_new_tab: false,
  blur_video_previews: false,
  profile_layout: "spotlight",
  profile_banner_style: "gradient",
  profile_card_style: "glass",
  profile_stat_style: "tiles",
  profile_content_focus: "balanced",
  profile_hero_alignment: "split",
  profile_avatar_shape: "circle",
  profile_media_shape: "soft",
  profile_surface_style: "standard",
  profile_social_layout: "rail",
  profile_featured_panel: "uploads",
  profile_backdrop_image_url: "",
  profile_backdrop_strength: 0.18,
  profile_show_joined_date: true,
  profile_show_uploads: true,
  profile_show_collections: true,
  profile_show_friends: true,
  profile_show_follow_counts: true,
};
