-- Server-rendered two-factor (TOTP) enrollment at
-- gallery.xenusanimations.studio/settings/2fa -- same "safe to rewrite"
-- rationale as pages_auth.lua/pages_admin.lua: a simple, low-interactivity
-- form flow any logged-in user can reach directly (the cookie set by
-- /login or the existing JSON API login both work here, via the same
-- current_user() cookie-or-bearer check every other endpoint uses).
--
-- Deliberately renders NO QR code image. Two reasons: (1) every third-party
-- "give us your data, we'll draw you a QR code" service would receive the
-- literal otpauth:// URI -- which contains the raw TOTP secret -- handing a
-- copy of the user's 2FA seed to an external party is a real secret leak,
-- not a hypothetical one. (2) generating a scannable QR code from scratch
-- in Lua (finder patterns, Reed-Solomon error correction, mask scoring)
-- is substantial, easy to get subtly wrong, and this environment has no
-- camera/scanner to verify a hand-rolled encoder actually scans. Instead:
-- the base32 secret is shown for manual entry (every authenticator app
-- supports this), grouped in 4s for readability, plus the same otpauth://
-- URI as a tappable link -- most authenticator apps register that URI
-- scheme, so tapping it on a phone that has one installed adds the account
-- directly, no camera needed either way.

local routes = require("routes")
local html = require("html")
local db = require("db")
local totp = require("totp")

local esc = html.esc
local parse_urlencoded = html.parse_urlencoded

local M = {}
local HTML_HEADERS = { ["Content-Type"] = "text/html; charset=utf-8" }

local STYLE = [[
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; background: #101318; color: #e7e9ee;
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display: flex; align-items: flex-start; justify-content: center; padding: 40px 20px; }
  .card { width: 100%; max-width: 440px; background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08); border-radius: 20px; padding: 32px; }
  h1 { margin: 0 0 4px; font-size: 20px; }
  p.lede { margin: 0 0 20px; color: #9aa1af; font-size: 14px; }
  .error { background: rgba(220,80,80,0.15); border: 1px solid rgba(220,80,80,0.4);
    color: #ffb4b4; border-radius: 12px; padding: 10px 12px; margin-bottom: 16px; font-size: 14px; }
  .flash { background: rgba(55,201,167,0.15); border: 1px solid rgba(55,201,167,0.4);
    color: #9fe8d4; border-radius: 12px; padding: 10px 12px; margin-bottom: 16px; font-size: 14px; }
  .secret { font: 16px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 1px;
    background: rgba(255,255,255,0.06); border-radius: 10px; padding: 12px; text-align: center; margin: 12px 0; }
  label { display: block; font-size: 13px; color: #9aa1af; margin: 14px 0 6px; }
  input { width: 100%; padding: 10px 12px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.12);
    background: rgba(255,255,255,0.03); color: #e7e9ee; font-size: 15px; }
  input:focus { outline: none; border-color: #37c9a7; }
  button { margin-top: 18px; padding: 11px 16px; border-radius: 12px; border: none;
    background: #37c9a7; color: #04211b; font-weight: 600; font-size: 14px; cursor: pointer; }
  button.danger { background: rgba(220,80,80,0.85); color: #2b0b0b; }
  .recovery-codes { font: 15px/1.8 ui-monospace, SFMono-Regular, Menlo, monospace;
    background: rgba(255,255,255,0.06); border-radius: 10px; padding: 14px; margin: 12px 0; }
  a.otpauth { display: inline-block; margin-top: 8px; color: #37c9a7; font-size: 13px; }
  .status-badge { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; }
  .status-badge.on { background: rgba(55,201,167,0.2); color: #37c9a7; }
  .status-badge.off { background: rgba(255,255,255,0.08); color: #9aa1af; }
</style>
]]

local function layout(title, body_html)
  return ([[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s // Image Gallery</title>
%s
</head>
<body>
<div class="card">%s</div>
</body>
</html>]]):format(esc(title), STYLE, body_html)
end

-- Base32 secrets are 16-32 chars with no natural separators; grouping in
-- 4s (the same convention authenticator apps' own "enter manually" screens
-- use) makes them meaningfully easier to transcribe correctly by hand.
local function group_secret(secret)
  local groups = {}
  for i = 1, #secret, 4 do
    groups[#groups + 1] = secret:sub(i, i + 3)
  end
  return table.concat(groups, " ")
end

local function status_body(enabled, recovery_remaining, flash, error_message)
  local flash_html = flash and ('<div class="flash">%s</div>'):format(esc(flash)) or ""
  local error_html = error_message and ('<div class="error">%s</div>'):format(esc(error_message)) or ""

  if enabled then
    return ([[
      <h1>Two-factor authentication</h1>
      <p class="lede"><span class="status-badge on">Enabled</span> &middot; %d recovery code(s) remaining</p>
      %s%s
      <form method="POST" action="/settings/2fa/disable">
        <label for="password">Confirm your password to disable 2FA</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <button class="danger" type="submit">Disable 2FA</button>
      </form>
    ]]):format(recovery_remaining or 0, flash_html, error_html)
  end

  return ([[
    <h1>Two-factor authentication</h1>
    <p class="lede"><span class="status-badge off">Not enabled</span></p>
    %s%s
    <form method="POST" action="/settings/2fa/start">
      <button type="submit">Set up 2FA</button>
    </form>
  ]]):format(flash_html, error_html)
end

local function enroll_body(secret, uri, error_message)
  return ([[
    <h1>Set up two-factor authentication</h1>
    <p class="lede">Add this account to your authenticator app (Google Authenticator, Authy, 1Password, etc.), then enter the 6-digit code it shows.</p>
    <p class="lede">Enter this key manually:</p>
    <div class="secret">%s</div>
    <a class="otpauth" href="%s">Or tap to open in an authenticator app</a>
    %s
    <form method="POST" action="/settings/2fa/confirm">
      <label for="code">6-digit code</label>
      <input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" required autofocus>
      <button type="submit">Verify and enable</button>
    </form>
  ]]):format(
    esc(group_secret(secret)), esc(uri),
    error_message and ('<div class="error">%s</div>'):format(esc(error_message)) or ""
  )
end

local function recovery_codes_body(codes)
  local lines = {}
  for _, code in ipairs(codes) do lines[#lines + 1] = esc(code) end
  return ([[
    <h1>2FA enabled</h1>
    <p class="lede">Save these recovery codes somewhere safe -- each one can be used once if you lose access to your authenticator app. They will not be shown again.</p>
    <div class="recovery-codes">%s</div>
    <form method="GET" action="/settings/2fa">
      <button type="submit">Done</button>
    </form>
  ]]):format(table.concat(lines, "<br>"))
end

-- Every handler needs "logged in" (no site-owner requirement -- this is
-- every user's own account setting). Mirrors pages_admin.lua's gate()
-- shape but with a plain login check instead of require_site_owner.
local function require_login(req)
  local user, status, body = routes.require_login_for_page(req)
  if user then return user end
  return nil, 302, "", { ["Location"] = "/login" }
end

function M.settings_page(req)
  local user, err_status, err_body, err_headers = require_login(req)
  if not user then return err_status, err_body, err_headers end
  local _, status_data = routes.totp_status(req)
  local flash = req.query.flash
  return 200, layout("Two-Factor Authentication", status_body(status_data and status_data.enabled, status_data and status_data.recovery_codes_remaining, flash, nil)), HTML_HEADERS
end

function M.start_enrollment(req)
  local user, err_status, err_body, err_headers = require_login(req)
  if not user then return err_status, err_body, err_headers end
  local status, body = routes.totp_enroll(req)
  if status ~= 200 then
    return status, layout("Two-Factor Authentication", status_body(false, 0, nil, "Could not start setup.")), HTML_HEADERS
  end
  return 200, layout("Set up 2FA", enroll_body(body.secret, body.uri, nil)), HTML_HEADERS
end

function M.confirm_enrollment(req)
  local user, err_status, err_body, err_headers = require_login(req)
  if not user then return err_status, err_body, err_headers end
  local fields = parse_urlencoded(req.raw_body)
  req.json = { code = fields.code }
  local status, body = routes.totp_confirm(req)
  if status ~= 200 then
    -- Re-read the SAME still-pending secret to redisplay the form -- do
    -- NOT call routes.totp_enroll() again here, it unconditionally
    -- generates and stores a brand-new secret on every call, which would
    -- silently invalidate the one the user just scanned/entered and force
    -- them to start over for no reason.
    local row = db.fetchone("SELECT totp_secret, username FROM users WHERE id=%s", user.id)
    local message = (type(body) == "table" and body.detail) or "Verification failed."
    if row and row.totp_secret then
      local uri = totp.provisioning_uri(row.totp_secret, row.username, "Image Gallery")
      return status, layout("Set up 2FA", enroll_body(row.totp_secret, uri, message)), HTML_HEADERS
    end
    return status, layout("Two-Factor Authentication", status_body(false, 0, nil, message)), HTML_HEADERS
  end
  return 200, layout("2FA enabled", recovery_codes_body(body.recovery_codes or {})), HTML_HEADERS
end

function M.disable_totp(req)
  local user, err_status, err_body, err_headers = require_login(req)
  if not user then return err_status, err_body, err_headers end
  local fields = parse_urlencoded(req.raw_body)
  req.json = { password = fields.password }
  local status, body = routes.totp_disable(req)
  if status ~= 200 then
    local message = (type(body) == "table" and body.detail) or "Could not disable 2FA."
    return status, layout("Two-Factor Authentication", status_body(true, nil, nil, message)), HTML_HEADERS
  end
  return 200, layout("Two-Factor Authentication", status_body(false, 0, "2FA disabled.", nil)), HTML_HEADERS
end

return M
