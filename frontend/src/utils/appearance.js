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
  ].join(" ");
}
