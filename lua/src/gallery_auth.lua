-- Image Gallery specific auth glue on top of the vendored src/auth.lua
-- primitives (password hashing + generic HMAC token issue/verify, copied
-- verbatim from SwarmPanel's lua/src/auth.lua).
--
-- Password hashing: SwarmPanel's M.password_hash/M.verify_password_hash
-- already produce/consume the exact `pbkdf2_sha256$<iter>$<b64 salt>$<b64
-- digest>` format app/auth.py's hash_password()/verify_password() use
-- (PBKDF2-HMAC-SHA256, 260000 iterations, standard non-urlsafe base64) --
-- reused as-is, byte-for-byte compatible, so account rows created by
-- whichever backend runs first stay readable by the other during any
-- side-by-side cutover window.
--
-- Session tokens: app/auth.py used itsdangerous.URLSafeTimedSerializer with
-- two distinct salts (one for real sessions, one for 2FA-pending). The
-- frontend (frontend/src/api.js) only ever stores/replays the token as an
-- opaque string -- it never parses it -- so byte-for-byte itsdangerous
-- compatibility is not required (see SwarmPanel/lua/src/auth.lua's own
-- design note, same reasoning applies here: this is a full backend
-- rewrite, not a shim next to a still-running Python instance). We reuse
-- the vendored HMAC-SHA256-signed-JSON scheme instead, with the "distinct
-- salt" property replicated by mixing a purpose-specific suffix into the
-- HMAC key so a 2FA-pending token can never verify as a real session token.
local base = require("auth")
local sodium = require("luasodium")

local M = {}

-- Mirrors app/routers/_shared.py's _media_access_token(): hex HMAC-SHA256 of
-- the decimal media id, keyed by the session secret. Used to let an <img>/
-- <video> tag (which never carries an Authorization header) reach an
-- age-gated adult file via a signed `?access=` query param instead.
function M.media_access_token(secret, media_id)
  local digest = base.hmac_sha256(secret, tostring(math.floor(tonumber(media_id))))
  return sodium.sodium_bin2hex(digest)
end

M.password_hash = base.password_hash
M.verify_password_hash = base.verify_password_hash
M.extract_bearer_token = base.extract_bearer_token

local SESSION_COOKIE_NAME = "image_gallery_session"
M.SESSION_COOKIE_NAME = SESSION_COOKIE_NAME

-- Builds the Set-Cookie header value for the session cookie. The frontend
-- (GitHub Pages) and the API (gallery.xenusanimations.studio, behind the
-- Cloudflare tunnel) are different origins, so this is a cross-site cookie:
-- without `SameSite=None; Secure` browsers (Chrome/Firefox/Safari all
-- default bare cookies to SameSite=Lax) silently refuse to store or send
-- it on cross-site fetches. That meant login "worked" (Set-Cookie came
-- back 200) but every subsequent authenticated request looked logged-out
-- to the browser -- surfacing as 403s on private/adult media, broken
-- personalized routes, and Chrome's devtools flagging the cookie as
-- rejected. `Secure` requires HTTPS, which the tunnel terminates as, so
-- it's always safe to set here.
function M.session_cookie(token, max_age_seconds)
  local attrs = "Path=/; HttpOnly; Secure; SameSite=None"
  if max_age_seconds then
    return SESSION_COOKIE_NAME .. "=" .. token .. "; " .. attrs .. "; Max-Age=" .. max_age_seconds
  end
  return SESSION_COOKIE_NAME .. "=" .. token .. "; " .. attrs
end

-- issue_token(secret, user, ttl_seconds) -> opaque bearer token string.
-- Mirrors app/auth.py's issue_token(): payload is {id, username, display_name}.
function M.issue_token(secret, user, ttl_seconds)
  return base.issue_token(secret, {
    id = tostring(user.id),
    username = user.username,
    display_name = user.display_name,
  }, ttl_seconds)
end

-- verify_token(secret, token, _max_age_seconds) -> payload table or nil.
-- _max_age_seconds is accepted for call-site symmetry with app/auth.py's
-- verify_token() but unused: our tokens self-embed an absolute expiry (exp)
-- at issue time (see auth.lua's issue_token), so there's nothing extra to
-- check here beyond what verify_token() already validates.
function M.verify_token(secret, token, _max_age_seconds)
  return base.verify_token(secret, token)
end

function M.require_auth(request_headers, request_cookies, secret, max_age_seconds)
  local token = M.extract_bearer_token(request_headers["authorization"])
  if not token then token = request_cookies and request_cookies[SESSION_COOKIE_NAME] end
  return M.verify_token(secret, token, max_age_seconds)
end

local TOTP_PENDING_SUFFIX = "#image_gallery_2fa_pending"
local TOTP_PENDING_TTL_SECONDS = 300

function M.issue_2fa_pending_token(secret, user_id)
  return base.issue_token(secret .. TOTP_PENDING_SUFFIX, { id = tostring(user_id) }, TOTP_PENDING_TTL_SECONDS)
end

-- Returns the user id as a STRING (never tonumber()'d) -- consistent with
-- the swarm-wide rule that wide integer ids must never round-trip through a
-- Lua double. It's safe to hand straight to db.lua as a query parameter;
-- Postgres implicitly casts an untyped string literal to the target bigint
-- column.
function M.verify_2fa_pending_token(secret, token)
  local data = base.verify_token(secret .. TOTP_PENDING_SUFFIX, token)
  if not data or not data.id then return nil end
  return tostring(data.id)
end

return M
