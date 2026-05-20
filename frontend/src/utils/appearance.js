import { safeColor } from "./format.js";

const CHOICES = {
  theme_mode: new Set(["system", "dark", "light"]),
  grid_density: new Set(["compact", "comfortable", "wide"]),
  profile_layout: new Set(["spotlight", "magazine", "stack", "split", "mosaic", "timeline"]),
  profile_banner_style: new Set(["gradient", "mesh", "frame", "aurora", "spotlight", "poster"]),
  profile_card_style: new Set(["glass", "solid", "outline", "elevated", "soft", "edge"]),
  profile_stat_style: new Set(["tiles", "ribbon", "minimal"]),
  profile_content_focus: new Set(["balanced", "gallery", "collections", "social"]),
  profile_hero_alignment: new Set(["split", "start", "center"]),
  profile_avatar_shape: new Set(["circle", "rounded", "square"]),
  profile_media_shape: new Set(["soft", "crisp", "poster"]),
  profile_surface_style: new Set(["standard", "quiet", "contrast", "editorial"]),
  profile_social_layout: new Set(["rail", "cards", "compact"]),
  profile_featured_panel: new Set(["uploads", "collections", "friends"]),
};

function choice(settings, key, fallback) {
  const value = String(settings?.[key] || fallback).trim().toLowerCase();
  return CHOICES[key]?.has(value) ? value : fallback;
}

export function galleryStyle(settings) {
  return {
    "--accent": safeColor(settings?.accent_color || "#37c9a7"),
  };
}

function safeImage(value) {
  const text = String(value || "").trim();
  if (!/^https?:\/\//i.test(text)) return "none";
  return `url("${text.replace(/["\\]/g, "\\$&")}")`;
}

function clamp(value, fallback, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}

export function profileStyle(settings, fallbackAccent = "#37c9a7") {
  return {
    "--accent": safeColor(settings?.accent_color || fallbackAccent),
    "--profile-backdrop": safeImage(settings?.profile_backdrop_image_url),
    "--profile-backdrop-strength": `${Math.round(clamp(settings?.profile_backdrop_strength, 0.18, 0, 0.55) * 100)}%`,
  };
}

export function galleryClassName(settings) {
  return [
    `gallery-theme-${choice(settings, "theme_mode", "system")}`,
    `gallery-grid-${choice(settings, "grid_density", "comfortable")}`,
    settings?.reduce_motion ? "gallery-motion-reduced" : "",
  ].filter(Boolean).join(" ");
}

export function profileClassName(settings) {
  return [
    `profile-layout-${choice(settings, "profile_layout", "spotlight")}`,
    `profile-banner-${choice(settings, "profile_banner_style", "gradient")}`,
    `profile-card-${choice(settings, "profile_card_style", "glass")}`,
    `profile-stat-${choice(settings, "profile_stat_style", "tiles")}`,
    `profile-focus-${choice(settings, "profile_content_focus", "balanced")}`,
    `profile-align-${choice(settings, "profile_hero_alignment", "split")}`,
    `profile-avatar-${choice(settings, "profile_avatar_shape", "circle")}`,
    `profile-media-${choice(settings, "profile_media_shape", "soft")}`,
    `profile-surface-${choice(settings, "profile_surface_style", "standard")}`,
    `profile-social-${choice(settings, "profile_social_layout", "rail")}`,
    `profile-feature-${choice(settings, "profile_featured_panel", "uploads")}`,
  ].join(" ");
}
