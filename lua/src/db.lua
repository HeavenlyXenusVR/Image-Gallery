-- Postgres access layer built on the vendored lib/swarmlua/pg.lua.
--
-- Unlike SwarmPanel's db.lua, this backend only ever talks to one database
-- (image_gallery), so there's no per-dbname pool table -- just a flat pool
-- of Pg instances, all against that one database.
--
-- Previously this held exactly one Pg instance, and every DB-bound request
-- serialized behind pg.lua's own busy-flag lock (see that file's header
-- comment) -- necessary to stop concurrent coroutines corrupting a SHARED
-- connection's wire protocol, but it meant literally every query anywhere
-- in the app -- an HLS segment auth check, an unrelated comment post, a
-- background digest job -- queued behind whichever one currently held that
-- single socket. Real concurrent viewers (this is a public gallery) turned
-- that into a genuine bottleneck independent of any specific route's own
-- query cost. A pool of independent Pg instances lets that many requests'
-- queries actually run in parallel; each instance still has its own
-- pg.lua-level lock protecting IT specifically, unchanged, so nothing about
-- that safety property is touched here -- this only adds a layer above it
-- that hands out whichever instance is currently idle instead of forcing
-- everyone onto the same one.
--
-- NUMERIC precision note: unlike SwarmPanel's image_gallery access (which
-- kept the columns as NUMERIC(20,0) and patched pgmoon's oid-1700
-- deserializer), THIS schema had every such id/counter column converted to
-- BIGINT during the Phase 1 schema fixups (see
-- ../../scripts/pg_numeric_to_bigint.sql) specifically so it wouldn't need
-- that patch and so FKs could reference the (already-bigint) primary keys.
-- pg.lua's existing oid-20 (int8) string-deserializer, used as-is, already
-- covers full precision for every wide-integer column in this schema. Do not
-- add a NUMERIC/oid-1700 patch here unless a future migration reintroduces
-- NUMERIC id columns.
local Pg = require("swarmlua.pg")

local M = {}
local pool = {}
local round_robin = 0
local cfg = nil

function M.init(settings)
  cfg = settings
end

local function new_conn()
  return Pg.new({
    host = cfg.db_host,
    port = cfg.db_port,
    user = cfg.db_user,
    password = cfg.db_password,
    database = cfg.db_name,
  })
end

-- Hands back an idle Pg instance where possible, growing the pool lazily
-- (up to db_pool_size) as concurrent demand actually shows up rather than
-- opening every connection at startup -- most of the time this app isn't
-- under concurrent DB load, so there's no reason to hold open connections
-- nothing is using yet. If every existing instance is currently mid-query,
-- round-robin across them instead of always piling onto pool[1]: each one
-- still queues safely on its own pg.lua-level lock (unchanged), this just
-- spreads that wait across db_pool_size sockets instead of concentrating
-- all of it on one.
local function acquire()
  for _, p in ipairs(pool) do
    if not p.busy then return p end
  end
  if #pool < (cfg.db_pool_size or 1) then
    local p = new_conn()
    pool[#pool + 1] = p
    return p
  end
  round_robin = (round_robin % #pool) + 1
  return pool[round_robin]
end

-- Runs `sql` (with %s-style placeholders, pgmoon-escaped) against the db.
-- Returns rows (array of column->value tables) or nil, err.
function M.query(sql, ...)
  local p = acquire()
  local rows, err = p:query(sql, ...)
  -- pg.lua's own query() can legitimately return `nil, nil` for a
  -- connection-level failure it has no formatted message for (e.g. a
  -- socket reset mid-query after this connection sat unused through a long
  -- upload's remux/AI/hash work) -- without this fallback that surfaced as
  -- a bare "Could not save media: nil" with no way to tell a real DB error
  -- from a dropped connection.
  if rows == nil then return nil, err or "database connection error (no detail available)" end
  if rows == true then return {} end -- DDL/DML with no result set
  return rows
end

function M.fetchall(sql, ...)
  local rows, err = M.query(sql, ...)
  return rows or {}, err
end

function M.fetchone(sql, ...)
  local rows, err = M.query(sql, ...)
  if not rows or not rows[1] then return nil, err end
  return rows[1], nil
end

function M.execute(sql, ...)
  local rows, err = M.query(sql, ...)
  if rows == nil then return nil, err end
  return true
end

-- Coerces a value that may have come back as a Lua string (bigint columns
-- are forced to string by pg.lua to preserve snowflake-scale precision) into
-- a Lua number. Safe to call on values that are already numbers.
function M.toint(v, default)
  if v == nil then return default end
  if type(v) == "number" then return math.floor(v) end
  local n = tonumber(v)
  if n == nil then return default end
  return math.floor(n)
end

function M.tobool(v)
  if type(v) == "boolean" then return v end
  if v == nil then return false end
  if v == "t" or v == "true" or v == "1" or v == 1 then return true end
  return false
end

-- pg.lua returns SQL NULL as Lua's cjson.null sentinel in some pgmoon
-- versions (or plain nil); normalize both to nil so `value or default`
-- fallback patterns (which cjson.null defeats, since it's a non-nil,
-- non-false userdata/table) are actually safe throughout this codebase.
local cjson = require("cjson.safe")
function M.norm(v)
  if v == nil or v == cjson.null then return nil end
  return v
end

function M.ping()
  local row, err = M.fetchone("SELECT now() AS now")
  if not row then return false, err end
  return true, row.now
end

return M
