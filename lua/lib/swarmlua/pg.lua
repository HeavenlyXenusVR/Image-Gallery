-- Postgres connection helper (pgmoon-backed), auto-reconnecting.
local pgmoon = require("pgmoon")
local unpack = table.unpack or unpack
local copas_ok, copas = pcall(require, "copas")

local Pg = {}
Pg.__index = Pg

function Pg.new(opts)
  local self = setmetatable({}, Pg)
  self.opts = {
    host = opts.host or "127.0.0.1",
    port = tonumber(opts.port or 5432),
    user = opts.user,
    password = opts.password,
    database = opts.database,
  }
  self.conn = nil
  self.busy = false
  return self
end

-- All requests share ONE physical pgmoon connection (see the header
-- comment), and now that it yields via copas instead of blocking, two
-- coroutines can genuinely interleave: A sends a query and yields waiting
-- on the socket, B sends its own query on the SAME connection before A's
-- response has been fully read, and the two responses corrupt each other
-- on the wire (observed as query() returning nil / request 500s under
-- concurrent load). A plain busy-flag spin-lock serializes access to the
-- connection itself -- callers queue and each query still completes
-- start-to-finish before the next begins -- without going back to
-- blocking the WHOLE event loop the way the unwrapped socket did: only
-- other DB-bound coroutines wait here, video/image byte-serving and
-- everything else keeps running.
local function lock_acquire(self)
  local in_coroutine = coroutine.isyieldable()
  while self.busy do
    if copas_ok and in_coroutine then
      copas.pause(0)
    else
      -- Can't yield outside a coroutine (e.g. main.lua's startup
      -- db.ping()) -- nothing else could be running concurrently at
      -- that point anyway, so just proceed.
      break
    end
  end
  self.busy = true
end

local function lock_release(self)
  self.busy = false
end

function Pg:ensure()
  local in_coroutine = coroutine.isyieldable()
  if self.conn and self.conn.sock then
    if in_coroutine and not self.conn_wrapped then
      -- main.lua's startup db.ping() runs before copas.loop() starts, so
      -- the first-ever connection was made outside a coroutine and left
      -- unwrapped (see below). Now that we're inside a real request's
      -- coroutine, drop it and reconnect so this and every later query
      -- on this shared connection actually go through copas -- a
      -- one-time reconnect on the very first request, not a per-request
      -- cost.
      self.conn = nil
    else
      return true
    end
  end
  local conn = pgmoon.new(self.opts)
  -- Every other network call in this codebase (Discord, Telegram, AI
  -- metadata) goes through copas.http specifically so it yields back to
  -- the shared single-threaded copas scheduler instead of blocking the
  -- whole event loop. pgmoon's default "luasocket" transport does NOT
  -- yield -- conn.sock is a plain blocking LuaSocket TCP object -- so
  -- without this, every single DB query (i.e. nearly every request,
  -- since almost every route touches the DB for at least an auth check)
  -- stalls video/image/HLS serving for every OTHER concurrent
  -- request/user for the full round-trip of that query. This was the
  -- root cause of "random" severe slowdowns under concurrent web+iOS
  -- usage. copas.wrap() gives the raw socket copas-cooperative
  -- send/receive/connect/settimeout/close methods with the exact same
  -- names pgmoon's own luasocket proxy already forwards to, so swapping
  -- it in here (before the proxy's __index has memoized any method
  -- closures -- that only happens on first use, i.e. the connect() call
  -- right below) is a drop-in replacement.
  --
  -- Only do this when actually running inside a copas coroutine, though:
  -- copas.connect/copas.wrap need the dispatcher's per-coroutine socket
  -- bookkeeping, which doesn't exist yet for main.lua's startup db.ping()
  -- (called before copas.loop() ever starts) -- that one blocking
  -- connect is a one-time startup cost, not a per-request stall, so it's
  -- fine left as a plain blocking socket.
  if copas_ok and in_coroutine and conn.sock and conn.sock.sock then
    conn.sock.sock = copas.wrap(conn.sock.sock)
    self.conn_wrapped = true
  else
    self.conn_wrapped = false
  end
  local ok, err = conn:connect()
  if not ok then
    return nil, "postgres connect failed: " .. tostring(err)
  end
  -- Discord snowflake IDs (guild/user/channel/role) live in BIGINT columns and routinely
  -- exceed 2^53, the largest integer a Lua double can represent exactly. pgmoon's default
  -- OID 20 (int8) deserializer runs every bigint value through tonumber(), which silently
  -- corrupts them, e.g. 1304564041863266347 comes back as 1.3045640418633e+18. Force bigint
  -- columns to come back as the raw wire-format string instead, which preserves full
  -- precision; safe to hand straight back into another bigint column or WHERE clause since
  -- Postgres implicitly casts untyped string literals to the target numeric type.
  conn:set_type_deserializer(20, "string")
  -- All app tables use "timestamp without time zone" (oid 1114) columns.
  -- pgmoon has no built-in deserializer for it, so it falls through to
  -- "string" and comes back verbatim in Postgres's text-output format
  -- ("2026-07-26 18:48:07.797921" -- space separator, no zone). Python's
  -- asyncpg driver returns a naive datetime for the same column, and
  -- app/routers/_shared.py's _jsonable() renders it via .isoformat(), which
  -- uses a "T" separator and (for a naive datetime) no zone suffix. Convert
  -- to match so both backends emit byte-identical timestamps for the same
  -- row.
  conn:set_type_deserializer(1114, "timestamp", function(_, val)
    return (val:gsub(" ", "T", 1))
  end)
  self.conn = conn
  return true
end

-- query(sql, ...) -> rows, err. Params are escaped via pgmoon's built-in escaping.
function Pg:query(sql, ...)
  local n = select('#', ...)
  local args = n > 0 and { ... } or nil

  lock_acquire(self)
  local success, res, err = pcall(function()
    local ok, ensure_err = self:ensure()
    if not ok then return nil, ensure_err end

    local formatted = sql
    if args then
      local escaped = {}
      for i = 1, n do
        local v = args[i]
        escaped[i] = (v == nil) and "NULL" or self.conn:escape_literal(v)
      end
      formatted = sql:format(unpack(escaped, 1, n))
    end

    local rows, qerr = self.conn:query(formatted)
    if rows == nil then
      -- connection may have dropped; retry once
      self.conn = nil
      local ok2 = self:ensure()
      if not ok2 then return nil, qerr end
      rows, qerr = self.conn:query(formatted)
      if rows == nil then return nil, qerr end
    end
    return rows
  end)
  lock_release(self)

  if not success then error(res, 0) end -- re-raise; res holds the pcall error here
  return res, err
end

return Pg
