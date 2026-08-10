-- Image Gallery backend entrypoint (Lua rewrite, first pass).
-- Run with: luajit main.lua   (see Dockerfile for the containerized path)

package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local httpd = require("httpd")
local db = require("db")
local config = require("config")
local routes = require("routes")
local static = require("static")
local pages_auth = require("pages_auth")
local pages_admin = require("pages_admin")
local pages_totp = require("pages_totp")
local pages_feeds = require("pages_feeds")

local settings = config.load()
routes.settings = settings
db.init(settings)

-- CORS: mirror app/main.py's allow-listed origins + regex fallback for
-- ephemeral tunnel hosts (Cloudflare/ngrok/pinggy). httpd.lua's CORS support
-- (vendored from SwarmPanel) only does exact-match against
-- M.cors.allowed_origins plus an optional M.cors.origin_suffix_matcher
-- function -- reused as-is rather than porting FastAPI's regex-based
-- CORSMiddleware line for line.
httpd.cors.allowed_origins = settings.cors_allowed_origins
if #httpd.cors.allowed_origins == 0 then
  httpd.cors.allowed_origins = {
    settings.pages_public_url:gsub("/+$", ""),
    "http://127.0.0.1:8788", "http://localhost:8788",
    "http://127.0.0.1:8000", "http://localhost:8000",
  }
end
if settings.cors_allow_origin_regex and settings.cors_allow_origin_regex ~= "" then
  -- NOT a full PCRE port of the Python regex (Lua patterns are far more
  -- limited) -- covers the common tunnel-host suffixes actually used by
  -- this deployment (trycloudflare.com, ngrok-free.dev, ngrok.io,
  -- pinggy-free.link, serveousercontent.com, lhr.life) plus private LAN
  -- http origins. Revisit if a new tunnel provider is added.
  local TUNNEL_SUFFIXES = { "trycloudflare%.com", "ngrok%-free%.dev", "ngrok%.io", "pinggy%-free%.link", "serveousercontent%.com", "lhr%.life" }
  httpd.cors.origin_suffix_matcher = function(origin)
    for _, suffix in ipairs(TUNNEL_SUFFIXES) do
      if origin:match("^https://[%w%-]+%." .. suffix .. "$") then return true end
    end
    if origin:match("^http://localhost:%d+$") or origin:match("^http://127%.0%.0%.1:%d+$") then return true end
    if origin:match("^http://10%.%d+%.%d+%.%d+:?%d*$") then return true end
    if origin:match("^http://192%.168%.%d+%.%d+:?%d*$") then return true end
    return false
  end
end

httpd.route("GET", "/api/health", routes.health)
httpd.route("GET", "/api/live/checks", routes.live_checks)

httpd.route("POST", "/api/auth/register", routes.register)
httpd.route("POST", "/api/auth/login", routes.login)
httpd.route("POST", "/api/auth/2fa/verify", routes.verify_2fa)
httpd.route("POST", "/api/auth/logout", routes.logout)
httpd.route("GET", "/api/me", routes.me)
httpd.route("GET", "/api/me/media", routes.my_media)
httpd.route("GET", "/api/me/stats", routes.creator_stats)
httpd.route("GET", "/api/me/likes", routes.feed_liked)
httpd.route("GET", "/api/feed/following", routes.feed_following)
httpd.route("PATCH", "/api/me/profile", routes.update_profile)
httpd.route("PATCH", "/api/me/settings", routes.update_settings)
httpd.route("POST", "/api/me/avatar", routes.update_avatar)
httpd.route("POST", "/api/me/age-verification", routes.verify_age)
httpd.route("POST", "/api/me/password", routes.change_password)
httpd.route("GET", "/api/me/export", routes.export_account)
httpd.route("GET", "/api/appearance/presets", routes.appearance_presets)

httpd.route("GET", "/api/categories", routes.list_categories)
httpd.route("POST", "/api/categories", routes.create_category)
httpd.route("GET", "/api/leaderboard", routes.leaderboard)

httpd.route("GET", "/api/media", routes.list_media)
httpd.route("POST", "/api/media", routes.upload_media)
-- "/bulk" and "/bulk-delete" MUST be registered before "/api/media/:media_id"
-- below (same first-match-wins ordering trap noted further down) since they
-- are literal 2nd-segment paths under /api/media/*, same shape as :media_id.
httpd.route("POST", "/api/media/bulk", routes.bulk_edit_media)
httpd.route("POST", "/api/media/bulk-delete", routes.bulk_delete_media)
httpd.route("POST", "/api/media/analyze", routes.analyze_media)
httpd.route("GET", "/api/media/trending", routes.media_trending)
-- ROUTE-ORDERING TRAP for future passes: httpd.lua's match_route() returns
-- the FIRST registered route whose pattern matches, with no most-specific-
-- wins logic. "/api/media/:media_id" below matches ANY single path segment
-- after "/api/media/", including literal ones like "analyze" (real Python
-- route -- see app/routers/media.py -- not yet ported here, part of the LLM
-- classification pipeline in TODO.md). Any such literal-segment route added
-- later MUST be registered BEFORE this line, or it will never be reached
-- (silently "handled" by media_detail's tonumber(...) failing and returning
-- a 404 instead of the real handler running).
httpd.route("GET", "/api/media/:media_id", routes.media_detail)
httpd.route("PATCH", "/api/media/:media_id", routes.update_media)
httpd.route("DELETE", "/api/media/:media_id", routes.delete_media)
httpd.route("POST", "/api/media/:media_id/like", routes.like_media)
httpd.route("POST", "/api/media/:media_id/bookmark", routes.bookmark_media)
httpd.route("POST", "/api/media/:media_id/comments", routes.add_comment)
httpd.route("POST", "/api/media/:media_id/react", routes.react_to_media_route)
httpd.route("GET", "/api/media/:media_id/similar", routes.similar_media)
httpd.route("PATCH", "/api/media/:media_id/controls", routes.set_media_controls)
httpd.route("POST", "/api/media/:media_id/restore", routes.restore_media)
httpd.route("POST", "/api/media/:media_id/report", routes.report_media)
httpd.route("POST", "/api/media/:media_id/ai/train", routes.train_media_ai)
httpd.route("POST", "/api/media/:media_id/diagnostics/load", routes.media_load_diagnostic)
httpd.route("GET", "/api/me/personal-tags", routes.my_personal_tags)
httpd.route("POST", "/api/media/:media_id/personal-tags", routes.add_personal_tag)
httpd.route("DELETE", "/api/media/:media_id/personal-tags/:tag", routes.remove_personal_tag)
httpd.route("DELETE", "/api/comments/:comment_id", routes.delete_comment)

httpd.route("GET", "/api/media/:media_id/thumb", routes.serve_media_thumb)
httpd.route("GET", "/api/media/:media_id/file", routes.serve_media_file)
httpd.route("GET", "/api/media/:media_id/preview", routes.serve_media_preview)
httpd.route("GET", "/api/media/:media_id/download", routes.download_media)
httpd.route("GET", "/api/users/:user_id/avatar", routes.serve_user_avatar)

-- Public profiles, follows, friend requests/friends, search, blocks -- see
-- routes.lua's "Public profiles, follows, friend requests..." section
-- header for why these were missing (never ported) and the git-history
-- recovery this pass is based on. "/search" MUST be registered before
-- "/api/users/:username" (same first-match-wins ordering trap noted
-- elsewhere in this file), and "/api/users/:username/profile" before the
-- bare "/api/users/:username" for the same reason.
httpd.route("GET", "/api/users/search", routes.search_users)
httpd.route("GET", "/api/users/:username/profile", routes.profile_page)
httpd.route("GET", "/api/users/:username", routes.public_profile)
httpd.route("POST", "/api/users/:user_id/follow", routes.follow_user)
httpd.route("POST", "/api/users/:user_id/friend-request", routes.send_friend_request)
httpd.route("GET", "/api/friends/requests", routes.friend_requests_list)
httpd.route("POST", "/api/friends/requests/:request_id", routes.respond_friend_request)
httpd.route("GET", "/api/me/friends", routes.my_friends)
httpd.route("GET", "/api/users/:user_id/followers", routes.user_followers)
httpd.route("GET", "/api/users/:user_id/following", routes.user_following)
httpd.route("GET", "/api/users/:user_id/friends", routes.user_friends)
httpd.route("POST", "/api/users/:user_id/block", routes.block_user)
httpd.route("GET", "/api/me/blocks", routes.my_blocks)

httpd.route("GET", "/api/me/2fa/status", routes.totp_status)
httpd.route("POST", "/api/me/2fa/enroll", routes.totp_enroll)
httpd.route("POST", "/api/me/2fa/confirm", routes.totp_confirm)
httpd.route("POST", "/api/me/2fa/disable", routes.totp_disable)

httpd.route("GET", "/api/tags", routes.tag_cloud)
httpd.route("GET", "/api/site/announcement", routes.site_announcement)
httpd.route("GET", "/api/site/background", routes.site_background)
httpd.route("GET", "/api/notifications", routes.notifications_list)
httpd.route("GET", "/api/notifications/unread-count", routes.notifications_unread_count)
httpd.route("POST", "/api/notifications/read-all", routes.notifications_mark_all_read)
httpd.route("POST", "/api/notifications/:notification_id/read", routes.notifications_mark_read)

-- "/threads" MUST be registered before "/api/messages/:user_id" (same
-- first-match-wins ordering trap noted above for /api/media/:media_id).
httpd.route("GET", "/api/messages/threads", routes.message_threads)
httpd.route("GET", "/api/messages/:user_id", routes.direct_messages)
httpd.route("POST", "/api/messages/:user_id", routes.send_direct_message)

-- "/suggestions" MUST be registered before "/api/collections/:collection_id".
httpd.route("GET", "/api/collections/suggestions", routes.collection_suggestions)
httpd.route("GET", "/api/collections", routes.list_collections)
httpd.route("POST", "/api/collections", routes.create_collection)
httpd.route("GET", "/api/collections/:collection_id", routes.collection_detail)
httpd.route("POST", "/api/collections/:collection_id/items", routes.save_collection_item)

httpd.route("GET", "/api/saved-searches", routes.list_saved_searches)
httpd.route("POST", "/api/saved-searches", routes.create_saved_search)
httpd.route("DELETE", "/api/saved-searches/:search_id", routes.delete_saved_search)

httpd.route("GET", "/api/stats", routes.admin_stats)
httpd.route("GET", "/api/admin/reports", routes.admin_list_reports)
httpd.route("POST", "/api/admin/reports/:report_id/resolve", routes.admin_resolve_report)
httpd.route("POST", "/api/admin/users/:user_id/ban", routes.admin_ban_user)
httpd.route("POST", "/api/admin/users/:user_id/unban", routes.admin_unban_user)
httpd.route("GET", "/api/admin/audit-log", routes.admin_audit_log)
httpd.route("GET", "/api/admin/flagged-media", routes.admin_flagged_media)
httpd.route("POST", "/api/admin/flagged-media/:media_id/resolve", routes.admin_resolve_flagged_media)
httpd.route("GET", "/api/admin/storage", routes.admin_storage)
httpd.route("POST", "/api/admin/storage/purge-orphans", routes.admin_purge_storage_orphans)
httpd.route("PATCH", "/api/admin/site-settings", routes.admin_update_site_settings)

-- "/export" MUST be registered before a future "/api/ai/vision/training/:id"-
-- shaped route, if one is ever added (none exists today, so ordering is not
-- currently load-bearing, but keep it above /training for consistency).
httpd.route("GET", "/api/ai/vision/status", routes.ai_vision_status)
httpd.route("GET", "/api/ai/vision/training/export", routes.export_ai_training)
httpd.route("GET", "/api/ai/vision/training", routes.list_ai_training)

-- Server-rendered login/register -- see pages_auth.lua's header comment for
-- why only these two pages, and how they reuse routes.login/register/
-- verify_2fa directly instead of duplicating auth logic. Registered before
-- static.register()/the SPA fallback so these exact paths win over the
-- React app's own client-side "/login" route on a hard navigation.
httpd.route("GET", "/login", pages_auth.login_page)
httpd.route("POST", "/login", pages_auth.login_submit)
httpd.route("POST", "/login/2fa", pages_auth.twofa_submit)
httpd.route("GET", "/register", pages_auth.register_page)
httpd.route("POST", "/register", pages_auth.register_submit)

-- Server-rendered site-owner admin dashboard -- see pages_admin.lua's
-- header comment. Every /admin/actions/* route re-checks site-ownership
-- itself (pages_admin.lua's gate()), so there's no privilege gap even
-- though these are registered like any other public path.
httpd.route("GET", "/admin", pages_admin.admin_page)
httpd.route("POST", "/admin/actions/report-resolve", pages_admin.action_report_resolve)
httpd.route("POST", "/admin/actions/flagged-resolve", pages_admin.action_flagged_resolve)
httpd.route("POST", "/admin/actions/ban", pages_admin.action_ban)
httpd.route("POST", "/admin/actions/unban", pages_admin.action_unban)
httpd.route("POST", "/admin/actions/purge-orphans", pages_admin.action_purge_orphans)
httpd.route("POST", "/admin/actions/site-settings", pages_admin.action_site_settings)

-- Server-rendered 2FA enrollment -- see pages_totp.lua's header comment.
-- Any logged-in user (not site-owner-only).
httpd.route("GET", "/settings/2fa", pages_totp.settings_page)
httpd.route("POST", "/settings/2fa/start", pages_totp.start_enrollment)
httpd.route("POST", "/settings/2fa/confirm", pages_totp.confirm_enrollment)
httpd.route("POST", "/settings/2fa/disable", pages_totp.disable_totp)

-- RSS feeds + sitemap -- see pages_feeds.lua's header comment. All public/
-- unauthenticated, crawlable endpoints. ".xml" is part of the literal path
-- (not an extension httpd.lua strips), matching what feed readers expect.
httpd.route("GET", "/feed.xml", pages_feeds.site_feed)
httpd.route("GET", "/feed/category/:slug.xml", pages_feeds.category_feed)
httpd.route("GET", "/feed/user/:username.xml", pages_feeds.user_feed)
httpd.route("GET", "/feed/tag/:tag.xml", pages_feeds.tag_feed)
httpd.route("GET", "/sitemap.xml", pages_feeds.sitemap)
httpd.route("GET", "/feed/me.xml", pages_feeds.personal_feed)

-- "On this day" memories + scoped read-only API keys.
httpd.route("GET", "/api/me/memories", routes.my_memories)
httpd.route("POST", "/api/me/api-keys", routes.create_api_key)
httpd.route("GET", "/api/me/api-keys", routes.list_api_keys)
httpd.route("DELETE", "/api/me/api-keys/:key_id", routes.revoke_api_key)

-- Serves the built React SPA directly at this backend's own hostname
-- (gallery.xenusanimations.studio), the same way SwarmPanel's Lua backend
-- now renders SwarmPanel directly -- see src/static.lua. Registered after
-- every /api/* route so nothing here can shadow the ordering-sensitive
-- :media_id-shaped API routes above.
static.register()
httpd.fallback_handler = static.fallback

local ok, err = db.ping()
if ok then
  print(string.format("[image-gallery-lua] Postgres reachable (server time: %s)", tostring(err)))
else
  print("[image-gallery-lua] WARNING: Postgres not reachable at startup: " .. tostring(err))
end

-- Telegram control-panel bridge (see lua/src/telegram.lua) -- runs as a
-- copas background coroutine within this same event loop, started before
-- httpd.run() so it's polling by the time the first HTTP request arrives.
-- No-op if no bot token is configured.
local telegram = require("telegram")
telegram.start(settings)

-- Weekly per-creator Discord stats digest (see lua/src/digest.lua) -- same
-- copas-background-coroutine pattern as telegram above.
local digest = require("digest")
digest.start(settings)

httpd.listen(settings.host, settings.port)
print(string.format("[image-gallery-lua] listening on %s:%d", settings.host, settings.port))
httpd.run()
