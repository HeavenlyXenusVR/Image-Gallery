-- Route handlers. Registered against httpd.lua's M.route(method, pattern, handler)
-- in main.lua. Each handler receives httpd.lua's `req` table and returns
-- (status, body_table_or_string, extra_headers).
--
-- Scope note (last updated 2026-08-10): this comment badly lagged reality
-- for a long time -- AI classification, Telegram, possible-duplicate
-- detection, saved-search notifications, and the admin storage/orphan-purge
-- endpoints were all already implemented below despite previously being
-- listed here as "NOT ported." Current real gaps, confirmed by actually
-- grepping for them rather than trusting this comment:
--   * Email verification/change (POST /api/me/email, /api/me/email/verify)
--     -- called by SettingsPage.jsx but never built, not even in the
--     original Python backend. Needs an email-sending decision (SMTP
--     provider) before it can be built; deliberately not guessed at.
--     Discord-based account verification (routes below, "Discord account
--     verification" section) covers the same "prove you own this account"
--     need without that dependency.
--   * Background AI learning (the periodic pass that turned curated
--     gallery metadata into new training examples) and the Ollama/
--     OpenAI-compatible vision provider backends (only Gemini is wired) --
--     both background-only, no user-facing surface; see TODO.md.

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
local discord_bot = require("discord_bot")
local auth_lib = require("auth")
local ai_metadata = require("ai_metadata")

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
  discord_user_id, discord_username, discord_verified_at,
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
  -- arr(), not a bare `{}` fallback: cjson.encode(empty_lua_table) always
  -- serializes as a JSON object ({}), never an array ([]) -- confirmed
  -- directly (luajit -e "print(cjson.encode({}))" prints "{}"), since Lua
  -- has no distinct empty-array type for it to infer from. Any user with no
  -- featured tags (the common case) was sending featured_tags as a JSON
  -- OBJECT instead of an array, which is a strict decode failure for any
  -- client expecting an array (iOS's GalleryUser.featuredTags: [String]?
  -- throws on `{}` instead of decoding an empty list) -- and since
  -- GalleryUser is embedded in most social endpoints (profiles, followers/
  -- following, friends, blocks, search, group members), one such user
  -- anywhere in a list response corrupted the whole response's decode.
  if row.featured_tags and row.featured_tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, row.featured_tags)
    row.featured_tags = (ok and type(decoded) == "table") and arr(decoded) or arr({})
  else
    row.featured_tags = arr({})
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

-- Must exactly match the real account's stored `email` column (case-
-- insensitively, see is_site_owner() below) AND that account needs
-- email_verified_at set, or the site-owner gate silently denies everyone,
-- including the real owner -- confirmed happening in production
-- (2026-08-02): this constant didn't match the live account's actual
-- stored email, and email_verified_at was NULL, so /admin and every
-- existing admin_* API endpoint had never actually been reachable.
local SITE_OWNER_EMAIL = "uxzheavenlyyei@icloud.com"

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

-- is_online (see the profile/list queries further down: "now() -
-- last_seen_at <= interval '180 seconds'") was previously only ever true
-- for the ~3 minutes right after logging IN -- last_seen_at had exactly
-- one writer in the whole codebase, the login route itself, so an account
-- actively browsing for hours showed as offline the entire time. Called
-- from both current_user() (every mutating/write request) and
-- auth_optional() (every read-context request -- feed, media, profile,
-- ~20 call sites), so any authenticated activity keeps the account
-- looking online, not just logging in. Same staleness-throttle pattern as
-- api_keys.last_used_at above: at most one write per account per minute,
-- not one per request.
local function touch_last_seen(user_id)
  if not user_id then return end
  db.execute(
    "UPDATE users SET last_seen_at=now() WHERE id=%s AND (last_seen_at IS NULL OR last_seen_at < now() - interval '60 seconds')",
    tostring(user_id)
  )
end

-- Depends()-equivalent: returns (user, auth_payload) or (nil, nil, status, body)
-- on failure. auth_payload is the decoded token {id, username, display_name}.
local function current_user(req)
  local auth = gauth.require_auth(req.headers, parse_cookies(req), M.settings.session_secret, M.settings.api_token_ttl_seconds)
  if not auth and req.method == "GET" then
    -- Scoped read-only API keys (see M.resolve_api_key/auth_optional
    -- further down this file) may satisfy any READ request that would
    -- otherwise need a real login -- Studio, Settings, Messages, Friends,
    -- Admin dashboards, etc. -- so the account owner (or a tool acting on
    -- their explicit behalf) can view their own logged-in UI for layout/
    -- rendering checks without a real session. Gated strictly on GET: a
    -- POST/PUT/PATCH/DELETE mutation never reaches this fallback, so a
    -- key can make pages RENDER as logged in but can never actually
    -- save/delete/upload/admin-act as the user.
    local key = req.query and nn(req.query.key)
    if key then
      local user_id = M.resolve_api_key(key)
      if user_id then auth = { id = user_id } end
    end
  end
  if not auth then return nil, nil, 401, { detail = "Login required" } end
  local user = get_user(auth.id)
  if is_actively_banned(user) then
    return nil, nil, 403, { detail = (user and nn(user.ban_reason)) or "Your account has been suspended." }
  end
  touch_last_seen(auth.id)
  return user, auth, nil, nil
end

-- Exported for pages_totp.lua's server-rendered 2FA settings page -- same
-- cookie-or-bearer login check as current_user(), just reshaped to
-- (user, status, body) since callers here don't need the raw auth payload.
function M.require_login_for_page(req)
  local user, auth, status, body = current_user(req)
  return user, status, body
end

-- Falls back to a `?key=gk_...` scoped API key (see M.resolve_api_key
-- further down this file) when there's no session cookie/bearer token.
-- Deliberately only wired in here, not into current_user()/require_auth():
-- every one of auth_optional's ~20 call sites is a GET/read-context route
-- (listing, detail, media-serving, profile/follow lists) that uses the
-- resolved viewer id purely to decide what's visible to them -- nothing
-- that calls auth_optional ever performs a mutation, so a key can only
-- ever see what its owning account could already see, never act as it.
-- Mutating routes all authenticate via current_user()/gauth.require_auth
-- directly and remain cookie/bearer-only.
local function auth_optional(req)
  local auth = gauth.require_auth(req.headers, parse_cookies(req), M.settings.session_secret, M.settings.api_token_ttl_seconds)
  if auth then
    touch_last_seen(auth.id)
    return auth
  end
  local key = req.query and nn(req.query.key)
  if not key then return nil end
  local user_id = M.resolve_api_key(key)
  if not user_id then return nil end
  touch_last_seen(user_id)
  return { id = user_id }
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

  -- LOWER() on both sides here too: an exact-match check would let someone
  -- register "heavenlyxenusvr" today even though "HeavenlyXenusVR" already
  -- exists (see login's fix above for why case can differ on old
  -- accounts), creating a second, genuinely different account that a
  -- case-insensitive login could then no longer tell apart from the
  -- original. Blocking the collision at registration time is the other
  -- half of actually fixing this for good.
  local existing = db.fetchone("SELECT id FROM users WHERE LOWER(username)=%s OR (LOWER(email)=%s AND email IS NOT NULL)", username, email)
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
  }, { ["Set-Cookie"] = gauth.session_cookie(token, M.settings.api_token_ttl_seconds) }
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

  -- LOWER(username)=%s, not username=%s: normalize_username() lowercases
  -- the input, but usernames created before the Lua rewrite (or imported
  -- from the old MySQL DB) can have mixed-case stored values -- e.g. the
  -- site owner's own "HeavenlyXenusVR". An exact-match comparison against
  -- a lowercased input silently locked every such account out of login
  -- entirely (confirmed live 2026-08-02: real failed attempts against a
  -- correct password, not rate-limited, not banned -- just never matching
  -- the row). Case-insensitive comparison fixes both the legacy accounts
  -- and is simply more forgiving for everyone going forward.
  local username = normalize_username(username_raw)
  local row = db.fetchone("SELECT id, password_hash FROM users WHERE LOWER(username)=%s", username)
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
  return 200, { user = user, token = token }, { ["Set-Cookie"] = gauth.session_cookie(token, M.settings.api_token_ttl_seconds) }
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
  return 200, { user = user, token = token }, { ["Set-Cookie"] = gauth.session_cookie(token, M.settings.api_token_ttl_seconds) }
end

function M.logout(req)
  return 200, { ok = true }, { ["Set-Cookie"] = gauth.session_cookie("", 0) }
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

-- Booru-style boolean tag query: "cat dog" = has both (AND), "cat OR dog" =
-- has either, "-cat" = must NOT have. Space-separated; an OR chain binds
-- tighter than the implicit AND between groups, e.g. "cat OR dog -wet"
-- means (cat OR dog) AND NOT wet. Deliberately not a full boolean-algebra
-- parser (no parens/nesting) -- this covers the actual booru convention
-- (Danbooru/e621/Derpibooru all use exactly this flat OR-groups-ANDed-
-- together-plus-NOT shape) without building a general expression parser
-- for a feature that's a search-bar convenience, not a query language.
-- Returns (and_groups, not_tags) where and_groups is an array of arrays
-- (each inner array is an OR-group of tag strings) and not_tags is a flat
-- array of excluded tag strings.
local function parse_tag_query(input)
  local tokens = {}
  for word in tostring(input or ""):gmatch("%S+") do
    if #tokens < 40 then tokens[#tokens + 1] = word end
  end
  local and_groups, not_tags = {}, {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    if tok:sub(1, 1) == "-" and #tok > 1 then
      not_tags[#not_tags + 1] = tok:sub(2):lower():sub(1, 60)
      i = i + 1
    else
      local or_group = { tok:lower():sub(1, 60) }
      i = i + 1
      while tokens[i] and tokens[i]:upper() == "OR" and tokens[i + 1] do
        or_group[#or_group + 1] = tokens[i + 1]:lower():sub(1, 60)
        i = i + 2
      end
      and_groups[#and_groups + 1] = or_group
    end
  end
  return and_groups, not_tags
end

-- Builds a Postgres text[] array literal placeholder ("ARRAY[%s,%s,...]")
-- for jsonb's `?|`/`?&` "any/all of these keys exist" operators, appending
-- one %s + one param per tag. clauses/params are mutated in place (same
-- calling convention as list_media's own clause-building loop below).
local function append_tag_array_clause(clauses, params, tags, column, negate, mode)
  local placeholders = {}
  for _, tag in ipairs(tags) do
    placeholders[#placeholders + 1] = "%s"
    params[#params + 1] = tag
  end
  local array_sql = "ARRAY[" .. table.concat(placeholders, ",") .. "]"
  local op = mode == "all" and "?&" or "?|"
  local test = string.format("(%s::jsonb %s %s)", column, op, array_sql)
  clauses[#clauses + 1] = negate and ("NOT " .. test) or test
end

local VALID_SORTS = { new = true, old = true, popular = true, views = true, downloads = true, trending = true }

-- Moved here (before M.list_media/M.upload_media) rather than kept next to
-- the rest of the collections-section helpers further down, since both
-- collections AND saved-searches (further below) AND M.upload_media's
-- saved-search-match notification hook need this -- Lua locals are only
-- visible to code appearing after their declaration in the same scope.
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
    -- Always attach the capability token, not just for adult posts: plain
    -- <img>/<video src> tags don't send credentials cross-origin (no
    -- `crossorigin` attribute is set anywhere in the frontend, and adding
    -- one would require the media routes to send CORS headers too), so a
    -- private post's byte-serving routes never saw the owner's session
    -- cookie and 403'd even for the post's own owner viewing their own
    -- gallery. This JSON row was only handed to `row` after auth_optional's
    -- cookie check already passed (see M.list_media/M.media_detail's
    -- callers), so re-granting the same access via a URL-embedded token is
    -- not a privilege escalation -- it's carrying forward a decision
    -- already made, exactly like the pre-existing adult-content token did.
    do
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
  -- arr(), not a bare `{}` fallback -- see decode_user's featured_tags
  -- comment for why: an untagged post (extremely common) would otherwise
  -- send tags as a JSON object ({}) instead of an array ([]), which is a
  -- hard decode failure for any client expecting an array there -- and
  -- since this is the per-item decoder every feed/list endpoint calls, one
  -- untagged post anywhere in a page of results corrupted that entire
  -- response's decode for API clients with a strict [String] tags field.
  if row.tags and row.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, row.tags)
    row.tags = (ok and type(decoded) == "table") and arr(decoded) or arr({})
  else
    row.tags = arr({})
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
  local tag_query = nn(q.tags)
  local color_hex = nn(q.color) and tostring(q.color):gsub("^#", ""):match("^(%x%x%x%x%x%x)$") or nil
  local color_tolerance = math.max(4, math.min(tonumber(q.color_tolerance) or 40, 128))
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

  -- Hide posts from anyone the viewer has blocked or muted -- genuinely new
  -- enforcement (see should_suppress_notification's comment further down:
  -- "mute" was storable via the block/mute endpoint and shown in Settings,
  -- but nothing ever actually filtered on it, including block itself never
  -- being applied to feed visibility, only to DMs/follows/mentions).
  if viewer_id then
    clauses[#clauses + 1] = "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)"
    params[#params + 1] = viewer0
  end

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
    -- media_items.text_search is a generated tsvector(title || ' ' ||
    -- description) column with its own GIN index
    -- (idx_media_items_text_search) that already existed on this table but
    -- was never actually queried anywhere -- title/description search ran
    -- as a plain ILIKE seq-scan-shaped pattern match instead. plainto_tsquery
    -- gets real word-boundary/stemmed matching (searching "cat" now also
    -- matches "cats"/"catlike", which a substring ILIKE never would) AND
    -- lets the GIN index actually get used. tags stays on ILIKE -- it's a
    -- JSON-encoded array column, not part of text_search, and a plain
    -- substring match across the raw JSON text is still the simplest way
    -- to catch a query that's itself a tag/tag fragment.
    clauses[#clauses + 1] = "(m.text_search @@ plainto_tsquery('english', %s) OR m.tags ILIKE %s)"
    params[#params + 1] = query_text
    params[#params + 1] = "%" .. query_text:gsub("([%%_])", "\\%1") .. "%"
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
  if tag_query then
    local and_groups, not_tags = parse_tag_query(tag_query)
    for _, or_group in ipairs(and_groups) do
      append_tag_array_clause(clauses, params, or_group, "m.tags", false, "any")
    end
    if #not_tags > 0 then
      append_tag_array_clause(clauses, params, not_tags, "m.tags", true, "any")
    end
  end
  if color_hex then
    -- Per-channel absolute-difference box filter (not true Euclidean
    -- distance -- avoids needing sqrt/power in SQL for what's already an
    -- approximate 8x8-average "dominant color", so extra precision here
    -- wouldn't mean much). dominant_color is stored as "#rrggbb"; extract
    -- each byte via decode(...,'hex') + get_byte rather than three
    -- separate substring/to_number calls.
    local target_r = tonumber(color_hex:sub(1, 2), 16)
    local target_g = tonumber(color_hex:sub(3, 4), 16)
    local target_b = tonumber(color_hex:sub(5, 6), 16)
    clauses[#clauses + 1] = [[
      m.dominant_color IS NOT NULL
      AND ABS(get_byte(decode(substring(m.dominant_color from 2), 'hex'), 0) - %s) <= %s
      AND ABS(get_byte(decode(substring(m.dominant_color from 2), 'hex'), 1) - %s) <= %s
      AND ABS(get_byte(decode(substring(m.dominant_color from 2), 'hex'), 2) - %s) <= %s
    ]]
    params[#params + 1] = tostring(target_r); params[#params + 1] = tostring(color_tolerance)
    params[#params + 1] = tostring(target_g); params[#params + 1] = tostring(color_tolerance)
    params[#params + 1] = tostring(target_b); params[#params + 1] = tostring(color_tolerance)
  end

  local where = "WHERE " .. table.concat(clauses, " AND ")
  local order = ({
    popular = "m.pinned_at DESC NULLS LAST, like_count DESC, m.views DESC, m.created_at DESC",
    downloads = "m.pinned_at DESC NULLS LAST, m.downloads DESC, m.created_at DESC",
    views = "m.pinned_at DESC NULLS LAST, m.views DESC, m.created_at DESC",
    old = "m.created_at ASC",
    -- Age-decayed "hot" score (views + 3x weight per like, divided by age in
    -- hours to a power) -- same idea as Reddit/HN ranking. Deliberately
    -- built from columns list_media already selects (m.views, like_count,
    -- m.created_at) rather than a media_views time-window join: that table
    -- is a per-viewer dedup set (one row per unique viewer ever, see its
    -- schema/TODO.md), not a view-event log, so a true "views in the last N
    -- days" score isn't available without a schema change. The age decay
    -- gets the same practical effect (recent posts with traction rank
    -- above old posts with high raw totals) using only existing columns.
    -- Note: can't reference the `like_count` SELECT-list alias here --
    -- Postgres only resolves output aliases when they're the *entire*
    -- ORDER BY item, not when nested inside a larger expression (confirmed
    -- live: "column \"like_count\" does not exist") -- so this repeats the
    -- underlying COUNT(DISTINCT l.user_id) aggregate instead.
    trending = "m.pinned_at DESC NULLS LAST, (m.views + COUNT(DISTINCT l.user_id) * 3) / POWER(EXTRACT(EPOCH FROM (now() - m.created_at)) / 3600 + 2, 1.5) DESC, m.created_at DESC",
    -- ts_rank against the same text_search column the WHERE clause above
    -- now actually searches -- m.text_search is safe to reference here
    -- despite the GROUP BY not listing it: m.id (media_items' primary
    -- key) IS in GROUP BY, and Postgres treats every other column of the
    -- same table as functionally dependent on it, so no aggregate/GROUP BY
    -- is needed for other bare m.* references.
    relevance = "ts_rank(m.text_search, plainto_tsquery('english', %s)) DESC, m.pinned_at DESC NULLS LAST, m.created_at DESC",
  })[sort] or "m.pinned_at DESC NULLS LAST, m.created_at DESC"
  -- A text search with the caller's default sort ("new"/unset) reads
  -- results ranked by relevance, not upload date -- matches what "true
  -- indexing" is actually for. An explicit sort=... still always wins.
  local effective_sort = sort
  if query_text ~= "" and (not sort or sort == "" or sort == "new") then
    effective_sort = "relevance"
    order = "ts_rank(m.text_search, plainto_tsquery('english', %s)) DESC, m.pinned_at DESC NULLS LAST, m.created_at DESC"
  end

  -- Build the full parameter list in call order: 4 leading viewer refs used
  -- by the SELECT list's CASE expressions + the 2 JOIN viewer refs, then the
  -- WHERE clause's own params (already collected above), then LIMIT/OFFSET.
  local sql_params = { viewer0, viewer0, viewer0, viewer0, viewer0, viewer0 }
  for _, p in ipairs(params) do sql_params[#sql_params + 1] = p end
  -- order's own %s (the relevance branch's ts_rank(...) call) sits
  -- textually between the WHERE clause and LIMIT/OFFSET in the final SQL
  -- -- its parameter has to land in that same position in sql_params, not
  -- appended after limit/offset.
  if effective_sort == "relevance" then sql_params[#sql_params + 1] = query_text end
  sql_params[#sql_params + 1] = tostring(limit)
  sql_params[#sql_params + 1] = tostring(offset)

  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color,
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
  return 200, { media = arr(rows), limit = limit, offset = offset, sort = effective_sort }
end

-- Shared by the three feed-shaped endpoints below (feed_following,
-- feed_liked, media_trending) -- deliberately NOT wired into list_media()
-- above (which stays exactly as already verified/live) to avoid risking a
-- regression there; this repeats list_media's SELECT/JOIN/GROUP BY shape
-- once, for these three new callers, rather than three more full copies.
-- `extra_clause`/`extra_params` is one optional additional %s-style WHERE
-- fragment (already includes its own params); `order_sql` is a trusted
-- internal literal (never user input), same convention as list_media's own
-- `order` table.
local function fetch_media_feed(req, viewer_id, extra_clause, extra_params, order_sql, limit, offset)
  local viewer_can_open_adult = false
  if viewer_id then
    local viewer = get_user(viewer_id)
    viewer_can_open_adult = viewer ~= nil and nn(viewer.age_verified_at) ~= nil and viewer.adult_content_consent
  end
  local viewer0 = viewer_id or "0"

  local clauses = {
    "m.deleted_at IS NULL",
    "(m.visibility='public' OR m.user_id=%s)",
    "(m.publish_at IS NULL OR m.publish_at <= now() OR m.user_id=%s)",
  }
  local params = { viewer0, viewer0 }
  -- Same block/mute feed-hiding as list_media (see its own comment) --
  -- applies here too since this backs the following/liked/trending feeds.
  if viewer_id then
    clauses[#clauses + 1] = "m.user_id NOT IN (SELECT blocked_id FROM user_blocks WHERE blocker_id=%s)"
    params[#params + 1] = viewer0
  end
  if extra_clause then
    clauses[#clauses + 1] = extra_clause
    for _, p in ipairs(extra_params or {}) do params[#params + 1] = p end
  end
  local where = "WHERE " .. table.concat(clauses, " AND ")

  local sql_params = { viewer0, viewer0, viewer0, viewer0, viewer0, viewer0 }
  for _, p in ipairs(params) do sql_params[#sql_params + 1] = p end
  sql_params[#sql_params + 1] = tostring(limit)
  sql_params[#sql_params + 1] = tostring(offset)

  local sql = string.format([[
    SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
           m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
           m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
           m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color,
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
  ]], where, order_sql)

  local rows, err = db.fetchall(sql, unpack(sql_params))
  if err then return nil, err end
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return rows
end

-- GET /api/feed/following -- confirmed live-404ing: FeedPage.jsx (routed at
-- /following) has always called this endpoint, but it was never registered
-- in main.lua. Same "shipped in React, never ported to Lua" gap this
-- project has repeatedly found (login/register, /admin, social routes,
-- site background all had the same shape).
function M.feed_following(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local q = req.query or {}
  local limit = bounded_limit(q.limit, 60)
  local offset = bounded_offset(q.offset)
  local rows, err = fetch_media_feed(
    req, viewer0,
    "m.user_id IN (SELECT followed_id FROM user_follows WHERE follower_id=%s)", { viewer0 },
    "m.pinned_at DESC NULLS LAST, m.created_at DESC", limit, offset
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), limit = limit, offset = offset }
end

-- GET /api/me/likes -- same dead-endpoint shape as feed_following above:
-- FeedPage.jsx's mode="liked" variant (routed at /liked) has always called
-- this, also never registered.
function M.feed_liked(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)
  local q = req.query or {}
  local limit = bounded_limit(q.limit, 60)
  local offset = bounded_offset(q.offset)
  local rows, err = fetch_media_feed(
    req, viewer0,
    "EXISTS (SELECT 1 FROM media_likes ml WHERE ml.media_id=m.id AND ml.user_id=%s)", { viewer0 },
    "m.pinned_at DESC NULLS LAST, m.created_at DESC", limit, offset
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), limit = limit, offset = offset }
end

local TRENDING_WINDOWS = { ["1"] = true, ["7"] = true, ["30"] = true }

-- GET /api/media/trending?days=N&limit=N -- same dead-endpoint shape again:
-- TrendingPage.jsx (routed at /trending) has always called this with a
-- day-window param; never registered. Distinct from list_media's own
-- `sort=trending` (added earlier this pass) -- that one is an all-time,
-- age-decayed ranking with no window; the frontend never actually calls it
-- and always expected this dedicated windowed endpoint instead, per its own
-- lede text ("ranked by views, likes, and comments within the selected
-- window") -- no age-decay needed here since the window itself bounds
-- recency.
function M.media_trending(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local q = req.query or {}
  local days = TRENDING_WINDOWS[tostring(q.days or "7")] and tostring(q.days) or "7"
  local limit = bounded_limit(q.limit, 30)
  local rows, err = fetch_media_feed(
    req, viewer_id,
    "m.created_at > now() - (%s || ' days')::interval", { days },
    "(m.views + COUNT(DISTINCT l.user_id) * 3 + COUNT(DISTINCT cm.id) * 2) DESC, m.created_at DESC",
    limit, 0
  )
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, { media = arr(rows), days = tonumber(days), limit = limit }
end

-- GET /api/leaderboard?window=7d|30d|all -- public creator ranking. Net-new
-- (no dead frontend route recovered here, unlike feed_following/feed_liked/
-- media_trending above). Ranks by the same visibility guard as list_media,
-- respecting public_profile for display name/avatar the same way
-- fetch_media_feed's SELECT list does.
local LEADERBOARD_WINDOW_DAYS = { ["7d"] = "7", ["30d"] = "30" }

function M.leaderboard(req)
  local q = req.query or {}
  local window = (q.window == "7d" or q.window == "30d" or q.window == "all") and q.window or "30d"
  local days = LEADERBOARD_WINDOW_DAYS[window]
  -- Applied identically to the main aggregate AND both like-count subqueries
  -- below, so "7-day leaderboard" consistently means "views/likes/posts from
  -- posts created in the last 7 days" rather than mixing an all-time like
  -- count into a windowed view count.
  local main_window_clause = days and "AND m.created_at > now() - (%s || ' days')::interval" or ""
  local sub_window_clause = days and "AND lm.created_at > now() - (%s || ' days')::interval" or ""

  local sql = string.format([[
    SELECT u.id, u.username,
           CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name,
           CASE WHEN u.public_profile THEN u.avatar_path ELSE NULL END AS user_avatar_path,
           u.profile_color, u.public_profile,
           COALESCE(SUM(m.views), 0) AS total_views,
           COUNT(DISTINCT m.id) AS post_count,
           (SELECT COUNT(*) FROM media_likes l
            JOIN media_items lm ON lm.id = l.media_id AND lm.deleted_at IS NULL
            WHERE lm.user_id = u.id %s) AS total_likes
    FROM media_items m
    JOIN users u ON u.id = m.user_id
    WHERE m.deleted_at IS NULL AND m.visibility='public'
      AND (m.publish_at IS NULL OR m.publish_at <= now())
      %s
    GROUP BY u.id
    ORDER BY (COALESCE(SUM(m.views), 0) + (
      SELECT COUNT(*) FROM media_likes l
      JOIN media_items lm ON lm.id = l.media_id AND lm.deleted_at IS NULL
      WHERE lm.user_id = u.id %s
    ) * 3) DESC
    LIMIT 25
  ]], sub_window_clause, main_window_clause, sub_window_clause)

  local params = {}
  if days then params = { days, days, days } end
  local rows, err = db.fetchall(sql, unpack(params))
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end

  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.total_views = db.toint(row.total_views, 0)
    row.post_count = db.toint(row.post_count, 0)
    row.total_likes = db.toint(row.total_likes, 0)
    row.public_profile = db.tobool(row.public_profile)
    if row.user_avatar_path and row.user_avatar_path ~= cjson.null then
      row.user_avatar_url = origin .. "/api/users/" .. row.id .. "/avatar"
    end
    row.user_avatar_path = nil
  end
  return 200, { window = window, creators = arr(rows) }
end

-- GET /api/me/media -- the Studio tab's data source. Mirrors
-- app/routers/account.py's my_media() + app/db/media.py's list_user_media()
-- (recovered from git history: 9986ab5^:app/routers/account.py +
-- app/db/media.py) -- never ported to Lua at all, confirmed live (the
-- Studio tab showed "Not found"/0 posts for an account with 15 real
-- uploads). Unlike list_media() above, this has no visibility filter at
-- all: it's the owner looking at their OWN media, so private/unlisted/
-- deleted posts are all included by design (Studio's own client-side
-- filter chips split them back out) -- only "which media_kind/adult
-- content is the viewer allowed to see" logic (decode_media_row) still
-- applies, same as everywhere else media rows get shaped.
function M.my_media(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local include_deleted = req.query.include_deleted ~= "false" and req.query.include_deleted ~= "0"
  local viewer_can_open_adult = nn(user.age_verified_at) ~= nil and user.adult_content_consent
  local viewer0 = tostring(user.id)

  local where = include_deleted and "m.user_id=%s" or "m.user_id=%s AND m.deleted_at IS NULL"
  local sql = string.format(
    [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
             m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
             m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
             m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
             m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color, m.deleted_at,
             c.name AS category_name, c.slug AS category_slug,
             sc.name AS subcategory_name, sc.slug AS subcategory_slug,
             u.username, u.display_name, u.profile_color, u.public_profile,
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
      WHERE %s
      GROUP BY m.id, c.name, c.slug, sc.name, sc.slug, u.username, u.display_name, u.profile_color, u.public_profile
      ORDER BY m.created_at DESC
      LIMIT 200
    ]],
    where
  )
  local rows, err = db.fetchall(sql, viewer0, viewer0, viewer0)
  if err then return 500, { detail = "Query failed: " .. tostring(err) } end
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return 200, { media = arr(rows) }
end

-- GET /api/me/stats -- Creator analytics dashboard data source. Two parts:
-- (1) top_posts: the creator's own non-deleted media ranked by views, same
-- join shape as M.my_media above (likes/comments/bookmarks) just re-ordered
-- and capped smaller since this is a "top N" table, not the full Studio list.
-- (2) daily_new_viewers: a day-bucketed count of media_views rows (the
-- per-viewer-ever dedup table backing the view-count-dedup fix) for the
-- last 30 days across all of this creator's media. This is "unique viewer
-- growth," NOT "total views" -- media_views has one row per viewer per
-- media item, ever (PRIMARY KEY (media_id, viewer_key)), so it can't count
-- repeat views; label it accordingly in the UI.
-- Extracted so the weekly Discord digest (digest.lua) can call this from a
-- background loop with no real HTTP `req` -- only needs a raw user id and an
-- origin string for building absolute thumb URLs (avoids depending on
-- with_urls()/request_origin(), which both require a real req.headers).
local function creator_stats_for(user_id, origin)
  local viewer0 = tostring(user_id)

  local top_posts, err1 = db.fetchall([[
    SELECT m.id, m.title, m.media_kind, m.mime_type, m.original_filename, m.storage_path,
           m.views, m.downloads, m.created_at, m.visibility,
           COUNT(DISTINCT l.user_id) AS like_count,
           COUNT(DISTINCT b.user_id) AS save_count,
           COUNT(DISTINCT cm.id) AS comment_count
    FROM media_items m
    LEFT JOIN media_likes l ON l.media_id = m.id
    LEFT JOIN media_bookmarks b ON b.media_id = m.id
    LEFT JOIN media_comments cm ON cm.media_id = m.id
    WHERE m.user_id = %s AND m.deleted_at IS NULL
    GROUP BY m.id
    ORDER BY m.views DESC, m.created_at DESC
    LIMIT 20
  ]], viewer0)
  if err1 then return nil, err1 end
  for _, row in ipairs(top_posts) do
    row.id = db.toint(row.id, row.id)
    row.views = db.toint(row.views, 0)
    row.downloads = db.toint(row.downloads, 0)
    row.like_count = db.toint(row.like_count, 0)
    row.save_count = db.toint(row.save_count, 0)
    row.comment_count = db.toint(row.comment_count, 0)
    if row.media_kind == "image" or row.media_kind == "video" then
      row.thumb_url = append_query(origin .. "/api/media/" .. row.id .. "/thumb", "w", "640")
    end
  end

  local daily_new_viewers, err2 = db.fetchall([[
    SELECT date_trunc('day', mv.created_at) AS day, COUNT(*) AS new_viewers
    FROM media_views mv
    JOIN media_items m ON m.id = mv.media_id
    WHERE m.user_id = %s AND mv.created_at > now() - interval '30 days'
    GROUP BY 1
    ORDER BY 1
  ]], viewer0)
  if err2 then return nil, err2 end
  for _, row in ipairs(daily_new_viewers) do
    row.new_viewers = db.toint(row.new_viewers, 0)
  end

  local totals = db.fetchone([[
    SELECT COALESCE(SUM(m.views), 0) AS total_views,
           COUNT(DISTINCT l.user_id || ':' || l.media_id) AS total_likes,
           COUNT(DISTINCT b.user_id || ':' || b.media_id) AS total_saves
    FROM media_items m
    LEFT JOIN media_likes l ON l.media_id = m.id
    LEFT JOIN media_bookmarks b ON b.media_id = m.id
    WHERE m.user_id = %s AND m.deleted_at IS NULL
  ]], viewer0)

  return {
    top_posts = arr(top_posts),
    daily_new_viewers = arr(daily_new_viewers),
    totals = {
      total_views = db.toint(totals and totals.total_views, 0),
      total_likes = db.toint(totals and totals.total_likes, 0),
      total_saves = db.toint(totals and totals.total_saves, 0),
    },
  }
end
M.creator_stats_for = creator_stats_for

function M.creator_stats(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local result, err = creator_stats_for(user.id, request_origin(req))
  if not result then return 500, { detail = "Query failed: " .. tostring(err) } end
  return 200, result
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
           m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color,
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

-- "Related media": scored by tag overlap (reusing the same jsonb `?|`
-- helper the boolean tag search uses) OR-ed with same-category, ranked by
-- overlap count with category match as a tiebreaker. Falls back to the
-- original category-only/newest behavior when the seed post has no tags,
-- so an untagged post still gets a non-empty related list. Deliberately
-- skips perceptual-hash comparison here -- find_possible_duplicates
-- already showed that's expensive even scoped to a single user's 1500
-- most recent uploads; not worth it for a "you might also like" widget
-- spanning every user's media.
--
-- Shared by M.media_detail (the on-page rail, limit=12/offset=0) and
-- M.similar_media (a real "More like this" paginated feed -- previously
-- a second, independently-written, slightly-worse copy of this exact
-- logic that nothing in either frontend ever actually called).
local function compute_similar_media(req, media_id, item, adult_allowed, limit, offset)
  local seed_tags = {}
  if item.tags and item.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, item.tags)
    if ok and type(decoded) == "table" then seed_tags = decoded end
  end

  local similar_sql, similar_params
  if #seed_tags > 0 then
    local where_tag_parts, where_tag_params = {}, {}
    append_tag_array_clause(where_tag_parts, where_tag_params, seed_tags, "m.tags", false, "any")

    local order_placeholders, order_tag_params = {}, {}
    for _, tag in ipairs(seed_tags) do
      order_placeholders[#order_placeholders + 1] = "%s"
      order_tag_params[#order_tag_params + 1] = tag
    end
    local order_tag_array_sql = "ARRAY[" .. table.concat(order_placeholders, ",") .. "]"

    similar_sql = string.format([[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
             m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views
      FROM media_items m
      WHERE m.id != %%s AND m.deleted_at IS NULL AND m.visibility='public'
        AND (m.publish_at IS NULL OR m.publish_at <= now())
        AND (m.category_id = %%s OR %s)
      ORDER BY
        (CASE WHEN m.category_id = %%s THEN 1 ELSE 0 END)
        + (SELECT count(*) FROM jsonb_array_elements_text(m.tags::jsonb) t WHERE t = ANY(%s::text[])) DESC,
        m.created_at DESC
      LIMIT %%s OFFSET %%s
    ]], where_tag_parts[1], order_tag_array_sql)

    similar_params = { tostring(media_id), tostring(item.category_id) }
    for _, p in ipairs(where_tag_params) do similar_params[#similar_params + 1] = p end
    similar_params[#similar_params + 1] = tostring(item.category_id)
    for _, p in ipairs(order_tag_params) do similar_params[#similar_params + 1] = p end
    similar_params[#similar_params + 1] = tostring(limit)
    similar_params[#similar_params + 1] = tostring(offset)
  else
    similar_sql = [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
             m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views
      FROM media_items m
      WHERE m.category_id = %s AND m.id != %s AND m.deleted_at IS NULL AND m.visibility='public'
        AND (m.publish_at IS NULL OR m.publish_at <= now())
      ORDER BY m.created_at DESC
      LIMIT %s OFFSET %s
    ]]
    similar_params = { tostring(item.category_id), tostring(media_id), tostring(limit), tostring(offset) }
  end
  local similar = db.fetchall(similar_sql, unpack(similar_params))
  for _, row in ipairs(similar) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.is_adult = db.tobool(row.is_adult)
    with_urls(req, row, adult_allowed)
  end
  attach_media_subcategories(similar)
  return similar
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

  -- Only credit a view the first time this viewer sees this post, ever --
  -- previously every single media_detail request incremented
  -- unconditionally (confirmed also true of the original Python backend,
  -- so not a rewrite regression, but a real reported bug either way:
  -- reopening a post, a pull-to-refresh, or the client silently retrying
  -- a request all inflated the count). viewer_key is "user:<id>" for a
  -- logged-in viewer or "ip:<address>" for an anonymous one (public posts
  -- don't require login to view, so there's no user id to key on); the
  -- media_views row's PRIMARY KEY does the actual dedup work via ON
  -- CONFLICT DO NOTHING -- views only ever increments when that INSERT
  -- actually adds a new row.
  local viewer_key = viewer_id and ("user:" .. viewer_id) or ("ip:" .. client_ip(req))
  local new_view = db.fetchone(
    "INSERT INTO media_views (media_id, viewer_key) VALUES (%s, %s) ON CONFLICT (media_id, viewer_key) DO NOTHING RETURNING media_id",
    tostring(media_id), viewer_key
  )
  if new_view then
    db.execute("UPDATE media_items SET views=views+1 WHERE id=%s", tostring(media_id))
  end

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

  local similar = compute_similar_media(req, media_id, item, adult_allowed, 12, 0)

  -- Personal tags (see the "Personal/private tags" section below) are
  -- private to the viewer -- only ever fetched/shown for the logged-in
  -- viewer's own tags on this post, never anyone else's, regardless of
  -- who owns the post itself.
  local personal_tags = {}
  if viewer_id then
    local rows = db.fetchall("SELECT tag FROM media_personal_tags WHERE media_id=%s AND user_id=%s ORDER BY tag", tostring(media_id), viewer_id)
    for _, row in ipairs(rows) do personal_tags[#personal_tags + 1] = row.tag end
  end

  return 200, {
    media = decode_media_row(item, adult_allowed, req),
    comments = arr(comments),
    reactions = { counts = counts, my_reaction = my_reaction },
    similar = arr(similar),
    personal_tags = arr(personal_tags),
  }
end

-- ---------------------------------------------------------------------------
-- Personal/private tags -- an idea from Romanticise (a booru-style personal
-- image database): tags visible only to the tagger, layered on top of the
-- shared public tag set, for private organization ("saw this on twitter",
-- "ref for character X") that shouldn't be public metadata on someone
-- else's (or even your own) post. Any logged-in user can personal-tag any
-- post they can already see (ensure_media_visible) -- these are private TO
-- THE TAGGER, not restricted to the post owner.
-- ---------------------------------------------------------------------------

local function clean_personal_tag(raw)
  local cleaned = trim(nn(raw) or ""):lower():gsub("%s+", " ")
  return cleaned:sub(1, 60)
end

function M.add_personal_tag(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item = fetch_media_by_id(media_id, tostring(user.id))
  local vstatus, vbody = ensure_media_visible(item, tostring(user.id))
  if vstatus then return vstatus, vbody end

  local payload = json_body(req)
  local tag = clean_personal_tag(payload.tag)
  if tag == "" then return 400, { detail = "Tag is required." } end
  db.execute(
    "INSERT INTO media_personal_tags (media_id, user_id, tag) VALUES (%s, %s, %s) ON CONFLICT (media_id, user_id, tag) DO NOTHING",
    tostring(media_id), tostring(user.id), tag
  )
  local rows = db.fetchall("SELECT tag FROM media_personal_tags WHERE media_id=%s AND user_id=%s ORDER BY tag", tostring(media_id), tostring(user.id))
  local tags = {}
  for _, row in ipairs(rows) do tags[#tags + 1] = row.tag end
  return 200, { personal_tags = arr(tags) }
end

function M.remove_personal_tag(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local tag = clean_personal_tag(req.params.tag)
  db.execute("DELETE FROM media_personal_tags WHERE media_id=%s AND user_id=%s AND tag=%s", tostring(media_id), tostring(user.id), tag)
  local rows = db.fetchall("SELECT tag FROM media_personal_tags WHERE media_id=%s AND user_id=%s ORDER BY tag", tostring(media_id), tostring(user.id))
  local tags = {}
  for _, row in ipairs(rows) do tags[#tags + 1] = row.tag end
  return 200, { personal_tags = arr(tags) }
end

-- Lists everything the viewer has personally tagged with a given tag
-- (or, with no tag param, their full set of distinct personal tags) --
-- the "browse my own private organization" half of the feature, mirrors
-- how the public tag cloud/search work but scoped to media_personal_tags.
function M.my_personal_tags(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local tag = nn(req.query.tag)
  if tag then
    local rows = db.fetchall(
      [[
        SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
               m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views, m.visibility
        FROM media_personal_tags pt
        JOIN media_items m ON m.id = pt.media_id
        WHERE pt.user_id=%s AND pt.tag=%s AND m.deleted_at IS NULL
        ORDER BY pt.created_at DESC
        LIMIT 200
      ]],
      tostring(user.id), clean_personal_tag(tag)
    )
    local adult_allowed = viewer_adult_allowed(tostring(user.id))
    for _, row in ipairs(rows) do
      row.id = db.toint(row.id, row.id)
      row.user_id = db.toint(row.user_id, row.user_id)
      row.category_id = db.toint(row.category_id, row.category_id)
      row.views = db.toint(row.views, 0)
      row.is_adult = db.tobool(row.is_adult)
      with_urls(req, row, adult_allowed)
    end
    return 200, { media = arr(rows) }
  end
  local tag_rows = db.fetchall(
    "SELECT tag, COUNT(*) AS n FROM media_personal_tags WHERE user_id=%s GROUP BY tag ORDER BY n DESC, tag ASC",
    tostring(user.id)
  )
  for _, row in ipairs(tag_rows) do row.n = db.toint(row.n, 0) end
  return 200, { tags = arr(tag_rows) }
end

-- ---------------------------------------------------------------------------
-- "On this day" memories -- resurfaces the viewer's own uploads from
-- exactly today's month/day in a past year. Simple date-match query, no
-- background job needed (Python's/Lua's TODO.md-tracked "unported
-- background loops" are for things that need to run unattended and push
-- notifications out; this is on-demand, computed the moment a client asks).
-- ---------------------------------------------------------------------------

function M.my_memories(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.media_kind, m.mime_type,
             m.original_filename, m.storage_path, m.is_adult, m.created_at, m.views, m.visibility,
             EXTRACT(YEAR FROM now())::int - EXTRACT(YEAR FROM m.created_at)::int AS years_ago
      FROM media_items m
      WHERE m.user_id=%s AND m.deleted_at IS NULL
        AND EXTRACT(MONTH FROM m.created_at) = EXTRACT(MONTH FROM now())
        AND EXTRACT(DAY FROM m.created_at) = EXTRACT(DAY FROM now())
        AND EXTRACT(YEAR FROM m.created_at) < EXTRACT(YEAR FROM now())
      ORDER BY m.created_at ASC
      LIMIT 50
    ]],
    tostring(user.id)
  )
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.user_id = db.toint(row.user_id, row.user_id)
    row.category_id = db.toint(row.category_id, row.category_id)
    row.views = db.toint(row.views, 0)
    row.years_ago = db.toint(row.years_ago, row.years_ago)
    row.is_adult = db.tobool(row.is_adult)
    with_urls(req, row, adult_allowed)
  end
  return 200, { media = arr(rows) }
end

-- ---------------------------------------------------------------------------
-- Scoped read-only API keys -- for third-party/personal integrations (a
-- Discord bot, a personal script) that should be able to read a user's OWN
-- gallery data without handing over their real login session. Deliberately
-- NOT wired into current_user()/auth_optional() at all -- rather than
-- retrofit the entire auth stack (and risk a wiring mistake accidentally
-- granting write access through a token meant to be read-only), a key only
-- ever unlocks the small dedicated read-only surface below (right now:
-- M.my_memories-style "own media" list and the personal RSS feed in
-- pages_feeds.lua). The raw key is shown to the user exactly once, at
-- creation; only its SHA-256 hash is ever stored.
-- ---------------------------------------------------------------------------

-- Required here (not just relying on the later `local sodium =
-- require("luasodium")` further down this file, near the duplicate-
-- detection code) since these functions are defined before that point --
-- require() is cached/idempotent, so this is the same module table either
-- way, just visible from here too.
local sodium = require("luasodium")

local API_KEY_PREFIX = "gk_"

-- Exported so pages_feeds.lua's keyed personal feed can authenticate a
-- ?key= query param the same way, without duplicating the hash-and-look-up
-- logic. Returns the owning user id (string) or nil.
function M.resolve_api_key(raw_key)
  raw_key = tostring(raw_key or "")
  if raw_key:sub(1, #API_KEY_PREFIX) ~= API_KEY_PREFIX then return nil end
  local token_hash = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(raw_key))
  local row = db.fetchone("SELECT id, user_id FROM api_keys WHERE token_hash=%s AND revoked_at IS NULL", token_hash)
  if not row then return nil end
  -- Now that auth_optional() (see above) resolves a key on every read-
  -- context request -- including HLS segment fetches, which can be 50-100+
  -- per video watched -- an unconditional UPDATE here would mean that many
  -- writes per video. The staleness guard keeps last_used_at meaningfully
  -- fresh (still-accurate to within a minute) while collapsing a whole
  -- streaming session down to at most one write.
  db.execute(
    "UPDATE api_keys SET last_used_at=now() WHERE id=%s AND (last_used_at IS NULL OR last_used_at < now() - interval '60 seconds')",
    tostring(db.toint(row.id, row.id))
  )
  return tostring(db.toint(row.user_id, row.user_id))
end

function M.create_api_key(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local label = trim(nn(payload.label) or "API key"):sub(1, 80)
  local raw_key = API_KEY_PREFIX .. sodium.sodium_bin2hex(sodium.randombytes_buf(24))
  local token_hash = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(raw_key))
  local row, err = db.fetchone(
    "INSERT INTO api_keys (user_id, label, token_hash) VALUES (%s, %s, %s) RETURNING id, created_at",
    tostring(user.id), label, token_hash
  )
  if not row then return 500, { detail = "Could not create API key: " .. tostring(err) } end
  return 200, {
    -- Only place the raw key is ever returned -- store it now, it cannot
    -- be recovered later (only the hash persists).
    key = raw_key,
    id = db.toint(row.id, row.id),
    label = label,
    created_at = row.created_at,
  }
end

function M.list_api_keys(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    "SELECT id, label, created_at, last_used_at, revoked_at FROM api_keys WHERE user_id=%s ORDER BY created_at DESC",
    tostring(user.id)
  )
  for _, row in ipairs(rows) do row.id = db.toint(row.id, row.id) end
  return 200, { api_keys = arr(rows) }
end

function M.revoke_api_key(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local key_id = tonumber(req.params.key_id)
  if not key_id then return 404, { detail = "API key not found." } end
  db.execute("UPDATE api_keys SET revoked_at=now() WHERE id=%s AND user_id=%s AND revoked_at IS NULL", tostring(key_id), tostring(user.id))
  return 200, { ok = true }
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

-- Forward-declared: assigned further down (in the messaging section) once
-- NOTIFICATION_KINDS/user_blocks-table logic exists -- same pattern as
-- notify_matching_saved_searches above.
local create_notification, is_blocked_either_way

-- Mirrors app/routers/media.py's add_comment(): notifies the post owner and
-- parses @mentions (excluding self and blocked users) same as Python.
local MENTION_RE = "@([%w_%.%-]+)"
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

  local kind = parent_id and "reply" or "comment"
  create_notification(item.user_id, user.id, kind, media_id, text)

  local mentions, seen_mention = {}, {}
  for _, name in (" " .. text):gmatch("([^%w_])@([%w_%.%-]+)") do
    local lowered = name:lower()
    if #name >= 3 and #name <= 40 and not seen_mention[lowered] then
      seen_mention[lowered] = true
      mentions[#mentions + 1] = lowered
      if #mentions >= 10 then break end
    end
  end
  if #mentions > 0 then
    local placeholders = {}
    for i = 1, #mentions do placeholders[i] = "%s" end
    local resolved = db.fetchall(
      "SELECT id, username FROM users WHERE LOWER(username) IN (" .. table.concat(placeholders, ", ") .. ")",
      unpack(mentions)
    )
    local notified = {}
    for _, u in ipairs(resolved) do
      local mentioned_id = db.toint(u.id, u.id)
      if mentioned_id ~= user.id and mentioned_id ~= db.toint(item.user_id, item.user_id) and not notified[mentioned_id] then
        notified[mentioned_id] = true
        if not is_blocked_either_way(user.id, mentioned_id) then
          create_notification(mentioned_id, user.id, "mention", media_id, text)
        end
      end
    end
  end

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
  local my_reaction = r and r.emoji or nil
  if tostring(item.user_id) ~= tostring(user.id) and my_reaction then
    create_notification(item.user_id, user.id, "reaction", media_id, my_reaction)
  end
  return 200, { reactions = { counts = counts, my_reaction = my_reaction } }
end

-- ---------------------------------------------------------------------------
-- Media upload (POST /api/media) -- multipart form upload -> DB blob storage
-- (media_files.save_media_file) -> media_items row. Mirrors
-- app/routers/media.py's upload_media() + app/db/media.py's add_media().
--
-- Video thumb/quality cache warmup is not queued here; serve_media_thumb
-- already renders+caches lazily on first request instead.
-- ---------------------------------------------------------------------------

-- Validates the frontend's "Schedule for later" field (a datetime-local
-- value round-tripped through JS Date#toISOString(), e.g.
-- "2026-08-10T15:30:00.000Z"). Returns nil (immediate publish) when blank,
-- the validated timestamp string when it parses and is in the future, or
-- nil + an error message otherwise. Parsing/future-check is delegated to
-- Postgres itself (a single cheap round trip) rather than hand-rolling
-- ISO8601 parsing in Lua -- avoids silently accepting a format Postgres
-- would then reject at INSERT time, after the file blob is already saved.
local function parse_publish_at(raw)
  raw = nn(raw)
  if not raw or trim(raw) == "" then return nil, nil end
  local row, err = db.fetchone("SELECT (%s::timestamp > now()) AS in_future", raw)
  if not row then return nil, "Invalid schedule date." end
  if not db.tobool(row.in_future) then return nil, "Scheduled time must be in the future." end
  return raw, nil
end

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

-- POST /api/me/avatar, /api/me/age-verification, /api/me/password,
-- GET /api/me/export -- all four recovered from git history
-- (9986ab5^:app/routers/account.py) and confirmed live-404ing: the React
-- Settings page has always called these, but none were ever ported to Lua.
-- (email change/verify, also called by SettingsPage.jsx, never existed even
-- in the Python backend -- genuinely new work needing an email-sending
-- decision, left for a separate pass rather than guessed at here.) Placed
-- here (rather than up near update_profile/update_settings, its more
-- natural neighbors) because update_avatar needs sniff_magic/safe_extension/
-- sodium, all locals not yet in scope up there.

function M.update_avatar(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > 5 * 1024 * 1024 then
    return 413, { detail = "Avatars must be 5MB or smaller." }
  end
  local rl_status, rl_body = ratelimit.check("avatar:" .. user.id, 20, 3600)
  if rl_status then return rl_status, rl_body end

  local sniffed_mime, media_kind = sniff_magic(upload.content)
  if not sniffed_mime or media_kind ~= "image" then return 400, { detail = "Avatar must be an image." } end
  local original_filename = ((upload.filename or "avatar"):match("([^/\\]+)$") or "avatar"):sub(1, 255)
  if not safe_extension(original_filename, sniffed_mime) then
    return 400, { detail = "Unsupported file extension." }
  end
  local sha256 = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(upload.content))

  local file_id, err = media_files.save_avatar_file(user.id, upload.content, sha256, sniffed_mime, original_filename)
  if not file_id then return 500, { detail = "Avatar upload failed: " .. tostring(err) } end

  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_derived_accent(refreshed) }
end

function M.verify_age(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  if not db.tobool(payload.confirm_over_18) then
    return 400, { detail = "Confirm that you are 18 or older to continue." }
  end
  local birthdate = nn(payload.birthdate)
  if not birthdate or not tostring(birthdate):match("^%d%d%d%d%-%d%d%-%d%d$") then
    return 400, { detail = "Birthdate must use YYYY-MM-DD." }
  end
  -- Single round trip: validate + compute age in Postgres rather than
  -- hand-rolling date math in Lua.
  local row = db.fetchone(
    "SELECT (%s::date > CURRENT_DATE) AS in_future, date_part('year', age(CURRENT_DATE, %s::date)) AS age_years",
    birthdate, birthdate
  )
  if not row then return 400, { detail = "Invalid birthdate." } end
  if db.tobool(row.in_future) then return 400, { detail = "Birthdate cannot be in the future." } end
  if db.toint(row.age_years, 0) < 18 then
    return 403, { detail = "You must be 18 or older to view 18+ posts." }
  end

  db.execute(
    "UPDATE users SET birthdate=%s, age_verified_at=now(), adult_content_consent=true WHERE id=%s",
    birthdate, tostring(user.id)
  )
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_derived_accent(refreshed) }
end

function M.change_password(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local old_password = tostring(nn(payload.old_password) or "")
  local new_password = tostring(nn(payload.new_password) or "")
  if #new_password < 8 then
    return 400, { detail = "New password must be at least 8 characters." }
  end
  local row = db.fetchone("SELECT password_hash FROM users WHERE id=%s", user.id)
  if not row or not gauth.verify_password_hash(old_password, row.password_hash) then
    return 401, { detail = "Current password is incorrect." }
  end
  db.execute("UPDATE users SET password_hash=%s WHERE id=%s", gauth.password_hash(new_password), user.id)
  return 200, { ok = true }
end

function M.export_account(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local viewer0 = tostring(user.id)

  local profile = get_user(viewer0)
  profile.password_hash = nil
  profile.totp_secret = nil
  profile.totp_recovery_codes = nil

  local media = db.fetchall(
    "SELECT id, title, description, tags, media_kind, visibility, views, downloads, created_at FROM media_items WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )
  local collections = db.fetchall(
    "SELECT id, name, description, is_public, is_smart, created_at FROM media_collections WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )
  local following = db.fetchall(
    "SELECT u.id, u.username FROM user_follows f JOIN users u ON u.id = f.followed_id WHERE f.follower_id=%s",
    viewer0
  )
  local followers = db.fetchall(
    "SELECT u.id, u.username FROM user_follows f JOIN users u ON u.id = f.follower_id WHERE f.followed_id=%s",
    viewer0
  )
  local likes = db.fetchall("SELECT media_id FROM media_likes WHERE user_id=%s", viewer0)
  local bookmarks = db.fetchall("SELECT media_id FROM media_bookmarks WHERE user_id=%s", viewer0)
  local comments = db.fetchall(
    "SELECT media_id, body, created_at FROM media_comments WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )
  local saved_searches = db.fetchall(
    "SELECT name, filter_json, created_at FROM saved_searches WHERE user_id=%s ORDER BY created_at DESC",
    viewer0
  )

  local payload = {
    exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    profile = profile,
    media = arr(media),
    collections = arr(collections),
    following = arr(following),
    followers = arr(followers),
    likes = arr(likes),
    bookmarks = arr(bookmarks),
    comments = arr(comments),
    saved_searches = arr(saved_searches),
  }
  return 200, cjson.encode(payload), {
    ["Content-Type"] = "application/json; charset=utf-8",
    ["Content-Disposition"] = string.format('attachment; filename="image-gallery-export-%s.json"', viewer0),
  }
end

-- ---------------------------------------------------------------------------
-- Discord account verification. Genuinely new feature (there's no email
-- verification equivalent to recover from git history -- the frontend never
-- had one either): confirms account ownership via Discord instead of email,
-- using the same CSPRNG code + hash helpers (auth_lib.verification_code()/
-- verification_token_hash()) this codebase already has (originally written
-- for a since-unbuilt email flow, per their own doc comments in auth.lua).
--
-- Two delivery methods for the same code:
--   "dm"      -- via discord_bot.lua's real bot (needs GALLERY_DISCORD_BOT_TOKEN
--                configured, and the user must share a Discord server with
--                the bot -- Discord doesn't allow bots to DM strangers).
--   "webhook" -- posts to the user's own already-configured
--                discord_webhook_url (user_settings, the same per-creator
--                setting upload notifications already use) -- works today,
--                no bot needed.
-- ---------------------------------------------------------------------------

local DISCORD_VERIFY_TTL_SECONDS = 600
local DISCORD_VERIFY_MAX_ATTEMPTS = 5

function M.discord_verify_status(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  local pending = db.fetchone(
    "SELECT method, expires_at, (now() > expires_at) AS is_expired FROM discord_verifications WHERE user_id=%s",
    user.id
  )
  local pending_out = nil
  if pending and not db.tobool(pending.is_expired) then
    pending_out = { method = pending.method, expires_at = pending.expires_at }
  end
  return 200, {
    verified = nn(user.discord_verified_at) ~= nil,
    discord_username = nn(user.discord_username),
    discord_user_id = nn(user.discord_user_id),
    pending = pending_out,
    dm_available = discord_bot.enabled(),
  }
end

function M.discord_verify_start(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  local rl_status, rl_body = ratelimit.check("discord_verify:" .. user.id, 5, 3600)
  if rl_status then return rl_status, rl_body end

  local payload = json_body(req)
  local method = nn(payload.method)
  if method ~= "dm" and method ~= "webhook" then
    return 400, { detail = 'method must be "dm" or "webhook".' }
  end

  local code = auth_lib.verification_code()
  local target

  if method == "dm" then
    if not discord_bot.enabled() then
      return 400, { detail = "Discord verification isn't configured on this server yet." }
    end
    target = tostring(nn(payload.discord_user_id) or ""):match("^%d+$")
    if not target then
      return 400, {
        detail = "Enter a valid Discord User ID (numbers only -- in Discord, enable "
          .. "Settings > Advanced > Developer Mode, then right-click your name and Copy User ID).",
      }
    end
    local send_ok, send_err = discord_bot.send_dm(
      target, "Your Nyxframe verification code is: " .. code .. "\nIt expires in 10 minutes."
    )
    if not send_ok then return 400, { detail = send_err } end
  else
    local webhook_url = user.user_settings and user.user_settings.discord_webhook_url
    if not discord_webhook.is_valid_url(webhook_url) then
      return 400, { detail = "Set a Discord webhook URL under Settings > Integrations first." }
    end
    target = webhook_url
    discord_webhook.send(webhook_url, { {
      title = "Nyxframe verification code",
      description = "Code: **" .. code .. "**\nExpires in 10 minutes. Enter it on the Settings page.",
      color = 0x37c9a7,
    } })
  end

  db.execute(
    [[
      INSERT INTO discord_verifications (user_id, code_hash, method, target, attempts, expires_at)
      VALUES (%s, %s, %s, %s, 0, now() + interval '10 minutes')
      ON CONFLICT (user_id) DO UPDATE SET
        code_hash=EXCLUDED.code_hash, method=EXCLUDED.method, target=EXCLUDED.target,
        attempts=0, expires_at=EXCLUDED.expires_at, created_at=now()
    ]],
    user.id, auth_lib.verification_token_hash(code), method, target:sub(1, 255)
  )

  return 200, { ok = true, method = method, expires_in_seconds = DISCORD_VERIFY_TTL_SECONDS }
end

function M.discord_verify_confirm(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local code = trim(tostring(nn(payload.code) or ""))
  if code == "" then return 400, { detail = "Enter the code you received." } end

  local pending = db.fetchone(
    "SELECT method, target, code_hash, attempts, (now() > expires_at) AS is_expired FROM discord_verifications WHERE user_id=%s",
    user.id
  )
  if not pending then return 400, { detail = "No verification in progress -- start over." } end
  if db.toint(pending.attempts, 0) >= DISCORD_VERIFY_MAX_ATTEMPTS or db.tobool(pending.is_expired) then
    db.execute("DELETE FROM discord_verifications WHERE user_id=%s", user.id)
    return 400, { detail = "That code expired or had too many incorrect attempts -- start over." }
  end

  if auth_lib.verification_token_hash(code) ~= pending.code_hash then
    db.execute("UPDATE discord_verifications SET attempts=attempts+1 WHERE user_id=%s", user.id)
    return 400, { detail = "Incorrect code." }
  end

  if pending.method == "dm" then
    local discord_username = discord_bot.get_user(pending.target)
    db.execute(
      "UPDATE users SET discord_user_id=%s, discord_username=%s, discord_verified_at=now() WHERE id=%s",
      pending.target, discord_username, user.id
    )
  else
    db.execute("UPDATE users SET discord_verified_at=now() WHERE id=%s", user.id)
  end
  db.execute("DELETE FROM discord_verifications WHERE user_id=%s", user.id)

  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_derived_accent(refreshed) }
end

function M.discord_unlink(req)
  local user, session, status, body = current_user(req)
  if not user then return status, body end
  db.execute(
    "UPDATE users SET discord_user_id=NULL, discord_username=NULL, discord_verified_at=NULL WHERE id=%s",
    user.id
  )
  db.execute("DELETE FROM discord_verifications WHERE user_id=%s", user.id)
  local refreshed = get_user(user.id)
  refreshed.site_owner = is_site_owner(refreshed)
  return 200, { user = with_derived_accent(refreshed) }
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

-- ---------------------------------------------------------------------------
-- Possible-duplicate-upload warning via perceptual image hashing. Mirrors
-- app/routers/media.py's _find_possible_duplicates() + app/ai_metadata.py's
-- _hex_hamming_distance() -- the actual hash computation lives in
-- media_files.image_fingerprint() (ffmpeg-based, see that file's comment for
-- why it isn't bit-identical to Python's PIL-based hashes; irrelevant here
-- since candidates are always hashed by this same backend).
-- ---------------------------------------------------------------------------

local bit = require("bit")

-- Compares two equal-length hex hash strings 8 hex chars (32 bits) at a
-- time, since `bit` only handles 32-bit values. Returns nil if either hash
-- is missing/malformed.
local function hex_hamming_distance(a, b)
  a = tostring(a or ""):lower()
  b = tostring(b or ""):lower()
  if a == "" or b == "" or #a ~= #b or #a % 8 ~= 0 then return nil end
  local dist = 0
  for i = 1, #a, 8 do
    local ha, hb = tonumber(a:sub(i, i + 7), 16), tonumber(b:sub(i, i + 7), 16)
    if not ha or not hb then return nil end
    local x = bit.bxor(ha, hb)
    while x ~= 0 do
      dist = dist + bit.band(x, 1)
      x = bit.rshift(x, 1)
    end
  end
  return dist
end

-- Scoped to the uploader's own media (not the whole gallery) to keep the
-- comparison pool small and the result meaningful -- catching accidental
-- re-uploads, not flagging every repost. Advisory only; never blocks the
-- upload itself.
-- `scope`: "mine" (default, unchanged behavior) scopes candidates to the
-- uploader's own prior uploads. "site" widens the search to every user's
-- uploads, opt-in only (see M.upload_media's check_site_duplicates flag) --
-- bounded by dedup_scan_window_days (config.lua) rather than just the 1500-
-- row cap, since "site-wide" with no time bound would just become "the 1500
-- newest uploads from anyone," missing older duplicates and not meaningfully
-- related to fingerprint similarity.
local function find_possible_duplicates(req, user_id, fingerprint, limit, scope)
  limit = limit or 3
  if not fingerprint then return {} end
  local current_phash, current_dhash = nn(fingerprint.image_phash), nn(fingerprint.image_dhash)
  if not current_phash and not current_dhash then return {} end

  local candidates
  if scope == "site" then
    candidates = db.fetchall(string.format([[
      SELECT id, title, image_phash, image_dhash
      FROM media_items
      WHERE user_id != %%s AND deleted_at IS NULL AND media_kind='image' AND visibility='public'
        AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL)
        AND created_at > now() - (%d || ' days')::interval
      ORDER BY created_at DESC
      LIMIT 1500
    ]], M.settings.dedup_scan_window_days), tostring(user_id))
  else
    candidates = db.fetchall([[
      SELECT id, title, image_phash, image_dhash
      FROM media_items
      WHERE user_id=%s AND deleted_at IS NULL AND media_kind='image'
        AND (image_phash IS NOT NULL OR image_dhash IS NOT NULL)
      ORDER BY created_at DESC
      LIMIT 1500
    ]], tostring(user_id))
  end

  local scored = {}
  for _, candidate in ipairs(candidates) do
    local pdist = current_phash and hex_hamming_distance(current_phash, candidate.image_phash) or nil
    local ddist = current_dhash and hex_hamming_distance(current_dhash, candidate.image_dhash) or nil
    if pdist and pdist > M.settings.visual_phash_max_distance then pdist = nil end
    if ddist and ddist > M.settings.visual_dhash_max_distance then ddist = nil end
    if pdist or ddist then
      local best = pdist and ddist and math.min(pdist, ddist) or (pdist or ddist)
      scored[#scored + 1] = { distance = best, candidate = candidate }
    end
  end
  table.sort(scored, function(a, b) return a.distance < b.distance end)

  local origin = request_origin(req)
  local results = {}
  for i = 1, math.min(limit, #scored) do
    local entry = scored[i]
    results[#results + 1] = {
      id = db.toint(entry.candidate.id, entry.candidate.id),
      title = entry.candidate.title,
      thumb_url = append_query(origin .. "/api/media/" .. entry.candidate.id .. "/thumb", "w", "640"),
      distance = entry.distance,
    }
  end
  return results
end

-- Mirrors app/routers/media.py's _notify_discord_upload/_notify_discord_upload_async.
-- Fire-and-forget (see discord_webhook.lua): a slow/broken webhook must
-- never delay or fail the upload response.
-- Forward-declared: the actual function is assigned further down (in the
-- saved-searches section, after create_notification/is_blocked_either_way
-- exist) since Lua locals are only visible to code after their declaration
-- -- this `local` here just reserves the upvalue so M.upload_media below can
-- close over it; by the time any request actually runs, the whole module
-- has finished loading and the assignment further down has already happened.
local notify_matching_saved_searches

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
    print("[nyxframe] Discord upload webhook notification failed for user " .. tostring(uploader.id) .. ": " .. tostring(err))
  end
end

-- Shared by both upload paths: the normal single-request multipart upload
-- (M.upload_media, still used for anything that fits under one request --
-- the Cloudflare tunnel this deployment sits behind hard-413s any single
-- request body over ~100MB, well below what M.settings.max_upload_bytes
-- allows) and the chunked upload path (M.upload_chunk_finish) that exists
-- specifically to get large videos past that same edge limit by sending
-- them as several sub-100MB requests instead of one.
local function finalize_upload_debug_mark(label, t0)
  if os.getenv("GALLERY_UPLOAD_DEBUG_TIMING") then
    io.stdout:write(string.format("[upload-timing] %s at +%.2fs\n", label, os.time() - t0))
    io.stdout:flush()
  end
end

-- `source` is either `{content = "..."}` (already in memory -- the plain
-- multipart upload path, where httpd.lua's parser already holds the whole
-- request body as one string anyway, so there's nothing to gain by
-- treating it specially) or `{file_path = "...", file_size = N}` (a
-- chunked upload's already-fully-assembled session file, still just
-- sitting on disk). The file_path case is what actually matters: sniffing
-- reads a few hundred bytes, hashing streams the file in chunks
-- (media_files.sha256_file), AI analysis extracts one small preview frame
-- via ffmpeg reading straight from the path, and the final storage step
-- is a plain rename -- a multi-hundred-MB upload's real content is never
-- pulled into a single Lua string anywhere in this path. Confirmed live
-- (2026-08-10) that holding that much in LuaJIT's GC-managed heap was
-- itself what froze this single-threaded server, independent of raw OS
-- memory pressure: a full GC sweep is a stop-the-world pause proportional
-- to live heap size.
local function source_sniff_prefix(source)
  if source.content then return source.content:sub(1, 512) end
  local f = io.open(source.file_path, "rb")
  if not f then return "" end
  local prefix = f:read(512) or ""
  f:close()
  return prefix
end

local function source_size(source)
  return source.content and #source.content or source.file_size
end

local function source_sha256(source)
  if source.content then
    return sodium.sodium_bin2hex(sodium.crypto_hash_sha256(source.content))
  end
  return media_files.sha256_file(source.file_path)
end

-- Fingerprinting is image-only, and images realistically never approach
-- the size where holding one fully in memory matters -- so the file_path
-- case just reads the whole (small) file once here rather than needing
-- its own streaming image_fingerprint variant.
local function source_content_for_fingerprint(source)
  if source.content then return source.content end
  local f = io.open(source.file_path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function finalize_upload(req, user, source, original_filename, form)
  local debug_t0 = os.time()
  finalize_upload_debug_mark("start", debug_t0)
  local sniffed_mime, media_kind = sniff_magic(source_sniff_prefix(source))
  finalize_upload_debug_mark("sniff_magic done", debug_t0)
  if not sniffed_mime then return 400, { detail = "Unsupported or invalid file bytes." } end
  local safe_ext = safe_extension(original_filename, sniffed_mime)
  if not safe_ext then
    return 400, { detail = "Unsupported file extension." }
  end

  local title_raw = trim(nn(form.title) or ""):sub(1, 160)
  local description_raw = trim(nn(form.description) or "")
  local tags_hint = parse_tags(form.tags)
  local visibility = (nn(form.visibility) or "public"):lower()
  if visibility ~= "public" and visibility ~= "unlisted" and visibility ~= "private" then
    return 400, { detail = "Visibility must be public, unlisted, or private." }
  end
  local publish_at, publish_at_err = parse_publish_at(form.publish_at)
  if publish_at_err then return 400, { detail = publish_at_err } end
  local comments_enabled = form_bool(form.comments_enabled, true)
  local downloads_enabled = form_bool(form.downloads_enabled, true)
  local is_adult_input = form_bool(form.is_adult, false)
  local auto_ai = form_bool(form.auto_ai, true)

  -- AI-assisted auto-fill (see ai_metadata.lua for what this does and
  -- doesn't cover): only ever fills in gaps the uploader left blank --
  -- title, tags, category/subcategory -- and is best-effort (pcall'd; a
  -- broken/unreachable AI provider must never fail the upload itself).
  local analysis = nil
  if auto_ai and M.settings.ai_enabled and (media_kind == "image" or media_kind == "video") then
    local ok, result = pcall(ai_metadata.analyze_media_bytes, {
      content = source.content, file_path = source.file_path, filename = original_filename, mime_type = sniffed_mime, media_kind = media_kind,
      title_hint = title_raw, description_hint = description_raw, tags_hint = tags_hint, settings = M.settings,
    })
    if ok then analysis = result end
  end
  finalize_upload_debug_mark("ai analysis done", debug_t0)

  -- Auto-organization (tags/subcategories) only auto-applies above this
  -- confidence -- title is left ungated below (a so-so title guess is
  -- low-stakes and the uploader notices/fixes it immediately; it isn't an
  -- "organization" decision the way tags/category are), and category
  -- itself is deliberately left ungated too, since it's the one REQUIRED
  -- field here -- gating it would turn a low-confidence guess into a new
  -- upload failure ("Category is required") for uploads that silently
  -- succeeded before this change, which is a bigger behavior change than
  -- "auto-organize with high confidence" asked for. Tags and
  -- subcategories are both optional, so gating them can only ever leave a
  -- field blank for the uploader to notice and fill in themselves --
  -- never break the upload.
  local AI_ORGANIZE_MIN_CONFIDENCE = 0.6
  local ai_organize_confident = analysis and (tonumber(analysis.confidence) or 0) >= AI_ORGANIZE_MIN_CONFIDENCE

  local title = title_raw ~= "" and title_raw or (analysis and analysis.title) or ""
  if title == "" then return 400, { detail = "Title is required." } end
  local description = description_raw ~= "" and description_raw:sub(1, 2000) or nil
  local tags = (ai_organize_confident and #analysis.tags > 0) and analysis.tags or tags_hint

  local category_id = tonumber(form.category_id)
  if not category_id or category_id <= 0 then
    local category_kind = nn(form.category_kind) or (media_kind == "video" and "video" or "image")
    local category_name = nn(form.category_name)
    if not category_name or trim(category_name) == "" then category_name = analysis and analysis.category_name or nil end
    category_id = find_or_create_category(category_name, category_kind, user.id)
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
  if #requested_ids == 0 and #requested_names == 0 and ai_organize_confident then
    for _, name in ipairs(analysis.subcategory_names or {}) do requested_names[#requested_names + 1] = name end
  end
  requested_names = normalize_subcategory_names(requested_names)

  local resolved_subcategory_ids, subcat_err = resolve_subcategory_ids(category_id, requested_ids, requested_names, user.id)
  if not resolved_subcategory_ids then return 400, { detail = subcat_err } end
  local subcategory_id = resolved_subcategory_ids[1]

  local sha256 = source_sha256(source)
  finalize_upload_debug_mark("sha256 done", debug_t0)
  local moderation = moderate_upload(title, description, tags, original_filename, sniffed_mime,
    is_adult_input or (analysis and analysis.is_adult) or false)

  local fingerprint = media_kind == "image" and media_files.image_fingerprint(source_content_for_fingerprint(source)) or nil
  local possible_duplicates = find_possible_duplicates(req, user.id, fingerprint)
  -- Site-wide check is opt-in per upload (not automatic) so the default
  -- upload response/behavior for everyone who doesn't set this flag is
  -- completely unchanged.
  local possible_site_duplicates = form_bool(form.check_site_duplicates, false)
    and find_possible_duplicates(req, user.id, fingerprint, 3, "site")
    or {}
  finalize_upload_debug_mark("moderation/fingerprint/dupes done", debug_t0)

  local media_file, save_err = media_files.save_media_file_to_disk(M.settings.uploads_dir, {
    content = source.content,
    source_path = source.file_path,
    sha256 = sha256,
    ext = safe_ext,
    original_filename = original_filename,
  })
  finalize_upload_debug_mark("save_media_file done", debug_t0)
  if not media_file then return 500, { detail = "Could not store uploaded file: " .. tostring(save_err) } end

  local row, insert_err = db.fetchone(
    [[
      INSERT INTO media_items
        (user_id, category_id, subcategory_id, title, description, tags, media_kind, mime_type, original_filename,
         storage_path, file_size, media_file_id, content_sha256, visibility, comments_enabled, downloads_enabled,
         is_adult, adult_marked_by_user, adult_marked_by_ai, moderation_status, moderation_score, moderation_reason, moderated_at,
         image_phash, image_dhash, image_width, image_height, dominant_color, publish_at)
      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,now(),%s,%s,%s,%s,%s,%s)
      RETURNING id
    ]],
    tostring(user.id), tostring(category_id), subcategory_id and tostring(subcategory_id) or nil,
    title, description, cjson.encode(arr(tags)), media_kind, sniffed_mime, original_filename,
    media_file.storage_path, tostring(source_size(source)), nil, sha256,
    visibility, comments_enabled, downloads_enabled,
    moderation.is_adult, moderation.adult_marked_by_user, moderation.adult_marked_by_ai,
    moderation.moderation_status, tostring(moderation.moderation_score), moderation.moderation_reason,
    fingerprint and fingerprint.image_phash or nil, fingerprint and fingerprint.image_dhash or nil,
    fingerprint and fingerprint.image_width and tostring(fingerprint.image_width) or nil,
    fingerprint and fingerprint.image_height and tostring(fingerprint.image_height) or nil,
    fingerprint and fingerprint.dominant_color or nil, publish_at
  )
  finalize_upload_debug_mark("media_items insert done", debug_t0)
  if not row then return 500, { detail = "Could not save media: " .. tostring(insert_err) } end
  local media_id = db.toint(row.id, row.id)
  write_media_subcategories(media_id, resolved_subcategory_ids)

  local item = fetch_media_by_id(media_id, tostring(user.id))
  local adult_allowed = viewer_adult_allowed(tostring(user.id))
  local enriched = decode_media_row(item, adult_allowed, req)
  finalize_upload_debug_mark("decode_media_row done", debug_t0)
  notify_discord_upload(req, user, enriched)
  finalize_upload_debug_mark("notify_discord_upload done", debug_t0)
  -- Scheduled posts (future publish_at) aren't visible yet, so saved-search
  -- subscribers must not be notified until the scheduled time actually
  -- arrives; there's no publish-time sweep (see parse_publish_at's comment
  -- above -- visibility is computed at read time everywhere), so a
  -- scheduled post simply never triggers this notification retroactively.
  if visibility == "public" and not publish_at then
    notify_matching_saved_searches(user.id, enriched)
  end
  return 200, { media = enriched, possible_duplicates = arr(possible_duplicates), possible_site_duplicates = arr(possible_site_duplicates) }
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

  local original_filename = ((upload.filename or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)
  return finalize_upload(req, user, { content = upload.content }, original_filename, form)
end

-- ---------------------------------------------------------------------------
-- Chunked upload (large videos). The Cloudflare tunnel this deployment sits
-- behind hard-413s any single request body over ~100MB regardless of what
-- M.settings.max_upload_bytes allows -- confirmed live: a 105MB POST gets a
-- Cloudflare-branded 413 before it ever reaches this process, while 95MB
-- goes through fine. M.upload_media above therefore stays correct only up
-- to that edge limit; anything larger (most videos with the cap now raised
-- to 700MB) has to be split into several sub-100MB requests instead of one,
-- which is what this session-based init/append/finish flow does. Sessions
-- live in-process only (no DB table, no clustering here) and are pruned
-- lazily on each init call rather than on a timer.
-- ---------------------------------------------------------------------------

local UPLOAD_CHUNK_SESSION_TTL_SECONDS = 2 * 3600
local upload_chunk_sessions = {}

local function prune_upload_chunk_sessions()
  local now = os.time()
  for id, session in pairs(upload_chunk_sessions) do
    if now - session.created_at > UPLOAD_CHUNK_SESSION_TTL_SECONDS then
      pcall(os.remove, session.temp_path)
      upload_chunk_sessions[id] = nil
    end
  end
end

function M.upload_chunk_init(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local rl_status, rl_body = ratelimit.check("upload:" .. user.id, M.settings.upload_rate_limit_per_hour, 3600)
  if rl_status then return rl_status, rl_body end

  prune_upload_chunk_sessions()

  local json = req.json or {}
  local total_size = tonumber(json.total_size)
  local filename = ((nn(json.filename) or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)
  if not total_size or total_size <= 0 then
    return 400, { detail = "total_size is required." }
  end
  if total_size > M.settings.max_upload_bytes then
    return 413, { detail = string.format("Uploads must be %dMB or smaller.", math.floor(M.settings.max_upload_bytes / (1024 * 1024))) }
  end

  local session_id = sodium.sodium_bin2hex(sodium.randombytes_buf(16))
  local temp_path = M.settings.uploads_dir .. "/_upload_sessions_" .. session_id .. ".part"
  local f, ferr = io.open(temp_path, "wb")
  if not f then return 500, { detail = "Could not start upload: " .. tostring(ferr) } end
  f:close()

  upload_chunk_sessions[session_id] = {
    user_id = user.id,
    temp_path = temp_path,
    filename = filename,
    total_size = total_size,
    received_bytes = 0,
    next_index = 0,
    created_at = os.time(),
  }

  -- 20MB keeps every individual request comfortably under the ~100MB
  -- Cloudflare edge ceiling even accounting for retries/overhead; it's a
  -- suggestion the client is free to ignore (chunks are appended in order
  -- by index regardless of size), not an enforced contract.
  return 200, { session_id = session_id, chunk_size = 20 * 1024 * 1024 }
end

function M.upload_chunk_append(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local session_id = nn(req.query and req.query.session_id)
  local index = tonumber(req.query and req.query.index)
  local session = session_id and upload_chunk_sessions[session_id]
  if not session or session.user_id ~= user.id then
    return 404, { detail = "Upload session not found or expired." }
  end
  if not index or index ~= session.next_index then
    return 409, { detail = "Chunks must be uploaded in order, starting at 0." }
  end
  local chunk = req.raw_body or ""
  if chunk == "" then
    return 400, { detail = "Empty chunk." }
  end
  if session.received_bytes + #chunk > session.total_size then
    pcall(os.remove, session.temp_path)
    upload_chunk_sessions[session_id] = nil
    return 413, { detail = "Received more bytes than declared at upload start." }
  end

  local f, ferr = io.open(session.temp_path, "ab")
  if not f then return 500, { detail = "Could not write chunk: " .. tostring(ferr) } end
  f:write(chunk)
  f:close()

  session.received_bytes = session.received_bytes + #chunk
  session.next_index = session.next_index + 1
  return 200, { ok = true, received_bytes = session.received_bytes }
end

function M.upload_chunk_finish(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end

  local form = req.json or {}
  local session_id = nn(form.session_id)
  local session = session_id and upload_chunk_sessions[session_id]
  if not session or session.user_id ~= user.id then
    return 404, { detail = "Upload session not found or expired." }
  end
  if session.received_bytes ~= session.total_size then
    return 400, { detail = "Upload is incomplete: expected " .. session.total_size .. " bytes, received " .. session.received_bytes .. "." }
  end

  local temp_path = session.temp_path
  local total_size = session.total_size
  upload_chunk_sessions[session_id] = nil

  if not total_size or total_size == 0 then
    pcall(os.remove, temp_path)
    return 400, { detail = "Upload is empty." }
  end

  -- req.json fields double as the "form" here since chunk sessions carry
  -- metadata as JSON, not multipart -- form_bool/nn etc all just expect
  -- string-ish values, and cjson already decodes true/false as Lua
  -- booleans, so coerce back to the "true"/"false" strings those helpers
  -- expect from a real multipart form field.
  local pseudo_form = {}
  for k, v in pairs(form) do
    if type(v) == "boolean" then
      pseudo_form[k] = v and "true" or "false"
    elseif type(v) == "table" then
      pseudo_form[k] = cjson.encode(v)
    else
      pseudo_form[k] = v
    end
  end

  -- Deliberately NOT read into memory here -- see finalize_upload's
  -- `source` doc comment. save_media_file_to_disk renames temp_path away
  -- on success/dedup; this cleanup only fires if finalize_upload returned
  -- an error before reaching that step (e.g. failed validation), in which
  -- case the file is still sitting at temp_path and would otherwise leak.
  local status_code, resp_body = finalize_upload(
    req, user, { file_path = temp_path, file_size = total_size }, session.filename, pseudo_form
  )
  pcall(os.remove, temp_path)
  return status_code, resp_body
end

-- Standalone "preview the AI suggestion before uploading" endpoint. Mirrors
-- app/routers/media.py's analyze_media_upload(): does NOT save anything --
-- just runs the same analysis + possible-duplicate check upload_media does
-- and returns the result for a client to show as a suggestion.
function M.analyze_media(req)
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

  local rl_status, rl_body = ratelimit.check("analyze:" .. user.id, M.settings.analyze_rate_limit_per_hour, 3600)
  if rl_status then return rl_status, rl_body end

  local sniffed_mime, media_kind = sniff_magic(upload.content)
  if not sniffed_mime then return 400, { detail = "Unsupported or invalid file bytes." } end
  local original_filename = ((upload.filename or "upload"):match("([^/\\]+)$") or "upload"):sub(1, 255)

  local title_hint = trim(nn(form.title) or ""):sub(1, 160)
  local description_hint = trim(nn(form.description) or "")
  local tags_hint = parse_tags(form.tags)

  local analysis
  if M.settings.ai_enabled and (media_kind == "image" or media_kind == "video") then
    local ok, result = pcall(ai_metadata.analyze_media_bytes, {
      content = upload.content, filename = original_filename, mime_type = sniffed_mime, media_kind = media_kind,
      title_hint = title_hint, description_hint = description_hint, tags_hint = tags_hint, settings = M.settings,
    })
    if ok then analysis = result end
  end
  if not analysis then
    analysis = ai_metadata.heuristic_analysis(original_filename, sniffed_mime, media_kind, title_hint, description_hint, tags_hint, media_files.media_dimensions(upload.content))
  end

  local fingerprint = media_kind == "image" and media_files.image_fingerprint(upload.content) or nil
  local possible_duplicates = find_possible_duplicates(req, user.id, fingerprint)

  return 200, {
    analysis = {
      title = analysis.title,
      suggested_filename = analysis.suggested_filename,
      tags = arr(analysis.tags),
      category_name = analysis.category_name,
      subcategory_name = analysis.subcategory_name,
      subcategory_names = arr(analysis.subcategory_names),
      is_adult = analysis.is_adult,
      source = analysis.source,
      confidence = analysis.confidence,
      reason = analysis.reason,
      description = analysis.description,
    },
    media_kind = media_kind,
    mime_type = sniffed_mime,
    original_filename = original_filename,
    possible_duplicates = arr(possible_duplicates),
  }
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

-- Real paginated "More like this" feed, not just the fixed 12-item rail
-- M.media_detail shows inline -- previously this route existed with its
-- own independently-written (and slightly cruder: fixed to the first 8
-- tags, no offset/pagination at all) copy of that same scoring logic,
-- but nothing in either frontend ever actually called it. Now backs a
-- real dedicated "more like this" page/infinite-scroll feed.
function M.similar_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local adult_allowed = viewer_adult_allowed(viewer_id)

  local source = fetch_media_by_id(media_id, viewer_id or "0")
  if not source or nn(source.deleted_at) then return 200, { media = {} } end

  local limit = bounded_limit(req.query.limit, 24, 60)
  local offset = bounded_offset(req.query.offset)
  local rows = compute_similar_media(req, media_id, source, adult_allowed, limit, offset)
  return 200, { media = arr(rows), limit = limit, offset = offset }
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
  return 200, { secret = secret, uri = totp.provisioning_uri(secret, user.username, "Nyxframe") }
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

-- ---------------------------------------------------------------------------
-- Site-wide rotating background. Mirrors app/routers/media_feed.py's
-- _background_candidate_rows()/_site_background_snapshot()/site_background()
-- (recovered from git history: 9986ab5^:app/routers/media_feed.py +
-- app/db/feed_collections.py's list_public_background_candidates()) --
-- another endpoint the Lua rewrite never ported, so the frontend's already-
-- built 5-minute rotation/crossfade logic (App.jsx) had nothing to fetch
-- and silently did nothing.
--
-- Simplified from the Python version in one deliberate way: Python falls
-- back to sniffing image-file header bytes for width/height when
-- image_width/image_height aren't populated on the row yet. This port
-- skips that fallback and only considers images that already have both
-- columns set -- simpler, and every current upload path already populates
-- them, so the candidate pool isn't meaningfully smaller. If a future
-- upload path stops populating dimensions, those images just won't be
-- eligible as backgrounds (fails safe, not silently wrong).
--
-- Module-level tables, not per-request state: this backend is one process
-- (no multi-worker fan-out to keep in sync), so a plain Lua table living
-- for the process lifetime plays the same role as Python's
-- main._background_cache / main._site_background_state globals -- every
-- client polling within the same 5-minute window gets the identical pick.
local BACKGROUND_CACHE_SECONDS = 300
local SITE_BACKGROUND_ROTATION_SECONDS = 300
local background_candidates_cache = { items = nil, built_at = 0 }
local site_background_state = { item = nil, picked_at = 0 }
math.randomseed(os.time())

local function background_candidate_rows()
  local now = os.time()
  if background_candidates_cache.items and (now - background_candidates_cache.built_at) < BACKGROUND_CACHE_SECONDS then
    return background_candidates_cache.items
  end
  -- Orientation + adult-content + visibility filtering all happen in SQL
  -- (not Lua-side after fetch): is_adult=false is not optional here -- this
  -- is the one condition standing between "site background" and "surprise
  -- 18+ content on every visitor's screen", so it lives in the WHERE clause
  -- itself rather than a filter step that's easier to accidentally skip.
  --
  -- Orientation only (width > height), not a near-exact-16:9 ratio check --
  -- the previous `ABS(ratio - 16/9) <= 0.035` tolerance rejected anything
  -- that wasn't almost exactly widescreen (a 4:3, 16:10, or ultrawide
  -- landscape image all fail that check despite being perfectly good
  -- backgrounds), which is stricter than "landscape" actually means. GIFs
  -- were never excluded here -- they share media_kind='image' with regular
  -- images (see is_gif_media(); distinguished only by mime_type/filename),
  -- so this already covered them once orientation was the only gate left.
  local rows = db.fetchall([[
      SELECT m.id, m.title, m.original_filename, m.mime_type, m.image_width, m.image_height,
             c.name AS category_name, sc.name AS subcategory_name,
             u.username, CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name
      FROM media_items m
      JOIN categories c ON c.id = m.category_id
      LEFT JOIN subcategories sc ON sc.id = m.subcategory_id
      JOIN users u ON u.id = m.user_id
      WHERE m.deleted_at IS NULL
        AND m.visibility='public'
        AND m.media_kind='image'
        AND m.is_adult=false
        AND m.image_width IS NOT NULL AND m.image_height IS NOT NULL
        AND m.image_width > m.image_height
      ORDER BY COALESCE(m.pinned_at, m.created_at) DESC, m.created_at DESC
      LIMIT 180
    ]])
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.image_width = db.toint(row.image_width, row.image_width)
    row.image_height = db.toint(row.image_height, row.image_height)
  end
  background_candidates_cache.items = rows
  background_candidates_cache.built_at = now
  return rows
end

function M.site_background(req)
  local now = os.time()
  local needs_pick = (not site_background_state.item)
    or site_background_state.picked_at == 0
    or (now - site_background_state.picked_at) >= SITE_BACKGROUND_ROTATION_SECONDS
  if needs_pick then
    local candidates = background_candidate_rows()
    if #candidates == 0 then
      site_background_state.item = nil
      site_background_state.picked_at = now
    else
      -- Never repeat the immediately-previous pick when more than one
      -- candidate exists, so a slow-changing gallery doesn't visibly
      -- "rotate" to the exact same image it just showed.
      local previous_id = site_background_state.item and site_background_state.item.id
      local pool = {}
      for _, item in ipairs(candidates) do
        if item.id ~= previous_id then pool[#pool + 1] = item end
      end
      if #pool == 0 then pool = candidates end
      site_background_state.item = pool[math.random(#pool)]
      site_background_state.picked_at = now
    end
  end

  local item = site_background_state.item
  local remaining = math.max(1, SITE_BACKGROUND_ROTATION_SECONDS - (now - site_background_state.picked_at))
  if not item then
    return 200, {
      enabled = false, background = cjson.null, background_url = cjson.null, url = cjson.null,
      updated_at = cjson.null, status = "disabled", refresh_after_seconds = SITE_BACKGROUND_ROTATION_SECONDS,
    }
  end

  local origin = request_origin(req)
  -- GIFs go out as the raw original file, not the w=1440 thumb -- the
  -- thumb endpoint flattens everything (animated or not) to a single
  -- static WebP frame for grid-display performance, which would silently
  -- turn an animated GIF background into a still image. The frontend
  -- applies this as a CSS background-image, and browsers do animate GIFs
  -- used that way, so serving the real file is all that's needed here.
  local url
  if is_gif_media(item) then
    url = origin .. "/api/media/" .. item.id .. "/file"
  else
    url = append_query(origin .. "/api/media/" .. item.id .. "/thumb", "w", "1440")
  end
  return 200, {
    enabled = true,
    status = "active",
    background = {
      id = item.id,
      title = nn(item.title) or nn(item.original_filename) or ("Background " .. item.id),
      username = item.username,
      display_name = item.display_name,
      category_name = item.category_name,
      subcategory_name = item.subcategory_name,
      width = item.image_width,
      height = item.image_height,
      url = url,
    },
    updated_at = site_background_state.picked_at,
    refresh_after_seconds = remaining,
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

-- Mirrors app/db/notifications.py's NOTIFICATION_KINDS exactly -- note "like"
-- and "report" are NOT valid kinds in Python (likes don't notify at all;
-- reports go through write_audit_log, not the notifications table).
local NOTIFICATION_KINDS = {
  follow = true, friend_request = true, friend_accept = true, comment = true,
  message = true, mention = true, reply = true, reaction = true, saved_search = true,
}

-- True if `recipient_id` has blocked OR muted `actor_id` (either kind, not
-- bidirectional like is_blocked_either_way below -- muting someone is a
-- one-way "don't show me them" preference, it shouldn't also suppress
-- notifications the other person would get about the muter). Genuinely new
-- (not a git-history recovery): "mute" has been storable via
-- POST /api/users/:id/block since block_user() was ported, and shown in
-- Settings' "Blocked & Muted" list, but nothing ever actually consulted it
-- anywhere -- confirmed via a full grep for "mute"/"is_muted" across this
-- file, and confirmed the concept never existed in the original Python
-- backend either (this file's own stale comment claiming to mirror a
-- Python is_muted() was aspirational, not real -- there's no such function
-- in git history).
local function should_suppress_notification(recipient_id, actor_id)
  if not recipient_id or not actor_id then return false end
  local row = db.fetchone(
    "SELECT 1 FROM user_blocks WHERE blocker_id=%s AND blocked_id=%s LIMIT 1",
    tostring(recipient_id), tostring(actor_id)
  )
  return row ~= nil
end

-- Mirrors app/db/notifications.py's create_notification(): silently skips
-- self-notifications and unknown kinds rather than erroring, since callers
-- (like send_direct_message below) don't want a notification-table hiccup
-- to fail the actual action.
create_notification = function(recipient_id, actor_id, kind, media_id, preview)
  if not NOTIFICATION_KINDS[kind] then return end
  if actor_id and tostring(actor_id) == tostring(recipient_id) then return end
  if actor_id and should_suppress_notification(recipient_id, actor_id) then return end
  preview = preview and trim(preview):sub(1, 160) or nil
  if preview == "" then preview = nil end
  db.execute(
    "INSERT INTO notifications (recipient_id, actor_id, kind, media_id, preview) VALUES (%s, %s, %s, %s, %s)",
    tostring(recipient_id), actor_id and tostring(actor_id) or nil, kind, media_id and tostring(media_id) or nil, preview
  )
end

-- Mirrors app/db/social.py's is_blocked_either_way().
is_blocked_either_way = function(user_a, user_b)
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

-- ---------------------------------------------------------------------------
-- Saved searches: persisted /api/media filters that notify their owner when
-- new matching public media is uploaded. Mirrors app/routers/saved_searches.py
-- + app/db/feed_collections.py's create/list/delete_saved_search,
-- find_saved_searches_matching, touch_saved_search_notified, and
-- _media_matches_saved_search_filter. Reuses the same
-- sanitize_smart_filter/SMART_FILTER_KEYS used by smart collections, since a
-- saved search's filter_json is the exact same validated shape.
-- NOT ported: Python's is_muted() check before notifying (muting isn't a
-- ported feature at all yet) -- only the block check applies here.
-- ---------------------------------------------------------------------------

local function decode_saved_search(row)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.user_id = db.toint(row.user_id, row.user_id)
  if row.filter_json and row.filter_json ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, row.filter_json)
    row.filter_json = (ok and type(decoded) == "table") and decoded or {}
  else
    row.filter_json = {}
  end
  return row
end

function M.list_saved_searches(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall("SELECT * FROM saved_searches WHERE user_id=%s ORDER BY created_at DESC", user.id)
  for _, row in ipairs(rows) do decode_saved_search(row) end
  return 200, { saved_searches = arr(rows) }
end

function M.create_saved_search(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local name = trim(nn(payload.name) or ""):gsub("%s+", " "):sub(1, 80)
  if name == "" then return 400, { detail = "Name is required." } end
  local cleaned = sanitize_smart_filter(payload.filter_json)

  local row, err = db.fetchone(
    "INSERT INTO saved_searches (user_id, name, filter_json) VALUES (%s, %s, %s) RETURNING id",
    user.id, name, cjson.encode(cleaned)
  )
  if not row then return 500, { detail = "Could not save search: " .. tostring(err) } end
  local search = db.fetchone("SELECT * FROM saved_searches WHERE id=%s", tostring(db.toint(row.id, row.id)))
  return 200, { saved_search = decode_saved_search(search) }
end

function M.delete_saved_search(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local search_id = tonumber(req.params.search_id)
  if not search_id then return 404, { detail = "Saved search not found." } end
  local existing = db.fetchone("SELECT id FROM saved_searches WHERE id=%s AND user_id=%s", tostring(search_id), user.id)
  if not existing then return 404, { detail = "Saved search not found." } end
  db.execute("DELETE FROM saved_searches WHERE id=%s AND user_id=%s", tostring(search_id), user.id)
  return 200, { deleted = true }
end

-- Mirrors _media_matches_saved_search_filter(): evaluates a saved-search
-- filter against a single freshly-uploaded item in Lua rather than SQL, same
-- rationale as Python (runs once per upload against a handful of saved
-- searches, not per page view).
local function media_matches_saved_search_filter(media, filter_json)
  if filter_json.media_kind and media.media_kind ~= filter_json.media_kind then return false end
  if filter_json.category_id and tostring(media.category_id) ~= tostring(filter_json.category_id) then return false end
  if filter_json.subcategory_id then
    local match = false
    local wanted = tostring(filter_json.subcategory_id)
    if media.subcategory_id and tostring(media.subcategory_id) == wanted then match = true end
    if not match and type(media.subcategories) == "table" then
      for _, sc in ipairs(media.subcategories) do
        if sc.id and tostring(sc.id) == wanted then match = true; break end
      end
    end
    if not match then return false end
  end
  if filter_json.adult == "only" and not media.is_adult then return false end
  if filter_json.adult == "hide" and media.is_adult then return false end
  if filter_json.min_size ~= nil and (tonumber(media.file_size) or 0) < tonumber(filter_json.min_size) then return false end
  if filter_json.max_size ~= nil and (tonumber(media.file_size) or 0) > tonumber(filter_json.max_size) then return false end
  if filter_json.uploader and nn(filter_json.uploader) then
    local needle = tostring(filter_json.uploader):lower()
    local haystack = ((media.username or "") .. " " .. (media.display_name or "")):lower()
    if not haystack:find(needle, 1, true) then return false end
  end
  if filter_json.q and nn(filter_json.q) then
    local needle = tostring(filter_json.q):lower()
    local tag_text = ""
    if type(media.tags) == "table" then tag_text = table.concat(media.tags, " ") end
    local haystack = ((media.title or "") .. " " .. (media.description or "") .. " " .. tag_text):lower()
    if not haystack:find(needle, 1, true) then return false end
  end
  return true
end

-- Assigns the local forward-declared near notify_discord_upload, above
-- M.upload_media -- see that declaration's comment for why.
notify_matching_saved_searches = function(uploader_id, item)
  local ok, err = pcall(function()
    local rows = db.fetchall("SELECT * FROM saved_searches WHERE user_id != %s", tostring(uploader_id))
    for _, row in ipairs(rows) do
      decode_saved_search(row)
      if media_matches_saved_search_filter(item, row.filter_json) then
        if not is_blocked_either_way(row.user_id, uploader_id) then
          create_notification(
            row.user_id, uploader_id, "saved_search", item.id,
            string.format('New match for "%s": %s', tostring(row.name), tostring(item.title))
          )
          db.execute("UPDATE saved_searches SET last_notified_at=CURRENT_TIMESTAMP WHERE id=%s", tostring(row.id))
        end
      end
    end
  end)
  if not ok then
    print("[nyxframe] saved-search match notification failed for uploader " .. tostring(uploader_id) .. ": " .. tostring(err))
  end
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
-- Group messaging. Genuinely new (not a git-history recovery like the DM
-- functions above) -- MessagesPage.jsx's "New group" UI has always called
-- GET/POST /api/threads and GET/POST /api/threads/:id/messages, but neither
-- the endpoints nor the underlying tables (message_groups/
-- message_group_members/group_messages -- see
-- scripts/pg_add_message_groups.sql) existed until now: confirmed via git
-- history that no hits for "api/threads"/"message_groups" exist anywhere in
-- the removed Python app/ tree either.
-- ---------------------------------------------------------------------------

local function group_membership_row(group_id, user_id)
  return db.fetchone(
    "SELECT 1 FROM message_group_members WHERE group_id=%s AND user_id=%s",
    tostring(group_id), tostring(user_id)
  )
end

-- Shared by list_groups/create_group: builds one thread-shaped row for a
-- single group from the given viewer's perspective. display_name falls back
-- to a comma-joined list of the OTHER members when the group has no
-- explicit name -- same idea as how most chat apps title an unnamed group.
local function decode_group_thread(group_id, viewer_id)
  local group = db.fetchone("SELECT id, name, created_by, created_at FROM message_groups WHERE id=%s", tostring(group_id))
  if not group then return nil end
  local members = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile THEN u.display_name ELSE u.username END AS display_name
      FROM message_group_members gm JOIN users u ON u.id = gm.user_id
      WHERE gm.group_id = %s
      ORDER BY gm.joined_at ASC
    ]],
    tostring(group_id)
  )
  for _, m in ipairs(members) do m.id = db.toint(m.id, m.id) end

  local display_name = nn(group.name)
  if not display_name then
    local other_names = {}
    for _, m in ipairs(members) do
      if tostring(m.id) ~= tostring(viewer_id) then other_names[#other_names + 1] = m.display_name end
    end
    display_name = #other_names > 0 and table.concat(other_names, ", ") or "Group"
  end

  local last = db.fetchone(
    "SELECT body FROM group_messages WHERE group_id=%s ORDER BY created_at DESC LIMIT 1",
    tostring(group_id)
  )

  return {
    id = db.toint(group.id, group.id),
    name = nn(group.name),
    display_name = display_name,
    last_message = last and last.body or nil,
    members = arr(members),
  }
end

function M.list_groups(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local group_ids = db.fetchall(
    [[
      SELECT gm.group_id FROM message_group_members gm
      JOIN message_groups g ON g.id = gm.group_id
      WHERE gm.user_id = %s
      ORDER BY g.created_at DESC
    ]],
    user.id
  )
  local threads = {}
  for _, row in ipairs(group_ids) do
    local thread = decode_group_thread(row.group_id, user.id)
    if thread then threads[#threads + 1] = thread end
  end
  return 200, { threads = arr(threads) }
end

function M.create_group(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local payload = json_body(req)
  local requested_ids = {}
  if type(payload.member_ids) == "table" then
    for _, id in ipairs(payload.member_ids) do
      local n = tonumber(id)
      if n and tostring(n) ~= tostring(user.id) then requested_ids[#requested_ids + 1] = n end
    end
  end
  -- Dedup + drop anyone blocked either way with the creator -- silently, so
  -- the group still forms with whoever's left rather than erroring the
  -- whole request over one bad invite (mirrors send_direct_message's own
  -- is_blocked_either_way check, just non-fatal here since this is a
  -- multi-member create, not a single-recipient send).
  local seen, member_ids = {}, {}
  for _, id in ipairs(requested_ids) do
    if not seen[id] and not is_blocked_either_way(user.id, id) then
      seen[id] = true
      member_ids[#member_ids + 1] = id
    end
  end
  if #member_ids == 0 then
    return 400, { detail = "Add at least one other member to start a group." }
  end

  local name = nn(payload.name)
  if name then
    name = trim(name):sub(1, 120)
    if name == "" then name = nil end
  end

  local row, err = db.fetchone(
    "INSERT INTO message_groups (name, created_by) VALUES (%s, %s) RETURNING id",
    name, user.id
  )
  if not row then return 500, { detail = "Could not create group: " .. tostring(err) } end
  local group_id = db.toint(row.id, row.id)

  db.execute("INSERT INTO message_group_members (group_id, user_id) VALUES (%s, %s)", tostring(group_id), user.id)
  for _, member_id in ipairs(member_ids) do
    db.execute(
      "INSERT INTO message_group_members (group_id, user_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
      tostring(group_id), tostring(member_id)
    )
  end

  return 200, { thread = decode_group_thread(group_id, user.id) }
end

function M.group_messages(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local group_id = tonumber(req.params.group_id)
  if not group_id then return 404, { detail = "Group not found." } end
  if not group_membership_row(group_id, user.id) then return 404, { detail = "Group not found." } end

  local limit = tonumber(req.query.limit) or 80
  local rows = db.fetchall(
    [[
      SELECT msg.id, msg.group_id, msg.sender_id, msg.body, msg.created_at,
             u.username, u.display_name, u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile
      FROM group_messages msg
      JOIN users u ON u.id = msg.sender_id
      WHERE msg.group_id = %s
      ORDER BY msg.created_at DESC, msg.id DESC
      LIMIT %s
    ]],
    tostring(group_id), tostring(math.max(1, math.min(limit, 200)))
  )
  local ordered = {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    row.id = db.toint(row.id, row.id)
    row.group_id = db.toint(row.group_id, row.group_id)
    row.sender_id = db.toint(row.sender_id, row.sender_id)
    row.public_profile = db.tobool(row.public_profile)
    if row.user_avatar_path and row.user_avatar_path ~= cjson.null then
      row.user_avatar_path = request_origin(req) .. "/api/users/" .. row.sender_id .. "/avatar"
    else
      row.user_avatar_path = nil
    end
    ordered[#ordered + 1] = row
  end
  return 200, { messages = arr(ordered) }
end

function M.send_group_message(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local group_id = tonumber(req.params.group_id)
  if not group_id then return 404, { detail = "Group not found." } end
  if not group_membership_row(group_id, user.id) then return 404, { detail = "Group not found." } end

  local payload = json_body(req)
  local cleaned = trim(nn(payload.body) or ""):gsub("%s+", " ")
  if cleaned == "" then return 400, { detail = "Message cannot be empty." } end
  if #cleaned > 2000 then return 400, { detail = "Message must be 2000 characters or fewer." } end

  local row = db.fetchone(
    "INSERT INTO group_messages (group_id, sender_id, body) VALUES (%s, %s, %s) RETURNING id",
    tostring(group_id), user.id, cleaned
  )
  if not row then return 500, { detail = "Could not send message." } end

  local message = db.fetchone(
    [[
      SELECT msg.id, msg.group_id, msg.sender_id, msg.body, msg.created_at,
             u.username, u.display_name, u.avatar_path AS user_avatar_path, u.profile_color, u.public_profile
      FROM group_messages msg JOIN users u ON u.id = msg.sender_id
      WHERE msg.id = %s
    ]],
    tostring(db.toint(row.id, row.id))
  )
  message.id = db.toint(message.id, message.id)
  message.group_id = db.toint(message.group_id, message.group_id)
  message.sender_id = db.toint(message.sender_id, message.sender_id)
  message.public_profile = db.tobool(message.public_profile)
  if message.user_avatar_path and message.user_avatar_path ~= cjson.null then
    message.user_avatar_path = request_origin(req) .. "/api/users/" .. message.sender_id .. "/avatar"
  else
    message.user_avatar_path = nil
  end

  local other_members = db.fetchall(
    "SELECT user_id FROM message_group_members WHERE group_id=%s AND user_id != %s",
    tostring(group_id), user.id
  )
  for _, m in ipairs(other_members) do
    create_notification(m.user_id, user.id, "message", nil, cleaned)
  end

  return 200, { message = message }
end

-- ---------------------------------------------------------------------------
-- Collections. Mirrors app/routers/collections.py + the collection-related
-- half of app/db/feed_collections.py (following_feed/liked_media/saved
-- searches are a different router's territory and NOT covered here).
-- ---------------------------------------------------------------------------

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
               m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color,
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
        GROUP BY m.id, mci.added_at, c.name, c.slug, sc.name, sc.slug, u.username, u.display_name,
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
-- Public profiles, follows, friend requests/friends, user search, blocks.
-- Mirrors app/routers/social.py + app/db/social.py (recovered from git
-- history: 9986ab5^:app/routers/social.py and app/db/social.py). Previously
-- missing entirely from the Lua rewrite -- discovered live-404ing on
-- /api/users/search, /api/users/:username(/profile), followers/following/
-- friends, friend-request/block, breaking profile pages, search, and
-- follow/friend flows for both the web app and iOS.
-- ---------------------------------------------------------------------------

-- Mirrors app/db/social.py's friend_status(): "self" | "friends" |
-- "pending_out" | "pending_in" | "none".
local function friend_status(viewer_id, user_id)
  if not viewer_id then return "none" end
  if tostring(viewer_id) == tostring(user_id) then return "self" end
  local row = db.fetchone(
    [[
      SELECT requester_id, addressee_id, status
      FROM friend_requests
      WHERE (requester_id=%s AND addressee_id=%s) OR (requester_id=%s AND addressee_id=%s)
      ORDER BY CASE status
        WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5
      END, created_at DESC
      LIMIT 1
    ]],
    tostring(viewer_id), tostring(user_id), tostring(user_id), tostring(viewer_id)
  )
  if not row or row.status == "declined" or row.status == "cancelled" then return "none" end
  if row.status == "accepted" then return "friends" end
  return tostring(row.requester_id) == tostring(viewer_id) and "pending_out" or "pending_in"
end

function M.search_users(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local viewer0 = tostring(viewer_id or 0)
  local q = trim(nn(req.query.q) or ""):gsub("%s+", " "):sub(1, 80)
  local limit = bounded_limit(req.query.limit, 30, 60)
  local needle = "%" .. q:gsub("([%%_])", "\\%1") .. "%"
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.show_liked_count, u.show_collections,
             u.show_recent_uploads, u.show_friends, u.adult_content_consent, u.email_verified_at,
             u.last_seen_at,
             COUNT(DISTINCT m.id) AS media_count,
             COUNT(DISTINCT f.follower_id) AS follower_count,
             MAX(CASE WHEN mine.follower_id IS NULL THEN 0 ELSE 1 END) AS followed_by_me
      FROM users u
      LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND m.visibility='public'
      LEFT JOIN user_follows f ON f.followed_id=u.id
      LEFT JOIN user_follows mine ON mine.followed_id=u.id AND mine.follower_id::text=%s
      WHERE %s = ''
         OR u.username ILIKE %s
         OR (CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE NULL END) ILIKE %s
         OR (CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END) ILIKE %s
         OR (CASE WHEN u.public_profile OR u.id::text=%s THEN u.profile_headline ELSE NULL END) ILIKE %s
      GROUP BY u.id
      ORDER BY (u.username=%s) DESC, follower_count DESC, media_count DESC, u.created_at DESC
      LIMIT %s
    ]],
    viewer0, viewer0, viewer0, viewer0, viewer0, q, needle, viewer0, needle, viewer0, needle, viewer0, needle,
    q, tostring(limit)
  )
  -- Batch friend_status lookups: previously one db.fetchone() per result row
  -- (N+1). Fetch every friend_requests row touching the viewer and any result
  -- user in a single query, then resolve status per-user in Lua.
  local statuses = {}
  if viewer_id and #rows > 0 then
    local placeholders = {}
    local ids = {}
    for i, row in ipairs(rows) do
      placeholders[i] = "%s"
      ids[i] = tostring(row.id)
    end
    local in_list = table.concat(placeholders, ", ")
    -- Build one flat params table and unpack() it exactly once, in the
    -- tail position: Lua only expands unpack()/a multi-value expression
    -- to multiple values when it's the LAST argument in a call -- every
    -- earlier occurrence silently truncates to its first element. Calling
    -- unpack(ids) twice in the same db.fetchall(...) argument list (as
    -- this did before) meant the first occurrence collapsed to a single
    -- value, so db.fetchall got 7 params for a 10-placeholder query and
    -- pg.lua's string.format() blew up with "bad argument #8" -- confirmed
    -- live via /api/users/search for any authenticated viewer with at
    -- least one result, i.e. this broke user search for every logged-in
    -- user, silently (never caught before since no prior testing had a
    -- real session to reach this branch).
    local fr_params = { viewer0 }
    for _, id in ipairs(ids) do fr_params[#fr_params + 1] = id end
    fr_params[#fr_params + 1] = viewer0
    for _, id in ipairs(ids) do fr_params[#fr_params + 1] = id end
    local fr_rows = db.fetchall(
      string.format(
        [[
          SELECT requester_id, addressee_id, status
          FROM friend_requests
          WHERE (requester_id=%%s AND addressee_id IN (%s)) OR (addressee_id=%%s AND requester_id IN (%s))
          ORDER BY CASE status
            WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5
          END, created_at DESC
        ]],
        in_list, in_list
      ),
      unpack(fr_params)
    )
    for _, fr in ipairs(fr_rows) do
      local other_id = tostring(fr.requester_id) == viewer0 and tostring(fr.addressee_id) or tostring(fr.requester_id)
      -- Rows are already ordered by priority/recency, same as the old
      -- per-pair LIMIT 1 query -- keep only the first (best) row per user.
      if not statuses[other_id] then
        if fr.status == "declined" or fr.status == "cancelled" then
          statuses[other_id] = "none"
        elseif fr.status == "accepted" then
          statuses[other_id] = "friends"
        else
          statuses[other_id] = tostring(fr.requester_id) == viewer0 and "pending_out" or "pending_in"
        end
      end
    end
  end
  for _, row in ipairs(rows) do
    decode_user(row)
    row.media_count = db.toint(row.media_count, 0)
    row.follower_count = db.toint(row.follower_count, 0)
    row.followed_by_me = db.tobool(row.followed_by_me)
    if not viewer_id then
      row.friend_status = "none"
    elseif tostring(viewer_id) == tostring(row.id) then
      row.friend_status = "self"
    else
      row.friend_status = statuses[tostring(row.id)] or "none"
    end
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows), limit = limit }
end

-- NOT routes.lua's normalize_username() (that one lowercases, for
-- register/login only -- see its own comment). Mirrors app/db/_shared.py's
-- normalize_username(), which only trims: usernames are matched exactly as
-- stored, case-sensitively. Lua-registered accounts are always lowercase
-- already (register() lowercases at insert time), but accounts created
-- before that -- or migrated from the old MySQL DB -- can have mixed-case
-- usernames, so forcibly lowercasing the URL param here would 404 real
-- profiles like the site owner's own "HeavenlyXenusVR".
local function trimmed_username(u)
  return trim(u or ""):sub(1, 40)
end

local function get_public_profile(req, username, viewer_id)
  local viewer0 = tostring(viewer_id or 0)
  local row = db.fetchone(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.profile_headline ELSE NULL END AS profile_headline,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.featured_tags ELSE NULL END AS featured_tags,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.website_url ELSE NULL END AS website_url,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.location_label ELSE NULL END AS location_label,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.user_settings ELSE NULL END AS user_settings,
             u.avatar_file_id, u.profile_color, u.public_profile, u.show_liked_count,
             u.show_collections, u.show_recent_uploads, u.show_friends, u.created_at, u.last_seen_at,
             u.discord_verified_at, u.discord_username,
             u.user_settings::jsonb->>'profile_show_follow_counts' AS show_follow_counts_raw,
             u.user_settings::jsonb->>'profile_show_joined_date' AS show_joined_date_raw,
             COUNT(DISTINCT m.id) AS media_count,
             COALESCE(SUM(CASE WHEN m.deleted_at IS NULL AND m.visibility='public' THEN m.downloads ELSE 0 END), 0) AS download_count,
             COUNT(DISTINCT (ml.user_id, ml.media_id)) AS like_count,
             COUNT(DISTINCT f1.follower_id) AS follower_count,
             COUNT(DISTINCT f2.followed_id) AS following_count,
             COUNT(DISTINCT CASE WHEN fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id) THEN fr.id END) AS friend_count,
             MAX(CASE WHEN f3.follower_id::text=%s THEN 1 ELSE 0 END) AS followed_by_me,
             (now() - u.last_seen_at) <= interval '180 seconds' AS is_online
      FROM users u
      LEFT JOIN media_items m ON m.user_id=u.id AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=%s)
      LEFT JOIN media_likes ml ON ml.media_id=m.id
      LEFT JOIN user_follows f1 ON f1.followed_id=u.id
      LEFT JOIN user_follows f2 ON f2.follower_id=u.id
      LEFT JOIN user_follows f3 ON f3.followed_id=u.id AND f3.follower_id::text=%s
      LEFT JOIN friend_requests fr ON fr.status='accepted' AND (fr.requester_id=u.id OR fr.addressee_id=u.id)
      WHERE u.username=%s
      GROUP BY u.id
    ]],
    viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0, viewer0,
    trimmed_username(username)
  )
  if not row then return nil end
  decode_user(row)
  row.media_count = db.toint(row.media_count, 0)
  row.download_count = db.toint(row.download_count, 0)
  row.like_count = db.toint(row.like_count, 0)
  row.follower_count = db.toint(row.follower_count, 0)
  row.following_count = db.toint(row.following_count, 0)
  row.friend_count = db.toint(row.friend_count, 0)
  row.followed_by_me = db.tobool(row.followed_by_me)
  row.is_online = db.tobool(row.is_online)
  row.friend_status = viewer_id and friend_status(viewer_id, row.id) or "none"

  -- Privacy toggles that were stored/editable (Settings page) but never
  -- actually gated anything server-side -- confirmed via grep, same class
  -- of bug as mute's: show_liked_count, profile_show_follow_counts, and
  -- profile_show_joined_date all existed purely as inert form fields.
  -- like_count/follower_count/following_count/created_at were always
  -- computed and returned regardless, so turning the toggle off only ever
  -- hid the number client-side -- the real value was still sitting in the
  -- API response for anyone to read directly.
  local is_owner = viewer_id and tostring(viewer_id) == tostring(row.id)
  if not is_owner then
    if not db.tobool(row.show_liked_count) then row.like_count = nil end
    if row.show_follow_counts_raw == "false" then
      row.follower_count = nil
      row.following_count = nil
    end
    if row.show_joined_date_raw == "false" then row.created_at = nil end
    -- show_friends already gated the friends LIST (M.profile_page's
    -- list_profile_friends call), but not this raw count -- same partial-
    -- leak pattern as the three fields above, just missed in that pass
    -- since it's driven by an existing column rather than a settings-blob
    -- lookup.
    if not db.tobool(row.show_friends) then row.friend_count = nil end
  end
  row.show_follow_counts_raw = nil
  row.show_joined_date_raw = nil
  return row
end

function M.public_profile(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local profile = get_public_profile(req, req.params.username, viewer_id)
  if not profile then return 404, { detail = "User not found." } end
  if viewer_id and is_blocked_either_way(viewer_id, profile.id) then
    return 404, { detail = "User not found." }
  end
  return 200, { user = with_user_urls(req, profile) }
end

local function list_profile_media(req, target_id, viewer_id, viewer_can_open_adult, limit)
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT m.id, m.user_id, m.category_id, m.subcategory_id, m.title, m.description, m.tags,
             m.media_kind, m.mime_type, m.original_filename, m.storage_path, m.file_size,
             m.views, m.downloads, m.created_at, m.updated_at, m.visibility,
             m.comments_enabled, m.downloads_enabled, m.pinned_at, m.is_adult,
             m.adult_marked_by_user, m.adult_marked_by_ai, m.moderation_status, m.dominant_color,
             c.name AS category_name, c.slug AS category_slug,
             sc.name AS subcategory_name, sc.slug AS subcategory_slug,
             u.username, u.display_name, u.profile_color, u.public_profile,
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
      WHERE m.user_id=%s AND m.deleted_at IS NULL AND (m.visibility='public' OR m.user_id::text=%s)
      GROUP BY m.id, c.name, c.slug, sc.name, sc.slug, u.username, u.display_name, u.profile_color, u.public_profile
      ORDER BY m.pinned_at DESC NULLS LAST, m.created_at DESC
      LIMIT %s
    ]],
    viewer0, viewer0, tostring(target_id), viewer0, tostring(limit)
  )
  attach_media_subcategories(rows)
  for _, row in ipairs(rows) do decode_media_row(row, viewer_can_open_adult, req) end
  return rows
end

local function list_profile_collections(req, target_id, viewer_id, adult_allowed, limit)
  local v = tostring(viewer_id or 0)
  local rows = db.fetchall(
    COLLECTION_SELECT .. [[
      WHERE mc.user_id=%s AND (mc.is_public OR mc.user_id=%s)
      GROUP BY mc.id, u.id
      ORDER BY mc.updated_at DESC, mc.created_at DESC
      LIMIT %s
    ]],
    v, v, tostring(target_id), v, tostring(limit)
  )
  for _, row in ipairs(rows) do
    decode_collection(row)
    with_collection_urls(req, row, adult_allowed)
  end
  return rows
end

local function list_profile_friends(user_id, viewer_id, limit)
  -- Must tostring() here (not just `viewer_id or "0"`): callers pass a mix
  -- of already-string ids (from auth_optional()) and raw numbers (from
  -- decode_user()'s current_user()/get_public_profile() results, e.g.
  -- my_friends() passing user.id twice) -- a bare Lua number bound against
  -- this query's "::text=%s" comparisons makes Postgres error with
  -- "operator does not exist: text = integer", which db.fetchall()
  -- swallows and returns as an empty list, not a visible error.
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.last_seen_at, fr.responded_at AS friended_at
      FROM friend_requests fr
      JOIN users u ON u.id = CASE WHEN fr.requester_id::text=%s THEN fr.addressee_id ELSE fr.requester_id END
      WHERE fr.status='accepted' AND (fr.requester_id::text=%s OR fr.addressee_id::text=%s)
      ORDER BY fr.responded_at DESC, fr.created_at DESC
      LIMIT %s
    ]],
    viewer0, viewer0, viewer0, tostring(user_id), tostring(user_id), tostring(user_id), tostring(limit)
  )
  for _, row in ipairs(rows) do decode_user(row) end
  return rows
end

function M.profile_page(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local profile = get_public_profile(req, req.params.username, viewer_id)
  if not profile then return 404, { detail = "User not found." } end
  if viewer_id and is_blocked_either_way(viewer_id, profile.id) then
    return 404, { detail = "User not found." }
  end
  local adult_allowed = viewer_adult_allowed(viewer_id)
  local is_owner = viewer_id and tostring(viewer_id) == tostring(profile.id)
  local settings = profile.user_settings or {}
  local show_uploads = is_owner or (settings.profile_show_uploads ~= nil and settings.profile_show_uploads or profile.show_recent_uploads)
  local show_collections = is_owner or (settings.profile_show_collections ~= nil and settings.profile_show_collections or profile.show_collections)
  local show_friends = is_owner or (settings.profile_show_friends ~= nil and settings.profile_show_friends or profile.show_friends)
  local media = show_uploads and list_profile_media(req, profile.id, viewer_id, adult_allowed, 36) or {}
  local collections = show_collections and list_profile_collections(req, profile.id, viewer_id, adult_allowed, 12) or {}
  local friends = show_friends and list_profile_friends(profile.id, viewer_id, 18) or {}
  return 200, {
    user = with_user_urls(req, profile),
    media = arr(media),
    collections = arr(collections),
    friends = arr(friends),
  }
end

function M.follow_user(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local followed_id = tonumber(req.params.user_id)
  if not followed_id then return 404, { detail = "User not found." } end
  local payload = json_body(req)
  local following = db.tobool(payload.following)
  if tostring(user.id) == tostring(followed_id) then
    return 400, { detail = "You cannot follow yourself." }
  end
  if following and is_blocked_either_way(user.id, followed_id) then
    return 403, { detail = "You cannot follow this user." }
  end
  local exists = db.fetchone("SELECT id FROM users WHERE id=%s", tostring(followed_id))
  if not exists then return 404, { detail = "User not found." } end
  if following then
    db.execute("INSERT INTO user_follows (follower_id, followed_id) VALUES (%s, %s) ON CONFLICT (follower_id, followed_id) DO NOTHING", tostring(user.id), tostring(followed_id))
  else
    db.execute("DELETE FROM user_follows WHERE follower_id=%s AND followed_id=%s", tostring(user.id), tostring(followed_id))
  end
  local count_row = db.fetchone("SELECT COUNT(*) AS n FROM user_follows WHERE followed_id=%s", tostring(followed_id))
  if following then create_notification(followed_id, user.id, "follow") end
  return 200, { followed_id = followed_id, following = following, follower_count = db.toint(count_row and count_row.n, 0) }
end

function M.send_friend_request(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local addressee_id = tonumber(req.params.user_id)
  if not addressee_id then return 404, { detail = "User not found." } end
  if tostring(user.id) == tostring(addressee_id) then
    return 400, { detail = "You cannot friend yourself." }
  end
  if is_blocked_either_way(user.id, addressee_id) then
    return 403, { detail = "You cannot send a friend request to this user." }
  end
  local exists = db.fetchone("SELECT id FROM users WHERE id=%s", tostring(addressee_id))
  if not exists then return 400, { detail = "User not found." } end

  local existing = db.fetchone(
    [[
      SELECT * FROM friend_requests
      WHERE (requester_id=%s AND addressee_id=%s) OR (requester_id=%s AND addressee_id=%s)
      ORDER BY CASE status
        WHEN 'accepted' THEN 1 WHEN 'pending' THEN 2 WHEN 'declined' THEN 3 WHEN 'cancelled' THEN 4 ELSE 5
      END, created_at DESC
      LIMIT 1
    ]],
    tostring(user.id), tostring(addressee_id), tostring(addressee_id), tostring(user.id)
  )
  local result_status, request_row
  if existing and existing.status == "accepted" then
    result_status, request_row = "friends", existing
  elseif existing and existing.status == "pending" then
    if tostring(existing.requester_id) == tostring(addressee_id) then
      db.execute("UPDATE friend_requests SET status='accepted', responded_at=CURRENT_TIMESTAMP WHERE id=%s", tostring(existing.id))
      existing.status = "accepted"
      result_status, request_row = "friends", existing
    else
      result_status, request_row = "pending_out", existing
    end
  elseif existing then
    db.execute(
      "UPDATE friend_requests SET requester_id=%s, addressee_id=%s, status='pending', created_at=CURRENT_TIMESTAMP, responded_at=NULL WHERE id=%s",
      tostring(user.id), tostring(addressee_id), tostring(existing.id)
    )
    result_status = "pending_out"
    request_row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s", tostring(existing.id))
  else
    local inserted = db.fetchone(
      "INSERT INTO friend_requests (requester_id, addressee_id) VALUES (%s, %s) RETURNING id",
      tostring(user.id), tostring(addressee_id)
    )
    result_status = "pending_out"
    request_row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s", tostring(inserted.id))
  end
  if request_row then
    request_row.id = db.toint(request_row.id, request_row.id)
    request_row.requester_id = db.toint(request_row.requester_id, request_row.requester_id)
    request_row.addressee_id = db.toint(request_row.addressee_id, request_row.addressee_id)
  end
  create_notification(addressee_id, user.id, "friend_request")
  return 200, { status = result_status, request = request_row }
end

local function decode_friend_request_row(row)
  row.id = db.toint(row.id, row.id)
  row.requester_id = db.toint(row.requester_id, row.requester_id)
  row.addressee_id = db.toint(row.addressee_id, row.addressee_id)
  row.user_id = db.toint(row.user_id, row.user_id)
  row.public_profile = db.tobool(row.public_profile)
  row.is_online = db.tobool(row.is_online)
  local user = {
    id = row.user_id, username = row.username, display_name = row.display_name,
    bio = row.bio, avatar_path = row.avatar_path, profile_color = row.profile_color,
    public_profile = row.public_profile, last_seen_at = row.last_seen_at,
  }
  row.user = user
  return row
end

function M.friend_requests_list(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local function fetch(own_col, other_col)
    local rows = db.fetchall(
      string.format(
        [[
          SELECT fr.*, u.id AS user_id, u.username, u.display_name, u.bio, u.avatar_path,
                 u.profile_color, u.public_profile, u.last_seen_at
          FROM friend_requests fr
          JOIN users u ON u.id=fr.%s
          WHERE fr.%s=%%s AND fr.status='pending'
          ORDER BY fr.created_at DESC
          LIMIT 100
        ]],
        other_col, own_col
      ),
      tostring(user.id)
    )
    for _, row in ipairs(rows) do
      decode_friend_request_row(row)
      with_user_urls(req, row.user)
    end
    return rows
  end
  return 200, {
    incoming = arr(fetch("addressee_id", "requester_id")),
    outgoing = arr(fetch("requester_id", "addressee_id")),
  }
end

function M.respond_friend_request(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local request_id = tonumber(req.params.request_id)
  if not request_id then return 404, { detail = "Friend request not found." } end
  local payload = json_body(req)
  local action = nn(payload.action)
  local next_status = ({ accept = "accepted", decline = "declined", cancel = "cancelled" })[action or ""]
  if not next_status then return 400, { detail = "Action must be accept, decline, or cancel." } end

  local row
  if action == "cancel" then
    row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s AND requester_id=%s AND status='pending'", tostring(request_id), tostring(user.id))
  else
    row = db.fetchone("SELECT * FROM friend_requests WHERE id=%s AND addressee_id=%s AND status='pending'", tostring(request_id), tostring(user.id))
  end
  if not row then return 404, { detail = "Friend request not found." } end
  db.execute("UPDATE friend_requests SET status=%s, responded_at=CURRENT_TIMESTAMP WHERE id=%s", next_status, tostring(request_id))
  row.status = next_status
  row.id = db.toint(row.id, row.id)
  row.requester_id = db.toint(row.requester_id, row.requester_id)
  row.addressee_id = db.toint(row.addressee_id, row.addressee_id)
  if next_status == "accepted" then
    create_notification(row.requester_id, user.id, "friend_accept")
  end
  return 200, { request = row }
end

function M.my_friends(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local friends = list_profile_friends(user.id, user.id, 80)
  for _, row in ipairs(friends) do with_user_urls(req, row) end
  return 200, { friends = arr(friends) }
end

function M.user_followers(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.last_seen_at
      FROM user_follows f
      JOIN users u ON u.id = f.follower_id
      WHERE f.followed_id=%s
      ORDER BY f.created_at DESC
      LIMIT 200
    ]],
    viewer0, viewer0, viewer0, tostring(user_id)
  )
  for _, row in ipairs(rows) do
    decode_user(row)
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows) }
end

function M.user_following(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local viewer0 = tostring(viewer_id or 0)
  local rows = db.fetchall(
    [[
      SELECT u.id, u.username,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.display_name ELSE u.username END AS display_name,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.bio ELSE NULL END AS bio,
             CASE WHEN u.public_profile OR u.id::text=%s THEN u.avatar_path ELSE NULL END AS avatar_path,
             u.profile_color, u.public_profile, u.last_seen_at
      FROM user_follows f
      JOIN users u ON u.id = f.followed_id
      WHERE f.follower_id=%s
      ORDER BY f.created_at DESC
      LIMIT 200
    ]],
    viewer0, viewer0, viewer0, tostring(user_id)
  )
  for _, row in ipairs(rows) do
    decode_user(row)
    with_user_urls(req, row)
  end
  return 200, { users = arr(rows) }
end

function M.user_friends(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local user_id = tonumber(req.params.user_id)
  if not user_id then return 404, { detail = "User not found." } end
  local friends = list_profile_friends(user_id, viewer_id, 80)
  for _, row in ipairs(friends) do with_user_urls(req, row) end
  return 200, { friends = arr(friends) }
end

function M.block_user(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local target_id = tonumber(req.params.user_id)
  if not target_id then return 404, { detail = "User not found." } end
  local payload = json_body(req)
  local kind = nn(payload.kind)
  if kind ~= "block" and kind ~= "mute" then return 400, { detail = "kind must be block or mute." } end
  if tostring(user.id) == tostring(target_id) then
    return 400, { detail = "You cannot block or mute yourself." }
  end
  local exists = db.fetchone("SELECT id FROM users WHERE id=%s", tostring(target_id))
  if not exists then return 400, { detail = "User not found." } end
  local active = db.tobool(payload.active)
  if active then
    db.execute(
      "INSERT INTO user_blocks (blocker_id, blocked_id, kind) VALUES (%s, %s, %s) ON CONFLICT (blocker_id, blocked_id, kind) DO NOTHING",
      tostring(user.id), tostring(target_id), kind
    )
  else
    db.execute("DELETE FROM user_blocks WHERE blocker_id=%s AND blocked_id=%s AND kind=%s", tostring(user.id), tostring(target_id), kind)
  end
  return 200, { blocked_id = target_id, kind = kind, active = active }
end

function M.my_blocks(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local rows = db.fetchall(
    [[
      SELECT ub.kind, ub.created_at, u.id, u.username, u.display_name, u.avatar_path, u.profile_color
      FROM user_blocks ub
      JOIN users u ON u.id = ub.blocked_id
      WHERE ub.blocker_id=%s
      ORDER BY ub.created_at DESC
    ]],
    tostring(user.id)
  )
  local blocks = {}
  for _, row in ipairs(rows) do
    local kind = row.kind
    local created_at = row.created_at
    row.kind, row.created_at = nil, nil
    decode_user(row)
    with_user_urls(req, row)
    blocks[#blocks + 1] = { kind = kind, created_at = created_at, user = row }
  end
  return 200, { blocks = arr(blocks) }
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
-- Exported for pages_admin.lua's server-rendered dashboard, which needs the
-- exact same "logged in AND verified site owner" check the JSON API
-- endpoints below use, but renders an HTML page/redirect on failure instead
-- of a JSON error body.
M.require_site_owner_for_page = require_site_owner

local function write_audit_log(actor_id, action, target_type, target_id, detail)
  detail = detail and tostring(detail):sub(1, 500) or nil
  if detail == "" then detail = nil end
  db.execute(
    "INSERT INTO moderation_audit_log (actor_id, action, target_type, target_id, detail) VALUES (%s, %s, %s, %s, %s)",
    actor_id and tostring(actor_id) or nil, tostring(action):sub(1, 60), tostring(target_type):sub(1, 30),
    target_id and tostring(target_id) or nil, detail
  )
end

-- ---------------------------------------------------------------------------
-- Background music (see scripts/pg_add_background_music.sql). Up to
-- MAX_BACKGROUND_MUSIC_TRACKS tracks the site owner injects/removes from
-- the admin panel; every visitor's client shuffles through whatever's
-- currently uploaded while browsing (M.list_background_music /
-- M.serve_background_music_file, both public/unauthenticated -- ambient
-- music isn't gated content) and ducks it when a video with sound starts
-- playing (client-side, see frontend/src/components/BackgroundMusicPlayer.jsx).
-- ---------------------------------------------------------------------------

local MAX_BACKGROUND_MUSIC_TRACKS = 10
local MAX_BACKGROUND_MUSIC_BYTES = 30 * 1024 * 1024

-- Minimal magic-byte sniffer for the handful of audio containers a track
-- upload realistically arrives as -- mirrors sniff_magic's image/video
-- approach (never trust the client-supplied Content-Type for what gets
-- stored/served back out).
local function sniff_audio_magic(content)
  local head = content:sub(1, 64)
  if head:sub(1, 3) == "ID3" then return "audio/mpeg" end
  -- Frame-sync MP3 with no ID3 tag: 11 set bits (0xFFE.. / 0xFFF..).
  if #head >= 2 and head:byte(1) == 0xFF and (head:byte(2) & 0xE0) == 0xE0 then return "audio/mpeg" end
  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WAVE" then return "audio/wav" end
  if head:sub(1, 4) == "OggS" then return "audio/ogg" end
  if head:sub(1, 4) == "fLaC" then return "audio/flac" end
  if #head >= 12 and head:sub(5, 8) == "ftyp" then
    local brands = head:sub(9, 32):lower()
    if brands:find("m4a", 1, true) or brands:find("m4b", 1, true) then return "audio/mp4" end
  end
  return nil
end

local BACKGROUND_MUSIC_EXT = {
  ["audio/mpeg"] = ".mp3", ["audio/wav"] = ".wav", ["audio/ogg"] = ".ogg",
  ["audio/flac"] = ".flac", ["audio/mp4"] = ".m4a",
}

function M.admin_list_background_music(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local rows = db.fetchall(
    "SELECT bm.id, bm.title, bm.original_filename, bm.mime_type, bm.file_size, bm.sort_order, bm.created_at, " ..
      "u.username AS uploaded_by_username " ..
      "FROM background_music bm LEFT JOIN users u ON u.id = bm.uploaded_by " ..
      "ORDER BY bm.sort_order ASC, bm.id ASC"
  )
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.file_size = db.toint(row.file_size, 0)
    row.url = origin .. "/api/background-music/" .. tostring(row.id) .. "/file"
  end
  return 200, { tracks = arr(rows), max_tracks = MAX_BACKGROUND_MUSIC_TRACKS }
end

function M.admin_upload_background_music(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end

  local count_row = db.fetchone("SELECT COUNT(*) AS n FROM background_music")
  if db.toint(count_row and count_row.n, 0) >= MAX_BACKGROUND_MUSIC_TRACKS then
    return 400, { detail = string.format("Only %d background tracks are allowed at once -- remove one first.", MAX_BACKGROUND_MUSIC_TRACKS) }
  end

  local upload = (req.files or {}).file
  if not upload or not upload.content or upload.content == "" then
    return 400, { detail = "Upload is empty." }
  end
  if #upload.content > MAX_BACKGROUND_MUSIC_BYTES then
    return 413, { detail = string.format("Tracks must be %dMB or smaller.", math.floor(MAX_BACKGROUND_MUSIC_BYTES / (1024 * 1024))) }
  end
  local mime_type = sniff_audio_magic(upload.content)
  if not mime_type then
    return 400, { detail = "Unsupported audio format. Use MP3, WAV, OGG, FLAC, or M4A." }
  end

  local form = req.form or {}
  local original_filename = ((upload.filename or "track"):match("([^/\\]+)$") or "track"):sub(1, 255)
  local title = trim(nn(form.title) or ""):sub(1, 120)
  if title == "" then
    title = (original_filename:gsub(BACKGROUND_MUSIC_EXT[mime_type] and BACKGROUND_MUSIC_EXT[mime_type] .. "$" or "%.[^.]+$", ""))
  end

  local next_sort_row = db.fetchone("SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM background_music")
  local sort_order = db.toint(next_sort_row and next_sort_row.n, 0)

  local row = db.fetchone(
    "INSERT INTO background_music (title, original_filename, mime_type, content, file_size, sort_order, uploaded_by) " ..
      "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
    title, original_filename, mime_type, media_files.bytea_literal(upload.content), tostring(#upload.content), tostring(sort_order), tostring(owner.id)
  )
  write_audit_log(owner.id, "background_music_upload", "background_music", row and row.id, title)
  return 200, { id = row and db.toint(row.id), title = title }
end

function M.admin_delete_background_music(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end
  local track_id = tonumber(req.params.track_id)
  if not track_id then return 404, { detail = "Track not found." } end
  local existing = db.fetchone("SELECT id, title FROM background_music WHERE id=%s", tostring(track_id))
  if not existing then return 404, { detail = "Track not found." } end
  db.execute("DELETE FROM background_music WHERE id=%s", tostring(track_id))
  write_audit_log(owner.id, "background_music_delete", "background_music", track_id, existing.title)
  return 200, { ok = true }
end


-- Public: every visitor's client (logged in or not) fetches this list to
-- build its own local shuffle order -- no auth, no per-track access
-- token, same as the site's public media browsing.
function M.list_background_music(req)
  local rows = db.fetchall(
    "SELECT id, title FROM background_music ORDER BY sort_order ASC, id ASC"
  )
  local origin = request_origin(req)
  for _, row in ipairs(rows) do
    row.id = db.toint(row.id, row.id)
    row.url = origin .. "/api/background-music/" .. tostring(row.id) .. "/file"
  end
  return 200, { tracks = arr(rows) }
end

function M.serve_background_music_file(req)
  local track_id = tonumber(req.params.track_id)
  if not track_id then return 404, { detail = "Track not found." } end
  local row = db.fetchone("SELECT mime_type, content FROM background_music WHERE id=%s", tostring(track_id))
  if not row then return 404, { detail = "Track not found." } end
  return 200, row.content, { ["Content-Type"] = row.mime_type, ["Cache-Control"] = "public, max-age=86400" }
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

local ORPHAN_CACHE_DIR_NAMES = { "_thumb_cache", "_video_cache", "_watermark_cache" }
local ORPHAN_MIN_AGE_SECONDS = 24 * 3600

-- Lua's %q escapes for a *Lua* string literal, not a shell argument -- use
-- real single-quote shell escaping instead (same convention as
-- media_files.lua's own shell_quote(), duplicated here since that one is
-- local to that module).
local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Duplicated from media_files.lua's own local ffmpeg_bin() for the same
-- reason as shell_quote above.
local function ffmpeg_bin()
  return os.getenv("GALLERY_FFMPEG_BIN") or "ffmpeg"
end

-- Pull N random tracks out of an arbitrary playlist URL (YouTube,
-- SoundCloud, anything yt-dlp's extractors cover) and add them as
-- background music. Runs entirely as a detached background job -- even a
-- handful of audio extractions can take minutes total, far past any
-- reasonable request timeout -- so this returns immediately and the admin
-- panel just polls the regular list endpoint to see tracks appear.
--
-- The job never inserts into the DB itself (no bytea/DB code in the bash
-- script -- that's real complexity worth not duplicating). Instead it
-- re-uses M.admin_upload_background_music by curling it over localhost for
-- each downloaded file, authenticated with a short-lived token minted for
-- this job. That gets the exact same validation (audio sniffing, size cap,
-- the MAX_BACKGROUND_MUSIC_TRACKS cap enforced per-insert) for free instead
-- of a second, easier-to-drift-out-of-sync copy of it.
--
-- Never string-interpolates untrusted text (playlist entry titles, etc.)
-- into a shell command: yt-dlp's own output-template sanitizes the title
-- into a filesystem-safe filename, and that's the ONLY place a title ever
-- appears -- curl's `-F file=@path` reads the multipart filename from the
-- path's basename, so no title text is ever concatenated into a command
-- line. The one piece of admin-supplied input (the playlist URL) is passed
-- as a real argv entry to bash (shell_quote'd once, by Lua, to launch the
-- script) and only ever referenced via a quoted shell variable after that,
-- never re-interpolated into another command string.
--
-- Same env-var-with-deployment-specific-fallback convention as
-- ffmpeg_bin()/ffprobe_bin() above: yt-dlp is a `pip install --user` tool
-- living in ~/.local/bin, which is on an interactive shell's PATH but NOT
-- on the systemd --user service's (confirmed live: PATH there is just
-- /usr/local/{s,}bin:/usr/bin:... -- a bare "yt-dlp" in the background
-- script failed with a silently-swallowed "command not found" every time,
-- the actual reason no tracks were ever appearing).
local function ytdlp_bin()
  return os.getenv("GALLERY_YTDLP_BIN") or (os.getenv("HOME") or "/home/proxy") .. "/.local/bin/yt-dlp"
end

function M.admin_import_background_music_playlist(req)
  local owner, status, body = require_site_owner(req)
  if not owner then return status, body end

  local payload = json_body(req)
  local playlist_url = trim(nn(payload.url) or "")
  if playlist_url == "" or not playlist_url:match("^https?://") then
    return 400, { detail = "Enter a valid playlist URL." }
  end

  local count_row = db.fetchone("SELECT COUNT(*) AS n FROM background_music")
  local remaining = MAX_BACKGROUND_MUSIC_TRACKS - db.toint(count_row and count_row.n, 0)
  if remaining <= 0 then
    return 400, { detail = string.format("Only %d background tracks are allowed at once -- remove one first.", MAX_BACKGROUND_MUSIC_TRACKS) }
  end
  local want = math.min(remaining, tonumber(payload.count) or remaining, 10)

  -- 20 minutes -- generous for even a slow multi-track import, but bounded
  -- (not a real login session) since this token only ever needs to live
  -- for the duration of this one background job.
  local internal_token = auth_lib.issue_token(M.settings.session_secret, { id = tostring(owner.id), username = owner.username }, 1200)

  -- No string.format here -- every value the script needs (playlist URL,
  -- track count, token, port, yt-dlp's real path) travels as a real bash
  -- argv entry ($1-$5), not interpolated into this template, so yt-dlp's
  -- own %(...)s output-template syntax can be written plainly instead of
  -- %%-escaped for a formatter that never runs over this string.
  local script = [[
#!/usr/bin/env bash
set -uo pipefail
PLAYLIST_URL="$1"
NEED="$2"
TOKEN="$3"
PORT="$4"
YTDLP="$5"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

"$YTDLP" --flat-playlist --print "%(webpage_url)s" "$PLAYLIST_URL" > "$TMPDIR/urls.txt" 2>/dev/null
shuf "$TMPDIR/urls.txt" | head -n "$NEED" > "$TMPDIR/picked.txt"

while IFS= read -r vurl; do
  [ -z "$vurl" ] && continue
  OUTDIR="$(mktemp -d)"
  timeout 180 nice -n 15 ionice -c2 -n6 "$YTDLP" -x --audio-format mp3 --audio-quality 5 \
    --no-playlist --match-filter "duration<900" \
    -o "$OUTDIR/%(title).100B.%(ext)s" "$vurl" >/dev/null 2>&1
  FILE="$(ls "$OUTDIR"/*.mp3 2>/dev/null | head -n1)"
  if [ -n "$FILE" ]; then
    curl -s -o /dev/null --max-time 60 -H "Authorization: Bearer $TOKEN" \
      -F "file=@$FILE;type=audio/mpeg" "http://127.0.0.1:$PORT/api/admin/background-music"
  fi
  rm -rf "$OUTDIR"
done < "$TMPDIR/picked.txt"
]]

  local script_path = os.tmpname() .. ".sh"
  local sf = assert(io.open(script_path, "wb"))
  sf:write(script)
  sf:close()

  local cmd = string.format(
    "( bash %s %s %s %s %s %s; rm -f %s ) </dev/null >/dev/null 2>&1 &",
    shell_quote(script_path), shell_quote(playlist_url), shell_quote(tostring(want)),
    shell_quote(internal_token), shell_quote(tostring(M.settings.port)), shell_quote(ytdlp_bin()),
    shell_quote(script_path)
  )
  os.execute(cmd)

  write_audit_log(owner.id, "background_music_playlist_import", "background_music", nil, playlist_url:sub(1, 200))
  return 202, { status = "importing", requested = want }
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
    -- NOT `cond and nil or false` -- that Lua ternary idiom breaks whenever
    -- the "true" branch value is itself nil/false (nil is falsy, so `or`
    -- always falls through to the third operand regardless of `cond`).
    -- Confirmed live: this previously reported "unreachable, no API key
    -- configured" unconditionally, even with gemini_key_configured=true.
    if M.settings.ai_api_key ~= "" then
      vision.reachable = nil
      vision.reason = nil
    else
      vision.reachable = false
      vision.reason = "Gemini provider is selected but no Gemini API key is configured."
    end
  elseif provider == "ollama" then
    local base_url = tostring(M.settings.ai_ollama_base_url or "http://127.0.0.1:11434"):gsub("/+$", "")
    -- copas.http, not socket.http directly -- see telegram.lua's api_call
    -- comment for why a blocking HTTP call here would stall every other
    -- in-flight request on this single-threaded server.
    local ok, http = pcall(require, "copas.http")
    local ok2, result = pcall(function()
      local ltn12 = require("ltn12")
      local chunks = {}
      local _, code = http.request({ url = base_url .. "/api/tags", sink = ltn12.sink.table(chunks), timeout = 3 })
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
-- AI training-example write path (POST /api/media/:media_id/ai/train).
-- Mirrors app/db/ai_vision.py's record_ai_vision_training_example() and
-- app/routers/media.py's train_media_ai(). NOTE: the dedupe_key here is NOT
-- byte-identical to Python's sha256(json.dumps(payload, sort_keys=True)) --
-- cjson has no whitespace/key-order mode matching Python's json.dumps
-- exactly, and this key is only used for this backend's own upsert-by-key
-- lookups going forward (Python is being retired), so internal consistency
-- is what matters, not cross-backend hash equality with rows Python wrote
-- previously (worst case: an occasional duplicate row instead of a perfect
-- upsert onto a pre-cutover Python-written example).
-- ---------------------------------------------------------------------------

local function ai_training_dedupe_key(payload)
  local ordered = table.concat({
    tostring(payload.user_id), tostring(payload.media_id or ""), tostring(payload.original_filename or ""),
    tostring(payload.corrected_title or ""), tostring(payload.corrected_category_name or ""),
    tostring(payload.corrected_subcategory_name or ""), table.concat(payload.corrected_tags or {}, ","),
    tostring(payload.image_phash or ""), tostring(payload.image_dhash or ""),
  }, "|")
  return sodium.sodium_bin2hex(sodium.crypto_hash_sha256(ordered))
end

-- Mirrors _clean_tags(): dedup, alnum/._- only, max 12, 32 chars each.
local function clean_ai_tags(values)
  local iterable = {}
  if type(values) == "string" then
    for tok in values:gmatch("[^,#%s]+") do iterable[#iterable + 1] = tok end
  elseif type(values) == "table" then
    iterable = values
  end
  local clean, seen = {}, {}
  for _, raw in ipairs(iterable) do
    local tag = tostring(raw):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[^%w_.%-]+", ""):sub(1, 32)
    local lowered = tag:lower()
    if tag ~= "" and not seen[lowered] then
      seen[lowered] = true
      clean[#clean + 1] = tag
      if #clean >= 12 then break end
    end
  end
  return clean
end

-- Returns (example) on success, or (nil, "forbidden"|"not_found"|error_string).
local function record_ai_training_example(user_id, media_id, source, corrected, notes)
  local title = clean_text(nn(corrected.title) or nn(corrected.corrected_title), 160)
  if title == "" then return nil, "Title is required." end
  local category_name = clean_text(nn(corrected.category_name) or nn(corrected.corrected_category_name), 80)
  if category_name == "" then category_name = nil end
  local subcategory_name = clean_text(nn(corrected.subcategory_name) or nn(corrected.corrected_subcategory_name), 80)
  if subcategory_name == "" then subcategory_name = nil end
  local corrected_tags = clean_ai_tags(corrected.tags or corrected.corrected_tags or {})
  local source_tags = clean_ai_tags(source.tags or source.source_tags or {})

  if media_id then
    local row = db.fetchone("SELECT id, user_id FROM media_items WHERE id=%s AND deleted_at IS NULL", tostring(media_id))
    if not row then return nil, "not_found" end
    if tostring(row.user_id) ~= tostring(user_id) then return nil, "forbidden" end
  end

  local original_filename = clean_text(source.original_filename, 255)
  if original_filename == "" then original_filename = nil end
  local source_title = clean_text(source.title, 160)
  if source_title == "" then source_title = nil end
  local source_category_name = clean_text(source.category_name, 80)
  if source_category_name == "" then source_category_name = nil end
  local source_subcategory_name = clean_text(source.subcategory_name, 80)
  if source_subcategory_name == "" then source_subcategory_name = nil end
  local notes_text = clean_text(notes, 500)
  if notes_text == "" then notes_text = nil end
  local image_phash = nn(source.image_phash) or nn(source.source_image_phash)
  local image_dhash = nn(source.image_dhash) or nn(source.source_image_dhash)
  local image_width = tonumber(source.image_width)
  local image_height = tonumber(source.image_height)
  local training_origin = clean_text(nn(source.training_origin) or nn(source.origin), 80)
  if training_origin == "" then training_origin = nil end
  local training_confidence = math.max(0.0, math.min(tonumber(source.training_confidence or corrected.training_confidence) or 0.72, 1.0))
  local corrected_is_adult = (corrected.is_adult or corrected.corrected_is_adult) and true or false

  local dedupe_key = ai_training_dedupe_key({
    user_id = user_id, media_id = media_id, original_filename = original_filename,
    corrected_title = title, corrected_category_name = category_name,
    corrected_subcategory_name = subcategory_name, corrected_tags = corrected_tags,
    image_phash = image_phash, image_dhash = image_dhash,
  })

  local existing = db.fetchone("SELECT id FROM ai_vision_training_examples WHERE dedupe_key=%s LIMIT 1", dedupe_key)
  local training_id
  if existing then
    training_id = db.toint(existing.id, existing.id)
    db.execute([[
      UPDATE ai_vision_training_examples
      SET source_title=COALESCE(%s, source_title),
          source_category_name=COALESCE(%s, source_category_name),
          source_subcategory_name=COALESCE(%s, source_subcategory_name),
          source_tags=%s,
          corrected_title=%s,
          corrected_category_name=COALESCE(%s, corrected_category_name),
          corrected_subcategory_name=COALESCE(%s, corrected_subcategory_name),
          corrected_tags=%s,
          corrected_is_adult=%s,
          notes=COALESCE(%s, notes),
          original_filename=COALESCE(%s, original_filename),
          image_phash=COALESCE(%s, image_phash),
          image_dhash=COALESCE(%s, image_dhash),
          image_width=COALESCE(%s, image_width),
          image_height=COALESCE(%s, image_height),
          training_origin=COALESCE(%s, training_origin),
          training_confidence=GREATEST(training_confidence, %s)
      WHERE id=%s
    ]],
      source_title, source_category_name, source_subcategory_name, cjson.encode(arr(source_tags)),
      title, category_name, subcategory_name, cjson.encode(arr(corrected_tags)),
      corrected_is_adult, notes_text, original_filename, image_phash, image_dhash,
      image_width and tostring(image_width) or nil, image_height and tostring(image_height) or nil,
      training_origin, tostring(training_confidence), tostring(training_id)
    )
  else
    local row, err = db.fetchone([[
      INSERT INTO ai_vision_training_examples
        (user_id, media_id, original_filename, source_title, source_category_name, source_subcategory_name,
         source_tags, corrected_title, corrected_category_name, corrected_subcategory_name, corrected_tags,
         corrected_is_adult, notes, dedupe_key, image_phash, image_dhash, image_width, image_height, training_origin, training_confidence)
      VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
      RETURNING id
    ]],
      tostring(user_id), media_id and tostring(media_id) or nil, original_filename, source_title,
      source_category_name, source_subcategory_name, cjson.encode(arr(source_tags)),
      title, category_name, subcategory_name, cjson.encode(arr(corrected_tags)),
      corrected_is_adult, notes_text, dedupe_key, image_phash, image_dhash,
      image_width and tostring(image_width) or nil, image_height and tostring(image_height) or nil,
      training_origin, tostring(training_confidence)
    )
    if not row then return nil, "Could not save training example: " .. tostring(err) end
    training_id = db.toint(row.id, row.id)
  end

  local result = db.fetchone("SELECT * FROM ai_vision_training_examples WHERE id=%s", tostring(training_id))
  return decode_ai_training_example(result)
end

function M.train_media_ai(req)
  local user, auth, status, body = current_user(req)
  if not user then return status, body end
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item = fetch_media_by_id(media_id, tostring(user.id))
  if not item then return 404, { detail = "Media not found." } end
  local item_tags = {}
  if item.tags and item.tags ~= cjson.null then
    local ok, decoded = pcall(cjson.decode, item.tags)
    if ok and type(decoded) == "table" then item_tags = decoded end
  end

  local payload = json_body(req)
  local corrected = {
    title = payload.title, category_name = payload.category_name,
    subcategory_name = payload.subcategory_name, tags = payload.tags or {},
    is_adult = payload.is_adult and true or false,
  }
  local source = {
    original_filename = item.original_filename, title = item.title,
    category_name = item.category_name, subcategory_name = item.subcategory_name,
    tags = item_tags,
  }
  local example, err = record_ai_training_example(user.id, media_id, source, corrected, payload.notes)
  if err == "forbidden" then return 403, { detail = "You can only train AI using your own media." } end
  if err == "not_found" then return 404, { detail = "Media not found." } end
  if not example then return 400, { detail = tostring(err) } end
  return 200, { training_example = example }
end

-- Client-side telemetry only (never blocks/affects the actual media load) --
-- mirrors app/routers/media.py's report_media_load_diagnostic().
function M.media_load_diagnostic(req)
  local media_id = tonumber(req.params.media_id)
  local auth = auth_optional(req)
  local payload = json_body(req)
  local context = tostring(nn(payload.context) or ""):lower():sub(1, 48)
  local outcome = tostring(nn(payload.outcome) or ""):lower():sub(1, 32)
  local media_kind = tostring(nn(payload.media_kind) or ""):lower():sub(1, 16)
  local selected_source = tostring(nn(payload.selected_source) or ""):lower():sub(1, 32)
  print(string.format(
    "[nyxframe] media load diagnostic media_id=%s outcome=%s context=%s selected=%s media_kind=%s viewer_id=%s",
    tostring(media_id), outcome ~= "" and outcome or "unknown", context ~= "" and context or "unknown",
    selected_source ~= "" and selected_source or "none", media_kind ~= "" and media_kind or "unknown",
    tostring(auth and auth.id or 0)
  ))
  return 200, { ok = true }
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

-- Same capability-token fallback as adult_file_allowed, for private posts:
-- lets the post's own owner load it via a plain <img>/<video src> tag (no
-- cookie sent cross-origin) as long as the URL came from a `with_urls`
-- response their own session was already allowed to see.
local function private_file_allowed(media_id, access, owner)
  if owner then return true end
  return access ~= nil and access ~= "" and access == gauth.media_access_token(M.settings.session_secret, media_id)
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

-- Shared by the file/preview/thumb image routes below. Previously only
-- serve_media_bytes_response (the ?quality=original "High Quality" /file
-- endpoint) applied a watermark, so it only ever showed up there --
-- serve_media_preview and serve_media_thumb (what viewers actually see in
-- the grid and lightbox the vast majority of the time) rendered straight
-- from the unwatermarked original bytes. Caches the watermarked ORIGINAL
-- (keyed by media_id + hash of the current watermark text), so callers
-- that then resize/re-encode it (render_webp_from_bytes for
-- previews/thumbs) all inherit the watermark for free instead of each
-- needing its own cache.
local function apply_image_watermark_if_configured(media_id, item, content, mime_type)
  if item.media_kind ~= "image" then return content end
  local owner = get_user(item.user_id)
  local watermark_text = owner and owner.user_settings and nn(owner.user_settings.watermark_text)
  if not watermark_text or watermark_text == "" then return content end

  local cache_key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(watermark_text)):sub(1, 16)
  local cache_dir = M.settings.uploads_dir .. "/_watermark_cache"
  local cache_path = cache_dir .. "/" .. tostring(media_id) .. "_" .. cache_key
  local cf = io.open(cache_path, "rb")
  if cf then
    local cached = cf:read("*a")
    cf:close()
    return cached
  end

  local watermarked = media_files.apply_watermark(content, mime_type, watermark_text)
  if watermarked then
    os.execute("mkdir -p " .. shell_quote(cache_dir))
    local out = io.open(cache_path, "wb")
    if out then
      out:write(watermarked)
      out:close()
    end
    return watermarked
  end
  return content
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
    content = apply_image_watermark_if_configured(media_id, item, content, item.mime_type)
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

-- ---------------------------------------------------------------------------
-- Video quality-variant transcoding (?quality=720p on GET .../file). Mirrors
-- app/routers/media_streaming.py's VIDEO_QUALITY_PROFILES/
-- _normalize_video_quality/_ensure_video_quality_cache, with one deliberate
-- simplification: Python streams the ffmpeg transcode to the client while
-- simultaneously writing the cache file (so playback starts within ~1s), and
-- dedups concurrent transcodes of the same (media_id, quality) via an
-- in-memory active-streams set. This backend already loads full DB-blob
-- content into memory and blocks copas' single-threaded event loop for the
-- duration of any ffmpeg call (see media_files.lua's render_webp -- same
-- accepted tradeoff, not new here), so a "transcode fully, then serve"
-- approach is consistent with the rest of this file: no partial-progress
-- streaming, and no dedup (two concurrent first-requests for the same
-- quality will transcode twice -- rare, self-correcting once the cache
-- file exists, and not worth an in-memory coordination table for this
-- deployment's traffic level).
-- ---------------------------------------------------------------------------

local VIDEO_QUALITY_PROFILES = {
  ["1080p"] = { max_width = 1920, crf = 22, audio_bitrate = "320k", preset = "fast", profile = "high" },
  ["720p"]  = { max_width = 1280, crf = 25, audio_bitrate = "256k", preset = "fast", profile = "high" },
  ["480p"]  = { max_width = 854,  crf = 28, audio_bitrate = "192k", preset = "fast", profile = "high" },
  ["144p"]  = { max_width = 256,  crf = 36, audio_bitrate = "64k",  preset = "ultrafast", profile = "baseline" },
}
local VIDEO_TRANSCODE_SIZE_LIMIT = 500 * 1024 * 1024

local function ffprobe_bin()
  return os.getenv("GALLERY_FFPROBE_BIN") or "ffprobe"
end

-- Reads the source video's pixel width via ffprobe, or nil if the probe
-- fails for any reason (corrupt/unusual container -- callers must fall
-- back to the old downscale-only behavior in that case, not crash).
local function probe_video_width(path)
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 %s 2>/dev/null",
    ffprobe_bin(), shell_quote(path)
  ))
  if not probe then return nil end
  local line = probe:read("*l")
  probe:close()
  return tonumber(line)
end

-- Builds the -vf scale filter for one quality-profile transcode. A plain
-- `scale='min(max_width,iw)'` (the old behavior) never grows the frame --
-- picking "1080p" on a phone upload that's actually 480p produced a file
-- labeled 1080p with zero visual improvement, just wasted encode time.
-- When the source is genuinely smaller than the requested rendition, scale
-- up to it for real and follow with a mild unsharp pass, since a bare
-- upscale by itself only produces a softer copy of the same pixels --
-- unsharp is what makes the extra resolution actually look sharper instead
-- of just blurrier-but-bigger. Downscaling (the common case) keeps the
-- original lanczos-only behavior unchanged.
local function video_scale_filter(src_path, max_width)
  local source_width = probe_video_width(src_path)
  if source_width and source_width > 0 and source_width < max_width then
    return string.format("scale=%d:-2:flags=lanczos,unsharp=5:5:0.8:5:5:0.0", max_width)
  end
  return string.format("scale='min(%d,iw)':-2:flags=lanczos", max_width)
end

local function normalize_video_quality(value)
  local quality = tostring(value or "high"):lower()
  local legacy = { medium = "720p", low = "480p", high = "original", original = "original" }
  quality = legacy[quality] or quality
  if quality == "original" or VIDEO_QUALITY_PROFILES[quality] then return quality end
  return "original"
end

local function video_quality_cache_path(media_id, quality, digest_seed)
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(digest_seed))):sub(1, 16)
  return M.settings.uploads_dir .. "/_video_cache/" .. tostring(media_id) .. "_" .. quality .. "_" .. key .. ".mp4"
end

local VIDEO_TRANSCODE_PENDING_STALE_SECONDS = 5 * 60

-- Returns (transcoded_bytes, "video/mp4") on success, or (nil) to signal
-- "serve the original instead" (quality is "original", no ffmpeg profile
-- for that quality name, the file is too large to transcode, or a
-- transcode isn't cached yet).
--
-- The transcode itself now always runs as a DETACHED background process
-- rather than inline: running it inline blocked copas' single-threaded
-- loop for the whole transcode (measured live: 6+ seconds for a 40MB->
-- 720p pass, during which a concurrent, completely unrelated request from
-- another client timed out with zero bytes received). A cache miss now
-- falls through to serving the original immediately (still Range/206-
-- servable, so playback still starts instantly) while ffmpeg runs
-- detached; the requested quality becomes available near-instantly, via
-- the cache-hit path below, for every request after that -- including a
-- retry/reload of this same video by the same viewer a moment later.
local function ensure_video_quality_cache(media_id, item, content, quality)
  local profile = VIDEO_QUALITY_PROFILES[quality]
  if not profile then return nil end
  if #content > VIDEO_TRANSCODE_SIZE_LIMIT then return nil end

  local sha_row = db.fetchone("SELECT content_sha256 FROM media_items WHERE id=%s", tostring(media_id))
  local owner = get_user(item.user_id)
  local watermark_text = owner and owner.user_settings and nn(owner.user_settings.watermark_text)
  local digest_seed = ((sha_row and nn(sha_row.content_sha256)) or item.updated_at or item.created_at or tostring(media_id))
    .. "|wm=" .. tostring(watermark_text or "")
  local cache_file = video_quality_cache_path(media_id, quality, digest_seed)

  local existing = io.open(cache_file, "rb")
  if existing then
    local bytes = existing:read("*a")
    existing:close()
    if bytes and #bytes > 0 then return bytes, "video/mp4" end
  end

  -- A ".pending" marker (its content is just the unix timestamp it was
  -- created at) records that a background job is already in flight for
  -- this exact (media_id, quality, content digest), so a burst of
  -- requests before the first transcode finishes doesn't launch a pile of
  -- duplicate ffmpeg processes. Filesystem-based rather than an in-memory
  -- Lua table so it's automatically correct even across a server restart
  -- mid-transcode; a max age guards against a marker orphaned by a
  -- process that died without cleaning up after itself.
  local pending_marker = cache_file .. ".pending"
  local pf = io.open(pending_marker, "rb")
  local pending_age = nil
  if pf then
    pending_age = tonumber(pf:read("*a"))
    pf:close()
  end
  local already_pending = pending_age and (os.time() - pending_age) < VIDEO_TRANSCODE_PENDING_STALE_SECONDS

  if not already_pending then
    os.execute("mkdir -p " .. shell_quote(M.settings.uploads_dir .. "/_video_cache"))
    local src = cache_file .. ".src." .. tostring(math.random(100000, 999999)) .. ".bin"
    local f = assert(io.open(src, "wb"))
    f:write(content)
    f:close()

    local marker = assert(io.open(pending_marker, "wb"))
    marker:write(tostring(os.time()))
    marker:close()

    local tmp_dst = cache_file .. ".tmp." .. tostring(math.random(100000, 999999)) .. ".mp4"
    local scale_filter = video_scale_filter(src, profile.max_width)
    local wm_filter, wm_text_file = media_files.video_watermark_filter(watermark_text)
    if wm_filter then scale_filter = scale_filter .. "," .. wm_filter end
    local cleanup = shell_quote(src) .. " " .. shell_quote(pending_marker) .. " " .. shell_quote(tmp_dst)
    if wm_text_file then cleanup = cleanup .. " " .. shell_quote(wm_text_file) end
    -- nice/ionice: this whole codepath was already "run detached so it
    -- doesn't block the event loop", but a CPU-bound ffmpeg encode at
    -- default (0) priority still competes for the CPU with the luajit
    -- process itself on a single/few-core box -- confirmed live: a
    -- watermarked re-encode saturated CPU badly enough that the whole
    -- site (unrelated requests, even the static SPA) went unresponsive
    -- for as long as ffmpeg ran, the "random severe slowdown under load"
    -- symptom in a different guise from the DB-blocking one. Lowest CPU
    -- ("nice -n 19") and I/O ("ionice -c2 -n7", best-effort lowest) scheduling
    -- priority so the kernel always favors the request-serving process.
    local cmd = string.format(
      "( nice -n 19 ionice -c2 -n7 %s -y -hide_banner -loglevel error -i %s -map 0:v:0 -map 0:a:0? -vf %s -c:v libx264 -preset %s -crf %d "
        .. "-profile:v %s -level 4.1 -pix_fmt yuv420p -c:a aac -b:a %s -movflags +faststart -f mp4 %s "
        .. "&& mv -f %s %s; rm -f %s ) </dev/null >/dev/null 2>&1 &",
      ffmpeg_bin(), shell_quote(src), shell_quote(scale_filter),
      profile.preset, profile.crf, profile.profile, profile.audio_bitrate, shell_quote(tmp_dst),
      shell_quote(tmp_dst), shell_quote(cache_file),
      cleanup
    )
    os.execute(cmd)
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Real HLS adaptive streaming. Range/206 (below) gets a player playing
-- almost instantly and buffering progressively, but it's still one fixed
-- rendition per request -- no seamless quality switching, and a quality
-- change means abandoning the current connection and re-requesting the
-- whole file at a different rendition. This gives real segmented,
-- progressively-encoded HLS: ffmpeg is launched detached (same pattern as
-- ensure_video_quality_cache above) with `-f hls`, which writes the
-- .m3u8 playlist and .ts segments to disk INCREMENTALLY as it encodes --
-- a client can start playing segment 0 while segment 4 is still being
-- encoded, and AVPlayer/hls.js re-poll the (still-growing) playlist for
-- new segments exactly like a live stream, dropping the trailing
-- #EXT-X-ENDLIST tag in automatically once ffmpeg reaches end of input.
-- "original" quality uses `-c copy` (remux only, no re-encode) so it's
-- available almost immediately regardless of source length.
-- ---------------------------------------------------------------------------

local HLS_SEGMENT_SECONDS = 6

-- media_id kept as a param (unused now) rather than reshuffling both call
-- sites -- item.content_sha256 (fetch_media_stream_row above) replaces
-- what used to be this function's own db.fetchone, which fired a second,
-- redundant query for the same row on every call -- including
-- serve_hls_segment's per-segment call, i.e. every ~6s of playback.
local function media_content_digest_seed(media_id, item, watermark_text)
  local base = nn(item.content_sha256) or item.updated_at or item.created_at or tostring(media_id)
  return base .. "|wm=" .. tostring(watermark_text or "")
end

local function hls_variant_dir(media_id, quality, digest_seed)
  local key = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(tostring(digest_seed))):sub(1, 16)
  return M.settings.uploads_dir .. "/_hls_cache/" .. tostring(media_id) .. "_" .. quality .. "_" .. key
end

-- Returns the variant's cache directory (which may not have any segments
-- in it yet -- see the bounded poll in M.serve_hls_playlist) or nil if
-- this quality isn't offered at all for this file.
-- A playlist.m3u8 that exists but has no #EXT-X-ENDLIST is a dead artifact
-- from an encode that never finished (ffmpeg crashed, got OOM-killed, or --
-- since the detached transcode job lives in this service's systemd
-- cgroup and `systemctl restart` defaults to KillMode=control-group --
-- simply got torn down by a routine backend restart landing mid-transcode.
-- Confirmed live: media 606's 720p variant has been a 0-byte playlist.m3u8
-- plus a truncated last segment since a restart on 2026-08-10, and would
-- have 503'd "still starting up" forever, since nothing ever re-triggers
-- an encode for a file that already "exists".
local function hls_variant_ready(dir)
  local f = io.open(dir .. "/playlist.m3u8", "rb")
  if not f then return false end
  local text = f:read("*a")
  f:close()
  return text ~= nil and text:find("#EXT-X-ENDLIST", 1, true) ~= nil
end

-- `item` alone (no pre-read file bytes) is enough to check whether a
-- variant is already cached -- the size cap uses the DB's file_size
-- column rather than an actual read, and pending/ready checks are pure
-- filesystem stats. The full source is only read from disk/DB (via
-- content_fn, called at most once) on a genuine cache miss, right before
-- it's written to source.bin. This matters because M.serve_hls_playlist
-- calls this on every playlist request, including hls.js's periodic
-- re-polls of a still-growing (no #EXT-X-ENDLIST yet) playlist during an
-- active transcode -- previously that read the ENTIRE source file into
-- memory on every one of those polls, for every concurrent viewer,
-- regardless of whether anything actually needed launching. On a public
-- gallery with several people watching different in-progress transcodes
-- at once, that was real, repeated, avoidable memory/disk pressure.
local function ensure_hls_variant(media_id, item, content_fn, quality)
  if quality ~= "original" and not VIDEO_QUALITY_PROFILES[quality] then return nil end
  -- "original" is a `-c copy` remux (no re-encode -- see the codec_args
  -- branch below), not a real transcode, so the size cap that exists to
  -- bound ffmpeg re-encode time doesn't apply to it. Applying it here
  -- anyway meant any upload over the cap 404'd on EVERY quality, including
  -- the one rendition explicitly meant to "be available almost instantly
  -- regardless of source length" per this section's own header comment --
  -- the exact "nothing plays" symptom for large uploads.
  if quality ~= "original" and db.toint(item.file_size, 0) > VIDEO_TRANSCODE_SIZE_LIMIT then return nil end

  local owner = get_user(item.user_id)
  local watermark_text = owner and owner.user_settings and nn(owner.user_settings.watermark_text)
  local digest_seed = media_content_digest_seed(media_id, item, watermark_text)
  local dir = hls_variant_dir(media_id, quality, digest_seed)

  -- Same filesystem-based ".pending" dedup as ensure_video_quality_cache.
  local pending_marker = dir .. ".pending"
  local pf = io.open(pending_marker, "rb")
  local pending_age = pf and tonumber(pf:read("*a")) or nil
  if pf then pf:close() end
  local still_encoding = pending_age and (os.time() - pending_age) < VIDEO_TRANSCODE_PENDING_STALE_SECONDS

  -- Trust the existing directory only if it's genuinely complete, or a
  -- transcode for it is still actively running (don't stomp on/duplicate
  -- live work just because the playlist hasn't gotten its ENDLIST yet).
  if hls_variant_ready(dir) or still_encoding then return dir end

  -- Claim this slot BEFORE calling content_fn(), not after: content_fn()
  -- reads through resolve_media_bytes, which can hit the DB (potentially a
  -- large blob fetch) and therefore genuinely yields to copas's scheduler
  -- (see swarmlua/pg.lua's single-shared-connection lock). If the marker
  -- write happened after that yield, two viewers' requests landing on the
  -- same cold digest within the same moment could both pass the check
  -- above before either had written the marker, and both go on to launch
  -- their own duplicate ffmpeg job against the same output directory.
  -- Writing the marker here, before the one yielding step in this
  -- function, keeps the check-then-claim sequence atomic with respect to
  -- other coroutines the same way it was when content was always resolved
  -- up front by the caller.
  local marker = assert(io.open(pending_marker, "wb"))
  marker:write(tostring(os.time()))
  marker:close()

  local content = content_fn()
  if not content then
    os.remove(pending_marker)
    return nil, "missing"
  end

  os.execute("mkdir -p " .. shell_quote(dir))
  local src = dir .. "/source.bin"
  local f = assert(io.open(src, "wb"))
  f:write(content)
  f:close()
  content = nil

  local wm_filter, wm_text_file = media_files.video_watermark_filter(watermark_text)

  local codec_args
  if quality == "original" then
    if wm_filter then
      -- A watermark can't be burned in through `-c copy` (stream remux,
      -- no filter graph runs at all) -- fall back to a visually-lossless
      -- re-encode at the source resolution so "original" still gets
      -- watermarked like every other quality instead of silently
      -- skipping it, which was the actual bug report ("watermark
      -- doesn't show up at all on videos").
      codec_args = string.format(
        "-vf %s -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 320k",
        shell_quote(wm_filter)
      )
    else
      codec_args = "-c copy"
    end
  else
    local profile = VIDEO_QUALITY_PROFILES[quality]
    local scale_filter = video_scale_filter(src, profile.max_width)
    if wm_filter then scale_filter = scale_filter .. "," .. wm_filter end
    codec_args = string.format(
      "-vf %s -c:v libx264 -preset %s -crf %d -profile:v %s -level 4.1 -pix_fmt yuv420p -c:a aac -b:a %s",
      shell_quote(scale_filter), profile.preset, profile.crf, profile.profile, profile.audio_bitrate
    )
  end

  local cleanup = shell_quote(src) .. " " .. shell_quote(pending_marker)
  if wm_text_file then cleanup = cleanup .. " " .. shell_quote(wm_text_file) end

  -- hls_flags temp_file: each playlist rewrite happens via write-then-
  -- rename, so a concurrent read of playlist.m3u8 (M.serve_hls_playlist,
  -- possibly mid-encode) never sees a torn/partial write.
  -- nice/ionice: see ensure_video_quality_cache's identical comment --
  -- keeps a CPU-heavy detached encode from starving the request-serving
  -- process of CPU, confirmed live to otherwise make the whole site
  -- unresponsive for the duration of the encode.
  local cmd = string.format(
    "( nice -n 19 ionice -c2 -n7 %s -y -hide_banner -loglevel error -i %s -map 0:v:0 -map 0:a:0? %s "
      .. "-f hls -hls_time %d -hls_list_size 0 -hls_playlist_type vod -hls_flags independent_segments+temp_file "
      .. "-hls_segment_filename %s %s "
      .. "; rm -f %s ) </dev/null >/dev/null 2>&1 &",
    ffmpeg_bin(), shell_quote(src), codec_args, HLS_SEGMENT_SECONDS,
    shell_quote(dir .. "/seg_%05d.ts"), shell_quote(dir .. "/playlist.m3u8"),
    cleanup
  )
  os.execute(cmd)
  return dir
end

-- Builds the query string to propagate onto sub-resource URLs (master
-- playlist -> per-quality playlist -> segments), so a viewer who only
-- authenticated via ?access= or ?key= on the FIRST request stays
-- authenticated through the rest of the chain -- relative-URL resolution
-- doesn't inherit a parent playlist's query string on its own, and a
-- <video> tag/HLS player can't attach custom headers to the sub-requests
-- it makes. ?access= (the narrower, single-post capability token) wins if
-- both are somehow present.
local function hls_propagated_qs(req)
  local access = req.query and nn(req.query.access)
  if access then return "?access=" .. access end
  local key = req.query and nn(req.query.key)
  if key then return "?key=" .. key end
  return nil
end

-- fetch_media_by_id joins categories/subcategories/users and aggregates
-- likes/comments/bookmarks with 3 COUNT DISTINCTs -- built for rendering a
-- post's full detail view, not for an auth check. hls_check_access runs on
-- EVERY segment request (every ~6s of playback, per viewer, per active
-- stream) as well as every playlist load, so on a public gallery with
-- several people streaming at once that heavy query was firing constantly
-- for no reason -- none of the joined/aggregated columns are used past
-- this function. This lean, join-free query carries only what
-- hls_check_access/ensure_hls_variant/resolve_media_bytes/serve_hls_segment
-- actually read.
local function fetch_media_stream_row(media_id)
  return db.fetchone([[
    SELECT id, user_id, media_kind, mime_type, original_filename, storage_path, file_size,
           created_at, updated_at, visibility, is_adult, deleted_at, content_sha256
    FROM media_items WHERE id = %s
  ]], tostring(media_id))
end

-- Shared by all three HLS routes below: 404s (not 403 -- matches this
-- file's "don't leak existence" convention elsewhere) on anything that
-- would also 404/403 through the regular file-serving path.
local function hls_check_access(req, media_id)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_stream_row(media_id)
  if not item or nn(item.deleted_at) ~= nil then return nil, 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return nil, 403, { detail = "This post is private." }
  end
  if item.is_adult and not adult_file_allowed(req, media_id, req.query.access, viewer_id) then
    return nil, 403, { detail = "Age verification required for this 18+ post." }
  end
  if item.media_kind ~= "video" then return nil, 404, { detail = "Not a video." } end
  return item
end

local HLS_BANDWIDTH_BY_QUALITY = { ["1080p"] = 5000000, ["720p"] = 2800000, ["480p"] = 1400000, ["144p"] = 300000 }

function M.serve_hls_master(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  local item, status, body = hls_check_access(req, media_id)
  if not item then return status, body end

  local access_qs = hls_propagated_qs(req) or ""
  local lines = { "#EXTM3U", "#EXT-X-VERSION:6" }
  -- Original first: no re-encode needed (fast remux), so it's always the
  -- quickest to become available and is a sane default rendition even
  -- for a source too large to offer any transcoded quality for.
  lines[#lines + 1] = '#EXT-X-STREAM-INF:BANDWIDTH=8000000,NAME="Original"'
  lines[#lines + 1] = string.format("/api/media/%d/hls/original/playlist.m3u8%s", media_id, access_qs)
  for _, quality in ipairs({ "1080p", "720p", "480p", "144p" }) do
    lines[#lines + 1] = string.format('#EXT-X-STREAM-INF:BANDWIDTH=%d,NAME="%s"', HLS_BANDWIDTH_BY_QUALITY[quality], quality)
    lines[#lines + 1] = string.format("/api/media/%d/hls/%s/playlist.m3u8%s", media_id, quality, access_qs)
  end
  return 200, table.concat(lines, "\n") .. "\n",
    { ["Content-Type"] = "application/vnd.apple.mpegurl", ["Cache-Control"] = "no-cache" }
end

function M.serve_hls_playlist(req)
  local media_id = tonumber(req.params.media_id)
  local quality = normalize_video_quality(req.params.quality)
  if not media_id then return 404, { detail = "Media not found." } end
  local item, status, body = hls_check_access(req, media_id)
  if not item then return status, body end

  local dir, err = ensure_hls_variant(media_id, item, function() return resolve_media_bytes(item) end, quality)
  if not dir then
    if err == "missing" then return 404, { detail = "File is missing." } end
    return 404, { detail = "This quality is not available for this video." }
  end

  -- Bounded, yielding wait for the first segment(s): a cold cache means
  -- the background ffmpeg job was JUST launched a moment ago by the call
  -- above, so the playlist file may not have its first #EXTINF entry
  -- written yet. copas.sleep yields to the scheduler on each iteration
  -- (confirmed: coroutine_yield under the hood) so other in-flight
  -- requests are serviced during this wait, unlike the multi-minute
  -- fully-synchronous transcode this replaces.
  -- ffmpeg writes segment lines as bare relative filenames ("seg_00000.ts")
  -- with no awareness of the request's own ?access= token -- fine for a
  -- non-adult video (M.serve_hls_segment only checks that token when
  -- item.is_adult), but an adult-gated post needs every segment request
  -- to carry it too, and relative-URL resolution doesn't inherit a
  -- parent playlist's query string. Rewritten here rather than relying on
  -- AVURLAssetHTTPHeaderFieldsKey propagating to segment requests, which
  -- this app has already hit real inconsistency with for redirects/Range
  -- requests -- and web's plain <video> tag can't attach custom headers
  -- to sub-resource requests at all regardless.
  local access_qs = hls_propagated_qs(req)

  local playlist_path = dir .. "/playlist.m3u8"
  local waited = 0
  while waited < 8 do
    local f = io.open(playlist_path, "rb")
    if f then
      local text = f:read("*a")
      f:close()
      if text and text:find("#EXTINF", 1, true) then
        if access_qs then
          -- Escape any literal "%" in the token itself so gsub's
          -- replacement-string parser doesn't mistake it for a
          -- backreference/escape sequence.
          local safe_access_qs = access_qs:gsub("%%", "%%%%")
          text = text:gsub("(seg_%d+%.ts)", "%1" .. safe_access_qs)
        end
        return 200, text, { ["Content-Type"] = "application/vnd.apple.mpegurl", ["Cache-Control"] = "no-cache" }
      end
    end
    local copas_ok, copas = pcall(require, "copas")
    if copas_ok then copas.sleep(0.25) end
    waited = waited + 0.25
  end
  return 503, { detail = "This video is still starting up -- try again in a moment." }
end

function M.serve_hls_segment(req)
  local media_id = tonumber(req.params.media_id)
  local quality = normalize_video_quality(req.params.quality)
  local segment = req.params.segment
  if not media_id or not segment or not segment:match("^seg_%d+%.ts$") then
    return 404, { detail = "Not found." }
  end
  local item, status, body = hls_check_access(req, media_id)
  if not item then return status, body end

  local seg_owner = get_user(item.user_id)
  local seg_watermark_text = seg_owner and seg_owner.user_settings and nn(seg_owner.user_settings.watermark_text)
  local digest_seed = media_content_digest_seed(media_id, item, seg_watermark_text)
  local dir = hls_variant_dir(media_id, quality, digest_seed)
  local f = io.open(dir .. "/" .. segment, "rb")
  if not f then return 404, { detail = "Segment not found." } end
  local bytes = f:read("*a")
  f:close()
  return 200, bytes, { ["Content-Type"] = "video/mp2t", ["Cache-Control"] = "public, max-age=86400" }
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

local function serve_media_bytes_response(req, media_id, as_download, quality)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local item = fetch_media_by_id(media_id, viewer_id or "0")
  if not item or nn(item.deleted_at) ~= nil then return 404, { detail = "Media not found." } end
  item.is_adult = db.tobool(item.is_adult)
  local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return 403, { detail = "This post is private." }
  end
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

  content = apply_image_watermark_if_configured(media_id, item, content, mime_type)

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

  local normalized_quality = normalize_video_quality(quality)
  if item.media_kind == "video" and normalized_quality ~= "original" then
    local transcoded, transcoded_mime = ensure_video_quality_cache(media_id, item, content, normalized_quality)
    if transcoded then
      return respond_with_range(req, transcoded, transcoded_mime, {
        ["Cache-Control"] = "public, max-age=86400",
        ["X-Video-Quality"] = normalized_quality,
        ["X-Video-Codec"] = "h264/aac",
      })
    end
    -- Transcode unavailable/failed/too large -- fall through to the original,
    -- same as Python's _video_variant_response returning None.
  end
  return respond_with_range(req, content, mime_type, { ["Cache-Control"] = "public, max-age=86400" })
end

function M.serve_media_file(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  return serve_media_bytes_response(req, media_id, false, req.query and req.query.quality)
end

function M.download_media(req)
  local media_id = tonumber(req.params.media_id)
  if not media_id then return 404, { detail = "Media not found." } end
  return serve_media_bytes_response(req, media_id, true)
end

-- ---------------------------------------------------------------------------
-- Zip downloads (StudioPage.jsx's "Download selected" and
-- CollectionsPage.jsx's "Download collection" -- both confirmed
-- live-404ing, and the zip-building capability they need didn't exist
-- anywhere in this codebase yet, unlike most other gaps this session which
-- were "recover the existing logic." Shells out to the system `zip` binary
-- via os.execute/os.tmpname, the same convention media_files.lua already
-- uses for ffmpeg/ImageMagick calls (see its "ffmpeg-backed thumbnail"
-- section) -- no Lua zip library is installed (checked: neither `zip` nor
-- `minizip` rocks are available), and this matches how every other
-- shell-out in this codebase already works rather than introducing a new
-- technique.
-- ---------------------------------------------------------------------------

local function zip_shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Writes each accessible item's bytes to a scratch temp dir, zips it with
-- the system `zip` binary, reads the result back into memory, and cleans up
-- -- returns the zip bytes, or nil if nothing was downloadable (private and
-- not owned, downloads disabled and not owned, or bytes missing). Mirrors
-- serve_media_bytes_response's own per-item visibility/downloads_enabled
-- gating, just skipping rather than 403ing the whole batch over one
-- inaccessible item.
local function build_media_zip(items, viewer_id)
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute("mkdir -p " .. zip_shell_quote(tmp_dir))

  local file_paths = {}
  for _, item in ipairs(items) do
    local owner = viewer_id and tostring(item.user_id) == tostring(viewer_id)
    local visible = item.visibility ~= "private" or owner
    local allowed = db.tobool(item.downloads_enabled) or owner
    if visible and allowed then
      local content = resolve_media_bytes(item)
      if content then
        local safe_base = tostring(item.original_filename or ("media-" .. item.id)):gsub("[/\\]", "_")
        local path = tmp_dir .. "/" .. tostring(item.id) .. "-" .. safe_base
        local f = io.open(path, "wb")
        if f then
          f:write(content)
          f:close()
          file_paths[#file_paths + 1] = path
        end
      end
    end
  end

  if #file_paths == 0 then
    os.execute("rm -rf " .. zip_shell_quote(tmp_dir))
    return nil
  end

  local zip_path = tmp_dir .. ".zip"
  local quoted_paths = {}
  for _, p in ipairs(file_paths) do quoted_paths[#quoted_paths + 1] = zip_shell_quote(p) end
  local cmd = "cd " .. zip_shell_quote(tmp_dir) .. " && zip -j -q " .. zip_shell_quote(zip_path)
    .. " " .. table.concat(quoted_paths, " ") .. " </dev/null >/dev/null 2>&1"
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)

  local zip_bytes = nil
  if success then
    local f = io.open(zip_path, "rb")
    if f then
      zip_bytes = f:read("*a")
      f:close()
    end
  end
  os.execute("rm -rf " .. zip_shell_quote(tmp_dir))
  os.remove(zip_path)
  return zip_bytes
end

-- POST /api/media/download-batch -- confirmed live-404ing: StudioPage.jsx's
-- "Download selected" bulk action has always called this.
function M.download_media_batch(req)
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  local rl_status, rl_body = ratelimit.check("download_batch:" .. (viewer_id or client_ip(req)), 30, 3600)
  if rl_status then return rl_status, rl_body end

  local payload = json_body(req)
  local ids = {}
  if type(payload.media_ids) == "table" then
    for _, id in ipairs(payload.media_ids) do
      local n = tonumber(id)
      if n then ids[#ids + 1] = n end
    end
  end
  if #ids == 0 then return 400, { detail = "No posts selected." } end
  if #ids > 50 then return 400, { detail = "Select 50 or fewer posts at a time." } end

  local items = {}
  for _, id in ipairs(ids) do
    local item = fetch_media_by_id(id, viewer_id or "0")
    if item and nn(item.deleted_at) == nil then
      item.is_adult = db.tobool(item.is_adult)
      items[#items + 1] = item
    end
  end

  local zip_bytes = build_media_zip(items, viewer_id)
  if not zip_bytes then return 404, { detail = "None of the selected posts could be downloaded." } end
  return 200, zip_bytes, {
    ["Content-Type"] = "application/zip",
    ["Content-Disposition"] = 'attachment; filename="gallery-selection.zip"',
  }
end

-- GET /api/collections/:collection_id/download -- confirmed live-404ing:
-- CollectionsPage.jsx has always called this. Delegates access control
-- entirely to M.collection_detail (private-collection 404 gating, smart-
-- collection filter resolution) rather than duplicating it.
function M.download_collection(req)
  local status, body = M.collection_detail(req)
  if status ~= 200 then return status, body end
  local auth = auth_optional(req)
  local viewer_id = auth and tostring(auth.id) or nil
  -- body.media went through arr() inside collection_detail, which returns
  -- the special cjson.empty_array sentinel (not a real table) for an empty
  -- list -- `#` on that userdata errors, so normalize back to {} here.
  local items = type(body.media) == "table" and body.media or {}
  if #items == 0 then return 404, { detail = "This collection has no downloadable posts." } end

  local zip_bytes = build_media_zip(items, viewer_id)
  if not zip_bytes then return 404, { detail = "None of the posts in this collection could be downloaded." } end

  local raw_name = tostring((body.collection and body.collection.name) or "collection")
  local safe_name = raw_name:gsub("[^%w%-_ ]", ""):gsub("%s+", "-"):sub(1, 60)
  if safe_name == "" then safe_name = "collection" end
  return 200, zip_bytes, {
    ["Content-Type"] = "application/zip",
    ["Content-Disposition"] = string.format('attachment; filename="%s.zip"', safe_name),
  }
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
  if item.visibility == "private" and not private_file_allowed(media_id, req.query.access, owner) then
    return 403, { detail = "This post is private." }
  end
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
  content = apply_image_watermark_if_configured(media_id, item, content, item.mime_type)
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

-- ---------------------------------------------------------------------------
-- "My Other Projects" tab: proxies each project's latest .ipa from its
-- GitHub repo (Lumisound, and now Nyxframe itself once it goes back to
-- private -- the whole reason this got generalized instead of staying a
-- Lumisound-only special case). A private repo means the browser can't just
-- link straight to a GitHub release asset -- private-repo asset downloads
-- need an Authorization header GitHub's own CDN redirect won't carry, and
-- this repo owner obviously can't hand out their GitHub token to the page's
-- visitors. Shells out to the `gh` CLI instead of a Lua HTTPS client: it's
-- already authenticated on this box (this backend and `gh` both run as the
-- same user), so this never needs to read/store/handle the token itself --
-- confirmed `gh auth status` succeeds even with every keyring/DBus/session
-- env var stripped, so it works fine from this systemd --user service's
-- minimal environment too. Same detached-background-job + bounded-poll
-- shape as the video transcode section above, so a slow GitHub fetch
-- yields to other requests instead of blocking the single-threaded server.
-- ---------------------------------------------------------------------------

local PROJECT_DOWNLOAD_POLL_SECONDS = 20

local function project_download_cache_dir()
  local dir = M.settings.uploads_dir .. "/_project_downloads"
  os.execute("mkdir -p " .. shell_quote(dir))
  return dir
end

-- Fast metadata-only call (no asset bytes), so a synchronous io.popen here
-- is fine -- this is the same kind of brief, bounded call the rest of this
-- file already makes synchronously (e.g. ffprobe-equivalent lookups).
local function project_latest_tag(repo)
  local handle = io.popen(
    "env -i HOME=" .. shell_quote(os.getenv("HOME") or "") .. " PATH=" .. shell_quote(os.getenv("PATH") or "")
      .. " gh release list --repo " .. shell_quote(repo)
      .. " --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null"
  )
  if not handle then return nil end
  local tag = handle:read("*a")
  handle:close()
  tag = tag and tag:gsub("%s+$", "") or ""
  return tag ~= "" and tag or nil
end

local function project_safe_tag(tag)
  return (tag:gsub("[^%w%.%-]", "_"))
end

-- key: short filesystem-safe prefix for this project's cache files (e.g.
-- "lumisound"/"nyxframe"). display_name: used only in the filename and
-- error text shown to the visitor.
local function download_latest_ipa(repo, key, display_name)
  local tag = project_latest_tag(repo)
  if not tag then return 502, { detail = "Could not reach GitHub to check the latest " .. display_name .. " release. Try again shortly." } end

  local dir = project_download_cache_dir()
  local safe_tag = project_safe_tag(tag)
  local final_path = dir .. "/" .. key .. "_" .. safe_tag .. ".ipa"
  local filename = display_name .. "-" .. safe_tag .. ".ipa"

  local existing = io.open(final_path, "rb")
  if existing then
    local content = existing:read("*a")
    existing:close()
    return 200, content, {
      ["Content-Type"] = "application/octet-stream",
      ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
      ["Cache-Control"] = "private, max-age=0, no-cache",
    }
  end

  -- Same filesystem-based ".pending" dedup as the video transcode section:
  -- a concurrent second visitor hitting this while the first download is
  -- still in flight waits on the SAME fetch rather than kicking off a
  -- redundant one.
  local pending_marker = final_path .. ".pending"
  local pf = io.open(pending_marker, "rb")
  local pending_age = pf and tonumber(pf:read("*a")) or nil
  if pf then pf:close() end
  local still_fetching = pending_age and (os.time() - pending_age) < PROJECT_DOWNLOAD_POLL_SECONDS

  if not still_fetching then
    local marker = assert(io.open(pending_marker, "wb"))
    marker:write(tostring(os.time()))
    marker:close()

    local tmp_path = final_path .. ".tmp." .. tostring(math.random(100000, 999999))
    local cmd = string.format(
      "( env -i HOME=%s PATH=%s gh release download %s --repo %s --pattern '*.ipa' -O %s --clobber "
        .. "&& mv -f %s %s; rm -f %s %s ) </dev/null >/dev/null 2>&1 &",
      shell_quote(os.getenv("HOME") or ""), shell_quote(os.getenv("PATH") or ""),
      shell_quote(tag), shell_quote(repo), shell_quote(tmp_path),
      shell_quote(tmp_path), shell_quote(final_path),
      shell_quote(tmp_path), shell_quote(pending_marker)
    )
    os.execute(cmd)
  end

  local waited = 0
  while waited < PROJECT_DOWNLOAD_POLL_SECONDS do
    local f = io.open(final_path, "rb")
    if f then
      local content = f:read("*a")
      f:close()
      return 200, content, {
        ["Content-Type"] = "application/octet-stream",
        ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
        ["Cache-Control"] = "private, max-age=0, no-cache",
      }
    end
    local copas_ok, copas = pcall(require, "copas")
    if copas_ok then copas.sleep(0.5) end
    waited = waited + 0.5
  end
  return 503, { detail = "Still fetching the latest " .. display_name .. " build from GitHub -- try again in a moment." }
end

function M.download_lumisound(req)
  return download_latest_ipa("HeavenlyXenusVR/Lumisound", "lumisound", "Lumisound")
end

function M.download_nyxframe(req)
  return download_latest_ipa("HeavenlyXenusVR/Nyxframe", "nyxframe", "Nyxframe")
end

return M
