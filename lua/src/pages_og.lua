-- Open Graph / Twitter Card link previews for /media/:id. Right now
-- sharing a post link to Discord/Twitter/iMessage/Slack shows a generic
-- app-shell preview (the React SPA's static index.html has no per-post
-- info -- it can't, it's the same file for every route). This intercepts
-- requests from known link-unfurling crawlers only and serves a tiny
-- static HTML page with real og:title/og:image/og:description tags
-- instead, while real browsers still get the normal SPA shell (see
-- static.lua's fallback, which calls into this module).
--
-- Deliberately excludes private and 18+ posts from ever getting a rich
-- preview -- crawlers ignore auth entirely, so a preview generated here is
-- effectively public regardless of the post's own visibility, and an
-- adult-flagged post's thumbnail auto-embedding in a Discord channel is
-- exactly the kind of accidental exposure this feature must not cause.
local db = require("db")
local html = require("html")
local cjson_safe = require("cjson.safe")

local M = {}

local function nn(v)
  if v == nil or v == cjson_safe.null then return nil end
  return v
end

-- Substring match against a lowercased User-Agent -- every one of these
-- unfurl bots identifies itself plainly (no need for a full UA parser).
local CRAWLER_PATTERNS = {
  "discordbot", "twitterbot", "facebookexternalhit", "slackbot",
  "telegrambot", "whatsapp", "linkedinbot", "pinterestbot", "redditbot",
  "skypeuripreview", "vkshare", "embedly", "googlebot", "bingbot",
}

function M.is_crawler(user_agent)
  local ua = tostring(user_agent or ""):lower()
  if ua == "" then return false end
  for _, pattern in ipairs(CRAWLER_PATTERNS) do
    if ua:find(pattern, 1, true) then return true end
  end
  return false
end

-- Returns an HTML string, or nil if this media_id isn't eligible for a
-- rich preview (missing, deleted, private, or 18+) -- callers should fall
-- through to the normal SPA shell in that case, not show an error page.
function M.render_media_preview(origin, media_id)
  local row = db.fetchone(
    [[
      SELECT m.id, m.title, m.description, m.is_adult, m.visibility, m.deleted_at, m.media_kind,
             u.username
      FROM media_items m
      JOIN users u ON u.id = m.user_id
      WHERE m.id=%s
    ]],
    tostring(media_id)
  )
  if not row then return nil end
  if nn(row.deleted_at) then return nil end
  if row.visibility ~= "public" then return nil end
  if db.tobool(row.is_adult) then return nil end

  local title = row.title and row.title ~= "" and row.title or ("Post by @" .. tostring(row.username))
  local description = (row.description and row.description ~= "") and row.description
    or ("Shared by @" .. tostring(row.username) .. " on Nyxframe")
  local thumb_url = origin .. "/api/media/" .. tostring(media_id) .. "/thumb?w=1200"
  local page_url = origin .. "/media/" .. tostring(media_id)
  local esc_title, esc_desc, esc_thumb, esc_url = html.esc(title), html.esc(description), html.esc(thumb_url), html.esc(page_url)

  return ([[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>%s</title>
<meta property="og:type" content="website">
<meta property="og:site_name" content="Nyxframe">
<meta property="og:title" content="%s">
<meta property="og:description" content="%s">
<meta property="og:image" content="%s">
<meta property="og:url" content="%s">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="%s">
<meta name="twitter:description" content="%s">
<meta name="twitter:image" content="%s">
<link rel="canonical" href="%s">
</head>
<body><p><a href="%s">%s</a></p></body>
</html>]]):format(
    esc_title, esc_title, esc_desc, esc_thumb, esc_url, esc_title, esc_desc, esc_thumb, esc_url, esc_url, esc_title
  )
end

return M
