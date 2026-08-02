-- Minimal HTTP/1.1 JSON API server on copas+luasocket.
--
-- Framework choice (see final report for full justification): copas +
-- luasocket + a hand-rolled request/response layer, all libraries already
-- vendored/proven in this exact environment for the 13 Lua bot rewrites
-- (lua-shared/swarmlua). Rejected alternatives:
--   * OpenResty/nginx  - explicitly ruled out by the deployment model (plain
--     LuaJIT in Alpine, no nginx sidecar, matches the bots).
--   * pegasus.lua      - a reasonable pure-Lua HTTP framework, but it is a
--     NEW dependency with no track record in this project, whereas copas is
--     already installed, tested, and used for the bots' own event loop.
--   * lua-http (cqueues) - modern and full-featured, but built on cqueues, a
--     different event-loop model than the copas loop the rest of the swarm
--     already standardized on; mixing two coroutine schedulers in one
--     process is asking for trouble.
-- WebSocket upgrade: implemented below using the already-installed
-- `lua-websockets` rock's `websocket.handshake` (Sec-WebSocket-Accept
-- computation for the 101 response) and `websocket.sync` (frame
-- encode/decode glued to a socket via sock_send/sock_receive/sock_close
-- callbacks) — reusing the accepted HTTP socket directly, no second
-- listener/port needed. See M.ws_route()/handle_ws_upgrade() below. The
-- receive side does NOT reuse websocket.sync's own receive() for the read
-- loop in routes.lua's /ws handler, because that function treats every
-- socket error -- including a plain read timeout -- as a fatal disconnect,
-- and this server needs "no message in N seconds" to mean "send a keepalive
-- ping and keep waiting", matching app/routers/websocket.py's behavior.

local socket = require("socket")
local copas = require("copas")
local cjson = require("cjson.safe")
local ws_handshake = require("websocket.handshake")
local ws_sync = require("websocket.sync")

local M = {}
M.routes = {} -- { {method=, pattern=, keys={}, handler=} }
M.ws_routes = {} -- { {pattern=, handler=} }, GET+Upgrade:websocket only, exact-path match
M.cors = { allowed_origins = {}, origin_suffix_matcher = nil }
-- Optional fallback(method, path) -> status, body, headers | nil, called only
-- when no registered route matches. Returning nil keeps the normal JSON 404
-- (see static.lua's SPA fallback, the only current user of this hook).
M.fallback_handler = nil

local function split_path_pattern(pattern)
  local keys = {}
  local regex = "^" .. pattern:gsub("([%.%-%+%[%]%(%)%$%^%%])", "%%%1"):gsub(":([%w_]+)", function(name)
    keys[#keys + 1] = name
    return "([^/]+)"
  end) .. "$"
  return regex, keys
end

function M.route(method, pattern, handler)
  local regex, keys = split_path_pattern(pattern)
  M.routes[#M.routes + 1] = { method = method, regex = regex, keys = keys, handler = handler, pattern = pattern }
end

-- WS routes are exact-path only (just "/ws" today) — no :param support needed.
-- handler(conn, req, sock) owns the full connection lifecycle (its own
-- receive/send loop) and is called once per accepted upgrade; httpd closes
-- the socket when the handler returns, if it isn't already closed.
function M.ws_route(pattern, handler)
  M.ws_routes[#M.ws_routes + 1] = { pattern = pattern, handler = handler }
end

local function match_ws_route(path)
  for _, r in ipairs(M.ws_routes) do
    if r.pattern == path then return r.handler end
  end
  return nil
end

local function match_route(method, path)
  for _, r in ipairs(M.routes) do
    if r.method == method then
      if #r.keys > 0 then
        local caps = { path:match(r.regex) }
        if caps[1] ~= nil then
          local params = {}
          for i, k in ipairs(r.keys) do params[k] = caps[i] end
          return r.handler, params
        end
      elseif path:match(r.regex) then
        return r.handler, {}
      end
    end
  end
  return nil
end

-- Minimal multipart/form-data parser for file uploads (mirrors what FastAPI's
-- UploadFile/Form(...) parsing gives app/routers/media.py's upload_media).
-- Whole body is already in memory by the time this runs (see the
-- content-length read in handle_connection below) -- same tradeoff already
-- accepted elsewhere in this port (e.g. media_files.lua's ffmpeg shell-out)
-- rather than streaming multi-GB uploads to a temp file the way Python's
-- _read_validated_upload_streamed does; fine for this deployment's traffic
-- level, revisit if very large uploads become common.
local function parse_multipart(body, boundary)
  local form, files = {}, {}
  local delim = "--" .. boundary
  local pos = 1
  local parts = {}
  while true do
    local s, e = body:find(delim, pos, true)
    if not s then break end
    local next_s = body:find(delim, e + 1, true)
    if not next_s then break end
    parts[#parts + 1] = body:sub(e + 1, next_s - 1)
    pos = next_s
  end
  for _, part in ipairs(parts) do
    part = part:gsub("^\r\n", "")
    local header_end = part:find("\r\n\r\n", 1, true)
    if header_end then
      local header_block = part:sub(1, header_end - 1)
      local content = part:sub(header_end + 4):gsub("\r\n$", "")
      local name = header_block:match('name="([^"]*)"')
      local filename = header_block:match('filename="([^"]*)"')
      local content_type = header_block:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)")
      if name and filename ~= nil then
        files[name] = { filename = filename, content_type = content_type, content = content }
      elseif name then
        form[name] = content
      end
    end
  end
  return form, files
end

local function url_decode(s)
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

local function parse_query(qs)
  local out = {}
  if not qs then return out end
  for pair in qs:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=?(.*)$")
    if k then out[url_decode(k)] = url_decode(v or "") end
  end
  return out
end

local function origin_allowed(origin)
  if not origin or origin == "" then return false end
  for _, allowed in ipairs(M.cors.allowed_origins) do
    if allowed == origin then return true end
  end
  if M.cors.origin_suffix_matcher and M.cors.origin_suffix_matcher(origin) then
    return true
  end
  return false
end

local function apply_cors(headers_out, req_headers)
  local origin = req_headers["origin"]
  if origin_allowed(origin) then
    headers_out["Access-Control-Allow-Origin"] = origin
    headers_out["Access-Control-Allow-Credentials"] = "true"
    headers_out["Vary"] = "Origin"
  end
  headers_out["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  headers_out["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
end

local function read_headers(sock)
  local headers = {}
  local first_line = nil
  while true do
    local line, err = copas.receive(sock, "*l")
    if not line then return nil, nil, err end
    if first_line == nil then
      first_line = line
    elseif line == "" then
      break
    else
      local k, v = line:match("^([^:]+):%s*(.*)$")
      if k then headers[k:lower()] = v end
    end
  end
  return first_line, headers
end

local function send_response(sock, status, status_text, headers, body)
  body = body or ""
  headers["Content-Length"] = tostring(#body)
  headers["Connection"] = "close"
  headers["Server"] = "SwarmPanel-Lua"
  local lines = { string.format("HTTP/1.1 %d %s", status, status_text) }
  for k, v in pairs(headers) do
    lines[#lines + 1] = string.format("%s: %s", k, tostring(v))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  copas.send(sock, table.concat(lines, "\r\n"))
end

local STATUS_TEXT = {
  [200] = "OK", [201] = "Created", [204] = "No Content", [206] = "Partial Content",
  [301] = "Moved Permanently", [303] = "See Other",
  [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
  [404] = "Not Found", [405] = "Method Not Allowed", [409] = "Conflict",
  [416] = "Range Not Satisfiable",
  [429] = "Too Many Requests", [500] = "Internal Server Error",
  [503] = "Service Unavailable",
}

-- Accepts a WS upgrade on the already-accepted HTTP socket and hands off to
-- the registered handler for the rest of the connection's lifetime. Mirrors
-- websocket.handshake.accept_upgrade()'s own validation (upgrade/connection/
-- version/key headers present) but works from the already-parsed headers
-- table instead of re-parsing raw request text, since httpd.lua already did
-- that in read_headers().
local function handle_ws_upgrade(sock, headers, path, query, handler)
  local key = headers["sec-websocket-key"]
  local version = headers["sec-websocket-version"]
  local connection_hdr = (headers["connection"] or ""):lower()
  if not key or key == "" or version ~= "13" or not connection_hdr:match("upgrade") then
    pcall(copas.send, sock, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    return
  end
  local origin = headers["origin"]
  if origin and origin ~= "" and not origin_allowed(origin) then
    pcall(copas.send, sock, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    return
  end

  local accept_key = ws_handshake.sec_websocket_accept(key)
  local resp = "HTTP/1.1 101 Switching Protocols\r\n"
    .. "Upgrade: websocket\r\n"
    .. "Connection: Upgrade\r\n"
    .. "Sec-WebSocket-Accept: " .. accept_key .. "\r\n\r\n"
  local sent = copas.send(sock, resp)
  if not sent then
    pcall(function() sock:close() end)
    return
  end

  local conn = { is_server = true, state = "OPEN" }
  conn.sock_send = function(_, ...) return copas.send(sock, ...) end
  conn.sock_receive = function(_, ...) return copas.receive(sock, ...) end
  conn.sock_close = function(_)
    pcall(function() sock:shutdown() end)
    pcall(function() sock:close() end)
  end
  conn = ws_sync.extend(conn)

  local req = { path = path, query = query or {}, headers = headers }
  local ok, err = pcall(handler, conn, req, sock)
  if not ok then
    print("[swarmpanel-lua] ws handler error: " .. tostring(err))
  end
  if conn.state ~= "CLOSED" then
    pcall(function() conn:close() end)
  end
  pcall(function() sock:close() end)
end

local function handle_connection(sock)
  local ok, err = pcall(function()
    local first_line, headers = read_headers(sock)
    if not first_line then return end
    local method, path_and_query = first_line:match("^(%u+)%s+(%S+)%s+HTTP/")
    if not method then
      send_response(sock, 400, "Bad Request", {}, cjson.encode({ detail = "Malformed request line" }))
      return
    end
    local path, qs = path_and_query:match("^([^?]*)%??(.*)$")
    local query = parse_query(qs)

    if method == "GET" and (headers["upgrade"] or ""):lower() == "websocket" then
      local ws_handler = match_ws_route(path)
      if ws_handler then
        handle_ws_upgrade(sock, headers, path, query, ws_handler)
        return
      end
      -- No matching WS route: fall through to the normal 404 path below (no
      -- body to read on a GET+Upgrade request either way).
    end

    local body = ""
    local content_length = tonumber(headers["content-length"] or "0") or 0
    if content_length > 0 then
      local data, rerr = copas.receive(sock, content_length)
      body = data or ""
    end

    local resp_headers = {}
    apply_cors(resp_headers, headers)

    if method == "OPTIONS" then
      send_response(sock, 204, "No Content", resp_headers, "")
      return
    end

    local handler, params = match_route(method, path)
    if not handler then
      if M.fallback_handler then
        local fb_status, fb_body, fb_headers = M.fallback_handler(method, path)
        if fb_status then
          for k, v in pairs(fb_headers or {}) do resp_headers[k] = v end
          send_response(sock, fb_status, STATUS_TEXT[fb_status] or "OK", resp_headers, fb_body)
          return
        end
      end
      resp_headers["Content-Type"] = "application/json"
      send_response(sock, 404, "Not Found", resp_headers, cjson.encode({ detail = "Not found" }))
      return
    end

    -- Client IP: prefer X-Forwarded-For (this panel typically sits behind
    -- the cloudflared/ngrok tunnel in .bin/, see task #12), falling back to
    -- the raw peer address for direct/local connections. Mirrors
    -- security.py's _client_ip().
    local xff = (headers["x-forwarded-for"] or ""):match("^[^,]+")
    local client_ip = (xff and xff:match("^%s*(.-)%s*$") ~= "" and xff:match("^%s*(.-)%s*$")) or nil
    if not client_ip then
      local peer_ok, peer_ip = pcall(function() return (sock:getpeername()) end)
      client_ip = (peer_ok and peer_ip) or "unknown"
    end

    local req = {
      method = method,
      path = path,
      query = query,
      params = params or {},
      headers = headers,
      raw_body = body,
      client_ip = client_ip,
      form = {},
      files = {},
    }
    local content_type = headers["content-type"] or ""
    if body ~= "" and content_type:match("application/json") then
      local decoded = cjson.decode(body)
      req.json = decoded or {}
    elseif body ~= "" and content_type:match("multipart/form%-data") then
      local boundary = content_type:match('boundary="?([^";]+)"?')
      if boundary then
        req.form, req.files = parse_multipart(body, boundary)
      end
      req.json = {}
    else
      req.json = {}
    end

    local status, resp_body, extra_headers = handler(req)
    status = status or 200
    for k, v in pairs(extra_headers or {}) do resp_headers[k] = v end
    resp_headers["Content-Type"] = resp_headers["Content-Type"] or "application/json"
    local body_out
    if type(resp_body) == "table" then
      body_out = cjson.encode(resp_body)
    else
      body_out = tostring(resp_body or "")
    end
    send_response(sock, status, STATUS_TEXT[status] or "OK", resp_headers, body_out)
  end)
  if not ok then
    pcall(send_response, sock, 500, "Internal Server Error", { ["Content-Type"] = "application/json" }, cjson.encode({ detail = "Internal server error" }))
  end
  pcall(function() sock:close() end)
end

function M.listen(host, port)
  local server = assert(socket.bind(host, port))
  server:settimeout(0)
  copas.addserver(server, handle_connection)
  print(string.format("[swarmpanel-lua] listening on %s:%d", host, port))
end

function M.run()
  copas.loop()
end

return M
