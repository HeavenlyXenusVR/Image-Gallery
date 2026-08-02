-- Image Gallery backend entrypoint (Lua rewrite, first pass).
-- Run with: luajit main.lua   (see Dockerfile for the containerized path)

package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local httpd = require("httpd")
local db = require("db")
local config = require("config")
local routes = require("routes")

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
httpd.route("PATCH", "/api/me/profile", routes.update_profile)
httpd.route("PATCH", "/api/me/settings", routes.update_settings)
httpd.route("GET", "/api/appearance/presets", routes.appearance_presets)

httpd.route("GET", "/api/categories", routes.list_categories)
httpd.route("POST", "/api/categories", routes.create_category)

httpd.route("GET", "/api/media", routes.list_media)
httpd.route("POST", "/api/media", routes.upload_media)
-- "/bulk" and "/bulk-delete" MUST be registered before "/api/media/:media_id"
-- below (same first-match-wins ordering trap noted further down) since they
-- are literal 2nd-segment paths under /api/media/*, same shape as :media_id.
httpd.route("POST", "/api/media/bulk", routes.bulk_edit_media)
httpd.route("POST", "/api/media/bulk-delete", routes.bulk_delete_media)
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
httpd.route("DELETE", "/api/comments/:comment_id", routes.delete_comment)

httpd.route("GET", "/api/media/:media_id/thumb", routes.serve_media_thumb)
httpd.route("GET", "/api/media/:media_id/file", routes.serve_media_file)
httpd.route("GET", "/api/media/:media_id/preview", routes.serve_media_preview)
httpd.route("GET", "/api/media/:media_id/download", routes.download_media)
httpd.route("GET", "/api/users/:user_id/avatar", routes.serve_user_avatar)

httpd.route("GET", "/api/me/2fa/status", routes.totp_status)
httpd.route("POST", "/api/me/2fa/enroll", routes.totp_enroll)
httpd.route("POST", "/api/me/2fa/confirm", routes.totp_confirm)
httpd.route("POST", "/api/me/2fa/disable", routes.totp_disable)

httpd.route("GET", "/api/tags", routes.tag_cloud)
httpd.route("GET", "/api/site/announcement", routes.site_announcement)
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

local ok, err = db.ping()
if ok then
  print(string.format("[image-gallery-lua] Postgres reachable (server time: %s)", tostring(err)))
else
  print("[image-gallery-lua] WARNING: Postgres not reachable at startup: " .. tostring(err))
end

httpd.listen(settings.host, settings.port)
print(string.format("[image-gallery-lua] listening on %s:%d", settings.host, settings.port))
httpd.run()
