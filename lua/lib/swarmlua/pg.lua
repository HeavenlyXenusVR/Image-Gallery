-- Postgres connection helper (pgmoon-backed), auto-reconnecting.
local pgmoon = require("pgmoon")
local unpack = table.unpack or unpack

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
  return self
end

function Pg:ensure()
  if self.conn and self.conn.sock then
    return true
  end
  local conn = pgmoon.new(self.opts)
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
  local ok, err = self:ensure()
  if not ok then return nil, err end

  local n = select('#', ...)
  if n > 0 then
    local args = { ... }
    for i = 1, n do
      local v = args[i]
      args[i] = (v == nil) and "NULL" or self.conn:escape_literal(v)
    end
    sql = sql:format(unpack(args, 1, n))
  end

  local res, err2 = self.conn:query(sql)
  if res == nil then
    -- connection may have dropped; retry once
    self.conn = nil
    local ok2 = self:ensure()
    if not ok2 then return nil, err2 end
    res, err2 = self.conn:query(sql)
    if res == nil then return nil, err2 end
  end
  return res
end

return Pg
