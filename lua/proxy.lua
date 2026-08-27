-- Minimal TCP round-robin reverse proxy in front of N Nyxframe backend
-- worker processes (see main.lua), each listening on 127.0.0.1 at its own
-- port. Built on copas+luasocket -- already vendored and already this
-- deployment's event-loop model (see httpd.lua's own listen()/run()) --
-- rather than reaching for nginx/haproxy, neither of which is installed on
-- this box and both of which would be a second, unrelated piece of
-- infrastructure to operate for what one small Lua file covers.
--
-- Deliberately dumb: a byte-level TCP relay, not an HTTP-aware reverse
-- proxy. Parsing/rewriting HTTP here would mean re-implementing chunked
-- transfer encoding, WebSocket framing, and Range/206 handling a second
-- time on top of what httpd.lua already does in every worker -- a raw
-- socket splice handles all of those transparently, since it never
-- inspects the bytes, just relays them in both directions.
--
-- Round-robin is per TCP CONNECTION, not per request -- normally a real
-- limitation for an HTTP proxy (one client's persistent keep-alive
-- connection would stick to a single backend for its whole lifetime), but
-- httpd.lua always sends "Connection: close" (see its send_response()) and
-- has no keep-alive support at all, so every request opens a brand new
-- connection here anyway. Per-connection round-robin is therefore exactly
-- equivalent to per-request round-robin for this backend specifically --
-- this would need revisiting if httpd.lua ever grows keep-alive support.
--
-- Run with: luajit proxy.lua   (see nyxframe-proxy.service)

package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local socket = require("socket")
local copas = require("copas")

local LISTEN_HOST = os.getenv("GALLERY_PROXY_HOST") or "0.0.0.0"
local LISTEN_PORT = tonumber(os.getenv("GALLERY_PROXY_PORT")) or 8789
local RELAY_CHUNK_BYTES = 8192

-- Comma-separated "host:port" list of backend workers, e.g.
-- "127.0.0.1:8790,127.0.0.1:8791". Falls back to a single pre-multi-worker
-- port if unset, so this proxy is a safe drop-in even before
-- GALLERY_PROXY_BACKENDS is configured anywhere.
local function parse_backends(raw)
  local backends = {}
  for entry in tostring(raw or ""):gmatch("[^,]+") do
    local host, port = entry:match("^%s*([^:]+):(%d+)%s*$")
    if host and port then backends[#backends + 1] = { host = host, port = tonumber(port) } end
  end
  return backends
end

local backends = parse_backends(os.getenv("GALLERY_PROXY_BACKENDS"))
if #backends == 0 then
  backends = { { host = "127.0.0.1", port = tonumber(os.getenv("GALLERY_HTTP_PORT")) or 8788 } }
end

do
  local labels = {}
  for _, b in ipairs(backends) do labels[#labels + 1] = b.host .. ":" .. b.port end
  print(string.format("[nyxframe-proxy] listening on %s:%d -> backends: %s",
    LISTEN_HOST, LISTEN_PORT, table.concat(labels, ", ")))
end

local next_backend = 0

-- Round-robins across every backend once per connection, skipping any that
-- refuse the TCP connect (a worker that's down, still starting up, or mid-
-- restart) rather than failing the client outright -- the whole point of
-- running more than one worker is that one being slow/dead shouldn't take
-- the site down with it.
local function connect_backend()
  for _ = 1, #backends do
    next_backend = (next_backend % #backends) + 1
    local b = backends[next_backend]
    local upstream = socket.tcp()
    local ok = copas.connect(upstream, b.host, b.port)
    if ok then return upstream, b end
    pcall(function() upstream:close() end)
  end
  return nil
end

-- Relays bytes from `from_sock` to `to_sock` until either side closes or
-- errors, then closes both ends. receivepartial (not a fixed-size receive)
-- is what makes this safe for interactive/streaming traffic: it returns as
-- soon as ANY data arrives ("timeout" on the underlying non-blocking read
-- just means "less than RELAY_CHUNK_BYTES available right now", not an
-- error -- only a non-timeout err, e.g. "closed", means the connection is
-- actually done), instead of blocking until a full RELAY_CHUNK_BYTES chunk
-- accumulates, which would otherwise stall small requests and keep-alive
-- idle periods.
local function pump(from_sock, to_sock)
  while true do
    local data, err, partial = copas.receivepartial(from_sock, RELAY_CHUNK_BYTES)
    local payload = data or partial
    if payload and #payload > 0 then
      if not copas.send(to_sock, payload) then break end
    end
    if not data and err ~= "timeout" then break end
  end
  pcall(function() from_sock:close() end)
  pcall(function() to_sock:close() end)
end

local function handle_connection(client)
  local upstream = connect_backend()
  if not upstream then
    pcall(function() client:close() end)
    return
  end
  -- Both directions need to pump concurrently -- one coroutine can't block
  -- on "read from client" and "read from upstream" at the same time, so the
  -- reverse direction runs as its own copas thread while this one handles
  -- client -> upstream.
  copas.addthread(pump, upstream, client)
  pump(client, upstream)
end

local server = assert(socket.bind(LISTEN_HOST, LISTEN_PORT))
copas.addserver(server, handle_connection)
print(string.format("[nyxframe-proxy] ready"))
copas.loop()
