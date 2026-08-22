-- RSS 2.0 feeds + sitemap.xml -- pure server-rendered XML, same
-- hand-rolled-string-templating approach as html.lua/pages_auth.lua, no
-- extra dependency. Lets people subscribe to new uploads (sitewide, per-
-- category, per-tag, or per-uploader) in an ordinary feed reader, and
-- gives search engines a discoverable list of public post URLs.
--
-- Every query here is scoped to public, non-deleted media only -- these
-- are unauthenticated, crawlable endpoints by design, so there's no
-- viewer to check adult-content consent against; adult posts are
-- excluded outright rather than shown gated (a feed reader/search
-- engine has no login flow to gate behind anyway).
local db = require("db")
local html = require("html")
local routes = require("routes")

local M = {}

local XML_HEADERS = { ["Content-Type"] = "application/rss+xml; charset=utf-8" }
local SITEMAP_HEADERS = { ["Content-Type"] = "application/xml; charset=utf-8" }

local function request_origin(headers)
  headers = headers or {}
  local proto = (headers["x-forwarded-proto"] or "http"):match("^[^,%s]+") or "http"
  local host = (headers["x-forwarded-host"] or headers["host"] or "localhost"):match("^[^,%s]+") or "localhost"
  return proto .. "://" .. host
end

local function rss_item(origin, row)
  local link = origin .. "/media/" .. tostring(row.id)
  local thumb = origin .. "/api/media/" .. tostring(row.id) .. "/thumb?w=800"
  return ([[
  <item>
    <title>%s</title>
    <link>%s</link>
    <guid isPermaLink="true">%s</guid>
    <pubDate>%s</pubDate>
    <description>%s</description>
    <enclosure url="%s" type="image/webp" />
  </item>]]):format(
    html.esc(row.title or ("Post #" .. tostring(row.id))), html.esc(link), html.esc(link),
    html.esc(tostring(row.pub_date or "") .. " +0000"), html.esc(row.description or ""), html.esc(thumb)
  )
end

local function rss_feed(origin, title, description, self_path, rows)
  local items = {}
  for _, row in ipairs(rows) do items[#items + 1] = rss_item(origin, row) end
  return ([[<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
  <title>%s</title>
  <link>%s</link>
  <atom:link href="%s%s" rel="self" type="application/rss+xml" xmlns:atom="http://www.w3.org/2005/Atom" />
  <description>%s</description>
%s
</channel>
</rss>]]):format(html.esc(title), html.esc(origin), html.esc(origin), html.esc(self_path), html.esc(description), table.concat(items, "\n"))
end

-- RFC 822 date computed directly in SQL (RSS's <pubDate> requires this
-- exact format) rather than one extra query per feed item.
local BASE_MEDIA_SELECT = [[
  SELECT m.id, m.title, m.description, m.created_at,
         to_char(m.created_at, 'Dy, DD Mon YYYY HH24:MI:SS') AS pub_date
  FROM media_items m
]]

function M.site_feed(req)
  local origin = request_origin(req.headers)
  local rows = db.fetchall(BASE_MEDIA_SELECT .. [[
    WHERE m.deleted_at IS NULL AND m.visibility='public' AND m.is_adult=false
      AND (m.publish_at IS NULL OR m.publish_at <= now())
    ORDER BY m.created_at DESC
    LIMIT 50
  ]])
  return 200, rss_feed(origin, "Nyxframe", "Recent public uploads", "/feed.xml", rows), XML_HEADERS
end

function M.category_feed(req)
  local slug = req.params.slug
  local category = db.fetchone("SELECT id, name FROM categories WHERE slug=%s", slug)
  if not category then return 404, "Category not found.", { ["Content-Type"] = "text/plain" } end
  local origin = request_origin(req.headers)
  local rows = db.fetchall(BASE_MEDIA_SELECT .. [[
    WHERE m.deleted_at IS NULL AND m.visibility='public' AND m.is_adult=false AND m.category_id=%s
      AND (m.publish_at IS NULL OR m.publish_at <= now())
    ORDER BY m.created_at DESC
    LIMIT 50
  ]], tostring(category.id))
  return 200, rss_feed(origin, "Nyxframe: " .. category.name, "Recent public uploads in " .. category.name, "/feed/category/" .. slug .. ".xml", rows), XML_HEADERS
end

function M.user_feed(req)
  local username = req.params.username
  local user = db.fetchone("SELECT id, username, public_profile FROM users WHERE username=%s", username)
  if not user or not db.tobool(user.public_profile) then
    return 404, "User not found.", { ["Content-Type"] = "text/plain" }
  end
  local origin = request_origin(req.headers)
  local rows = db.fetchall(BASE_MEDIA_SELECT .. [[
    WHERE m.deleted_at IS NULL AND m.visibility='public' AND m.is_adult=false AND m.user_id=%s
      AND (m.publish_at IS NULL OR m.publish_at <= now())
    ORDER BY m.created_at DESC
    LIMIT 50
  ]], tostring(user.id))
  return 200, rss_feed(origin, "Nyxframe: @" .. user.username, "Recent public uploads by @" .. user.username, "/feed/user/" .. username .. ".xml", rows), XML_HEADERS
end

function M.tag_feed(req)
  local tag = tostring(req.params.tag or ""):lower():sub(1, 60)
  local origin = request_origin(req.headers)
  local rows = db.fetchall(BASE_MEDIA_SELECT .. [[
    WHERE m.deleted_at IS NULL AND m.visibility='public' AND m.is_adult=false
      AND (m.publish_at IS NULL OR m.publish_at <= now())
      AND (m.tags::jsonb ? %s)
    ORDER BY m.created_at DESC
    LIMIT 50
  ]], tag)
  return 200, rss_feed(origin, 'Nyxframe: "' .. tag .. '"', "Recent public uploads tagged " .. tag, "/feed/tag/" .. tag .. ".xml", rows), XML_HEADERS
end

-- Personal feed authenticated by a scoped API key (routes.lua's
-- api_keys/M.resolve_api_key) instead of a session -- the one consumer of
-- that feature for now. Unlike the public feeds above, this includes
-- private/unlisted posts and 18+ content: it's the key owner's own
-- library, gated by possession of their own key, not a public/crawlable
-- endpoint.
function M.personal_feed(req)
  local user_id = routes.resolve_api_key(req.query.key)
  if not user_id then return 401, "Invalid or revoked API key.", { ["Content-Type"] = "text/plain" } end
  local origin = request_origin(req.headers)
  local rows = db.fetchall(BASE_MEDIA_SELECT .. [[
    WHERE m.user_id=%s AND m.deleted_at IS NULL
    ORDER BY m.created_at DESC
    LIMIT 100
  ]], user_id)
  return 200, rss_feed(origin, "My Nyxframe uploads", "All of your uploads, any visibility", "/feed/me.xml", rows), XML_HEADERS
end

-- Plain list of public post URLs for search-engine discoverability.
-- Deliberately excludes 18+ posts (same reasoning as the RSS feeds above:
-- these are unauthenticated crawlable endpoints, adult content has no
-- business being indexed through them) and caps at a sane size rather
-- than paginating -- revisit with a sitemap index file if this gallery
-- ever has tens of thousands of public posts.
function M.sitemap(req)
  local origin = request_origin(req.headers)
  local rows = db.fetchall([[
    SELECT id, updated_at FROM media_items
    WHERE deleted_at IS NULL AND visibility='public' AND is_adult=false
      AND (publish_at IS NULL OR publish_at <= now())
    ORDER BY created_at DESC
    LIMIT 5000
  ]])
  local urls = { ("  <url><loc>%s/</loc></url>"):format(html.esc(origin)) }
  for _, row in ipairs(rows) do
    urls[#urls + 1] = ("  <url><loc>%s/media/%s</loc><lastmod>%s</lastmod></url>"):format(
      html.esc(origin), tostring(row.id), html.esc(tostring(row.updated_at or ""):sub(1, 10))
    )
  end
  local xml = ([[<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
%s
</urlset>]]):format(table.concat(urls, "\n"))
  return 200, xml, SITEMAP_HEADERS
end

return M
