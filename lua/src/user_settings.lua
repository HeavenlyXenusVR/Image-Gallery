-- Port of app/db/account.py's AccountMixin.update_user_settings()/
-- update_user_profile() field cleaning, plus app/db/_shared.py's
-- DEFAULT_USER_SETTINGS. Previously NOT ported at all -- PATCH /api/me/
-- settings and PATCH /api/me/profile were entirely missing from routes.lua
-- (main.lua's own header comment flags this file as scoped to "health/auth/
-- categories/core media browsing only"). Every enum choice here has a real
-- server-side gate matching the Python original's `allowed_choices` dict
-- (frontend/src/utils/appearance.js's CHOICES set is the client-side mirror
-- of the same list and was already enum-safe; this was the missing
-- server-side half).
local cjson = require("cjson.safe")

local M = {}

M.DEFAULT_USER_SETTINGS = {
  theme_mode = "system", accent_color = "#37c9a7", accent_secondary = "", gallery_bg_color = "",
  grid_density = "comfortable", default_sort = "new", items_per_page = 24,
  autoplay_previews = false, muted_previews = true, reduce_motion = false,
  open_original_in_new_tab = false, blur_video_previews = false,
  profile_show_uploads = true, profile_show_collections = true, profile_show_friends = true,
  profile_show_follow_counts = true,
  profile_layout = "spotlight", profile_banner_style = "gradient", profile_card_style = "glass",
  profile_stat_style = "tiles", profile_content_focus = "balanced", profile_hero_alignment = "split",
  profile_avatar_shape = "circle", profile_media_shape = "soft", profile_surface_style = "standard",
  profile_social_layout = "rail", profile_featured_panel = "uploads",
  profile_backdrop_image_url = "", profile_backdrop_strength = 0.18, profile_show_joined_date = true,
  profile_name_style = "display", profile_header_style = "solid", profile_bg_color = "",
  card_hover_effect = "lift", card_aspect_ratio = "free", media_border_style = "none",
  gallery_font = "system", card_info_display = "below", column_gap = "normal",
  watermark_text = "", discord_webhook_url = "",
}

local ALLOWED_CHOICES = {
  theme_mode = { system = true, dark = true, light = true },
  grid_density = { compact = true, comfortable = true, wide = true },
  default_sort = { ["new"] = true, popular = true, downloads = true, views = true, old = true },
  profile_layout = { spotlight = true, magazine = true, stack = true, split = true, mosaic = true, timeline = true },
  profile_banner_style = { gradient = true, mesh = true, frame = true, aurora = true, spotlight = true, poster = true },
  profile_card_style = { glass = true, solid = true, outline = true, elevated = true, soft = true, edge = true },
  profile_stat_style = { tiles = true, ribbon = true, minimal = true },
  profile_content_focus = { balanced = true, gallery = true, collections = true, social = true },
  profile_hero_alignment = { split = true, start = true, center = true },
  profile_avatar_shape = { circle = true, rounded = true, square = true },
  profile_media_shape = { soft = true, crisp = true, poster = true },
  profile_surface_style = { standard = true, quiet = true, contrast = true, editorial = true },
  profile_social_layout = { rail = true, cards = true, compact = true },
  profile_featured_panel = { uploads = true, collections = true, friends = true },
  profile_name_style = { display = true, gradient = true, glow = true, outline = true },
  profile_header_style = { solid = true, glass = true, blur = true, transparent = true, gradient = true },
  card_hover_effect = { lift = true, zoom = true, reveal = true, glow = true, none = true },
  card_aspect_ratio = { ["16:9"] = true, ["4:3"] = true, ["1:1"] = true, ["3:4"] = true, free = true },
  media_border_style = { none = true, soft = true, crisp = true, glow = true, neon = true },
  gallery_font = { system = true, serif = true, mono = true, rounded = true },
  card_info_display = { overlay = true, below = true, hidden = true, minimal = true },
  column_gap = { tight = true, normal = true, wide = true, none = true },
}

local COLOR_FIELDS = { accent_color = true, accent_secondary = true, gallery_bg_color = true, profile_bg_color = true }
local URL_FIELDS = { profile_backdrop_image_url = true }

local function clean_color(value)
  local color = tostring(value or "#37c9a7"):match("^%s*(.-)%s*$")
  if not color:match("^#%x%x%x%x%x%x$") then error("Color must be a hex value like #37c9a7.", 0) end
  return color:lower()
end
M.clean_color = clean_color

local function clean_text(value, max_length, required)
  local text = tostring(value or ""):match("^%s*(.-)%s*$"):gsub("%s+", " ")
  if text == "" then
    if required then error("Field is required.", 0) end
    return nil
  end
  return text:sub(1, max_length)
end
M.clean_text = clean_text

local function clean_optional_url(value, max_length)
  local text = clean_text(value, max_length or 300)
  if not text then return nil end
  if not (text:match("^http://") or text:match("^https://")) then
    error("URL must start with http:// or https://.", 0)
  end
  return text
end
M.clean_optional_url = clean_optional_url

local function clean_tags(values)
  local clean, seen = {}, {}
  local list = values
  if type(values) == "string" then
    list = {}
    for tag in values:gmatch("[^,#%s]+") do list[#list + 1] = tag end
  end
  for _, raw in ipairs(list or {}) do
    local tag = tostring(raw or ""):match("^%s*(.-)%s*$"):gsub("[^A-Za-z0-9_.%-]+", ""):sub(1, 32)
    local lower = tag:lower()
    if tag ~= "" and not seen[lower] then
      seen[lower] = true
      clean[#clean + 1] = tag
      if #clean >= 12 then break end
    end
  end
  return clean
end
M.clean_tags = clean_tags

-- Port of is_valid_discord_webhook_url() (app/discord_webhook.py): full
-- https://discord.com/api/webhooks/<id>/<token> shape check, not just a
-- prefix match, so a stored webhook URL is always actually postable-to.
local function is_valid_discord_webhook_url(url)
  local host, path = tostring(url or ""):match("^https://([^/]+)(/.*)$")
  if not host then return false end
  host = host:lower()
  if host ~= "discord.com" and host ~= "www.discord.com" and host ~= "discordapp.com" and host ~= "www.discordapp.com" then
    return false
  end
  local parts = {}
  for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
  return #parts >= 4 and parts[1] == "api" and parts[2] == "webhooks"
end
M.is_valid_discord_webhook_url = is_valid_discord_webhook_url

-- payload: decoded JSON body (only keys the client actually sent should be
-- present -- caller filters nils before calling, matching Python's
-- `{k: v for k, v in payload.items() if v is not None}`).
-- existing: the user's current user_settings table (already-decoded JSON),
-- or {} for a brand new account.
function M.clean_user_settings(payload, existing)
  local settings = {}
  for k, v in pairs(M.DEFAULT_USER_SETTINGS) do settings[k] = v end
  for k, v in pairs(existing or {}) do settings[k] = v end

  for key in pairs(M.DEFAULT_USER_SETTINGS) do
    if payload[key] ~= nil then
      local value = payload[key]
      if ALLOWED_CHOICES[key] then
        local choice = tostring(value)
        if not ALLOWED_CHOICES[key][choice] then error("Invalid " .. key .. ".", 0) end
        settings[key] = choice
      elseif COLOR_FIELDS[key] then
        settings[key] = (value and value ~= "") and clean_color(value) or ""
      elseif key == "items_per_page" then
        local n = tonumber(value) or 24
        settings[key] = math.max(12, math.min(math.floor(n), 60))
      elseif URL_FIELDS[key] then
        settings[key] = clean_optional_url(value, 500) or ""
      elseif key == "profile_backdrop_strength" then
        local n = tonumber(value)
        if value ~= nil and not n then error("Backdrop strength must be a number.", 0) end
        settings[key] = math.max(0.0, math.min(n or 0.18, 0.55))
      elseif key == "watermark_text" then
        settings[key] = tostring(value or ""):match("^%s*(.-)%s*$"):sub(1, 40)
      elseif key == "discord_webhook_url" then
        local text = tostring(value or ""):match("^%s*(.-)%s*$"):sub(1, 300)
        if text ~= "" and not is_valid_discord_webhook_url(text) then
          error("Discord webhook URL must start with https://discord.com/api/webhooks/.", 0)
        end
        settings[key] = text
      else
        settings[key] = value and true or false
      end
    end
  end
  return settings
end

-- Port of update_user_profile()'s field cleaning (users table columns, not
-- user_settings JSON). website_url gets the same http(s):// gate as the
-- Python original.
function M.clean_profile_updates(payload)
  local fields = {
    display_name = clean_text(payload.display_name, 80, true),
    bio = clean_text(payload.bio, 500),
    profile_quote = clean_text(payload.profile_quote, 200),
    website_url = clean_text(payload.website_url, 300),
    location_label = clean_text(payload.location_label, 80),
    profile_headline = clean_text(payload.profile_headline, 120),
    featured_tags = cjson.encode(clean_tags(payload.featured_tags or {})),
    profile_color = clean_color(payload.profile_color),
    public_profile = (payload.public_profile == nil) and true or (payload.public_profile and true or false),
    show_liked_count = (payload.show_liked_count == nil) and true or (payload.show_liked_count and true or false),
    show_collections = (payload.show_collections == nil) and true or (payload.show_collections and true or false),
    show_recent_uploads = (payload.show_recent_uploads == nil) and true or (payload.show_recent_uploads and true or false),
    show_friends = (payload.show_friends == nil) and true or (payload.show_friends and true or false),
  }
  if fields.website_url and not (fields.website_url:match("^http://") or fields.website_url:match("^https://")) then
    error("Website must start with http:// or https://.", 0)
  end
  return fields
end

return M
