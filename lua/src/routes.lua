-- Route handlers. Registered against httpd.lua's M.route(method, pattern, handler)
-- in main.lua. Each handler receives httpd.lua's `req` table and returns
-- (status, body_table_or_string, extra_headers).
--
-- Scope note (last updated 2026-08-01): health/auth/categories/media
-- browsing+upload/social(likes,comments,bookmarks,reactions)/collections/
-- direct messages/site-owner admin+moderation/Discord upload webhooks/AI
-- vision status+training-export are all ported. Still NOT ported:
--   * The LLM-calling AI classification/analysis pipeline itself
--     (app/ai_metadata.py, ~2150 lines: OpenAI/Gemini/Ollama prompt
--     construction + heuristic fallback) that powers auto_ai on upload and
--     POST /api/media/analyze -- upload_media() below always requires an
--     explicit title/category instead of falling back to AI analysis.
--   * Telegram bot integration (app/telegram.py + whatever gallery-specific
--     command handlers are wired to it) -- a long-running polling
--     background service, architecturally distinct from this file's
--     request/response handlers.
--   * Possible-duplicate perceptual-hash detection, background AI
--     learning, saved-search match notifications, multi-subcategory arrays,
--     and video thumb/quality cache warmup (see upload_media()'s own
--     header comment).
--   * Admin storage dashboard / orphan-cache-purge endpoints (filesystem
--     walk of the on-disk thumb/video cache dirs; see the admin section's
--     header comment).

local cjson = require("cjson.safe")
local db = require("db")
local gauth = require("gallery_auth")
local ratelimit = require("ratelimit")
local totp = require("totp")
local media_files = require("media_files")
local user_settings = require("user_settings")
local gallery_looks = require("gallery_looks")
local colorutil = require("colorutil")
local discord_webhook = require("discord_webhook")

-- Attaches computed accent_contrast_text/accent_gradient onto a decoded
-- user's user_settings table, mirroring SwarmPanel's with_derived_accent.
-- Frontend no longer has to guess at readable text color for a user's
-- chosen accent, and always gets a sensible gradient partner even if
-- accent_secondary was never set.
local function with_derived_accent(user)
  if not user or type(user.user_settings) ~= "table" then return user end
  local accent = user.user_settings.accent_color
  if not accent or accent == "" then return user end
  local secondary = user.user_settings.accent_secondary
  if not secondary or secondary == "" then secondary = colorutil.auto_secondary(accent) end
  user.user_settings.accent_contrast_text = colorutil.contrast_text(accent)
  user.user_settings.accent_gradient = colorutil.gradient(accent, secondary)
  return user
end

-- This LuaJIT build has no table.unpack (only the global unpack()) -- same
-- shim already documented and applied in lib/swarmlua/pg.lua; needed again
-- here since list_media() below builds its parameter list dynamically.
local unpack = table.unpack or unpack

-- Forward declarations: verify_2fa (defined early, near the other auth
-- handlers, to match main.lua's route-registration reading order) calls
-- this, but its real implementation lives down in the TOTP section below
-- alongside the rest of the 2FA enroll/confirm/disable code it belongs with.
local verify_totp_or_recovery

local M = {}
M.settings = nil -- set by main.lua

local function json_body(req)
  if req.json and next(req.json) ~= nil then return req.json end
  if req.raw_body and req.raw_body ~= "" then
    local decoded = cjson.decode(req.raw_body)
    if decoded then return decoded end
  end
  return {}
end

-- Normalizes cjson.null and Lua nil to Lua nil so `value or default` fallback
-- patterns are safe everywhere in this file (cjson's null sentinel is a
-- non-nil, non-false lightuserdata that defeats `or` otherwise).
local function nn(v)
  if v == nil or v == cjson.null then return nil end
  return v
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- cjson can't tell an empty Lua table `{}` was meant as a JSON array `[]`
-- vs object `{}` and defaults to encoding it as `{}`  -- wrong for every
-- list-shaped API field here (media, subcategories, ...) whenever the list
-- happens to be empty, which silently breaks any frontend code that expects
-- to .map()/.forEach() the field. Use this for every such field instead of
-- a bare `{}`/`t`.
local function arr(t)
  if t == nil or next(t) == nil then return cjson.empty_array end
  return t
end

local function client_ip(req)
  return req.client_ip or "unknown"
end

-- ---------------------------------------------------------------------------
-- User row shaping (mirrors app/routers/_shared.py's _jsonable + the column
-- list app/db/account.py's get_user() selects).
-- ---------------------------------------------------------------------------

local USER_PUBLIC_COLUMNS = [[
  id, username, display_name, bio, website_url, location_label, profile_headline,
  featured_tags, profile_color,
  email, email_verified_at, avatar_path, avatar_file_id, avatar_mime_type, avatar_original_filename, public_profile,
  show_liked_count, show_collections, show_recent_uploads, show_friends,
  birthdate, age_verified_at, adult_content_consent, totp_enabled_at,
  user_settings, created_at, updated_at, last_seen_at,
  banned_at, banned_until, ban_reason
]]

local function decode_user(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  if row.avatar_file_id then row.avatar_file_id = db.toint(row.avatar_file_id, row.avatar_file_id) end
  row.public_profile = db.tobool(row.public_profile)
  row.show_liked_count = db.tobool(row.show_liked_count)
  row.show_collections = db.tobool(row.show_collections)
  row.show_recent_uploads = db.tobool(row.show_recent_uploads)
  row.show_friends = db.tobool(row.show_friends)
  row.adult_content_consent = db.tobool(row.adult_content_consent)
  row.totp_enabled = row.totp_enabled_at ~= nil and row.totp_enabled_at ~= cjson.null
  if row.featured_tags and row.featured_tags ~= cjson.null then
    row.featured_tags = cjson.decode(row.featured_tags) or {}
  else
    row.featured_tags = {}
  end
  if row.user_settings and row.user_settings ~= cjson.null then
    row.user_settings = cjson.decode(row.user_settings) or {}
  else
    row.user_settings = {}
  end
  return row
end

local function get_user(user_id)
  local row = db.fetchone("SELECT " .. USER_PUBLIC_COLUMNS .. " FROM users WHERE id=%s", user_id)
  return decode_user(row)
end

local SITE_OWNER_EMAIL = "heavenlyxenusvr@icloud.com"

local function is_site_owner(user)
  return user and nn(user.email_verified_at) ~= nil and tostring(user.email or ""):lower() == SITE_OWNER_EMAIL
end

local function is_actively_banned(user)
  if not user or nn(user.banned_at) == nil then return false end
  local until_ts = nn(user.banned_until)
  if not until_ts then return true end
  -- Postgres returns timestamps as "YYYY-MM-DD HH:MM:SS[.ffffff]" text; ISO-
  -- 8601 lexical order matches chronological order for this fixed format, so
  -- a plain string compare against a same-format "now" string is sufficient
  -- and avoids needing a date-parsing library for this check.
  local now_row = db.fetchone("SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS') AS now")
  return now_row and tostring(until_ts) > now_row.now
end

local function parse_cookies(req)
  local cookie_header = req.headers["cookie"] or ""
  local cookies = {}
  for k, v in cookie_header:gmatch("([%w_%-]+)=([^;]+)") do cookies[k] = v end
  return cookies
end

-- Depends()-equivalent: returns (user, auth_payload) or (nil, nil, status, body)
-- on failure. auth_payload is the decoded token {id, username, display_name}.
local function current_user(req)
  local auth = gauth.require_auth(req.headers, parse_cookies(req), M.settings.session_secret, M.settings.api_token_ttl_seconds)
  if not auth then return nil, nil, 401, { detail = "Login required" } end
  local user = get_user(auth.id)
  if is_actively_banned(user) then
    return nil, nil, 403, { detail = (user and nn(user.ban_reason)) or "Your account has been suspended." }
  end
  return user, auth, nil, nil
end

local function auth_optional(req)
  return gauth.require_auth(req.headers, parse_cookies(req), M.settings.session_secret, M.settings.api_token_ttl_seconds)
end

-- ---------------------------------------------------------------------------
-- Health / live checks
-- ---------------------------------------------------------------------------

function M.health(req)
  return 200, {
    ok = true,
    schema = M.settings.db_schema,
    storage_backend = M.settings.storage_backend,
    max_upload_bytes = M.settings.max_upload_bytes,
    media_page_limit = M.settings.media_page_limit,
    max_tags_per_upload = M.settings.max_tags_per_upload,
    request_id = req.headers["x-request-id"] or "",
    server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
  }
end

function M.live_checks(req)
  local checks = {}
  local ok, err = db.ping()
  if not ok then
    return 200, {
      ok = false,
      status = "offline",
      backend = "image_gallery",
      checks = { { id = "db", label = "Database reachable", ok = false, severity = "error", detail = "Database is unreachable." } },
      check_map = { api = true, db = false },
      snapshot = cjson.empty_array or {},
      storage_backend = M.settings.storage_backend,
      max_upload_bytes = M.settings.max_upload_bytes,
      media_page_limit = M.settings.media_page_limit,
      server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
    }
  end
  checks[#checks + 1] = { id = "api", label = "API reachable", ok = true, detail = "Backend responded." }
  checks[#checks + 1] = { id = "db", label = "Database reachable", ok = true, detail = "Schema " .. M.settings.db_schema .. " responded." }
  local auth = auth_optional(req)
  if auth then
    local user = get_user(auth.id)
    checks[#checks + 1] = { id = "session", label = "Login session", ok = user ~= nil, detail = user and "Signed in." or "Token is invalid or account is gone." }
  end
  local check_map = {}
  for _, c in ipairs(checks) do check_map[c.id] = c.ok end
  return 200, {
    ok = true,
    status = "ok",
    backend = "image_gallery",
    checks = checks,
    check_map = check_map,
    snapshot = {},
    storage_backend = M.settings.storage_backend,
    max_upload_bytes = M.settings.max_upload_bytes,
    media_page_limit = M.settings.media_page_limit,
    server_time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
  }
end

-- ---------------------------------------------------------------------------
-- Auth: register / login / logout / me / 2fa verify
-- ---------------------------------------------------------------------------

local function normalize_username(u)
  return trim(u):lower():sub(1, 40)
end

local function normalize_email(e)
  e = trim(e or ""):lower()
  if e == "" then return nil end
  return e:sub(1, 255)
end

function M.register(req)
  local ok429, body429 = ratelimit.check("register:" .. client_ip(req), 10, 3600)
  if ok429 then return ok429, body429 end
  local payload = json_body(req)
  local username = normalize_username(nn(payload.username) or "")
  local password = nn(payload.password) or ""
  local email = normalize_email(nn(payload.email))
  local display_name = trim(nn(payload.display_name) or username):sub(1, 80)
  if display_name == "" then display_name = username end

  if username == "" then return 400, { detail = "Username is required." } end
  if #password < 8 then return 400, { detail = "Password must be at least 8 characters." } end

  local existing = db.fetchone("SELECT id FROM users WHERE username=%s OR (email=%s AND email IS NOT NULL)", username, email)
  if existing then return 409, { detail = "That username or email is already taken." } end

  local password_hash = gauth.password_hash(password)
  local row, err = db.fetchone(
    "INSERT INTO users (username, display_name, password_hash, email) VALUES (%s, %s, %s, %s) RETURNING id",
    username, display_name, password_hash, email
  )
  if not row then return 500, { detail = "Registration failed: " .. tostring(err) } end
  local user = get_user(row.id)
  local token = gauth.issue_token(M.settings.session_secret, user, M.settings.api_token_ttl_seconds)
  return 200, {
    user = user,
    token = token,
    email_verification_sent = false,
    email_error = nil,
  }, { ["Set-Cookie"] = gauth.SESSION_COOKIE_NAME .. "=" .. token .. "; Path=/; HttpOnly; Max-Age=" .. M.settings.api_token_ttl_seconds }
end

function M.login(req)
  local payload = json_body(req)
  local username_raw = trim(nn(payload.username) or ""):sub(1, 80)
  local password = nn(payload.password) or ""
  local ip = client_ip(req)

  local recent = db.fetchone([[
    SELECT COUNT(*) AS n FROM auth_attempts
    WHERE successful=false AND created_at >= (now() - interval '15 minutes')
      AND (ip_address=%s OR username=%s)
  ]], ip, username_raw)
  if recent and db.toint(recent.n, 0) >= 8 then
    return 429, { detail = "Too many failed login attempts. Try again later." }
  end

  local username = normalize_username(username_raw)
  local row = db.fetchone("SELECT id, password_hash FROM users WHERE username=%s", username)
  local password_ok = row and gauth.verify_password_hash(password, row.password_hash)

  db.execute("INSERT INTO auth_attempts (username, ip_address, successful) VALUES (%s, %s, %s)",
    username_raw ~= "" and username_raw or nil, ip:sub(1, 64), password_ok and true or false)

  if not password_ok then return 401, { detail = "Invalid username or password." } end

  db.execute("UPDATE users SET last_login_at=now(), last_seen_at=now() WHERE id=%s", row.id)
  local user = get_user(row.id)
  if is_actively_banned(user) then
    return 403, { detail = nn(user.ban_reason) or "Your account has been suspended." }
  end
  if user.totp_enabled then
    local pending = gauth.issue_2fa_pending_token(M.settings.session_secret, user.id)
    return 200, { needs_2fa = true, pending_token = pending }
  end
  local token = gauth.issue_token(M.settings.session_secret, user, M.settings.api_token_ttl_seconds)
  return 200, { user = user, token = token }, { ["Set-Cookie"] = gauth.SESSION_COOKIE_NAME .. "=" .. token .. "; Path=/; HttpOnly; Max-Age=" .. M.settings.api_token_ttl_seconds }
end

function M.verify_2fa(req)
  local payload = json_body(req)
  local pending_token = nn(payload.pending_token)
  local code = tostring(nn(payload.code) or "")
  local user_id = pending_token and gauth.verify_2fa_pending_token(M.settings.session_secret, pending_token)
  if not user_id then return 401, { detail = "Your sign-in attempt expired. Log in again." } end
  local ok429, body429 = ratelimit.check("2fa-verify:" .. user_id, 10, 600)
  if ok429 then return ok429, body429 end
  if not verify_totp_or_recovery(user_id, code) then
    return 400, { detail = "Invalid authentication code." }
  end
  local user = get_user(user_id)
  if not user then return 404, { detail = "Account not found." } end
  local token = gauth.issue_token(M.settings.session_secret, user, M.settings.api_token_ttl_seconds)
  return 200, { user = user, token = token }, { ["Set-Cookie"] = gauth.SESSION_COOKIE_NAME .. "=" .. token .. "; Path=/; HttpOnly; Max-Age=" .. M.settings.api_token_ttl_seconds }
end

function M.logout(req)
  return 200, { ok = true }, { ["Set-Cookie"] = gauth.SESSION_COOKIE_NAME .. "=; Path=/; HttpOnly; Max-Age=0" }
end

function M.me(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  user.site_owner = is_site_owner(user)
  return 200, { user = with_derived_accent(user) }
end

-- Port of app/routers/account.py's PATCH /api/me/profile. Previously
-- entirely missing (see this file's header comment: "first pass ... core
-- media browsing only") -- SettingsPage.jsx/ProfilePage.jsx had no working
-- server endpoint to save profile edits to against this backend.
function M.update_profile(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local ok, result = pcall(user_settings.clean_profile_updates, json_body(req))
  if not ok then return 400, { detail = tostring(result):gsub("^.-:%d+:%s*", "") } end
  db.execute(
    [[UPDATE users SET display_name=%s, bio=%s, profile_quote=%s, website_url=%s, location_label=%s,
             profile_headline=%s, featured_tags=%s, profile_color=%s,
             public_profile=%s, show_liked_count=%s, show_collections=%s,
             show_recent_uploads=%s, show_friends=%s
      WHERE id=%s]],
    result.display_name, result.bio, result.profile_quote, result.website_url, result.location_label,
    result.profile_headline, result.featured_tags, result.profile_color,
    result.public_profile, result.show_liked_count, result.show_collections,
    result.show_recent_uploads, result.show_friends, user.id
  )
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_derived_accent(refreshed) }
end

-- Port of app/routers/account.py's PATCH /api/me/settings + app/db/
-- account.py's update_user_settings() enum/color/url validation (see
-- user_settings.lua's header comment -- this whole endpoint, and the
-- server-side enforcement of appearance.js's CHOICES set, was missing).
function M.update_settings(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  -- exclude_unset-equivalent: only keys the client actually sent, and only
  -- non-null values (matches account.py's `if value is not None` filter).
  local filtered = {}
  for k, v in pairs(payload) do
    if v ~= nil and v ~= cjson.null then filtered[k] = v end
  end
  local ok, result = pcall(user_settings.clean_user_settings, filtered, user.user_settings or {})
  if not ok then return 400, { detail = tostring(result):gsub("^.-:%d+:%s*", "") } end
  db.execute("UPDATE users SET user_settings=%s WHERE id=%s", cjson.encode(result), user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_derived_accent(refreshed) }
end

-- Server-owned appearance presets (see gallery_looks.lua), mirroring
-- SwarmPanel's /api/appearance/presets.
function M.appearance_presets(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  return 200, { gallery = gallery_looks.GALLERY_LOOKS, profile = gallery_looks.PROFILE_LOOKS }
end

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------

function M.list_categories(req)
  local categories = db.fetchall([[
    SELECT c.id, c.name, c.slug, c.media_kind, c.created_by, c.created_at,
           COUNT(m.id) AS media_count
    FROM categories c
    LEFT JOIN media_items m ON m.category_id = c.id AND m.deleted_at IS NULL
    GROUP BY c.id
    ORDER BY c.name
  ]])
  local subcategories = db.fetchall([[
    SELECT s.id, s.category_id, s.name, s.slug, s.created_by, s.created_at,
           COUNT(m.id) AS media_count
    FROM subcategories s
    LEFT JOIN media_item_subcategories ms ON ms.subcategory_id = s.id
    LEFT JOIN media_items m ON m.id = ms.media_id AND m.deleted_at IS NULL
    GROUP BY s.id
    ORDER BY s.name
  ]])
  -- pg.lua forces every bigint (oid 20) column -- id, category_id,
  -- created_by, and the COUNT(...) aggregate -- to come back as a STRING to
  -- protect Discord-snowflake-scale values from float precision loss (see
  -- db.lua's module comment). None of these particular columns ever reach
  -- that scale (small autoincrement ids, small counts), so convert them
  -- back to real numbers here to match app/db/categories.py's JSON contract
  -- (Python/aiomysql returns them as plain ints, serialized as JSON numbers,
  -- not strings) -- do this at the response boundary, not in db.lua itself,
  -- so the precision-safety default stays intact for anything that DOES
  -- need it.
  local function numify_category(row)
    row.id = db.toint(row.id, row.id)
    row.created_by = row.created_by ~= nil and db.toint(row.created_by, row.created_by) or nil
    row.media_count = db.toint(row.media_count, 0)
    return row
  end
  local grouped = {}
  for _, row in ipairs(subcategories) do
    local cid = tostring(row.category_id)
    numify_category(row)
    row.category_id = db.toint(cid, cid)
    grouped[cid] = grouped[cid] or {}
    table.insert(grouped[cid], row)
  end
  for _, row in ipairs(categories) do
    local cid = tostring(row.id)
    numify_category(row)
    row.subcategories = arr(grouped[cid] or {})
  end
  return 200, { categories = arr(categories) }
end

local MEDIA_KINDS = { image = true, video = true, mixed = true }

local function slugify(name)
  local slug = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then slug = "category" end
  return slug:sub(1, 80)
end

function M.create_category(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local name = trim(nn(payload.name) or ""):sub(1, 80)
  local media_kind = nn(payload.media_kind) or "mixed"
  if name == "" then return 400, { detail = "Category name is required." } end
  if not MEDIA_KINDS[media_kind] then return 400, { detail = "Category type must be image, video, or mixed." } end
  local slug = slugify(name)
  local existing = db.fetchone("SELECT * FROM categories WHERE name=%s OR slug=%s", name, slug)
  if existing then
    existing.id = db.toint(existing.id, existing.id)
    if existing.created_by then existing.created_by = db.toint(existing.created_by, existing.created_by) end
    return 200, { category = existing }
  end
  local row = db.fetchone(
    "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, %s) RETURNING *",
    name, slug, media_kind, user.id
  )
  if row then
    row.id = db.toint(row.id, row.id)
    if row.created_by then row.created_by = db.toint(row.created_by, row.created_by) end
  end
  return 200, { category = row }
end

-- ---------------------------------------------------------------------------
-- Media listing (GET /api/media) -- core browsing.
--
-- NOT YET PORTED as part of this: url/thumb_url/preview_url/download_url
-- generation (app/routers/_shared.py's _with_urls) -- those point at
-- file-serving routes (serve_media_file/thumb/preview, byte-range video
-- streaming) that this pass does not implement (see final report). This
-- returns full metadata (title, tags, counts, category, uploader) with
-- url fields left null so the contract shape matches but media bytes are
-- not yet servable through this backend.
-- ---------------------------------------------------------------------------

local VALID_SORTS = { new = true, old = true, popular = true, views = true, downloads = true }

local function bounded_limit(v, default, max_limit)
  local n = tonumber(v) or default
  return math.max(1, math.min(n, max_limit or M.settings.media_page_limit))
end

local function bounded_offset(v)
  local n = tonumber(v) or 0
  return math.max(0, n)
end

-- See the identical numify comment in list_categories: these id/count
-- columns are all small in practice (never Discord-snowflake scale), so
-- convert pg.lua's precision-safety string coercion back to real JSON
-- numbers here to match app/db/media.py's contract.
local function numify_media(row)
  for _, field in ipairs({ "id", "user_id", "category_id", "subcategory_id", "file_size", "views", "downloads", "like_count", "comment_count" }) do
    if row[field] ~= nil then row[field] = db.toint(row[field], row[field]) end
  end
  return row
end

-- Mirrors app/routers/_shared.py's _append_query().
local function append_query(url, key, value)
  local sep = url:find("?", 1, true) and "&" or "?"
  return url .. sep .. key .. "=" .. value
end

-- Absolute origin (scheme://host) for the request, honoring a reverse proxy's
-- X-Forwarded-Proto/Host the same way app/routers/_shared.py's
-- _api_cache_origin() does. Needed because the frontend is hosted on a
-- different origin (GitHub Pages / a tunnel domain) than the API, so
-- relative URLs in JSON responses would resolve against the WRONG origin in
-- the browser -- these must be absolute.
local function request_origin(req)
  local proto = (req.headers["x-forwarded-proto"] or "http"):match("^[^,%s]+") or "http"
  local host = (req.headers["x-forwarded-host"] or req.headers["host"] or "localhost"):match("^[^,%s]+") or "localhost"
  return proto .. "://" .. host
end

local function is_gif_media(row)
  local mime = tostring(row.mime_type or ""):lower()
  local filename = tostring(row.original_filename or row.storage_path or ""):lower()
  return mime == "image/gif" or filename:sub(-4) == ".gif"
end

-- Mirrors app/routers/_shared.py's _with_urls(): fills in url/thumb_url/
-- preview_url/download_url (and user_avatar_url) pointing at THIS backend's
-- own byte-serving routes (see M.serve_media_thumb/file/preview/download
-- below), or nulls them out entirely for a locked (is_adult, viewer not
-- age-verified) row. Mutates and returns `row`.
local function with_urls(req, row, adult_allowed)
  if not row then return nil end
  local origin = request_origin(req)
  local locked = row.is_adult and not adult_allowed
  row.locked = locked
  row.viewer_can_open_adult = adult_allowed
  row.requires_adult_blur = row.is_adult and adult_allowed
  if locked then
    row.storage_path = nil
    row.url, row.preview_url, row.thumb_url, row.download_url = nil, nil, nil, nil
  else
    local media_id = row.id
    row.url = origin .. "/api/media/" .. media_id .. "/file"
    row.download_url = origin .. "/api/media/" .. media_id .. "/download"
    if row.media_kind == "image" or row.media_kind == "video" then
      row.thumb_url = append_query(origin .. "/api/media/" .. media_id .. "/thumb", "w", "640")
    else
      row.thumb_url = nil
    end
    if is_gif_media(row) then
      row.preview_url = row.url
    elseif row.media_kind == "image" then
      row.preview_url = origin .. "/api/media/" .. media_id .. "/preview"
    else
      row.preview_url = row.thumb_url
    end
    if row.is_adult and adult_allowed then
      local token = gauth.media_access_token(M.settings.session_secret, media_id)
      row.url = append_query(row.url, "access", token)
      if row.preview_url then row.preview_url = append_query(row.preview_url, "access", token) end
      if row.thumb_url then row.thumb_url = append_query(row.thumb_url, "access", token) end
      row.download_url = append_query(row.download_url, "access", token)
    end
  end
  if row.user_avatar_path and row.user_avatar_path ~= cjson.null then
    row.user_avatar_url = origin .. "/api/users/" .. (row.user_id or row.id) .. "/avatar"
  end
  return row
end

local function decode_media_row(row, viewer_can_open_adult, req)
  numify_media(row)
  row.is_adult = db.tobool(row.is_adult)
  row.adult_marked_by_user = db.tobool(row.adult_marked_by_user)
  row.adult_marked_by_ai = db.tobool(row.adult_marked_by_ai)
  row.comments_enabled = db.tobool(row.comments_enabled)
  row.downloads_enabled = db.tobool(row.downloads_enabled)
  row.public_profile = db.tobool(row.public_profile)
  row.liked_by_me = db.tobool(row.liked_by_me)
  row.bookmarked_by_me = db.tobool(row.bookmarked_by_me)
  if row.tags and row.tags ~= cjson.null then
    row.tags = cjson.decode(row.tags) or {}
  else
    row.tags = {}
  end
  return with_urls(req, row, viewer_can_open_adult)
end

-- ---------------------------------------------------------------------------
-- Category/subcategory find-or-create + multi-subcategory support (up to
-- MAX_MEDIA_SUBCATEGORIES per post). Mirrors app/db/categories.py's
-- create_category/create_subcategory/resolve_subcategory_ids/
-- _write_media_subcategories and app/db/helpers.py's
-- _attach_media_subcategories/app/db/_shared.py's normalize_subcategory_ids/
-- _names. Placed here (before M.list_media/M.media_detail) rather than
-- alongside the rest of the upload-section helpers further down, since both
-- of those need attach_media_subcategories. media_items.subcategory_id
-- stays as the "primary" (first) subcategory for any code still reading
-- that single column directly; the full ordered set lives in
-- media_item_subcategories.
-- ---------------------------------------------------------------------------

local function find_or_create_category(name, media_kind, user_id)
  name = trim(name or ""):sub(1, 80)
  if name == "" then return nil end
  local slug = slugify(name)
  local existing = db.fetchone("SELECT id FROM categories WHERE name=%s OR slug=%s", name, slug)
  if existing then return db.toint(existing.id, existing.id) end
  local row = db.fetchone(
    "INSERT INTO categories (name, slug, media_kind, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
    name, slug, MEDIA_KINDS[media_kind] and media_kind or "mixed", tostring(user_id)
  )
  return row and db.toint(row.id, row.id) or nil
end

local function find_or_create_subcategory(category_id, name, user_id)
  name = trim(name or ""):sub(1, 80)
  if name == "" or not category_id then return nil end
  local slug = slugify(name)
  local existing = db.fetchone(
    "SELECT id FROM subcategories WHERE category_id=%s AND (name=%s OR slug=%s)",
    tostring(category_id), name, slug
  )
  if existing then return db.toint(existing.id, existing.id) end
  local row = db.fetchone(
    "INSERT INTO subcategories (category_id, name, slug, created_by) VALUES (%s, %s, %s, %s) RETURNING id",
    tostring(category_id), name, slug, tostring(user_id)
  )
  return row and db.toint(row.id, row.id) or nil
end

local MAX_MEDIA_SUBCATEGORIES = 3

local function clean_subcategory_name(value)
  return trim(tostring(value or "")):gsub("%s+", " "):sub(1, 80)
end

local function normalize_subcategory_ids(values)
  local ids, seen = {}, {}
  if type(values) == "table" then
    for _, raw in ipairs(values) do
      local id = tonumber(raw)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = math.floor(id)
        if #ids >= MAX_MEDIA_SUBCATEGORIES then break end
      end
    end
  end
  return ids
end

local function normalize_subcategory_names(values)
  local names, seen = {}, {}
  if type(values) == "table" then
    for _, raw in ipairs(values) do
      local cleaned = clean_subcategory_name(raw)
      if cleaned ~= "" then
        local key = cleaned:lower()
        if not seen[key] then
          seen[key] = true
          names[#names + 1] = cleaned
          if #names >= MAX_MEDIA_SUBCATEGORIES then break end
        end
      end
    end
  end
  return names
end

-- Returns (ids_list, nil) on success or (nil, error_message) on failure --
-- Lua has no exceptions worth structuring control flow around here, unlike
-- Python's ValueError.
local function resolve_subcategory_ids(category_id, subcategory_ids, subcategory_names, user_id)
  category_id = tonumber(category_id) or 0
  if category_id <= 0 then return nil, "Choose a valid category." end
  local ids = normalize_subcategory_ids(subcategory_ids)
  local names = normalize_subcategory_names(subcategory_names)

  if not db.fetchone("SELECT id FROM categories WHERE id=%s", tostring(category_id)) then
    return nil, "Category does not exist."
  end

  local validated = {}
  for _, id in ipairs(ids) do
    if not db.fetchone("SELECT id FROM subcategories WHERE id=%s AND category_id=%s", tostring(id), tostring(category_id)) then
      return nil, "Subcategory does not belong to that category."
    end
    validated[#validated + 1] = id
  end

  for _, name in ipairs(names) do
    if #validated >= MAX_MEDIA_SUBCATEGORIES then break end
    local new_id = find_or_create_subcategory(category_id, name, user_id)
    if new_id then
      local exists = false
      for _, v in ipairs(validated) do if v == new_id then exists = true; break end end
      if not exists then validated[#validated + 1] = new_id end
    end
  end

  if #validated > MAX_MEDIA_SUBCATEGORIES then
    local trimmed = {}
    for i = 1, MAX_MEDIA_SUBCATEGORIES do trimmed[i] = validated[i] end
    validated = trimmed
  end
  return validated
end

local function write_media_subcategories(media_id, subcategory_ids)
  local primary = subcategory_ids[1]
  db.execute("UPDATE media_items SET subcategory_id=%s WHERE id=%s", primary and tostring(primary) or nil, tostring(media_id))
  db.execute("DELETE FROM media_item_subcategories WHERE media_id=%s", tostring(media_id))
  for position, subcategory_id in ipairs(subcategory_ids) do
    db.execute(
      "INSERT INTO media_item_subcategories (media_id, subcategory_id, position) VALUES (%s, %s, %s)",
      tostring(media_id), tostring(subcategory_id), tostring(position)
    )
  end
end

-- Batch-attaches subcategories/subcategory_ids/subcategory_names to each row
-- in `rows` (each must have a numeric/bigint-string `id`), and overrides the
-- single subcategory_id/subcategory_name/subcategory_slug fields with the
-- primary (first) entry so single-subcategory API consumers keep working.
local function attach_media_subcategories(rows)
  if #rows == 0 then return rows end
  local id_list = {}
  for _, row in ipairs(rows) do id_list[#id_list + 1] = tostring(db.toint(row.id, row.id)) end

  local sub_rows = db.fetchall(string.format([[
    SELECT ms.media_id, ms.position, s.id, s.category_id, s.name, s.slug
    FROM media_item_subcategories ms
    JOIN subcategories s ON s.id = ms.subcategory_id
    WHERE ms.media_id IN (%s)
    ORDER BY ms.media_id ASC, ms.position ASC
  ]], table.concat(id_list, ",")))

  local grouped = {}
  for _, r in ipairs(sub_rows) do
    local mid = db.toint(r.media_id, r.media_id)
    grouped[mid] = grouped[mid] or {}
    grouped[mid][#grouped[mid] + 1] = {
      id = db.toint(r.id, r.id), category_id = db.toint(r.category_id, r.category_id),
      name = r.name, slug = r.slug,
    }
  end

  for _, row in ipairs(rows) do
    local subs = grouped[db.toint(row.id, row.id)] or {}
    row.subcategories = arr(subs)
    local sub_ids, sub_names = {}, {}
    for _, s in ipairs(subs) do
      sub_ids[#sub_ids + 1] = s.id
      sub_names[#sub_names + 1] = s.name
    end
    row.subcategory_ids = arr(sub_ids)
    row.subcategory_names = arr(sub_names)
    if #subs > 0 then
      row.subcategory_id = subs[1].id
      row.subcategory_name = subs[1].name
      row.subcategory_slug = subs[1].slug
    end
  end
  return rows
end

function M.list_media(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local viewer_can_open_adult = false
  if viewer_id then
    local viewer = get_user(viewer_id)
    viewer_can_open_adult = viewer ~= nil and nn(viewer.age_verified_at) ~= nil and viewer.adult_content_consent
  end

  local q = req.query or {}
  local media_kind = nn(q.media_kind)
  local category_id = tonumber(q.category_id)
  local subcategory_id = tonumber(q.subcategory_id)
  local query_text = trim(nn(q.q) or ""):sub(1, 80)
  local uploader = trim(nn(q.uploader) or ""):sub(1, 80)
  local min_size = tonumber(q.min_size)
  local max_size = tonumber(q.max_size)
  local date_from = nn(q.date_from)
  local date_to = nn(q.date_to)
  local adult = nn(q.adult)
  local sort = VALID_SORTS[q.sort or ""] and q.sort or "new"
  local limit = bounded_limit(q.limit, 60)
  local offset = bounded_offset(q.offset)
  local viewer0 = viewer_id or "0"

  local clauses = {
    "m.deleted_at IS NULL",
    "(m.visibility='public' OR m.user_id=%s)",
    "(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id=%s)",
  }
  local params = { viewer0, viewer0 }

  if media_kind == "image" or media_kind == "video" then
    clauses[#clauses + 1] = "m.media_kind=%s"; params[#params + 1] = media_kind
  end
  if category_id then
    clauses[#clauses + 1] = "m.category_id=%s"; params[#params + 1] = tostring(category_id)
  end
  if subcategory_id then
    clauses[#clauses + 1] = "EXISTS (SELECT 1 FROM media_item_subcategories ms WHERE ms.media_id=m.id AND ms.subcategory_id=%s)"
    params[#params + 1] = tostring(subcategory_id)
  end
  if query_text ~= "" then
    clauses[#clauses + 1] = "(m.title ILIKE %s OR m.description ILIKE %s OR m.tags ILIKE %s)"
    local needle = "%" .. query_text:gsub("([%%_])", "\\%1") .. "%"
    params[#params + 1] = needle; params[#params + 1] = needle; params[#params + 1] = needle
  end
  if uploader ~= "" then
    clauses[#clauses + 1] = "(u.username ILIKE %s OR u.display_name ILIKE %s)"
    local needle = "%" .. uploader:gsub("([%%_])", "\\%1") .. "%"
    params[#params + 1] = needle; params[#params + 1] = needle
  end
  if min_size then clauses[#clauses + 1] = "m.file_size >= %s"; params[#params + 1] = tostring(math.max(0, min_size)) end
  if max_size then clauses[#clauses + 1] = "m.file_size <= %s"; params[#params + 1] = tostring(math.max(0, max_size)) end
  if date_from then clauses[#clauses + 1] = "m.created_at::date >= %s"; params[#params + 1] = date_from end
  if date_to then clauses[#clauses + 1] = "m.created_at::date <= %s"; params[#params + 1] = date_to end
  if adult == "only" then clauses[#clauses + 1] = "m.is_adult=true"
  elseif adult == "hide" then clauses[#clauses + 1] = "m.is_adult=false" end

  local where = "WHERE " .. table.concat(clauses, " AND ")
  local order = ({
    popular = "m.pinned_at DESC NULLS LAST, like_count DESC, m.views DESC, m.created_at DESC",
    downloads = "m.pinned_at DESC NULLS LAST, m.downloads DESC, m.created_at DESC",
    views = "m.pinned_at DESC NULLS LAST, m.views DESC, m.created_at DESC",
    old = "m.created_at ASC",
  })[sort] or "m.pinned_at DESC NULLS LAST, m.created_at DESC"

  -- Build the full parameter list in call order: 4 leading viewer refs used
  -- by the SELECT list's CASE expressions + the 2 JOIN viewer refs, then the
  -- WHERE clause's own params (already collected above), then LIMIT/OFFSET.
  local sql_params = { viewer0, viewer0, viewer0, viewer0, viewer0, viewer0 }
  for _, p in ipairs(params) do sql_params[#sql_params + 1] = p end
  sql_params[#sql_params + 1] = tostring(limit)
  sql_params[#sql_params + 1] = tostring(offset)

  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status,
           c.name AS category_name, c.slug AS category_slug,
           sc.name AS subcategory_name, sc.slug AS subcategory_slug,
           u.username,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.bio ELSE NULL END AS user_bio,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.website_url ELSE NULL END AS user_website_url,
           CASE WHEN u.public_profile OR u.id::text=%%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           COUNT(DISTINCT l.user_id) AS like_count,
           COUNT(DISTINCT cm.id) AS comment_count,
           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
    FROM media_items m
    JOIN categories c ON c.id = m.category_id
    LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
    JOIN users u ON u.id = m.user_id
    LEFT JOIN media_likes l ON l.media_id = m.id
    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id::text = %%s
    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id::text = %%s
    LEFT JOIN media_comments cm ON cm.media_id = m.id
    %s
    GROUP BY m.id, c.name, c.slug, sc.name, sc.slug, u.username, u.display_name, u.bio,
             u.website_url, u.avatar_path, u.profile_color, u.public_profile, u.id
    ORDER BY %s
    LIMIT %%s OFFSET %%s
  ]], where, order)

  local rows, err = db.fetchall(sql, unpack(sql_params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return 200, { media = arr(rows), limit = limit, offset = offset, sort = sort }
end

-- ---------------------------------------------------------------------------
-- Single media item: detail / like / bookmark / comment / react
-- Mirrors app/routers/media.py's media_detail/like_media/bookmark_media/
-- add_comment/react_to_media + app/db/media.py's get_media/list_comments/
-- list_reactions.
-- ---------------------------------------------------------------------------

-- Single-row equivalent of list_media's own SELECT (mirrors app/db/media.py's
-- get_media()). Kept as a separate literal query rather than factored out of
-- list_media's already-verified SQL, to avoid risking a regression there.
local function fetch_media_by_id(media_id, viewer0)
  local row = db.fetchone([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status,
           m.deleted_at, m.publish_at,
           c.name AS category_name, c.slug AS category_slug,
           sc.name AS subcategory_name, sc.slug AS subcategory_slug,
           u.username,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS user_bio,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.website_url ELSE NULL END AS user_website_url,
           CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           COUNT(DISTINCT l.user_id) AS like_count,
           COUNT(DISTINCT cm.id) AS comment_count,
           MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
           MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
    FROM media_items m
    JOIN categories c ON c.id = m.category_id
    LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
    JOIN users u ON u.id = m.user_id
    LEFT JOIN media_likes l ON l.media_id = m.id
    LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id::text = %s
    LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id::text = %s
    LEFT JOIN media_comments cm ON cm.media_id = m.id
    WHERE m.id = %s
    GROUP BY m.id, c.name, c.slug, sc.name, sc.slug, u.username, u.display_name, u.bio,
             u.website_url, u.avatar_path, u.profile_color, u.public_profile, u.id
  ]], viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, tostring(media_id))
  if row then attach_media_subcategories({ row }) end
  return row
end

local function viewer_adult_allowed(viewer_id)
  if not viewer_id then return false end
  local viewer = get_user(viewer_id)
  return viewer ~= nil and nn(viewer.age_verified_at) ~= nil and viewer.adult_content_consent
end

-- Mirrors _ensure_media_visible_to_viewer(): returns nil on success, or
-- (status, body) the caller should return immediately.
local function ensure_media_visible(item, viewer_id)
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not owner then
    return 403, { detail = "This post is private." }
  end
  local publish_at = nn(item.publish_at)
  if publish_at and not owner then
    local row = db.fetchone("SELECT (%s::timestamp > now()) AS is_future", publish_at)
    if row and db.tobool(row.is_future) then return 404, { detail = "Media not found." } end
  end
  return nil
end

function M.media_detail(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local item = fetch_media_by_id(media_id, viewer_id or "0")
  local status, body = ensure_media_visible(item, viewer_id)
  if status then return status, body end
  if item.is_adult and not adult_allowed then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  db.execute("UPDATE media_items SET views=views+1 WHERE id=%s", tostring(media_id))

  local comments = db.fetchall([[
    SELECT cm.id, cm.media_id, cm.user_id, cm.body, cm.created_at, cm.parent_comment_id,
           u.username,
           CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile THEN u.avatar_path ELSE NULL END AS user_avatar_path
    FROM media_comments cm JOIN users u ON u.id = cm.user_id
    WHERE cm.media_id = %s
    ORDER BY cm.created_at ASC
    LIMIT 80
  ]], tostring(media_id))
  for _, c in ipairs(comments) do
    c.id = db.toint(c.id, c.id)
    c.media_id = db.toint(c.media_id, c.media_id)
    c.user_id = db.toint(c.user_id, c.user_id)
    if c.parent_comment_id then c.parent_comment_id = db.toint(c.parent_comment_id, c.parent_comment_id) end
  end

  local reaction_rows = db.fetchall(
    "SELECT emoji, COUNT(*) AS n FROM media_reactions WHERE media_id=%s GROUP BY emoji ORDER BY n DESC",
    tostring(media_id)
  )
  local counts = {}
  for _, r in ipairs(reaction_rows) do counts[r.emoji] = db.toint(r.n, 0) end
  local my_reaction = nil
  if viewer_id then
    local r = db.fetchone("SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), viewer_id)
    my_reaction = r and r.emoji or nil
  end

  local similar = db.fetchall([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
           m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views
    FROM media_items m
    WHERE m.category_id = %s AND m.id != %s AND m.deleted_at IS NULL AND m.visibility='public'
    ORDER BY m.created_at DESC
    LIMIT 8
  ]], tostring(item.category_id), tostring(media_id))
  for _, row in ipairs(similar) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.is_adult = db.tobool(row.is_adult)
    with_urls(req, row, adult_allowed)
  end
  attach_media_subcategories(similar)

  return 200, {
    media = decode_media_row(item, adult_allowed, req),
    comments = arr(comments),
    reactions = { counts = counts, my_reaction = my_reaction },
    similar = arr(similar),
  }
end

function M.like_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local liked = payload.liked and true or false

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  if liked then
    db.execute("INSERT INTO media_likes (user_id, media_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", user.id, tostring(media_id))
  else
    db.execute("DELETE FROM media_likes WHERE user_id=%s AND media_id=%s", user.id, tostring(media_id))
  end
  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

function M.bookmark_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local bookmarked = payload.bookmarked and true or false

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  if bookmarked then
    db.execute("INSERT INTO media_bookmarks (user_id, media_id) VALUES (%s, %s) ON CONFLICT DO NOTHING", user.id, tostring(media_id))
  else
    db.execute("DELETE FROM media_bookmarks WHERE user_id=%s AND media_id=%s", user.id, tostring(media_id))
  end
  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

-- NOTE: unlike Python's add_comment/react_to_media, this does not yet create
-- notification rows or parse @mentions (see app/routers/media.py lines
-- ~1184-1195) -- left for a follow-up pass; comments/reactions themselves
-- are fully functional.
function M.add_comment(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local text = trim(nn(payload.body) or "")
  if text == "" then return 400, { detail = "Comment cannot be empty." } end
  text = text:sub(1, 500)
  local parent_id = nn(payload.parent_comment_id)

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end
  if not db.tobool(item.comments_enabled) then
    return 403, { detail = "Comments are disabled for this post." }
  end

  local row, err = db.fetchone(
    "INSERT INTO media_comments (media_id, user_id, body, parent_comment_id) VALUES (%s, %s, %s, %s) RETURNING *",
    tostring(media_id), user.id, text, parent_id and tostring(parent_id) or nil
  )
  if not row then return 500, { detail = "Could not add comment: " .. tostring(err) } end
  row.id = db.toint(row.id, row.id)
  row.media_id = db.toint(row.media_id, row.media_id)
  row.user_id = db.toint(row.user_id, row.user_id)
  if row.parent_comment_id then row.parent_comment_id = db.toint(row.parent_comment_id, row.parent_comment_id) end
  return 200, { comment = row }
end

function M.react_to_media_route(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local emoji = trim(nn(payload.emoji) or ""):sub(1, 16)
  if emoji == "" then return 400, { detail = "An emoji is required." } end

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  local existing = db.fetchone("SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  if existing and existing.emoji == emoji then
    db.execute("DELETE FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  else
    db.execute([[
      INSERT INTO media_reactions (media_id, user_id, emoji) VALUES (%s, %s, %s)
      ON CONFLICT (media_id, user_id) DO UPDATE SET emoji=EXCLUDED.emoji, created_at=now()
    ]], tostring(media_id), user.id, emoji)
  end

  local reaction_rows = db.fetchall(
    "SELECT emoji, COUNT(*) AS n FROM media_reactions WHERE media_id=%s GROUP BY emoji ORDER BY n DESC",
    tostring(media_id)
  )
  local counts = {}
  for _, r in ipairs(reaction_rows) do counts[r.emoji] = db.toint(r.n, 0) end
  local r = db.fetchone("SELECT emoji FROM media_reactions WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  return 200, { reactions = { counts = counts, my_reaction = r and r.emoji or nil } }
end

-- ---------------------------------------------------------------------------
-- Media upload (POST /api/media) -- multipart form upload -> DB blob storage
-- (media_files.save_media_file) -> media_items row. Mirrors
-- app/routers/media.py's upload_media() + app/db/media.py's add_media().
--
-- NOT YET PORTED as part of this pass (left for a follow-up): AI auto-
-- classification/autofill (Python's auto_ai path), possible-duplicate
-- perceptual-hash detection, Discord upload notifications, background AI
-- learning, saved-search match notifications, publish_at scheduling, and
-- the multi-subcategory array (subcategory_ids_json) -- this accepts a
-- single subcategory via subcategory_id/subcategory_name, matching what
-- list_media/media_detail already expose (m.subcategory_id). Video thumb/
-- quality cache warmup is also not queued here; serve_media_thumb already
-- renders+caches lazily on first request instead.
-- ---------------------------------------------------------------------------

local sodium = require("luasodium")

local SAFE_EXTENSIONS = {
  [".jpg"] = true, [".jpeg"] = true, [".png"] = true, [".webp"] = true, [".gif"] = true,
  [".avif"] = true, [".bmp"] = true, [".mp4"] = true, [".webm"] = true, [".mov"] = true,
  [".m4v"] = true, [".ogg"] = true, [".flv"] = true, [".mkv"] = true,
}
local MIME_TO_EXT = {
  ["image/jpeg"] = ".jpg", ["image/png"] = ".png", ["image/webp"] = ".webp", ["image/gif"] = ".gif",
  ["image/avif"] = ".avif", ["image/bmp"] = ".bmp", ["video/mp4"] = ".mp4", ["video/webm"] = ".webm",
  ["video/quicktime"] = ".mov", ["video/x-m4v"] = ".m4v", ["video/ogg"] = ".ogg",
  ["video/x-flv"] = ".flv", ["video/x-matroska"] = ".mkv",
}

-- Mirrors app/routers/_shared.py's _sniff_magic(): content-based mime/kind
-- detection so an upload can't lie about its type via a spoofed extension or
-- declared Content-Type. Returns nil, nil on unrecognized bytes.
local function sniff_magic(content)
  local head = content:sub(1, 128)
  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return "image/webp", "image" end
  if #head >= 12 and head:sub(5, 8) == "ftyp" then
    local brands = head:sub(9, 32):lower()
    if brands:find("avif", 1, true) or brands:find("avis", 1, true) then return "image/avif", "image" end
    return "video/mp4", "video"
  end
  if head:sub(1, 4) == "\x1aE\xdf\xa3" then
    local mime = content:sub(1, 256):lower():find("matroska", 1, true) and "video/x-matroska" or "video/webm"
    return mime, "video"
  end
  if head:sub(1, 3) == "\xff\xd8\xff" then return "image/jpeg", "image" end
  if head:sub(1, 8) == "\x89PNG\r\n\x1a\n" then return "image/png", "image" end
  if head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a" then return "image/gif", "image" end
  if head:sub(1, 4) == "OggS" then return "video/ogg", "video" end
  if head:sub(1, 4) == "FLV\x01" then return "video/x-flv", "video" end
  return nil, nil
end

local function safe_extension(filename, mime_type)
  local ext = (filename or ""):match("(%.[^./\\]+)$")
  ext = ext and ext:lower() or ""
  if not SAFE_EXTENSIONS[ext] then ext = MIME_TO_EXT[mime_type] or "" end
  if not SAFE_EXTENSIONS[ext] then return nil end
  return ext == ".jpe" and ".jpg" or ext
end

-- Mirrors _normalize_upload_tag()/_parse_tags().
local function normalize_upload_tag(value)
  local cleaned = tostring(value or ""):match("^%s*(.-)%s*$"):gsub("^#+", ""):gsub("%s+", "-")
  cleaned = cleaned:gsub("[^%w_.%-]+", "")
  return cleaned:sub(1, M.settings.max_tag_length)
end

local function parse_tags(value)
  local tags, seen = {}, {}
  for raw in (value or ""):gmatch("[^,#\n\r\t]+") do
    local tag = normalize_upload_tag(raw)
    local lowered = tag:lower()
    if tag ~= "" and not seen[lowered] then
      seen[lowered] = true
      tags[#tags + 1] = tag
      if #tags >= M.settings.max_tags_per_upload then break end
    end
  end
  return tags
end

local ADULT_KEYWORDS = {
  "18plus", "18+", "adult", "nsfw", "not safe for work", "nude", "nudity",
  "explicit", "porn", "porno", "sex", "sexual", "hentai", "ecchi", "lewd",
  "erotic", "fetish", "onlyfans", "camgirl", "cam boy", "xxx",
}

-- Mirrors app/routers/media.py's _moderate_upload(). human_confirmed is
-- always treated as true here (status goes straight to "adult" rather than
-- "pending_review") since this pass has no AI-vision path that could flag
-- adult content the uploader themselves didn't check the box for.
local function moderate_upload(title, description, tags, filename, mime_type, user_marked_adult)
  local combined = table.concat({ title, description or "", table.concat(tags, " "), filename, mime_type }, " "):lower()
  local hits = {}
  for _, word in ipairs(ADULT_KEYWORDS) do
    if combined:find(word, 1, true) then hits[#hits + 1] = word end
  end
  local adult_by_ai = #hits > 0
  local is_adult = user_marked_adult or adult_by_ai
  local reason_parts = {}
  if user_marked_adult then reason_parts[#reason_parts + 1] = "Uploader marked this post as 18+." end
  if adult_by_ai then reason_parts[#reason_parts + 1] = "Automatic moderation matched: " .. table.concat(hits, ", ") .. "." end
  local reason = #reason_parts > 0 and table.concat(reason_parts, " "):sub(1, 300) or nil
  return {
    is_adult = is_adult,
    adult_marked_by_user = user_marked_adult,
    adult_marked_by_ai = adult_by_ai,
    moderation_status = is_adult and "adult" or "clear",
    moderation_score = adult_by_ai and 0.96 or (user_marked_adult and 0.75 or 0),
    moderation_reason = reason,
  }
end

local function form_bool(value, default)
  if value == nil then return default end
  return value == "true" or value == "1" or value == "on"
end

-- Mirrors app/routers/media.py's _notify_discord_upload/_notify_discord_upload_async.
-- Fire-and-forget (see discord_webhook.lua): a slow/broken webhook must
-- never delay or fail the upload response.
local function notify_discord_upload(req, uploader, item)
  local ok, err = pcall(function()
    local webhook_url = uploader.user_settings and uploader.user_settings.discord_webhook_url
    if not webhook_url or webhook_url == "" or webhook_url == cjson.null then return end
    local page_url = request_origin(req):gsub("/+$", "") .. "/media/" .. item.id
    local embed = {
      title = (nn(item.title) or "New upload"):sub(1, 256),
      url = page_url,
      color = 0x37c9a7,
      author = { name = uploader.display_name or uploader.username or "Someone" },
    }
    local description = trim(nn(item.description) or "")
    if description ~= "" then embed.description = description:sub(1, 300) end
    local image_url = nn(item.url) or nn(item.preview_url)
    if image_url and item.media_kind ~= "video" then
      embed.image = { url = image_url }
    elseif nn(item.thumb_url) then
      embed.thumbnail = { url = item.thumb_url }
    end
    discord_webhook.send(webhook_url, { embed })
  end)
  if not ok then
    print("[image-gallery-lua] Discord upload webhook notification failed for user " .. tostring(uploader.id) .. ": " .. tostring(err))
  end
end

function M.upload_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local form = req.form or {}
  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > M.settings.max_upload_bytes then
    return 413, { detail = string.format("Uploads must be %dMB or smaller.", math.floor(M.settings.max_upload_bytes / (1024 * 1024))) }
  end

  local rl_status, rl_body = ratelimit.check("upload:" .. user.id, M.settings.upload_rate_limit_per_hour, 3600)
  if rl_status then return rl_status, rl_body end

  local sniffed_mime, media_kind = sniff_magic(upload.content)
  if not sniffed_mime then return 400, { detail = "Unsupported or invalid file bytes." } end
  local original_filename = ((upload.filename or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)
  if not safe_extension(original_filename, sniffed_mime) then
    return 400, { detail = "Unsupported file extension." }
  end

  local title = trim(nn(form.title) or ""):sub(1, 160)
  if title == "" then return 400, { detail = "Title is required." } end
  local description_raw = trim(nn(form.description) or "")
  local description = description_raw ~= "" and description_raw:sub(1, 2000) or nil
  local tags = parse_tags(form.tags)
  local visibility = (nn(form.visibility) or "public"):lower()
  if visibility ~= "public" and visibility ~= "unlisted" and visibility ~= "private" then
    return 400, { detail = "Visibility must be public, unlisted, or private." }
  end
  local comments_enabled = form_bool(form.comments_enabled, true)
  local downloads_enabled = form_bool(form.downloads_enabled, true)
  local is_adult_input = form_bool(form.is_adult, false)

  local category_id = tonumber(form.category_id)
  if not category_id or category_id <= 0 then
    local category_kind = nn(form.category_kind) or (media_kind == "video" and "video" or "image")
    category_id = find_or_create_category(form.category_name, category_kind, user.id)
    if not category_id then return 400, { detail = "Category is required." } end
  end
  -- Multi-subcategory form fields: subcategory_ids_json/subcategory_names_json
  -- are JSON-array-encoded strings (multipart forms have no native array
  -- type), mirroring app/routers/media.py's upload_media() parsing of the
  -- same field names. Falls back to the single subcategory_id/
  -- subcategory_name fields for older/simpler callers.
  local requested_ids = {}
  if nn(form.subcategory_ids_json) then
    local ok, decoded = pcall(cjson.decode, form.subcategory_ids_json)
    if ok and type(decoded) == "table" then requested_ids = decoded end
  end
  local single_id = tonumber(form.subcategory_id)
  if single_id and single_id > 0 then table.insert(requested_ids, 1, single_id) end
  requested_ids = normalize_subcategory_ids(requested_ids)

  local requested_names = {}
  if nn(form.subcategory_names_json) then
    local ok, decoded = pcall(cjson.decode, form.subcategory_names_json)
    if ok and type(decoded) == "table" then requested_names = decoded end
  end
  if nn(form.subcategory_name) and trim(form.subcategory_name) ~= "" then
    table.insert(requested_names, 1, form.subcategory_name)
  end
  requested_names = normalize_subcategory_names(requested_names)

  local resolved_subcategory_ids, subcat_err = resolve_subcategory_ids(category_id, requested_ids, requested_names, user.id)
  if not resolved_subcategory_ids then return 400, { detail = subcat_err } end
  local subcategory_id = resolved_subcategory_ids[1]

  local sha256 = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(upload.content))
  local moderation = moderate_upload(title, description, tags, original_filename, sniffed_mime, is_adult_input)

  local media_file, save_err = media_files.save_media_file({
    user_id = user.id,
    content = upload.content,
    sha256 = sha256,
    mime_type = sniffed_mime,
    original_filename = original_filename,
    media_kind = media_kind,
    file_size = #upload.content,
    chunk_bytes = M.settings.db_blob_chunk_bytes,
  })
  if not media_file then return 500, { detail = "Could not store uploaded file: " .. tostring(save_err) } end

  local row, insert_err = db.fetchone(
    [[
      INSERT INTO media_items
        (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename,
         storage_path, file_size, media_file_id, content_sha256, visibility, comments_enabled, downloads_enabled,
         is_adult, adult_marked_by_user, adult_marked_by_ai, moderation_status, moderation_score, moderation_reason, moderated_at)
      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,now())
      RETURNING id
    ]],
    tostring(user.id), tostring(category_id), subcategory_id and tostring(subcategory_id) or nil,
    title, description, cjson.encode(arr(tags)), media_kind, sniffed_mime, original_filename,
    "db://media/" .. tostring(media_file.id), tostring(#upload.content), tostring(media_file.id), sha256,
    visibility, comments_enabled, downloads_enabled,
    moderation.is_adult, moderation.adult_marked_by_user, moderation.adult_marked_by_ai,
    moderation.moderation_status, tostring(moderation.moderation_score), moderation.moderation_reason
  )
  if not row then return 500, { detail = "Could not save media: " .. tostring(insert_err) } end
  local media_id = db.toint(row.id, row.id)
  write_media_subcategories(media_id, resolved_subcategory_ids)

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  local enriched = decode_media_row(item, adult_allowed, req)
  notify_discord_upload(req, user, enriched)
  return 200, { media = enriched, possible_duplicates = {} }
end

-- ---------------------------------------------------------------------------
-- Media edit/delete/moderation follow-ups: edit, controls-only patch,
-- soft-delete/restore, report, comment delete, similar-media, and bulk
-- edit/delete. Mirrors app/routers/media.py's edit_media/set_media_controls/
-- delete_media/restore_media/report_media/delete_comment/similar_media/
-- bulk_edit_media/bulk_delete_media + the corresponding app/db/media.py
-- functions. NOT ported: the AI-auto-train-on-edit side effect (requires the
-- LLM pipeline, see TODO.md) and multi-subcategory arrays (single
-- subcategory_id/subcategory_name only, matching the rest of this file).
-- ---------------------------------------------------------------------------

-- Shared by M.update_media and M.bulk_edit_media. Returns (nil, item) on
-- success or (status, error_message) on failure -- mirrors update_media()'s
-- ValueError/PermissionError/None-return cases as explicit return values
-- since Lua has no exceptions worth structuring control flow around here.
local function perform_update_media(media_id, owner_id, payload)
  local title = trim(nn(payload.title) or ""):gsub("%s+", " "):sub(1, 160)
  if title == "" then return 400, "Title is required." end
  local description = trim(nn(payload.description) or ""):gsub("%s+", " "):sub(1, 2000)

  local clean_tags, seen = {}, {}
  if type(payload.tags) == "table" then
    for _, raw in ipairs(payload.tags) do
      local tag = tostring(raw):gsub("[^%w_.%-]+", ""):sub(1, 32)
      local lowered = tag:lower()
      if tag ~= "" and not seen[lowered] then
        seen[lowered] = true
        clean_tags[#clean_tags + 1] = tag
        if #clean_tags >= 12 then break end
      end
    end
  end

  local category_id = tonumber(payload.category_id) or 0
  if category_id <= 0 then return 400, "A category is required." end
  local requested_ids = normalize_subcategory_ids(payload.subcategory_ids)
  if #requested_ids == 0 and nn(payload.subcategory_id) then
    requested_ids = normalize_subcategory_ids({ payload.subcategory_id })
  end
  local requested_names = normalize_subcategory_names(payload.subcategory_names)
  if #requested_names == 0 and nn(payload.subcategory_name) and trim(payload.subcategory_name) ~= "" then
    requested_names = normalize_subcategory_names({ payload.subcategory_name })
  end
  local resolved_subcategory_ids, subcat_err = resolve_subcategory_ids(category_id, requested_ids, requested_names, owner_id)
  if not resolved_subcategory_ids then return 400, subcat_err end

  local visibility = tostring(payload.visibility or "public"):lower()
  if visibility ~= "public" and visibility ~= "unlisted" and visibility ~= "private" then
    return 400, "Visibility must be public, unlisted, or private."
  end
  local is_adult = payload.is_adult and true or false
  local comments_enabled = true
  if payload.comments_enabled ~= nil then comments_enabled = payload.comments_enabled and true or false end
  local downloads_enabled = true
  if payload.downloads_enabled ~= nil then downloads_enabled = payload.downloads_enabled and true or false end
  local pinned = payload.pinned and "1" or "0"

  local row = db.fetchone("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", tostring(media_id))
  if not row then return 404, "Media not found." end
  if tostring(row.user_id) ~= tostring(owner_id) then return 403, "Only the uploader can edit this post." end

  db.execute([[
    UPDATE media_items
    SET title=%s, description=%s, tags=%s, category_id=%s,
        visibility=%s, comments_enabled=%s, downloads_enabled=%s,
        pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END,
        is_adult=%s, adult_marked_by_user=%s,
        moderation_status=CASE WHEN %s THEN 'adult' ELSE moderation_status END,
        moderation_reason=CASE WHEN %s THEN 'Uploader marked this post as 18+.' ELSE moderation_reason END,
        moderated_at=CASE WHEN %s THEN CURRENT_TIMESTAMP ELSE moderated_at END
    WHERE id=%s AND user_id=%s
  ]],
    title, description, cjson.encode(arr(clean_tags)), tostring(category_id),
    visibility, comments_enabled, downloads_enabled,
    pinned, is_adult, is_adult, is_adult, is_adult, is_adult, tostring(media_id), owner_id)
  write_media_subcategories(media_id, resolved_subcategory_ids)

  return nil, fetch_media_by_id(media_id, tostring(owner_id))
end

function M.update_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)

  local err_status, result = perform_update_media(media_id, user.id, payload)
  if err_status then return err_status, { detail = result } end
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(result, adult_allowed, req) }
end

function M.set_media_controls(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)

  local updates, params = {}, {}
  if nn(payload.visibility) then
    local v = tostring(payload.visibility):lower()
    if v ~= "public" and v ~= "unlisted" and v ~= "private" then
      return 400, { detail = "Visibility must be public, unlisted, or private." }
    end
    updates[#updates + 1] = "visibility=%s"; params[#params + 1] = v
  end
  if payload.comments_enabled ~= nil then
    updates[#updates + 1] = "comments_enabled=%s"; params[#params + 1] = payload.comments_enabled and true or false
  end
  if payload.downloads_enabled ~= nil then
    updates[#updates + 1] = "downloads_enabled=%s"; params[#params + 1] = payload.downloads_enabled and true or false
  end
  if payload.pinned ~= nil then
    updates[#updates + 1] = "pinned_at=CASE WHEN %s=1 THEN COALESCE(pinned_at, CURRENT_TIMESTAMP) ELSE NULL END"
    params[#params + 1] = payload.pinned and "1" or "0"
  end

  local row = db.fetchone("SELECT user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", tostring(media_id))
  if not row then return 404, { detail = "Media not found." } end
  if tostring(row.user_id) ~= tostring(user.id) then return 403, { detail = "Only the uploader can change post controls." } end

  if #updates > 0 then
    params[#params + 1] = tostring(media_id)
    params[#params + 1] = user.id
    db.execute("UPDATE media_items SET " .. table.concat(updates, ", ") .. " WHERE id=%s AND user_id=%s", unpack(params))
  end

  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

-- Shared by M.delete_media and M.bulk_delete_media. Returns the pre-delete
-- item row on success, nil if not found or not owned by owner_id.
local function perform_delete_media(media_id, owner_id)
  local item = fetch_media_by_id(media_id, tostring(owner_id))
  if not item or tostring(item.user_id) ~= tostring(owner_id) then return nil end
  db.execute(
    "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND user_id=%s AND deleted_at IS NULL",
    tostring(media_id), owner_id)
  return item
end

function M.delete_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item = perform_delete_media(media_id, user.id)
  if not item then return 404, { detail = "Media not found." } end
  return 200, { deleted = true }
end

function M.restore_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end

  local row = db.fetchone("SELECT user_id FROM media_items WHERE id=%s", tostring(media_id))
  if not row then return 404, { detail = "Media not found." } end
  if tostring(row.user_id) ~= tostring(user.id) then return 403, { detail = "Only the uploader can restore this post." } end
  db.execute("UPDATE media_items SET deleted_at=NULL, visibility='private' WHERE id=%s AND user_id=%s", tostring(media_id), user.id)

  local updated = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { media = decode_media_row(updated, adult_allowed, req) }
end

function M.report_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local payload = json_body(req)
  local reason = trim(nn(payload.reason) or ""):gsub("%s+", " "):sub(1, 80)
  if reason == "" then return 400, { detail = "A reason is required." } end
  local details = trim(nn(payload.details) or ""):gsub("%s+", " "):sub(1, 500)
  if details == "" then details = nil end

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  db.execute([[
    INSERT INTO media_reports (media_id, user_id, reason, details)
    VALUES (%s, %s, %s, %s)
    ON CONFLICT (media_id, user_id) DO UPDATE SET reason=EXCLUDED.reason, details=EXCLUDED.details, status='open', created_at=CURRENT_TIMESTAMP
  ]], tostring(media_id), user.id, reason, details)

  local report = db.fetchone("SELECT * FROM media_reports WHERE media_id=%s AND user_id=%s", tostring(media_id), user.id)
  if report then
    report.id = db.toint(report.id, report.id)
    report.media_id = db.toint(report.media_id, report.media_id)
    report.user_id = db.toint(report.user_id, report.user_id)
  end
  return 200, { report = report }
end

function M.delete_comment(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local comment_id = tonumber(req.params.comment_id)
  if not comment_id then return 404, { detail = "Comment not found." } end

  local row = db.fetchone([[
    SELECT cm.id, cm.user_id AS comment_user_id, m.user_id AS media_user_id
    FROM media_comments cm JOIN media_items m ON m.id=cm.media_id
    WHERE cm.id=%s
  ]], tostring(comment_id))
  if not row then return 404, { detail = "Comment not found." } end
  if tostring(row.comment_user_id) ~= tostring(user.id) and tostring(row.media_user_id) ~= tostring(user.id) then
    return 403, { detail = "Only the commenter or post owner can delete this comment." }
  end
  db.execute("DELETE FROM media_comments WHERE id=%s", tostring(comment_id))
  return 200, { deleted = true }
end

function M.similar_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local source = fetch_media_by_id(media_id, viewer_id or "0")
  if not source or nn(source.deleted_at) then return 200, { media = {} } end

  local tags = {}
  if source.tags and source.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, source.tags)
    if ok and type(decoded) == "table" then tags = decoded end
  end
  local tag_conditions, tag_params = {}, {}
  for i = 1, math.min(#tags, 8) do
    tag_conditions[#tag_conditions + 1] = "(m.tags::jsonb @> jsonb_build_array(%s::text))::int"
    tag_params[#tag_params + 1] = tostring(tags[i])
  end
  local tag_score_sql = #tag_conditions > 0 and table.concat(tag_conditions, " + ") or "0"
  local adult_clause = viewer_id and "" or "AND m.is_adult=false"

  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
           m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views,
           (%s + (m.category_id=%%s)::int) AS relevance
    FROM media_items m
    WHERE m.id != %%s AND m.deleted_at IS NULL AND m.visibility='public'
          AND (m.publish_at IS NULL OR m.publish_at <= now())
          %s
          AND (m.category_id=%%s OR %s > 0)
    ORDER BY relevance DESC, m.created_at DESC
    LIMIT %%s
  ]], tag_score_sql, adult_clause, tag_score_sql)

  local sql_params = {}
  for _, p in ipairs(tag_params) do sql_params[#sql_params + 1] = p end
  sql_params[#sql_params + 1] = tostring(source.category_id)
  sql_params[#sql_params + 1] = tostring(media_id)
  sql_params[#sql_params + 1] = tostring(source.category_id)
  for _, p in ipairs(tag_params) do sql_params[#sql_params + 1] = p end
  sql_params[#sql_params + 1] = "12"

  local rows, err = db.fetchall(sql, unpack(sql_params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.is_adult = db.tobool(row.is_adult)
    with_urls(req, row, adult_allowed)
  end
  attach_media_subcategories(rows)
  return 200, { media = arr(rows) }
end

local BULK_PATCH_FIELDS = {
  visibility = true, comments_enabled = true, downloads_enabled = true, pinned = true, is_adult = true,
}

function M.bulk_edit_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local owner_flag = is_site_owner(user)

  local ids, seen = {}, {}
  if type(payload.ids) == "table" then
    for _, raw in ipairs(payload.ids) do
      local id = tonumber(raw)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
        if #ids >= 200 then break end
      end
    end
  end

  local patch = type(payload.patch) == "table" and payload.patch or {}
  local add_tag = nn(patch.add_tag) and normalize_upload_tag(patch.add_tag) or ""
  local overrides = {}
  for k, v in pairs(patch) do
    if BULK_PATCH_FIELDS[k] then overrides[k] = v end
  end

  local results = {}
  for _, media_id in ipairs(ids) do
    local existing = fetch_media_by_id(media_id, tostring(user.id))
    if not existing or nn(existing.deleted_at) then
      results[#results + 1] = { id = media_id, ok = false, error = "Not found." }
    else
      local owner_id = db.toint(existing.user_id, existing.user_id)
      if owner_id ~= user.id and not owner_flag then
        results[#results + 1] = { id = media_id, ok = false, error = "Forbidden." }
      else
        local tags = {}
        if existing.tags and existing.tags ~= cjson.null then
          local ok, decoded = pcall(cjson.decode, existing.tags)
          if ok and type(decoded) == "table" then tags = decoded end
        end
        if add_tag ~= "" then
          local already = false
          for _, t in ipairs(tags) do if t == add_tag then already = true; break end end
          if not already then
            tags[#tags + 1] = add_tag
            while #tags > M.settings.max_tags_per_upload do table.remove(tags, 1) end
          end
        end
        local merged = {
          title = existing.title,
          description = existing.description,
          tags = tags,
          category_id = existing.category_id,
          subcategory_ids = existing.subcategory_ids,
          visibility = existing.visibility,
          comments_enabled = existing.comments_enabled == nil and true or existing.comments_enabled,
          downloads_enabled = existing.downloads_enabled == nil and true or existing.downloads_enabled,
          pinned = nn(existing.pinned_at) ~= nil,
          is_adult = existing.is_adult,
        }
        for k, v in pairs(overrides) do merged[k] = v end
        local err_status, result = perform_update_media(media_id, owner_id, merged)
        if err_status then
          results[#results + 1] = { id = media_id, ok = false, error = result }
        else
          results[#results + 1] = { id = media_id, ok = true }
        end
      end
    end
  end
  return 200, { results = arr(results) }
end

function M.bulk_delete_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local owner_flag = is_site_owner(user)

  local ids, seen = {}, {}
  if type(payload.ids) == "table" then
    for _, raw in ipairs(payload.ids) do
      local id = tonumber(raw)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
        if #ids >= 200 then break end
      end
    end
  end

  local results = {}
  for _, media_id in ipairs(ids) do
    local item = fetch_media_by_id(media_id, tostring(user.id))
    if not item or nn(item.deleted_at) then
      results[#results + 1] = { id = media_id, ok = false, error = "Not found." }
    else
      local owner_id = db.toint(item.user_id, item.user_id)
      if owner_id == user.id then
        local deleted = perform_delete_media(media_id, owner_id)
        results[#results + 1] = { id = media_id, ok = deleted ~= nil }
      elseif owner_flag then
        db.execute(
          "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND deleted_at IS NULL",
          tostring(media_id))
        results[#results + 1] = { id = media_id, ok = true }
      else
        results[#results + 1] = { id = media_id, ok = false, error = "Forbidden." }
      end
    end
  end
  return 200, { results = arr(results) }
end


-- ---------------------------------------------------------------------------
-- TOTP two-factor auth: enroll / confirm / disable / status, and real
-- verification wired into /api/auth/2fa/verify (replacing the previous
-- always-reject stub). Mirrors app/db/totp.py + app/totp.py exactly (same
-- pbkdf2_sha256-hashed recovery codes via gauth.password_hash, same
-- otpauth:// URI shape, same 6-digit/30s/+-1-step verification window).
-- ---------------------------------------------------------------------------

local function decode_recovery_codes(raw)
  if not raw or raw == cjson.null then return {} end
  local ok, decoded = pcall(cjson.decode, raw)
  if ok and type(decoded) == "table" then return decoded end
  return {}
end

-- Mirrors app/db/totp.py's verify_totp_or_recovery(): checks a live TOTP
-- code first, then falls back to consuming (and removing) a matching
-- recovery code.
function verify_totp_or_recovery(user_id, code)
  local row = db.fetchone("SELECT totp_secret, totp_enabled_at, totp_recovery_codes FROM users WHERE id=%s", user_id)
  if not row or nn(row.totp_enabled_at) == nil or nn(row.totp_secret) == nil then return false end
  if totp.verify_code(row.totp_secret, code, os.time()) then return true end
  local codes = decode_recovery_codes(nn(row.totp_recovery_codes))
  local stripped = trim(code)
  for i, hashed in ipairs(codes) do
    if gauth.verify_password_hash(stripped, hashed) then
      table.remove(codes, i)
      db.execute("UPDATE users SET totp_recovery_codes=%s WHERE id=%s", cjson.encode(arr(codes)), user_id)
      return true
    end
  end
  return false
end

function M.totp_status(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local row = db.fetchone("SELECT totp_enabled_at, totp_recovery_codes FROM users WHERE id=%s", user.id)
  local codes = decode_recovery_codes(row and nn(row.totp_recovery_codes))
  return 200, { enabled = (row and nn(row.totp_enabled_at) ~= nil) or false, recovery_codes_remaining = #codes }
end

function M.totp_enroll(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local secret = totp.generate_secret()
  db.execute("UPDATE users SET totp_secret=%s, totp_enabled_at=NULL WHERE id=%s", secret, user.id)
  return 200, { secret = secret, uri = totp.provisioning_uri(secret, user.username, "Image Gallery") }
end

function M.totp_confirm(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local code = tostring(nn(payload.code) or "")
  local row = db.fetchone("SELECT totp_secret FROM users WHERE id=%s", user.id)
  local secret = row and nn(row.totp_secret)
  if not secret then return 400, { detail = "Start 2FA setup first." } end
  if not totp.verify_code(secret, code, os.time()) then
    return 400, { detail = "Incorrect code. Check your authenticator app and try again." }
  end
  local recovery_codes = totp.generate_recovery_codes(8)
  local hashed = {}
  for i, rc in ipairs(recovery_codes) do hashed[i] = gauth.password_hash(rc) end
  db.execute("UPDATE users SET totp_enabled_at=now(), totp_recovery_codes=%s WHERE id=%s", cjson.encode(hashed), user.id)
  return 200, { enabled = true, recovery_codes = recovery_codes }
end

function M.totp_disable(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local password = tostring(nn(payload.password) or "")
  local row = db.fetchone("SELECT password_hash FROM users WHERE id=%s", user.id)
  if not row or not gauth.verify_password_hash(password, row.password_hash) then
    return 400, { detail = "Incorrect password." }
  end
  db.execute("UPDATE users SET totp_secret=NULL, totp_enabled_at=NULL, totp_recovery_codes=NULL WHERE id=%s", user.id)
  return 200, { enabled = false }
end

-- ---------------------------------------------------------------------------
-- Cheap read-only endpoints hit on nearly every page load (tag cloud, site
-- announcement banner, notification bell) -- ported because leaving them
-- 404ing would break the shell chrome on every single page, not just one
-- feature. Mirrors app/routers/categories.py's tags(), app/routers/admin.py's
-- site_announcement(), and app/routers/notifications.py's unread/read
-- endpoints (full notification listing/creation itself is NOT ported yet).
-- ---------------------------------------------------------------------------

function M.tag_cloud(req)
  local rows = db.fetchall(
    "SELECT tags FROM media_items WHERE tags IS NOT NULL AND deleted_at IS NULL AND visibility='public' ORDER BY created_at DESC LIMIT 500"
  )
  local counts = {}
  local order = {}
  for _, row in ipairs(rows) do
    if row.tags and row.tags ~= cjson.null then
      local ok, tags = pcall(cjson.decode, row.tags)
      if ok and type(tags) == "table" then
        for _, tag in ipairs(tags) do
          local normalized = trim(tostring(tag)):sub(1, 32)
          if normalized ~= "" then
            if not counts[normalized] then order[#order + 1] = normalized end
            counts[normalized] = (counts[normalized] or 0) + 1
          end
        end
      end
    end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a:lower() < b:lower()
  end)
  local out = {}
  for i = 1, math.min(30, #order) do out[i] = { tag = order[i], count = counts[order[i]] } end
  return 200, { tags = arr(out) }
end

function M.site_announcement(req)
  local row = db.fetchone("SELECT announcement_message, announcement_level, announcement_active, maintenance_mode, maintenance_message FROM site_settings WHERE id=1")
  row = row or {}
  return 200, {
    announcement_message = nn(row.announcement_message),
    announcement_level = nn(row.announcement_level) or "info",
    announcement_active = db.tobool(row.announcement_active),
    maintenance_mode = db.tobool(row.maintenance_mode),
    maintenance_message = nn(row.maintenance_message),
  }
end

function M.notifications_unread_count(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local row = db.fetchone("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { unread_count = db.toint(row and row.n, 0) }
end

function M.notifications_mark_read(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local notification_id = tonumber(req.params.notification_id)
  if notification_id then
    db.execute("UPDATE notifications SET read_at=now() WHERE id=%s AND recipient_id=%s AND read_at IS NULL", tostring(notification_id), user.id)
  end
  local row = db.fetchone("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { unread_count = db.toint(row and row.n, 0) }
end

function M.notifications_mark_all_read(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  db.execute("UPDATE notifications SET read_at=now() WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { unread_count = 0 }
end

function M.notifications_list(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local limit = bounded_limit(req.query.limit, 30, 100)
  local rows = db.fetchall([[
    SELECT n.id, n.recipient_id, n.actor_id, n.kind, n.media_id, n.preview, n.read_at, n.created_at,
           a.username AS actor_username, a.display_name AS actor_display_name
    FROM notifications n
    LEFT JOIN users a ON a.id = n.actor_id
    WHERE n.recipient_id = %s
    ORDER BY n.created_at DESC
    LIMIT %s
  ]], user.id, tostring(limit))
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.recipient_id = db.toint(row.recipient_id, row.recipient_id)
    if row.actor_id then row.actor_id = db.toint(row.actor_id, row.actor_id) end
    if row.media_id then row.media_id = db.toint(row.media_id, row.media_id) end
  end
  local unread_row = db.fetchone("SELECT COUNT(*) AS n FROM notifications WHERE recipient_id=%s AND read_at IS NULL", user.id)
  return 200, { notifications = arr(rows), unread_count = db.toint(unread_row and unread_row.n, 0) }
end

local NOTIFICATION_KINDS = {
  follow = true, like = true, comment = true, message = true, mention = true,
  friend_request = true, friend_accept = true, report = true,
}

-- Mirrors app/db/notifications.py's create_notification(): silently skips
-- self-notifications and unknown kinds rather than erroring, since callers
-- (like send_direct_message below) don't want a notification-table hiccup
-- to fail the actual action.
local function create_notification(recipient_id, actor_id, kind, media_id, preview)
  if not NOTIFICATION_KINDS[kind] then return end
  if actor_id and tostring(actor_id) == tostring(recipient_id) then return end
  preview = preview and trim(preview):sub(1, 160) or nil
  if preview == "" then preview = nil end
  db.execute(
    "INSERT INTO notifications (recipient_id, actor_id, kind, media_id, preview) VALUES (%s, %s, %s, %s, %s)",
    tostring(recipient_id), actor_id and tostring(actor_id) or nil, kind, media_id and tostring(media_id) or nil, preview
  )
end

-- Mirrors app/db/social.py's is_blocked_either_way().
local function is_blocked_either_way(user_a, user_b)
  if not user_a or not user_b then return false end
  local row = db.fetchone(
    [[
      SELECT 1 FROM user_blocks
      WHERE kind='block' AND ((blocker_id=%s AND blocked_id=%s) OR (blocker_id=%s AND blocked_id=%s))
      LIMIT 1
    ]],
    tostring(user_a), tostring(user_b), tostring(user_b), tostring(user_a)
  )
  return row ~= nil
end

-- Mirrors app/routers/_shared.py's _with_user_urls(): fills in avatar_url +
-- site_owner for a user-shaped row that has an avatar_path/avatar_file_id.
local function with_user_urls(req, user)
  if not user then return nil end
  if user.avatar_path and user.avatar_path ~= cjson.null then
    local origin = request_origin(req)
    user.avatar_url = origin .. "/api/users/" .. user.id .. "/avatar"
  end
  user.site_owner = is_site_owner(user)
  return user
end

-- ---------------------------------------------------------------------------
-- Direct messages. Mirrors app/routers/messages.py + app/db/messages.py.
-- ---------------------------------------------------------------------------

local function decode_message(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.sender_id = db.toint(row.sender_id, row.sender_id)
  row.recipient_id = db.toint(row.recipient_id, row.recipient_id)
  row.public_profile = db.tobool(row.public_profile)
  row.is_online = db.tobool(row.is_online)
  return row
end

function M.message_threads(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    [[
      SELECT
        other_user.id AS id, other_user.id AS user_id, other_user.username,
        CASE WHEN other_user.public_profile THEN other_user.display_name ELSE other_user.username END AS display_name,
        CASE WHEN other_user.public_profile THEN other_user.avatar_path ELSE NULL END AS avatar_path,
        other_user.profile_color, other_user.public_profile, other_user.last_seen_at,
        (now() - other_user.last_seen_at) <= interval '180 seconds' AS is_online,
        latest.id AS last_message_id, latest.body AS last_message, latest.created_at AS last_message_at,
        latest.sender_id AS last_sender_id, COALESCE(unread.unread_count, 0) AS unread_count
      FROM (
        SELECT CASE WHEN sender_id=%s THEN recipient_id ELSE sender_id END AS other_id, MAX(id) AS last_id
        FROM user_messages
        WHERE sender_id=%s OR recipient_id=%s
        GROUP BY other_id
      ) threads
      JOIN user_messages latest ON latest.id = threads.last_id
      JOIN users other_user ON other_user.id = threads.other_id
      LEFT JOIN (
        SELECT sender_id AS other_id, COUNT(*) AS unread_count
        FROM user_messages
        WHERE recipient_id=%s AND read_at IS NULL
        GROUP BY sender_id
      ) unread ON unread.other_id = threads.other_id
      ORDER BY latest.created_at DESC
      LIMIT 100
    ]],
    user.id, user.id, user.id, user.id
  )
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.last_message_id = row.last_message_id and db.toint(row.last_message_id, row.last_message_id) or nil
    row.last_sender_id = row.last_sender_id and db.toint(row.last_sender_id, row.last_sender_id) or nil
    row.unread_count = db.toint(row.unread_count, 0)
    row.public_profile = db.tobool(row.public_profile)
    row.is_online = db.tobool(row.is_online)
    with_user_urls(req, row)
  end
  return 200, { threads = arr(rows) }
end

local function fetch_direct_messages_sql(user_id, other_id, limit)
  return db.fetchall(
    [[
      SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile,
             (now() - u.last_seen_at) <= interval '180 seconds' AS is_online
      FROM user_messages msg
      JOIN users u ON u.id = msg.sender_id
      WHERE (msg.sender_id=%s AND msg.recipient_id=%s) OR (msg.sender_id=%s AND msg.recipient_id=%s)
      ORDER BY msg.created_at DESC, msg.id DESC
      LIMIT %s
    ]],
    tostring(user_id), tostring(other_id), tostring(other_id), tostring(user_id), tostring(math.max(1, math.min(limit, 200)))
  )
end

function M.direct_messages(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local other_id = tonumber(req.params.user_id)
  if not other_id then return 404, { detail = "User not found." } end
  if tostring(other_id) == tostring(user.id) then
    return 400, { detail = "Pick another user to view messages." }
  end
  local other = get_user(tostring(other_id))
  if not other then return 400, { detail = "User not found." } end

  db.execute(
    "UPDATE user_messages SET read_at=COALESCE(read_at, CURRENT_TIMESTAMP) WHERE sender_id=%s AND recipient_id=%s AND read_at IS NULL",
    tostring(other_id), user.id
  )
  local limit = tonumber(req.query.limit) or 80
  local rows = fetch_direct_messages_sql(user.id, other_id, limit)
  local ordered = {}
  for i = #rows, 1, -1 do ordered[#ordered + 1] = decode_message(rows[i]) end
  return 200, { messages = arr(ordered) }
end

function M.send_direct_message(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local other_id = tonumber(req.params.user_id)
  if not other_id then return 404, { detail = "User not found." } end
  if is_blocked_either_way(user.id, other_id) then
    return 403, { detail = "You cannot message this user." }
  end
  if tostring(other_id) == tostring(user.id) then
    return 400, { detail = "You cannot message yourself." }
  end
  local payload = json_body(req)
  local cleaned = trim(nn(payload.body) or ""):gsub("%s+", " ")
  if cleaned == "" then return 400, { detail = "Message cannot be empty." } end
  if #cleaned > 2000 then return 400, { detail = "Message must be 2000 characters or fewer." } end
  local other = get_user(tostring(other_id))
  if not other then return 400, { detail = "User not found." } end

  local row = db.fetchone(
    "INSERT INTO user_messages (sender_id, recipient_id, body) VALUES (%s, %s, %s) RETURNING id",
    user.id, tostring(other_id), cleaned
  )
  if not row then return 500, { detail = "Could not send message." } end
  local message = db.fetchone(
    [[
      SELECT msg.*, u.username, u.display_name, u.avatar_path, u.profile_color, u.public_profile,
             (now() - u.last_seen_at) <= interval '180 seconds' AS is_online
      FROM user_messages msg
      JOIN users u ON u.id = msg.sender_id
      WHERE msg.id = %s
    ]],
    tostring(db.toint(row.id, row.id))
  )
  create_notification(other_id, user.id, "message", nil, cleaned)
  return 200, { message = decode_message(message) }
end

-- ---------------------------------------------------------------------------
-- Collections. Mirrors app/routers/collections.py + the collection-related
-- half of app/db/feed_collections.py (following_feed/liked_media/saved
-- searches are a different router's territory and NOT covered here).
-- ---------------------------------------------------------------------------

local SMART_FILTER_KEYS = {
  media_kind = true, category_id = true, subcategory_id = true, q = true, uploader = true,
  min_size = true, max_size = true, date_from = true, date_to = true, adult = true, sort = true,
}
local DATE_RE = "^%d%d%d%d%-%d%d%-%d%d$"

-- Mirrors _sanitize_smart_collection_filter(): validates/coerces a saved
-- smart-collection filter the same way GET /api/media's own query params
-- would be, so a bad stored value can't reach list_media unvalidated.
local function sanitize_smart_filter(filter_json)
  local cleaned = {}
  for key, value in pairs(filter_json or {}) do
    if SMART_FILTER_KEYS[key] and value ~= nil and value ~= "" and value ~= cjson.null then
      if key == "media_kind" then
        if value == "image" or value == "video" then cleaned[key] = value end
      elseif key == "category_id" or key == "subcategory_id" then
        local n = tonumber(value)
        if n then cleaned[key] = math.floor(n) end
      elseif key == "min_size" or key == "max_size" then
        local n = tonumber(value)
        if n then cleaned[key] = math.max(0, math.floor(n)) end
      elseif key == "date_from" or key == "date_to" then
        if tostring(value):match(DATE_RE) then cleaned[key] = value end
      elseif key == "adult" then
        if value == "only" or value == "hide" then cleaned[key] = value end
      elseif key == "sort" then
        if VALID_SORTS[value] then cleaned[key] = value end
      elseif key == "q" or key == "uploader" then
        cleaned[key] = tostring(value):sub(1, 80)
      end
    end
  end
  return cleaned
end

local function clean_text(value, max_len)
  local cleaned = trim(nn(value) or ""):gsub("%s+", " ")
  return cleaned:sub(1, max_len)
end

local function decode_collection(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.user_id = db.toint(row.user_id, row.user_id)
  row.item_count = db.toint(row.item_count, 0)
  row.cover_media_id = row.cover_media_id and db.toint(row.cover_media_id, row.cover_media_id) or nil
  row.is_public = db.tobool(row.is_public)
  row.is_smart = db.tobool(row.is_smart)
  row.cover_is_adult = db.tobool(row.cover_is_adult)
  if row.is_smart and nn(row.filter_json) then
    local ok, decoded = pcall(cjson.decode, row.filter_json)
    row.filter = (ok and type(decoded) == "table") and decoded or {}
  else
    row.filter = {}
  end
  return row
end

-- Mirrors _with_collection_urls(): fills in cover_url (pointing at this
-- backend's own /api/media/:id/file) or locks the cover out entirely for an
-- unlocked-adult viewer, plus user_avatar_url.
local function with_collection_urls(req, collection, adult_allowed)
  if not collection then return nil end
  local origin = request_origin(req)
  if collection.cover_path and (adult_allowed or not collection.cover_is_adult) then
    if collection.cover_media_id then
      collection.cover_url = origin .. "/api/media/" .. collection.cover_media_id .. "/file"
    else
      collection.cover_url = nil
    end
  elseif collection.cover_is_adult then
    collection.cover_path = nil
    collection.cover_url = nil
    collection.cover_locked = true
  end
  if collection.user_avatar_path and collection.user_avatar_path ~= cjson.null then
    collection.user_avatar_url = origin .. "/api/users/" .. (collection.user_id or collection.id) .. "/avatar"
  end
  return collection
end

local COLLECTION_SELECT = [[
  SELECT mc.*, u.username, u.display_name, u.avatar_path AS user_avatar_path,
         COUNT(mi.id) AS item_count,
         MAX(mi.storage_path) AS cover_path,
         MAX(mi.media_kind) AS cover_media_kind,
         MAX(mi.id) AS cover_media_id,
         MAX(CASE WHEN mi.is_adult THEN 1 ELSE 0 END) AS cover_is_adult
  FROM media_collections mc
  JOIN users u ON u.id = mc.user_id
  LEFT JOIN media_collection_items mci ON mci.collection_id = mc.id
  LEFT JOIN media_items mi ON mi.id = mci.media_id AND mi.deleted_at IS NULL
    AND (mi.visibility='public' OR mi.user_id=%s OR mc.user_id=%s)
]]

local function fetch_collection(collection_id, viewer_id)
  local v = tostring(viewer_id or 0)
  return db.fetchone(
    COLLECTION_SELECT .. " WHERE mc.id=%s AND (mc.is_public OR mc.user_id=%s) GROUP BY mc.id, u.id",
    v, v, tostring(collection_id), v
  )
end

function M.collection_suggestions(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local existing = db.fetchall(
    COLLECTION_SELECT .. " WHERE mc.user_id=%s GROUP BY mc.id, u.id",
    user.id, user.id, user.id
  )
  local covered = {}
  for _, row in ipairs(existing) do
    if db.tobool(row.is_smart) and nn(row.filter_json) then
      local ok, decoded = pcall(cjson.decode, row.filter_json)
      if ok and type(decoded) == "table" and decoded.q then
        covered[tostring(decoded.q):lower()] = true
      end
    end
  end

  local rows = db.fetchall(
    "SELECT id, tags FROM media_items WHERE user_id=%s AND deleted_at IS NULL AND tags IS NOT NULL ORDER BY created_at DESC LIMIT 1000",
    user.id
  )
  local counts, sample = {}, {}
  for _, row in ipairs(rows) do
    if row.tags and row.tags ~= cjson.null then
      local ok, tags = pcall(cjson.decode, row.tags)
      if ok and type(tags) == "table" then
        for _, tag in ipairs(tags) do
          local normalized = trim(tostring(tag)):lower():sub(1, 32)
          if normalized ~= "" then
            counts[normalized] = (counts[normalized] or 0) + 1
            if not sample[normalized] then sample[normalized] = db.toint(row.id, row.id) end
          end
        end
      end
    end
  end
  local order = {}
  for tag, count in pairs(counts) do
    if count >= 4 and not covered[tag] then order[#order + 1] = tag end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local suggestions = {}
  for i = 1, math.min(8, #order) do
    local tag = order[i]
    suggestions[i] = {
      tag = tag, count = counts[tag],
      thumb_url = append_query(request_origin(req) .. "/api/media/" .. sample[tag] .. "/thumb", "w", "640"),
    }
  end
  return 200, { suggestions = arr(suggestions) }
end

function M.list_collections(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)
  local mine = req.query.mine == "true" or req.query.mine == "1"
  if mine and not viewer_id then return 401, { detail = "Login required" } end
  local v = viewer_id or "0"
  local where = mine and "mc.user_id=%s" or "(mc.is_public OR mc.user_id=%s)"
  local rows = db.fetchall(
    COLLECTION_SELECT .. " WHERE " .. where .. " GROUP BY mc.id, u.id ORDER BY mc.updated_at DESC, mc.created_at DESC LIMIT 100",
    v, v, v
  )
  for _, row in ipairs(rows) do
    decode_collection(row)
    with_collection_urls(req, row, adult_allowed)
  end
  return 200, { collections = arr(rows) }
end

function M.create_collection(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local name = clean_text(payload.name, 100)
  if name == "" then return 400, { detail = "Name is required." } end
  local description_text = clean_text(payload.description, 500)
  local description = description_text ~= "" and description_text or nil
  local is_public = payload.is_public == nil or db.tobool(payload.is_public)
  local is_smart = db.tobool(payload.is_smart)
  local stored_filter = nil
  if is_smart then
    stored_filter = cjson.encode(sanitize_smart_filter(payload.filter_json)):sub(1, 8000)
  end

  local row = db.fetchone(
    "INSERT INTO media_collections (user_id, name, description, is_public, is_smart, filter_json) VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
    user.id, name, description, is_public, is_smart, stored_filter
  )
  if not row then return 500, { detail = "Could not create collection." } end
  local collection = fetch_collection(db.toint(row.id, row.id), user.id)
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { collection = with_collection_urls(req, decode_collection(collection), adult_allowed) }
end

function M.collection_detail(req)
  local collection_id = tonumber(req.params.collection_id)
  if not collection_id then return 404, { detail = "Collection not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local collection = fetch_collection(collection_id, viewer_id)
  if not collection then return 404, { detail = "Collection not found." } end
  decode_collection(collection)

  local media_rows = {}
  if collection.is_smart then
    local filter = collection.filter or {}
    local fake_req = {
      headers = req.headers,
      query = {
        media_kind = filter.media_kind, category_id = filter.category_id and tostring(filter.category_id) or nil,
        subcategory_id = filter.subcategory_id and tostring(filter.subcategory_id) or nil,
        q = filter.q, uploader = filter.uploader,
        min_size = filter.min_size and tostring(filter.min_size) or nil,
        max_size = filter.max_size and tostring(filter.max_size) or nil,
        date_from = filter.date_from, date_to = filter.date_to, adult = filter.adult,
        sort = filter.sort or "new", limit = "120",
      },
    }
    local _, list_body = M.list_media(fake_req)
    media_rows = (list_body and list_body.media) or {}
  else
    local v = viewer_id or "0"
    media_rows = db.fetchall(
      [[
        SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
               m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
               m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
               m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
               m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status,
               c.name AS category_name, c.slug AS category_slug,
               sc.name AS subcategory_name, sc.slug AS subcategory_slug,
               u.username,
               CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
               CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS user_avatar_path,
               u.profile_color, u.public_profile,
               COUNT(DISTINCT l.user_id) AS like_count,
               COUNT(DISTINCT cm.id) AS comment_count,
               MAX(CASE WHEN b.user_id IS NULL THEN 0 ELSE 1 END) AS bookmarked_by_me,
               MAX(CASE WHEN l2.user_id IS NULL THEN 0 ELSE 1 END) AS liked_by_me
        FROM media_collection_items mci
        JOIN media_items m ON m.id = mci.media_id
        JOIN categories c ON c.id = m.category_id
        LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
        JOIN users u ON u.id = m.user_id
        LEFT JOIN media_likes l ON l.media_id = m.id
        LEFT JOIN media_likes l2 ON l2.media_id = m.id AND l2.user_id::text = %s
        LEFT JOIN media_bookmarks b ON b.media_id = m.id AND b.user_id::text = %s
        LEFT JOIN media_comments cm ON cm.media_id = m.id
        WHERE mci.collection_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=%s)
        GROUP BY m.id, c.name, c.slug, sc.name, sc.slug, u.username, u.display_name,
                 u.avatar_path, u.profile_color, u.public_profile, u.id
        ORDER BY mci.added_at DESC
        LIMIT 120
      ]],
      v, v, v, v, tostring(collection_id), v
    )
    for _, row in ipairs(media_rows) do decode_media_row(row, adult_allowed, req) end
  end

  return 200, {
    collection = with_collection_urls(req, collection, adult_allowed),
    media = arr(media_rows),
  }
end

function M.save_collection_item(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local collection_id = tonumber(req.params.collection_id)
  if not collection_id then return 404, { detail = "Collection not found." } end
  local payload = json_body(req)
  local media_id = tonumber(payload.media_id)
  if not media_id then return 400, { detail = "media_id is required." } end
  local saved = payload.saved == nil or db.tobool(payload.saved)

  local collection = fetch_collection(collection_id, user.id)
  if not collection or tostring(collection.user_id) ~= tostring(user.id) then
    return 404, { detail = "Collection not found." }
  end
  local media = fetch_media_by_id(media_id, tostring(user.id))
  if not media or nn(media.deleted_at) then return 404, { detail = "Collection not found." } end
  if media.visibility == "private" and tostring(media.user_id) ~= tostring(user.id) then
    return 404, { detail = "Collection not found." }
  end

  if saved then
    db.execute(
      "INSERT INTO media_collection_items (collection_id, media_id) VALUES (%s, %s) ON CONFLICT (collection_id, media_id) DO NOTHING",
      tostring(collection_id), tostring(media_id)
    )
  else
    db.execute(
      "DELETE FROM media_collection_items WHERE collection_id=%s AND media_id=%s",
      tostring(collection_id), tostring(media_id)
    )
  end
  db.execute("UPDATE media_collections SET updated_at=CURRENT_TIMESTAMP WHERE id=%s", tostring(collection_id))

  local updated = fetch_collection(collection_id, user.id)
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  return 200, { collection = with_collection_urls(req, decode_collection(updated), adult_allowed) }
end

-- ---------------------------------------------------------------------------
-- Site-owner admin/moderation. Mirrors app/routers/admin.py +
-- app/db/admin.py. NOT PORTED as part of this pass: the storage dashboard /
-- purge-orphans endpoints (app/routers/admin.py's storage_dashboard /
-- purge_storage_orphans) -- those filesystem-walk the on-disk thumb/video
-- cache dirs, which is lower value while the dataset is DB-blob-backed (see
-- media_files.lua's docstring); left for a follow-up.
-- ---------------------------------------------------------------------------

-- Depends()-equivalent for _require_site_owner(): returns (owner_user) or
-- (nil, status, body) on failure.
local function require_site_owner(req)
  local user, auth, status, body = current_user(req)
  if not user then return nil, status, body end
  if not is_site_owner(user) then
    return nil, 403, { detail = "Only the verified site owner can use this action." }
  end
  return user
end

local function write_audit_log(actor_id, action, target_type, target_id, detail)
  detail = detail and tostring(detail):sub(1, 500) or nil
  if detail == "" then detail = nil end
  db.execute(
    "INSERT INTO moderation_audit_log (actor_id, action, target_type, target_id, detail) VALUES (%s, %s, %s, %s, %s)",
    actor_id and tostring(actor_id) or nil, tostring(action):sub(1, 60), tostring(target_type):sub(1, 30),
    target_id and tostring(target_id) or nil, detail
  )
end

function M.admin_stats(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local users_row = db.fetchone("SELECT COUNT(*) AS n FROM users")
  local categories_row = db.fetchone("SELECT COUNT(*) AS n FROM categories")
  local media_row = db.fetchone("SELECT COUNT(*) AS n, COALESCE(SUM(file_size), 0) AS bytes FROM media_items")
  local likes_row = db.fetchone("SELECT COUNT(*) AS n FROM media_likes")
  return 200, {
    stats = {
      users = db.toint(users_row and users_row.n, 0),
      categories = db.toint(categories_row and categories_row.n, 0),
      media = db.toint(media_row and media_row.n, 0),
      bytes = db.toint(media_row and media_row.bytes, 0),
      likes = db.toint(likes_row and likes_row.n, 0),
    },
  }
end

local REPORT_STATUSES = { open = true, reviewed = true, dismissed = true }

function M.admin_list_reports(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local q = req.query or {}
  local report_status = REPORT_STATUSES[q.status or ""] and q.status or nil
  local limit = math.max(1, math.min(tonumber(q.limit) or 50, 200))
  local offset = math.max(0, tonumber(q.offset) or 0)
  local where = report_status and "WHERE r.status=%s" or ""
  local sql = string.format(
    [[
      SELECT r.id, r.media_id, r.user_id, r.reason, r.details, r.status, r.created_at,
             m.title AS media_title, m.media_kind, m.mime_type,
             m.deleted_at AS media_deleted_at, m.user_id AS media_owner_id,
             ru.username AS reporter_username, ru.display_name AS reporter_display_name,
             mu.username AS media_owner_username, mu.display_name AS media_owner_display_name
      FROM media_reports r
      JOIN media_items m ON m.id = r.media_id
      JOIN users ru ON ru.id = r.user_id
      JOIN users mu ON mu.id = m.user_id
      %s
      ORDER BY r.created_at DESC
      LIMIT %%s OFFSET %%s
    ]],
    where
  )
  local rows
  if report_status then
    rows = db.fetchall(sql, report_status, tostring(limit), tostring(offset))
  else
    rows = db.fetchall(sql, tostring(limit), tostring(offset))
  end
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.media_id = db.toint(row.media_id, row.media_id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.media_owner_id = row.media_owner_id and db.toint(row.media_owner_id, row.media_owner_id) or nil
    row.media_thumb_url = row.media_id and row.media_id > 0 and append_query(origin .. "/api/media/" .. row.media_id .. "/thumb", "w", "640") or nil
  end
  return 200, { reports = arr(rows), limit = limit, offset = offset }
end

function M.admin_resolve_report(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local report_id = tonumber(req.params.report_id)
  if not report_id then return 404, { detail = "Report not found." } end
  local payload = json_body(req)
  local new_status = nn(payload.status)
  if new_status ~= "reviewed" and new_status ~= "dismissed" then
    return 400, { detail = "status must be reviewed or dismissed." }
  end
  db.execute("UPDATE media_reports SET status=%s WHERE id=%s", new_status, tostring(report_id))
  local report = db.fetchone("SELECT * FROM media_reports WHERE id=%s", tostring(report_id))
  if not report then return 404, { detail = "Report not found." } end
  report.id = db.toint(report.id, report.id)
  report.media_id = db.toint(report.media_id, report.media_id)
  report.user_id = db.toint(report.user_id, report.user_id)
  write_audit_log(owner.id, "report_" .. new_status, "report", report_id, "media_id=" .. tostring(report.media_id))
  if payload.delete_media then
    db.execute(
      "UPDATE media_items SET deleted_at=CURRENT_TIMESTAMP, visibility='private' WHERE id=%s AND deleted_at IS NULL",
      tostring(report.media_id)
    )
    write_audit_log(owner.id, "delete_media", "media", report.media_id, nil)
  end
  return 200, { report = report }
end

function M.admin_ban_user(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  if tostring(user_id) == tostring(owner.id) then
    return 400, { detail = "You cannot ban your own account." }
  end
  local payload = json_body(req)
  local reason = trim(nn(payload.reason) or ""):sub(1, 300)
  if reason == "" then reason = nil end
  local until_value = nn(payload["until"])

  local result = db.execute(
    "UPDATE users SET banned_at=CURRENT_TIMESTAMP, banned_until=%s, ban_reason=%s, banned_by=%s WHERE id=%s",
    until_value, reason, owner.id, tostring(user_id)
  )
  local user = get_user(tostring(user_id))
  if not user then return 404, { detail = "User not found." } end
  write_audit_log(owner.id, "ban", "user", user_id, reason)
  user.site_owner = is_site_owner(user)
  return 200, { user = user }
end

function M.admin_unban_user(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  db.execute(
    "UPDATE users SET banned_at=NULL, banned_until=NULL, ban_reason=NULL, banned_by=NULL WHERE id=%s",
    tostring(user_id)
  )
  local user = get_user(tostring(user_id))
  if not user then return 404, { detail = "User not found." } end
  write_audit_log(owner.id, "unban", "user", user_id, nil)
  user.site_owner = is_site_owner(user)
  return 200, { user = user }
end

function M.admin_audit_log(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 50, 200))
  local offset = math.max(0, tonumber(req.query.offset) or 0)
  local rows = db.fetchall(
    [[
      SELECT a.*, u.username AS actor_username, COALESCE(u.display_name, u.username) AS actor_display_name
      FROM moderation_audit_log a
      LEFT JOIN users u ON u.id = a.actor_id
      ORDER BY a.created_at DESC
      LIMIT %s OFFSET %s
    ]],
    tostring(limit), tostring(offset)
  )
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.actor_id = row.actor_id and db.toint(row.actor_id, row.actor_id) or nil
    row.target_id = row.target_id and db.toint(row.target_id, row.target_id) or nil
  end
  return 200, { entries = arr(rows) }
end

function M.admin_flagged_media(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 50, 200))
  local offset = math.max(0, tonumber(req.query.offset) or 0)
  local rows = db.fetchall(
    [[
      SELECT m.*, u.username AS owner_username, COALESCE(u.display_name, u.username) AS owner_display_name
      FROM media_items m
      JOIN users u ON u.id = m.user_id
      WHERE m.moderation_status='pending_review' AND m.deleted_at IS NULL
      ORDER BY m.created_at DESC
      LIMIT %s OFFSET %s
    ]],
    tostring(limit), tostring(offset)
  )
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    numify_media(row)
    row.thumb_url = append_query(origin .. "/api/media/" .. row.id .. "/thumb", "w", "640")
  end
  return 200, { media = arr(rows) }
end

function M.admin_resolve_flagged_media(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Flagged media not found." } end
  local payload = json_body(req)
  local decision = nn(payload.decision)
  if decision ~= "clear" and decision ~= "adult" then
    return 400, { detail = "decision must be clear or adult." }
  end
  db.execute(
    "UPDATE media_items SET moderation_status=%s, is_adult=%s, moderated_at=CURRENT_TIMESTAMP WHERE id=%s AND moderation_status='pending_review'",
    decision, decision == "adult", tostring(media_id)
  )
  local item = db.fetchone("SELECT * FROM media_items WHERE id=%s", tostring(media_id))
  if not item then return 404, { detail = "Flagged media not found." } end
  numify_media(item)
  write_audit_log(owner.id, "flagged_media_" .. decision, "media", media_id, nil)
  return 200, { media = item }
end

-- ---------------------------------------------------------------------------
-- Storage dashboard + orphaned-cache-file purge. Mirrors
-- app/db/admin.py's storage_by_user() and app/routers/admin.py's
-- _walk_cache_dir()/storage_dashboard()/purge_storage_orphans(), with one
-- deliberate correction: Python builds its "referenced" set from
-- storage_by_user()'s top-N-by-user aggregate rows, which only ever have a
-- user_id column -- referenced = {str(row["id"]) ...} raises KeyError
-- immediately (no "id" key in that row shape) and, even if it didn't, a
-- per-user aggregate has no media ids in it to match cache filenames
-- against anyway (those are named "<media_id>_<width>.webp", see
-- serve_media_thumb). This port instead builds the referenced set from the
-- actual set of live media_items ids, which is what the cache filenames are
-- really keyed by, so orphan detection actually works.
-- ---------------------------------------------------------------------------

local function storage_by_user(limit)
  limit = math.max(1, math.min(limit or 20, 100))
  local totals = db.fetchone("SELECT COALESCE(SUM(file_size), 0) AS total_bytes, COUNT(*) AS total_items FROM media_items WHERE deleted_at IS NULL")
  local by_user = db.fetchall([[
    SELECT m.user_id, u.username, COALESCE(u.display_name, u.username) AS display_name,
           COUNT(*) AS item_count, COALESCE(SUM(m.file_size), 0) AS total_bytes
    FROM media_items m
    JOIN users u ON u.id = m.user_id
    WHERE m.deleted_at IS NULL
    GROUP BY m.user_id, u.id
    ORDER BY total_bytes DESC
    LIMIT %s
  ]], tostring(limit))
  for _, row in ipairs(by_user) do
    row.user_id = db.toint(row.user_id, row.user_id)
    row.item_count = db.toint(row.item_count, 0)
    row.total_bytes = db.toint(row.total_bytes, 0)
  end
  return {
    total_bytes = db.toint(totals and totals.total_bytes, 0),
    total_items = db.toint(totals and totals.total_items, 0),
    by_user = by_user,
  }
end

local function referenced_media_ids()
  local rows = db.fetchall("SELECT id FROM media_items WHERE deleted_at IS NULL")
  local set = {}
  for _, row in ipairs(rows) do set[tostring(db.toint(row.id, row.id))] = true end
  return set
end

local ORPHAN_CACHE_DIR_NAMES = { "_thumb_cache", "_video_cache" }
local ORPHAN_MIN_AGE_SECONDS = 24 * 3600

-- Lua's %q escapes for a *Lua* string literal, not a shell argument -- use
-- real single-quote shell escaping instead (same convention as
-- media_files.lua's own shell_quote(), duplicated here since that one is
-- local to that module).
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- No lfs/posix rock is vendored, so directory listing shells out to `find`
-- (same io.popen/os.execute pattern media_files.lua already uses for
-- ffmpeg). `find -printf` gives size+mtime+path in one pass without a
-- per-file stat() round-trip.
local function walk_cache_dir(uploads_dir, referenced_ids)
  local total_bytes, total_files, orphan_bytes = 0, 0, 0
  local orphan_files = {}
  local now = os.time()
  for _, dir_name in ipairs(ORPHAN_CACHE_DIR_NAMES) do
    local cache_dir = uploads_dir .. "/" .. dir_name
    local handle = io.popen(string.format("find %s -type f -printf '%%s %%T@ %%p\\n' 2>/dev/null", shell_quote(cache_dir)))
    if handle then
      for line in handle:lines() do
        local size_str, mtime_str, path = line:match("^(%d+) (%S+) (.+)$")
        if size_str then
          local size = tonumber(size_str) or 0
          local mtime = tonumber(mtime_str) or 0
          total_bytes = total_bytes + size
          total_files = total_files + 1
          local filename = path:match("([^/]+)$") or path
          local media_id = filename:match("^(%d+)")
          local is_referenced = media_id and referenced_ids[media_id]
          if not is_referenced and (now - mtime) > ORPHAN_MIN_AGE_SECONDS then
            orphan_bytes = orphan_bytes + size
            orphan_files[#orphan_files + 1] = { path = path, size = size }
          end
        end
      end
      handle:close()
    end
  end
  return {
    cache_total_bytes = total_bytes,
    cache_total_files = total_files,
    orphan_bytes = orphan_bytes,
    orphan_count = #orphan_files,
    orphan_files = orphan_files,
  }
end

function M.admin_storage(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local by_user = storage_by_user(25)
  local cache_info = walk_cache_dir(M.settings.uploads_dir, referenced_media_ids())
  return 200, {
    total_bytes = by_user.total_bytes,
    total_items = by_user.total_items,
    by_user = arr(by_user.by_user),
    cache_total_bytes = cache_info.cache_total_bytes,
    cache_total_files = cache_info.cache_total_files,
    orphan_bytes = cache_info.orphan_bytes,
    orphan_count = cache_info.orphan_count,
  }
end

function M.admin_purge_storage_orphans(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local cache_info = walk_cache_dir(M.settings.uploads_dir, referenced_media_ids())
  local removed, freed_bytes = 0, 0
  for _, entry in ipairs(cache_info.orphan_files) do
    if os.remove(entry.path) then
      removed = removed + 1
      freed_bytes = freed_bytes + entry.size
    end
  end
  write_audit_log(owner.id, "storage_purge_orphans", "storage", nil, string.format("removed=%d bytes=%d", removed, freed_bytes))
  return 200, { removed = removed, freed_bytes = freed_bytes }
end

local SITE_SETTINGS_FIELDS = {
  "announcement_message", "announcement_level", "announcement_active",
  "maintenance_mode", "maintenance_message",
}
local SITE_SETTINGS_BOOL_FIELDS = { announcement_active = true, maintenance_mode = true }

local function fetch_site_settings()
  local row = db.fetchone("SELECT * FROM site_settings WHERE id=1")
  return row or {}
end

function M.admin_update_site_settings(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local payload = json_body(req)
  local sets, params, touched = {}, {}, {}
  for _, key in ipairs(SITE_SETTINGS_FIELDS) do
    local value = payload[key]
    if value ~= nil and value ~= cjson.null then
      sets[#sets + 1] = key .. "=%s"
      if SITE_SETTINGS_BOOL_FIELDS[key] then
        params[#params + 1] = db.tobool(value)
      else
        params[#params + 1] = tostring(value):sub(1, 500)
      end
      touched[#touched + 1] = key
    end
  end
  if #sets > 0 then
    sets[#sets + 1] = "updated_by=%s"
    params[#params + 1] = tostring(owner.id)
    db.execute("UPDATE site_settings SET " .. table.concat(sets, ", ") .. " WHERE id=1", unpack(params))
    write_audit_log(owner.id, "site_settings_update", "site_settings", nil, table.concat(touched, ", "))
  end
  return 200, { settings = fetch_site_settings() }
end

-- ---------------------------------------------------------------------------
-- AI vision status + training-example listing/export. Mirrors
-- app/routers/ai_vision.py.
--
-- NOT PORTED as part of this pass: the actual LLM-calling classification
-- pipeline (app/ai_metadata.py, ~2150 lines of prompt construction, OpenAI/
-- Gemini/Ollama request handling, and heuristic fallback analysis) that
-- powers auto_ai on upload and POST /api/media/analyze -- this is a
-- substantially larger, separate effort flagged for its own follow-up
-- pass. What IS ported: provider/config status reporting and reading back
-- previously-recorded training examples (ai_vision_training_examples rows),
-- neither of which requires the analysis pipeline itself.
-- ---------------------------------------------------------------------------

local function normalized_ai_provider()
  local provider = tostring(M.settings.ai_provider or ""):lower()
  if provider == "google" or provider == "google-gemini" then provider = "gemini" end
  if provider == "" then provider = "heuristic-only" end
  return provider
end

local function active_ai_model()
  local provider = M.settings.ai_provider
  if provider == "gemini" or provider == "google" or provider == "google-gemini" then return M.settings.ai_model end
  if provider == "ollama" then return M.settings.ai_ollama_model end
  return M.settings.ai_model
end

local function active_ai_base_url()
  if M.settings.ai_provider == "ollama" then return M.settings.ai_ollama_base_url end
  return M.settings.ai_base_url
end

function M.ai_vision_status(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local provider = normalized_ai_provider()
  local training_count = 0
  local rows = db.fetchall(
    "SELECT id FROM ai_vision_training_examples WHERE user_id=%s ORDER BY created_at DESC LIMIT 1000",
    user.id
  )
  training_count = #rows

  local vision = {
    provider = provider,
    ai_enabled = M.settings.ai_enabled and true or false,
    training_examples_loaded_limit = M.settings.ai_training_examples_limit,
    training_examples_available = training_count,
    active_model = active_ai_model(),
    active_base_url = provider == "ollama" and active_ai_base_url() or nil,
    gemini_key_configured = (M.settings.ai_api_key ~= "" and provider == "gemini") and true or false,
  }
  if provider == "gemini" then
    vision.active_base_url = "https://generativelanguage.googleapis.com"
    vision.reachable = M.settings.ai_api_key ~= "" and nil or false
    vision.reason = M.settings.ai_api_key ~= "" and nil or "Gemini provider is selected but no Gemini API key is configured."
  elseif provider == "ollama" then
    local base_url = tostring(M.settings.ai_ollama_base_url or "http://127.0.0.1:11434"):gsub("/+$", "")
    local ok, http = pcall(require, "socket.http")
    local ok2, result = pcall(function()
      local ltn12 = require("ltn12")
      local chunks = {}
      http.TIMEOUT = 3
      local _, code = http.request({ url = base_url .. "/api/tags", sink = ltn12.sink.table(chunks) })
      if code ~= 200 then error("HTTP " .. tostring(code)) end
      local decoded = cjson.decode(table.concat(chunks)) or {}
      local models = {}
      for _, item in ipairs(decoded.models or {}) do
        if item.name and item.name ~= "" then models[#models + 1] = item.name end
        if #models >= 50 then break end
      end
      return models
    end)
    if ok and ok2 then
      vision.reachable = true
      vision.models = arr(result)
    else
      vision.reachable = false
      vision.reason = tostring(result):sub(1, 240)
    end
  end
  return 200, { vision = vision }
end

local function decode_ai_training_example(row)
  if not row then return nil end
  for _, key in ipairs({ "source_tags", "corrected_tags" }) do
    if row[key] and row[key] ~= cjson.null then
      local ok, decoded = pcall(cjson.decode, row[key])
      row[key] = (ok and type(decoded) == "table") and decoded or {}
    else
      row[key] = {}
    end
  end
  row.corrected_is_adult = db.tobool(row.corrected_is_adult)
  return row
end

function M.list_ai_training(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 50, 80))
  local rows = db.fetchall(
    "SELECT * FROM ai_vision_training_examples WHERE user_id=%s ORDER BY created_at DESC LIMIT %s",
    user.id, tostring(limit)
  )
  for _, row in ipairs(rows) do decode_ai_training_example(row) end
  return 200, { training_examples = arr(rows) }
end

function M.export_ai_training(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local limit = math.max(1, math.min(tonumber(req.query.limit) or 500, 5000))
  local rows = db.fetchall(
    [[
      SELECT t.*, m.media_kind, m.mime_type
      FROM ai_vision_training_examples t
      LEFT JOIN media_items m ON m.id = t.media_id
      WHERE t.user_id=%s
      ORDER BY t.created_at DESC
      LIMIT %s
    ]],
    user.id, tostring(limit)
  )
  local lines = {}
  for _, row in ipairs(rows) do
    decode_ai_training_example(row)
    lines[#lines + 1] = cjson.encode(row)
  end
  return 200, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""), {
    ["Content-Type"] = "application/x-ndjson; charset=utf-8",
    ["Content-Disposition"] = 'attachment; filename="gallery-ai-vision-training.jsonl"',
  }
end

-- ---------------------------------------------------------------------------
-- Media byte-serving: thumb / file / preview / download / avatar.
-- Mirrors app/routers/media_streaming.py. See media_files.lua's module
-- docstring for the storage-model correction versus this task's original
-- brief (DB blob storage is what's actually configured and live, not an
-- on-disk content-addressed tree) and for why ffmpeg (not a PIL-equivalent)
-- renders every thumbnail/preview here.
--
-- KNOWN LIMITATION vs Python: httpd.lua has no chunked/streaming response
-- support (see its send_response(), which always writes one Content-Length-
-- framed body) and no HTTP Range support for partial content, so this reads
-- whole files into memory rather than streaming byte ranges the way
-- media_streaming.py's StreamingResponse does. Acceptable for this
-- deployment's traffic/file sizes today; flagged as a real scaling gap for
-- large video files once uploads are re-populated.
-- ---------------------------------------------------------------------------

local function adult_file_allowed(req, media_id, access, viewer_id)
  if access and access ~= "" and access == gauth.media_access_token(M.settings.session_secret, media_id) then
    return true
  end
  return viewer_adult_allowed(viewer_id)
end

-- Resolves what to actually serve for a media item: DB blob (preferred) or
-- legacy on-disk file. Returns (content_bytes, mime_type) or (nil, nil) if
-- genuinely missing -- callers must 404 cleanly on the latter, not crash
-- (this is the common case for the current, April-29-restored dataset: see
-- media_files.lua's docstring -- media_files is empty for all 540 rows).
local function resolve_media_bytes(item)
  local file_info = media_files.get_media_file_info(item.id)
  if file_info then
    local full = media_files.get_media_file(item.id)
    if full and full.content and #full.content > 0 then
      return full.content, full.mime_type or item.mime_type, full.original_filename or item.original_filename
    end
  end
  local legacy = media_files.legacy_upload_path(M.settings.uploads_dir, item.storage_path)
  if legacy then
    local f = io.open(legacy, "rb")
    if f then
      local content = f:read("*a")
      f:close()
      return content, item.mime_type, item.original_filename
    end
  end
  return nil, nil, nil
end

function M.serve_media_thumb(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_by_id(media_id, viewer_id or "0")
  if not item then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  local width = math.max(160, math.min(tonumber(req.query.w) or 520, 1440))
  local shard = string.format("%02x", media_id % 256)
  local media_kind = tostring(item.media_kind or ""):lower()

  -- Cache lookup: images cache flat (matches the ~364 pre-existing cache
  -- files under uploads/_thumb_cache/ from before the restore), videos cache
  -- sharded -- see _video_thumb_cache_file's identical convention in Python.
  local flat_path = M.settings.uploads_dir .. "/_thumb_cache/" .. media_id .. "_" .. width .. ".webp"
  local shard_path = M.settings.uploads_dir .. "/_thumb_cache/" .. shard .. "/" .. media_id .. "_" .. width .. ".webp"
  local cache_path = media_kind == "video" and shard_path or flat_path
  local cf = io.open(cache_path, "rb")
  if cf then
    local bytes = cf:read("*a")
    cf:close()
    return 200, bytes, { ["Content-Type"] = "image/webp", ["Cache-Control"] = "public, max-age=604800, immutable" }
  end

  local content = resolve_media_bytes(item)
  if content then
    local rendered = media_files.render_webp_from_bytes(content, width, 84, media_kind == "video" and 0.35 or nil)
    if rendered then
      os.execute("mkdir -p " .. (media_kind == "video" and (M.settings.uploads_dir .. "/_thumb_cache/" .. shard) or (M.settings.uploads_dir .. "/_thumb_cache")))
      local out = io.open(cache_path, "wb")
      if out then out:write(rendered); out:close() end
      return 200, rendered, { ["Content-Type"] = "image/webp", ["Cache-Control"] = "public, max-age=604800, immutable" }
    end
  end

  if media_kind == "video" then
    local svg = media_files.video_placeholder_svg(width)
    return 200, svg, { ["Content-Type"] = "image/svg+xml", ["Cache-Control"] = "public, max-age=604800, immutable" }
  end
  return 404, { detail = "File missing from database." }
end

-- Adds real HTTP Range/206 support. Previously flagged as a KNOWN
-- LIMITATION (see this section's header comment above): httpd.lua always
-- wrote one Content-Length-framed body with no partial-content path, so
-- video <video> elements couldn't seek properly in the browser (seeking
-- a <video> depends on the server answering a Range request, not just on
-- the client re-requesting the whole file) and every scrub re-downloaded
-- the entire file. The full byte content is already in memory by the time
-- this runs (resolve_media_bytes() reads the whole DB blob), so this is
-- just header parsing + a string slice + a 206 status -- no actual
-- streaming/chunking machinery needed.
local function respond_with_range(req, content, mime_type, extra_headers)
  local total = #content
  local headers = { ["Content-Type"] = mime_type or "application/octet-stream", ["Accept-Ranges"] = "bytes" }
  for k, v in pairs(extra_headers or {}) do headers[k] = v end

  local range = req.headers and req.headers["range"]
  if not range then return 200, content, headers end

  local start_s, end_s = tostring(range):match("^bytes=(%d*)-(%d*)$")
  if not start_s or (start_s == "" and end_s == "") then
    -- Malformed/unsupported Range (e.g. multi-range) -- ignore and serve
    -- the full body rather than 416ing on something we just don't parse.
    return 200, content, headers
  end
  local start_byte, end_byte
  if start_s == "" then
    -- "bytes=-500" -- last 500 bytes.
    local suffix_len = tonumber(end_s) or 0
    start_byte = math.max(0, total - suffix_len)
    end_byte = total - 1
  else
    start_byte = tonumber(start_s) or 0
    end_byte = (end_s ~= "" and tonumber(end_s)) or (total - 1)
  end
  end_byte = math.min(end_byte, total - 1)
  if start_byte > end_byte or start_byte >= total then
    headers["Content-Range"] = "bytes */" .. total
    return 416, "", headers
  end

  headers["Content-Range"] = string.format("bytes %d-%d/%d", start_byte, end_byte, total)
  return 206, content:sub(start_byte + 1, end_byte + 1), headers
end

local function serve_media_bytes_response(req, media_id, as_download)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_by_id(media_id, viewer_id or "0")
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not owner then return 403, { detail = "This post is private." } end
  if as_download and not db.tobool(item.downloads_enabled) and not owner then
    return 403, { detail = "Downloads are disabled for this post." }
  end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end

  local content, mime_type, original_filename = resolve_media_bytes(item)
  if not content then
    return 404, { detail = "File is missing. Re-upload this post once so it can be saved into the new DB-backed file store." }
  end
  if as_download then
    db.execute("UPDATE media_items SET downloads=downloads+1 WHERE id=%s", tostring(media_id))
  end
  if as_download then
    -- Downloads always send the whole file -- Range/206 is a streaming-
    -- playback concern (<video> seeking), not a "save as" one.
    local headers = {
      ["Content-Type"] = mime_type or "application/octet-stream",
      ["Content-Disposition"] = "attachment; filename=\"" .. (original_filename or "download"):gsub('"', "") .. "\"",
      ["Cache-Control"] = "private, max-age=0, no-cache",
    }
    return 200, content, headers
  end
  return respond_with_range(req, content, mime_type, { ["Cache-Control"] = "public, max-age=86400" })
end

function M.serve_media_file(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  return serve_media_bytes_response(req, media_id, false)
end

function M.download_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  return serve_media_bytes_response(req, media_id, true)
end

function M.serve_media_preview(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_by_id(media_id, viewer_id or "0")
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not owner then return 403, { detail = "This post is private." } end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return 403, { detail = "Age verification required for this 18+ post." }
  end
  if tostring(item.media_kind or "") ~= "image" then
    return serve_media_bytes_response(req, media_id, false)
  end
  local content = resolve_media_bytes(item)
  if not content then
    return 404, { detail = "Preview is missing. Re-upload this post once so it can be saved into the new DB-backed file store." }
  end
  local size = tostring(req.query.size or "card")
  local max_edge = ({ mini = 360, detail = 1920 })[size] or 880
  local quality = ({ mini = 78, detail = 92 })[size] or 86
  local rendered = media_files.render_webp_from_bytes(content, max_edge, quality)
  if rendered then
    return 200, rendered, { ["Content-Type"] = "image/webp", ["Cache-Control"] = "public, max-age=86400" }
  end
  return 200, content, { ["Content-Type"] = item.mime_type or "application/octet-stream", ["Cache-Control"] = "public, max-age=86400" }
end

function M.serve_user_avatar(req)
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local file_row = media_files.get_avatar_file(user_id)
  if file_row and file_row.content and #file_row.content > 0 then
    return 200, file_row.content, { ["Content-Type"] = file_row.mime_type or "image/jpeg", ["Cache-Control"] = "public, max-age=86400" }
  end
  local user = get_user(tostring(user_id))
  local legacy = user and media_files.legacy_upload_path(M.settings.uploads_dir, nn(user.avatar_path))
  if legacy then
    local f = io.open(legacy, "rb")
    if f then
      local content = f:read("*a")
      f:close()
      return 200, content, { ["Content-Type"] = (user.avatar_mime_type) or "image/jpeg", ["Cache-Control"] = "public, max-age=86400" }
    end
  end
  local svg = string.format(
    "<svg xmlns='http://www.w3.org/2000/svg' width='128' height='128' viewBox='0 0 128 128'>"
      .. "<rect width='128' height='128' rx='64' fill='#202832'/>"
      .. "<text x='64' y='74' text-anchor='middle' font-family='Inter,Arial,sans-serif' font-size='34' font-weight='800' fill='#9ba8b7'>U%d</text></svg>",
    user_id
  )
  return 200, svg, { ["Content-Type"] = "image/svg+xml", ["Cache-Control"] = "public, max-age=3600" }
end

return M
