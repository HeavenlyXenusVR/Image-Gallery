-- Serves the built React SPA directly from the Lua backend so that
-- gallery.xenusanimations.studio is a fully working site on its own, not
-- just a JSON API -- mirrors SwarmPanel's src/static.lua pattern (see
-- SwarmPanel-strictly-Lua rewrite), adapted for a Vite-built SPA with
-- content-hashed asset filenames (SwarmPanel's static assets are two fixed
-- hand-written files, so it doesn't need the wildcard route below).
--
-- static/react/index.html is Vite's own build output with base:
-- "/static/react/" -- its asset paths are already root-relative
-- (/static/react/assets/...), so serving it unmodified at this backend's
-- own root is correct with zero rewriting, unlike the GitHub Pages shell
-- (index.html at repo root) which needs the extra /Image-Gallery/ prefix
-- injected by scripts/write-root-shell.mjs for that separate deployment.
local httpd = require("httpd")

local M = {}

local CONTENT_TYPES = {
  js = "application/javascript; charset=utf-8",
  css = "text/css; charset=utf-8",
  png = "image/png",
  ico = "image/vnd.microsoft.icon",
  webmanifest = "application/manifest+json",
  json = "application/json",
  map = "application/json",
  html = "text/html; charset=utf-8",
}

local function ext_of(filename)
  return filename:match("%.([%w]+)$")
end

local function read_file(relpath)
  local f = io.open(relpath, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local EXACT_ASSETS = {
  { path = "/favicon.ico", file = "../static/react/favicon.ico" },
  { path = "/service-worker.js", file = "../static/react/service-worker.js" },
  { path = "/static/react/favicon.ico", file = "../static/react/favicon.ico" },
  { path = "/static/react/apple-touch-icon.png", file = "../static/react/apple-touch-icon.png" },
  { path = "/static/react/manifest.webmanifest", file = "../static/react/manifest.webmanifest" },
  { path = "/static/react/pwa-192.png", file = "../static/react/pwa-192.png" },
  { path = "/static/react/pwa-512.png", file = "../static/react/pwa-512.png" },
  { path = "/static/react/service-worker.js", file = "../static/react/service-worker.js" },
}

local function serve_file(relpath)
  local data = read_file(relpath)
  if not data then return 404, "Not found", { ["Content-Type"] = "text/plain" } end
  local content_type = CONTENT_TYPES[ext_of(relpath)] or "application/octet-stream"
  return 200, data, {
    ["Content-Type"] = content_type,
    ["Cache-Control"] = "public, max-age=300",
  }
end

function M.register()
  for _, asset in ipairs(EXACT_ASSETS) do
    httpd.route("GET", asset.path, function() return serve_file(asset.file) end)
  end

  -- Content-hashed build output (index-XXXXXXXX.js/.css, plus .map files
  -- when sourcemaps are enabled) -- filenames change per build, so a single
  -- parametric route beats hardcoding today's hashes.
  httpd.route("GET", "/static/react/assets/:file", function(req)
    return serve_file("../static/react/assets/" .. req.params.file)
  end)
end

-- SPA fallback: any GET that isn't an API route and isn't a known static
-- asset above falls through to httpd's "no route matched" path, which
-- calls this. Serves the same index.html for "/", "/media/123",
-- "/users/alice", etc. -- client-side react-router then takes over,
-- exactly like the GitHub Pages 404.html trick this backend previously
-- relied on, except here it's a real 200 instead of a 404-that-looks-fine.
function M.fallback(method, path)
  if method ~= "GET" then return nil end
  if path:match("^/api/") then return nil end
  return serve_file("../static/react/index.html")
end

return M
