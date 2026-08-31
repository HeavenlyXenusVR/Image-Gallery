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
local bit = require("bit")
local ws_handshake = require("websocket.handshake")
local ws_sync = require("websocket.sync")

local M = {}
M.routes = {} -- { {method=, pattern=, keys={}, handler=} }
M.ws_routes = {} -- { {pattern=, handler=} }, GET+Upgrade:websocket only, exact-path match
M.cors = { allowed_origins = {}, origin_suffix_matcher = nil }
-- CIDR allow-list of peers this server will trust an incoming
-- X-Forwarded-For header from (set by main.lua from
-- config.lua's trusted_proxy_cidrs, itself GALLERY_TRUSTED_PROXY_CIDRS).
-- Populated before M.serve() is ever called; nil/empty means "trust no
-- one" -- every request then falls back to its raw TCP peer address, same
-- as if XFF were never sent. See ip_in_trusted_cidrs() below.
M.trusted_proxy_cidrs = {}
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

-- Baseline security headers, applied to every response. Nothing here is
-- environment-specific (unlike CORS) so it's safe to hardcode: this backend
-- is only ever reached over HTTPS in production (the Cloudflare tunnel
-- terminates TLS in front of it), and there's no legitimate reason for this
-- API/gallery to be framed by another site or have the browser MIME-sniff
-- its responses.
local function apply_security_headers(headers_out)
  -- Pins HTTPS for a year including subdomains, and opts into the browser
  -- preload list -- closes the window where a plain http:// first request
  -- could be intercepted before ever seeing a redirect.
  headers_out["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
  headers_out["X-Content-Type-Options"] = "nosniff"
  headers_out["X-Frame-Options"] = "DENY"
  headers_out["Referrer-Policy"] = "strict-origin-when-cross-origin"
end

local function apply_cors(headers_out, req_headers)
  apply_security_headers(headers_out)
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

-- ---------------------------------------------------------------------------
-- Access logging (Feature: request/status logging).
--
-- Previously this server logged nothing per-request at all -- no method,
-- path, status, timing, or client IP for any request, successful or not.
-- Combined with the unhandled-error swallowing this same file used to have
-- (see the 500 path below), that meant there was no way to answer "what did
-- the last hour of traffic actually look like" short of adding print()
-- statements by hand, reproducing, and removing them again -- exactly what
-- happened while diagnosing the HLS transcode-slot leak this same session.
--
-- One line per request, written to stdout (captured by journald under this
-- service's unit, same as every other log line here) once the response has
-- actually been sent, so the logged status always reflects what the client
-- received -- not what a handler intended to send before some later step
-- (CORS headers, body encoding) failed.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Trusted-proxy CIDR matching, for deciding whether to honor an incoming
-- X-Forwarded-For header at all (see M.trusted_proxy_cidrs above). No CIDR
-- utility existed anywhere in this codebase before this fix (confirmed via
-- grep across lua/src/*.lua) -- this is intentionally small: it only needs
-- to handle the shapes GALLERY_TRUSTED_PROXY_CIDRS actually holds
-- ("a.b.c.d/n" for IPv4, "addr/128" for an exact IPv6 match), not full
-- generality.
-- ---------------------------------------------------------------------------

local function ipv4_to_int(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if not (a and b and c and d) then return nil end
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

-- ip: plain address string (no port). cidr: "network/bits", or a bare
-- address (treated as an exact match, bits implied = full width).
local function ip_in_cidr(ip, cidr)
  if not ip or ip == "" then return false end
  local net, bits_str = cidr:match("^([^/]+)/(%d+)$")
  if not net then
    return ip == cidr
  end
  local bits = tonumber(bits_str)
  local is_v6 = ip:find(":", 1, true) or net:find(":", 1, true)
  if is_v6 then
    -- Only IPv6 CIDR actually configured for this deployment is ::1/128
    -- (loopback, exact match) -- rather than implement full 128-bit prefix
    -- math for a case that never comes up, this fails closed (does not
    -- match) for any IPv6 prefix shorter than /128, and does a plain string
    -- compare for /128.
    if bits >= 128 then return ip == net end
    return false
  end
  local ip_int, net_int = ipv4_to_int(ip), ipv4_to_int(net)
  if not ip_int or not net_int then return false end
  if bits <= 0 then return true end
  if bits >= 32 then return ip_int == net_int end
  local mask = bit.bnot(bit.rshift(0xFFFFFFFF, bits)) -- LuaJIT bit.* args/results are 32-bit
  return bit.band(ip_int, mask) == bit.band(net_int, mask)
end

local function ip_in_trusted_cidrs(ip)
  for _, cidr in ipairs(M.trusted_proxy_cidrs or {}) do
    if ip_in_cidr(ip, cidr) then return true end
  end
  return false
end

local function access_log_line(method, path, status, duration_ms, client_ip, user_agent)
  local level = (status and status >= 500) and "ERROR"
    or (status and status >= 400) and "WARN"
    or "INFO"
  print(string.format(
    "[access] %-5s %-45s %3d  %6.1fms  ip=%s  level=%s ua=%s",
    tostring(method or "?"), tostring(path or "?"), tonumber(status) or 0,
    duration_ms, tostring(client_ip or "?"), level,
    tostring((user_agent or ""):sub(1, 80))
  ))
end

local function handle_connection(sock)
  local start_time = socket.gettime()
  -- Populated as the request is parsed, so a log line can still be written
  -- (with whatever's known so far) even for a request that fails before a
  -- route was ever matched -- e.g. a malformed request line.
  local log_method, log_path, log_status, log_ip, log_ua = nil, nil, nil, nil, nil

  -- Every response in this function should go through this instead of
  -- calling send_response directly, purely so log_status always reflects
  -- what actually got sent to the client, from every exit path below.
  local function respond(status, status_text, headers, body)
    log_status = status
    send_response(sock, status, status_text, headers, body)
  end

  local ok, err = pcall(function()
    local first_line, headers = read_headers(sock)
    if not first_line then return end
    local method, path_and_query = first_line:match("^(%u+)%s+(%S+)%s+HTTP/")
    log_method = method or "?"
    if not method then
      respond(400, "Bad Request", {}, cjson.encode({ detail = "Malformed request line" }))
      return
    end
    local path, qs = path_and_query:match("^([^?]*)%??(.*)$")
    log_path = path
    local query = parse_query(qs)

    -- Client IP + User-Agent computed here (not just on the matched-route
    -- path below) so even a 400/404/OPTIONS response still logs who sent
    -- it. Only honors X-Forwarded-For when the actual TCP peer (this
    -- backend sits behind the cloudflared tunnel / nyxframe-proxy) is
    -- itself in M.trusted_proxy_cidrs -- otherwise ANY visitor could set
    -- their own X-Forwarded-For header and have it trusted outright, which
    -- silently defeated every IP-keyed rate limit in routes.lua
    -- (registration, login lockout, download-batch: an attacker could just
    -- roll the header to reset their own bucket on every request). Falls
    -- back to the raw peer address for direct/untrusted connections either
    -- way. Mirrors security.py's _client_ip(), now with the trust check
    -- Python's version already had.
    local peer_ok, peer_ip = pcall(function() return (sock:getpeername()) end)
    peer_ip = (peer_ok and peer_ip) or "unknown"
    local client_ip = peer_ip
    if ip_in_trusted_cidrs(peer_ip) then
      local xff = (headers["x-forwarded-for"] or ""):match("^[^,]+")
      xff = xff and xff:match("^%s*(.-)%s*$")
      if xff and xff ~= "" then client_ip = xff end
    end
    log_ip = client_ip
    log_ua = headers["user-agent"]

    if method == "GET" and (headers["upgrade"] or ""):lower() == "websocket" then
      local ws_handler = match_ws_route(path)
      if ws_handler then
        log_status = 101
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
      respond(204, "No Content", resp_headers, "")
      return
    end

    local handler, params = match_route(method, path)
    if not handler then
      if M.fallback_handler then
        local fb_status, fb_body, fb_headers = M.fallback_handler(method, path, headers)
        if fb_status then
          for k, v in pairs(fb_headers or {}) do resp_headers[k] = v end
          respond(fb_status, STATUS_TEXT[fb_status] or "OK", resp_headers, fb_body)
          return
        end
      end
      resp_headers["Content-Type"] = "application/json"
      respond(404, "Not Found", resp_headers, cjson.encode({ detail = "Not found" }))
      return
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
    respond(status, STATUS_TEXT[status] or "OK", resp_headers, body_out)
  end)
  if not ok then
    -- Previously silent: `err` was caught but never logged anywhere, so
    -- every 500 was completely invisible in `journalctl` -- the only way
    -- to diagnose one was reproducing it with ad-hoc print() patches added
    -- and removed by hand. print() here goes to the unit's stdout, same as
    -- every other log line this service already emits.
    print("[nyxframe] unhandled error: " .. tostring(err))
    log_status = 500
    pcall(respond, 500, "Internal Server Error", { ["Content-Type"] = "application/json" }, cjson.encode({ detail = "Internal server error" }))
  end
  if log_method then
    -- log_method is only nil for a connection that closed before sending
    -- any request line at all (e.g. a TCP health-check probe) -- nothing
    -- meaningful to log for those.
    access_log_line(log_method, log_path, log_status, (socket.gettime() - start_time) * 1000, log_ip, log_ua)
    io.stdout:flush()
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
