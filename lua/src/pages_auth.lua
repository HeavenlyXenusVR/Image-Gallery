-- Server-rendered login/register pages, served directly at
-- gallery.xenusanimations.studio/login and /register instead of falling
-- through to the React SPA shell (see static.lua's fallback). This is a
-- deliberately narrow slice of a much larger "rewrite the SPA to Lua"
-- discussion -- everything else (Discover, media detail, messages,
-- profile, upload, studio, settings, ...) stays the React app. Only the
-- two simplest, lowest-interactivity, easiest-to-verify-via-curl pages
-- were picked for this pass.
--
-- These handlers do NOT reimplement auth logic: they parse the
-- application/x-www-form-urlencoded POST body into the same shape
-- routes.lua's json_body() expects, then call routes.login()/register()/
-- verify_2fa() directly, so validation/rate-limiting/ban-checks/2FA/
-- password hashing stay in exactly one place. On success they render a
-- small bridge page that seeds localStorage with the same
-- image_gallery_token/image_gallery_user keys frontend/src/api.js reads,
-- then redirects to "/" -- so the SPA sees an already-logged-in session
-- immediately, identical to what a normal in-app JS login produces.
--
-- Note on route shadowing: react-router already owns a client-side "/login"
-- route (frontend/src/App.jsx). In-app navigations to it (clicking a link
-- while the SPA is already loaded) never leave the page, so they still show
-- the React AuthPage. Only a hard navigation -- typing the URL, a fresh
-- page load, a redirect from elsewhere -- hits this Lua route instead. Both
-- are valid login UIs; they just look different depending on entry point.
-- No dedicated "/register" route exists in the SPA, so that path is purely
-- additive.
--
-- No CSRF token: same call as SwarmPanel's own login/logout forms (see
-- html.lua's session_bar). A login/register POST doesn't need CSRF
-- protection in the way a state-changing action on an already-authenticated
-- session would -- the worst case ("login CSRF") only logs the victim into
-- the attacker's account, which they'd notice immediately.

local routes = require("routes")
local html = require("html")

local M = {}

local esc = html.esc
local parse_urlencoded = html.parse_urlencoded

local function layout(title, body_html)
  return ([[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s // Nyxframe</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
    background: #101318; color: #e7e9ee;
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    padding: 24px;
  }
  .card {
    width: 100%%; max-width: 380px; background: rgba(255,255,255,0.04);
    border: 1px solid rgba(255,255,255,0.08); border-radius: 20px; padding: 32px;
    backdrop-filter: blur(12px);
  }
  h1 { margin: 0 0 4px; font-size: 22px; }
  p.lede { margin: 0 0 24px; color: #9aa1af; font-size: 14px; }
  label { display: block; font-size: 13px; color: #9aa1af; margin: 16px 0 6px; }
  input {
    width: 100%%; padding: 10px 12px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.12);
    background: rgba(255,255,255,0.03); color: #e7e9ee; font-size: 15px;
  }
  input:focus { outline: none; border-color: #37c9a7; }
  button {
    width: 100%%; margin-top: 24px; padding: 12px; border-radius: 12px; border: none;
    background: #37c9a7; color: #04211b; font-weight: 600; font-size: 15px; cursor: pointer;
  }
  button:hover { filter: brightness(1.08); }
  .error { background: rgba(220,80,80,0.15); border: 1px solid rgba(220,80,80,0.4);
    color: #ffb4b4; border-radius: 12px; padding: 10px 12px; margin-bottom: 4px; font-size: 14px; }
  .switch { margin-top: 20px; text-align: center; font-size: 14px; color: #9aa1af; }
  .switch a { color: #37c9a7; text-decoration: none; }
</style>
</head>
<body>
<div class="card">%s</div>
</body>
</html>]]):format(esc(title), body_html)
end

-- Rendered instead of a redirect so the signed token never has to travel
-- through a URL (query string/browser history/referrer headers) -- it's
-- only ever in this response body and the two localStorage keys it writes.
local function success_bridge(user, token)
  local user_json = require("cjson.safe").encode(user) or "{}"
  local token_json = require("cjson.safe").encode(token) or '""'
  return ([[<!doctype html>
<html><head><meta charset="utf-8"><title>Signing in...</title></head>
<body style="background:#101318;color:#e7e9ee;font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;">
<p>Signing you in...</p>
<script>
  localStorage.setItem("image_gallery_token", %s);
  localStorage.setItem("image_gallery_user", JSON.stringify(%s));
  window.location.replace("/");
</script>
</body></html>]]):format(token_json, user_json)
end

local function login_form_body(error_message, prefill_username)
  return ([[
    <h1>Welcome back</h1>
    <p class="lede">Sign in to Nyxframe.</p>
    %s
    <form method="POST" action="/login">
      <label for="username">Username</label>
      <input id="username" name="username" type="text" autocomplete="username" required value="%s">
      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required>
      <button type="submit">Sign in</button>
    </form>
    <div class="switch">New here? <a href="/register">Create an account</a></div>
  ]]):format(
    error_message and ('<div class="error">' .. esc(error_message) .. "</div>") or "",
    esc(prefill_username or "")
  )
end

local function twofa_form_body(pending_token, error_message)
  return ([[
    <h1>Two-factor code</h1>
    <p class="lede">Enter the 6-digit code from your authenticator app.</p>
    %s
    <form method="POST" action="/login/2fa">
      <input type="hidden" name="pending_token" value="%s">
      <label for="code">Code</label>
      <input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" required autofocus>
      <button type="submit">Verify</button>
    </form>
  ]]):format(
    error_message and ('<div class="error">' .. esc(error_message) .. "</div>") or "",
    esc(pending_token)
  )
end

local function register_form_body(error_message, prefill)
  prefill = prefill or {}
  return ([[
    <h1>Create your account</h1>
    <p class="lede">Join Nyxframe.</p>
    %s
    <form method="POST" action="/register">
      <label for="username">Username</label>
      <input id="username" name="username" type="text" autocomplete="username" required value="%s">
      <label for="email">Email (optional)</label>
      <input id="email" name="email" type="email" autocomplete="email" value="%s">
      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="new-password" required minlength="8">
      <button type="submit">Create account</button>
    </form>
    <div class="switch">Already have an account? <a href="/login">Sign in</a></div>
  ]]):format(
    error_message and ('<div class="error">' .. esc(error_message) .. "</div>") or "",
    esc(prefill.username), esc(prefill.email)
  )
end

local HTML_HEADERS = { ["Content-Type"] = "text/html; charset=utf-8" }

function M.login_page(_req)
  return 200, layout("Sign in", login_form_body(nil, nil)), HTML_HEADERS
end

function M.register_page(_req)
  return 200, layout("Create account", register_form_body(nil, nil)), HTML_HEADERS
end

function M.login_submit(req)
  local fields = parse_urlencoded(req.raw_body)
  req.json = { username = fields.username, password = fields.password }
  local status, body, headers = routes.login(req)

  if status == 200 and body.needs_2fa then
    return 200, layout("Two-factor code", twofa_form_body(body.pending_token, nil)), HTML_HEADERS
  end
  if status ~= 200 then
    local message = (type(body) == "table" and body.detail) or "Sign-in failed."
    return status, layout("Sign in", login_form_body(message, fields.username)), HTML_HEADERS
  end

  local response_headers = { ["Content-Type"] = "text/html; charset=utf-8" }
  for k, v in pairs(headers or {}) do response_headers[k] = v end
  return 200, success_bridge(body.user, body.token), response_headers
end

function M.twofa_submit(req)
  local fields = parse_urlencoded(req.raw_body)
  req.json = { pending_token = fields.pending_token, code = fields.code }
  local status, body, headers = routes.verify_2fa(req)

  if status ~= 200 then
    local message = (type(body) == "table" and body.detail) or "Verification failed."
    return status, layout("Two-factor code", twofa_form_body(fields.pending_token, message)), HTML_HEADERS
  end

  local response_headers = { ["Content-Type"] = "text/html; charset=utf-8" }
  for k, v in pairs(headers or {}) do response_headers[k] = v end
  return 200, success_bridge(body.user, body.token), response_headers
end

function M.register_submit(req)
  local fields = parse_urlencoded(req.raw_body)
  req.json = { username = fields.username, password = fields.password, email = fields.email }
  local status, body, headers = routes.register(req)

  if status ~= 200 then
    local message = (type(body) == "table" and body.detail) or "Registration failed."
    return status, layout("Create account", register_form_body(message, fields)), HTML_HEADERS
  end

  local response_headers = { ["Content-Type"] = "text/html; charset=utf-8" }
  for k, v in pairs(headers or {}) do response_headers[k] = v end
  return 200, success_bridge(body.user, body.token), response_headers
end

return M
