import { safeColor } from "./format.js";

const CHOICES = {
  theme_mode: new Set(["system", "dark", "light"]),
  grid_density: new Set(["compact", "comfortable", "wide"]),
  card_hover_effect: new Set(["lift", "zoom", "reveal", "glow", "none"]),
  media_border_style: new Set(["none", "soft", "crisp", "glow", "neon"]),
  card_info_display: new Set(["below", "overlay", "minimal", "hidden"]),
  gallery_font: new Set(["system", "serif", "mono", "rounded"]),
  profile_name_style: new Set(["display", "gradient", "glow", "outline"]),
  profile_header_style: new Set(["solid", "glass", "blur", "transparent", "gradient"]),
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

const CARD_ASPECT_MAP = {
  "16:9": "16 / 9",
  "4:3": "4 / 3",
  "1:1": "1 / 1",
  "3:4": "3 / 4",
  free: "",
};

const FONT_MAP = {
  serif: "'Georgia', 'Times New Roman', serif",
  mono: "'Fira Code', 'Consolas', monospace",
  rounded: "'Nunito', 'Varela Round', system-ui, sans-serif",
  system: "",
};

const COLUMN_GAP_MAP = {
  none: "0px",
  tight: "8px",
  normal: "14px",
  wide: "24px",
};

export function galleryStyle(settings) {
  const style = {
    "--accent": safeColor(settings?.accent_color || "#37c9a7"),
  };

  // Accent secondary for gradients
  const secondaryRaw = String(settings?.accent_secondary || "").trim();
  if (/^#[0-9a-f]{6}$/i.test(secondaryRaw)) {
    style["--accent-secondary"] = secondaryRaw;
  }

  // Server-computed (colorutil.lua via routes.lua's with_derived_accent):
  // real WCAG contrast-ratio text color and an auto-derived gradient partner
  // when accent_secondary was never set by the user.
  if (settings?.accent_contrast_text) style["--accent-contrast-text"] = safeColor(settings.accent_contrast_text);
  if (settings?.accent_gradient) style["--accent-gradient"] = settings.accent_gradient;

  // Gallery background color override
  const bgRaw = String(settings?.gallery_bg_color || "").trim();
  if (/^#[0-9a-f]{6}$/i.test(bgRaw)) {
    style["--gallery-bg-override"] = bgRaw;
  }

  // Card hover effect — expressed as CSS classes but also as a variable for CSS consumers
  const hoverEffect = String(settings?.card_hover_effect || "lift").trim().toLowerCase();
  if (["lift", "zoom", "reveal", "glow", "none"].includes(hoverEffect)) {
    style["--card-hover-effect"] = hoverEffect;
  }

  // Card aspect ratio
  const aspectKey = String(settings?.card_aspect_ratio || "free").trim();
  const aspectValue = CARD_ASPECT_MAP[aspectKey];
  if (aspectValue) style["--card-aspect-ratio"] = aspectValue;

  // Media border style — expressed as variable for CSS consumers
  const borderStyle = String(settings?.media_border_style || "none").trim().toLowerCase();
  if (["none", "soft", "crisp", "glow", "neon"].includes(borderStyle)) {
    style["--media-border-style"] = borderStyle;
  }

  // Gallery font
  const fontKey = String(settings?.gallery_font || "system").trim().toLowerCase();
  const fontValue = FONT_MAP[fontKey];
  if (fontValue) style["--gallery-font"] = fontValue;

  // Column gap
  const gapKey = String(settings?.column_gap || "normal").trim().toLowerCase();
  const gapValue = COLUMN_GAP_MAP[gapKey];
  if (gapValue !== undefined) style["--media-grid-gap"] = gapValue || "14px";

  return style;
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
  const style = {
    "--accent": safeColor(settings?.accent_color || fallbackAccent),
    "--profile-backdrop": safeImage(settings?.profile_backdrop_image_url),
    "--profile-backdrop-strength": `${Math.round(clamp(settings?.profile_backdrop_strength, 0.18, 0, 0.55) * 100)}%`,
    // "Panel glass" controls: opacity 1 / blur 0px reproduce the original
    // solid-panel look exactly, so a user who never touches these two new
    // settings sees no change at all. Lower opacity lets the site-wide
    // rotating background show through the profile panel itself.
    "--profile-surface-opacity": clamp(settings?.profile_surface_opacity, 1, 0.2, 1),
    "--profile-surface-blur": `${Math.round(clamp(settings?.profile_surface_blur, 0, 0, 24))}px`,
  };

  const profileBgRaw = String(settings?.profile_bg_color || "").trim();
  if (/^#[0-9a-f]{6}$/i.test(profileBgRaw)) {
    style["--profile-bg-override"] = profileBgRaw;
  }

  const nameStyle = String(settings?.profile_name_style || "display").trim().toLowerCase();
  if (["display", "gradient", "glow", "outline"].includes(nameStyle)) {
    style["--profile-name-style"] = nameStyle;
  }

  const headerStyle = String(settings?.profile_header_style || "solid").trim().toLowerCase();
  if (["solid", "glass", "blur", "transparent", "gradient"].includes(headerStyle)) {
    style["--profile-header-style"] = headerStyle;
  }

  return style;
}

export function galleryClassName(settings) {
  return [
    `gallery-theme-${choice(settings, "theme_mode", "system")}`,
    `gallery-grid-${choice(settings, "grid_density", "comfortable")}`,
    `gallery-hover-${choice(settings, "card_hover_effect", "lift")}`,
    `gallery-border-${choice(settings, "media_border_style", "none")}`,
    `gallery-info-${choice(settings, "card_info_display", "below")}`,
    `gallery-font-${choice(settings, "gallery_font", "system")}`,
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
    `profile-name-${choice(settings, "profile_name_style", "display")}`,
    `profile-header-${choice(settings, "profile_header_style", "solid")}`,
  ].join(" ");
}
