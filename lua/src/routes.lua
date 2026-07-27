-- Route handlers. Registered against httpd.lua's M.route(method, pattern, handler)
-- in main.lua. Each handler receives httpd.lua's `req` table and returns
-- (status, body_table_or_string, extra_headers).
--
-- Scope note: this is a first pass covering health/auth/categories/core
-- media browsing only -- see the final report's itemized todo list for
-- everything not yet ported (uploads, comments/likes/social, collections,
-- messaging, moderation/admin, AI vision, Telegram/Discord integrations).

local cjson = require("cjson.safe")
local db = require("db")
local gauth = require("gallery_auth")
local ratelimit = require("ratelimit")
local totp = require("totp")
local media_files = require("media_files")
local user_settings = require("user_settings")
local gallery_looks = require("gallery_looks")
local colorutil = require("colorutil")

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
  return db.fetchone([[
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
