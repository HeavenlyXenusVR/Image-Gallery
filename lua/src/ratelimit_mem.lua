-- In-memory sliding-window rate limiter for auth-adjacent endpoints.
-- Direct port of app/security.py's _rate_limit_auth/AUTH_RATE_BUCKETS: a
-- flagged gap in the Lua rewrite (every login/register/verification/
-- password-change route was previously unprotected against brute-force or
-- spam abuse) found during the pre-cutover review of this backend.

local M = {}

local buckets = {}
local BUCKETS_MAX = 2000 -- prevent unbounded memory growth under load, same ceiling as Python

-- Returns true (and records the attempt) if under limit; false if the
-- caller should be rejected with 429. `key` should already include
-- whatever scoping the caller wants (IP, username, IP+username, etc.).
function M.allow(key, limit, window_seconds)
  local now = os.time()
  local bucket = buckets[key] or {}
  local kept = {}
  for _, t in ipairs(bucket) do
    if now - t < window_seconds then kept[#kept + 1] = t end
  end
  if #kept >= limit then
    buckets[key] = kept
    return false
  end
  kept[#kept + 1] = now
  buckets[key] = kept

  local count = 0
  for _ in pairs(buckets) do count = count + 1 end
  if count > BUCKETS_MAX then
    -- Prune fully-stale buckets first (mirrors Python's prune step).
    local stale = {}
    for k, v in pairs(buckets) do
      local all_stale = true
      for _, t in ipairs(v) do
        if now - t < window_seconds then all_stale = false; break end
      end
      if all_stale then stale[#stale + 1] = k end
    end
    for _, k in ipairs(stale) do buckets[k] = nil end

    count = 0
    for _ in pairs(buckets) do count = count + 1 end
    if count > BUCKETS_MAX then
      -- Still over: drop the oldest half by most-recent-attempt time.
      local entries = {}
      for k, v in pairs(buckets) do
        local last = 0
        for _, t in ipairs(v) do if t > last then last = t end end
        entries[#entries + 1] = { key = k, last = last }
      end
      table.sort(entries, function(a, b) return a.last < b.last end)
      for i = 1, math.floor(#entries / 2) do
        buckets[entries[i].key] = nil
      end
    end
  end

  return true
end

-- Convenience wrapper for route handlers: returns nil on success, or a
-- {status=429, body={detail=...}} table to return directly from the route.
function M.check(key, limit, window_seconds)
  if M.allow(key, limit, window_seconds) then return nil end
  return 429, { detail = "Too many authentication attempts. Try again later." }
end

return M
