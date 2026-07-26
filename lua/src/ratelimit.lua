-- DB-backed fixed-window rate limiter, matching app/db/account.py's
-- check_rate_limit() semantics (used by app/routers/_shared.py's
-- _rate_limit(), which itself falls back to an in-process bucket if the
-- DB call fails -- both behaviors are reproduced here) rather than
-- SwarmPanel's purely in-memory ratelimit.lua (vendored alongside this file
-- as ratelimit_mem.lua for reference/backup use, and used below as exactly
-- that: the same in-process fallback Python falls back to).
--
-- Design difference from a literal port of Python's algorithm: Python uses
-- SELECT ... FOR UPDATE inside an explicit BEGIN/COMMIT spanning multiple
-- round trips, which is safe there because aiomysql hands out a fresh
-- connection per request from a real pool. This backend's db.lua -- like
-- SwarmPanel's -- holds exactly ONE shared Postgres connection reused by
-- every concurrent coroutine (see db.lua's module comment); starting a
-- multi-statement transaction on that shared connection and yielding to the
-- socket mid-transaction would let a *different* request's query interleave
-- with it. Instead this does the whole fixed-window check-and-increment as
-- ONE atomic statement (INSERT ... ON CONFLICT DO UPDATE ... RETURNING),
-- which Postgres itself guarantees is atomic without needing a
-- client-visible transaction at all. See the api_rate_limits table (schema
-- fixed up in scripts/pg_schema_fixups.sql to have its PRIMARY KEY on
-- bucket_key, matching MariaDB's).
local db = require("db")

local M = {}

local mem_buckets = {}
local MEM_BUCKETS_MAX = 2000

local function mem_allow(key, limit, window_seconds)
  local now = os.time()
  local bucket = mem_buckets[key] or {}
  local kept = {}
  for _, t in ipairs(bucket) do
    if now - t < window_seconds then kept[#kept + 1] = t end
  end
  if #kept >= limit then
    mem_buckets[key] = kept
    return false
  end
  kept[#kept + 1] = now
  mem_buckets[key] = kept
  local count = 0
  for _ in pairs(mem_buckets) do count = count + 1 end
  if count > MEM_BUCKETS_MAX then
    local oldest_key, oldest_t = nil, math.huge
    for k, v in pairs(mem_buckets) do
      local last = v[#v] or 0
      if last < oldest_t then oldest_t, oldest_key = last, k end
    end
    if oldest_key then mem_buckets[oldest_key] = nil end
  end
  return true
end

-- allow(key, limit, window_seconds) -> true if under limit (and records the
-- attempt), false if the caller should be rejected with 429.
function M.allow(key, limit, window_seconds)
  local bucket_key = tostring(key or "unknown"):gsub("[^%w_.:@%-]", "_"):sub(1, 190)
  limit = math.max(1, tonumber(limit) or 1)
  window_seconds = math.max(1, tonumber(window_seconds) or 1)

  local row, err = db.fetchone(string.format([[
    INSERT INTO api_rate_limits (bucket_key, window_start, event_count, updated_at)
    VALUES (%%s, now(), 1, now())
    ON CONFLICT (bucket_key) DO UPDATE SET
      event_count = CASE WHEN EXTRACT(EPOCH FROM (now() - api_rate_limits.window_start)) >= %d
                          THEN 1
                          ELSE api_rate_limits.event_count + 1 END,
      window_start = CASE WHEN EXTRACT(EPOCH FROM (now() - api_rate_limits.window_start)) >= %d
                           THEN now()
                           ELSE api_rate_limits.window_start END,
      updated_at = now()
    RETURNING event_count
  ]], window_seconds, window_seconds), bucket_key)

  if row then
    local count = db.toint(row.event_count, limit + 1)
    return count <= limit
  end
  -- DB unavailable: fall back to the in-process bucket, same as Python's
  -- _rate_limit() except-and-fall-through behavior.
  return mem_allow(bucket_key, limit, window_seconds)
end

-- Convenience wrapper for route handlers: returns nil on success, or
-- {status=429, body={detail=...}} to send directly.
function M.check(key, limit, window_seconds)
  if M.allow(key, limit, window_seconds) then return nil end
  return 429, { detail = "Too many attempts. Try again later." }
end

return M
