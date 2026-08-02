-- Small shared helpers for the server-rendered pages (pages_auth.lua,
-- pages_admin.lua, ...). Deliberately tiny, no templating engine -- plain
-- Lua string-building with an explicit escaping helper, same approach as
-- SwarmPanel's src/html.lua. Every value interpolated into HTML from
-- user/DB data MUST go through esc() or it's an XSS hole.

local M = {}

local ESCAPE_MAP = {
  ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
  ['"'] = "&quot;", ["'"] = "&#39;",
}

-- routes.lua's arr() returns the special cjson.empty_array sentinel
-- (lightuserdata, not a table) for empty lists, so JSON responses encode
-- "[]" instead of "{}". These server-rendered pages call routes.* handlers
-- directly and iterate their response tables with ipairs() instead of
-- going through cjson -- ipairs() on that sentinel throws "table expected,
-- got userdata". Wrap any list pulled from a routes.* response body in
-- this before ipairs()-ing it.
function M.as_list(v)
  if type(v) == "table" then return v end
  return {}
end

function M.esc(v)
  if v == nil then return "" end
  if type(v) == "boolean" then v = tostring(v) end
  return (tostring(v):gsub('[&<>"\']', ESCAPE_MAP))
end

function M.urldecode(s)
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

-- Parses "a=b&c=d%20e" (application/x-www-form-urlencoded) -- the body
-- shape a plain HTML <form method="POST"> without enctype sends.
-- httpd.lua only parses application/json and multipart/form-data bodies;
-- these server-rendered pages are the only callers that need the third
-- standard content type, so it's handled here rather than growing
-- httpd.lua's request parser for a handful of call sites.
function M.parse_urlencoded(raw_body)
  local fields = {}
  for pair in (raw_body or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then
      fields[M.urldecode(k)] = M.urldecode(v or "")
    end
  end
  return fields
end

-- Minimal human-readable byte formatter (mirrors frontend/src/utils/format.js's
-- formatBytes()) for the storage dashboard.
function M.format_bytes(n)
  n = tonumber(n) or 0
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while n >= 1024 and i < #units do
    n = n / 1024
    i = i + 1
  end
  if i == 1 then return string.format("%d %s", n, units[i]) end
  return string.format("%.1f %s", n, units[i])
end

-- Truncates an ISO8601 timestamp to "YYYY-MM-DD HH:MM" for compact display
-- -- these pages don't need relative "3h ago" formatting (no client JS date
-- library here), just something readable.
function M.format_date(iso)
  if not iso or iso == "" then return "" end
  local date_part, time_part = tostring(iso):match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)")
  if date_part then return date_part .. " " .. time_part end
  return tostring(iso):sub(1, 16)
end

return M
