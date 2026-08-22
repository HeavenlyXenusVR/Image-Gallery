-- Weekly per-creator Discord stats digest. Runs as a copas background
-- coroutine within the same event loop as the HTTP server -- same pattern
-- telegram.lua's poll_loop/health_watch_loop and discord_webhook.lua's
-- fire-and-forget delivery already use (M.start() called from main.lua,
-- before httpd.run()).
--
-- Targets creators who already have a `discord_webhook_url` set in their
-- user_settings -- the same per-user setting notify_discord_upload already
-- sends upload alerts to (user_settings.lua's is_valid_discord_webhook_url
-- validates it at save time), so "has a webhook configured" is reused as
-- the opt-in signal rather than adding a separate flag.
--
-- Idempotency: the loop wakes every 6h and checks whether it's past the
-- configured weekly send time (config.lua's digest_send_weekday/hour), but
-- doesn't rely on hitting that check at exactly the right wakeup -- a
-- digest_sends(user_id, week_start) marker table (PRIMARY KEY, created ad
-- hoc via psql per this project's established migration process, same as
-- media_views was) makes "at most one send per creator per week" durable
-- across restarts and repeated wakeups within the same week.

local db = require("db")
local cjson = require("cjson.safe")
local discord_webhook = require("discord_webhook")
local routes = require("routes")

local M = {}
local settings

-- Monday-based week-start date (as "YYYY-MM-DD") for a given unix time.
-- os.date("!*t").wday is 1=Sunday..7=Saturday.
local function week_start_utc(t)
  local d = os.date("!*t", t)
  local days_since_monday = (d.wday + 5) % 7
  local monday = os.date("!*t", t - days_since_monday * 86400)
  return string.format("%04d-%02d-%02d", monday.year, monday.month, monday.day)
end

local function creators_with_webhook()
  local rows, err = db.fetchall([[
    SELECT id, user_settings FROM users
    WHERE user_settings->>'discord_webhook_url' IS NOT NULL
      AND user_settings->>'discord_webhook_url' != ''
  ]])
  if err then
    print("[nyxframe] digest: failed to list creators: " .. tostring(err))
    return {}
  end
  return rows
end

local function send_digest_for_user(user_row, week_start, origin)
  local ok, decoded = pcall(cjson.decode, user_row.user_settings)
  if not ok or type(decoded) ~= "table" then return end
  local webhook_url = decoded.discord_webhook_url
  if not discord_webhook.is_valid_url(webhook_url) then return end

  -- Reserve this (user, week) slot atomically before doing any work --
  -- ON CONFLICT DO NOTHING RETURNING mirrors media_views' own dedup INSERT,
  -- so a second wakeup this same week (or a restart mid-week) is a no-op.
  local reserved = db.fetchone(
    "INSERT INTO digest_sends (user_id, week_start) VALUES (%s, %s) ON CONFLICT DO NOTHING RETURNING user_id",
    tostring(user_row.id), week_start
  )
  if not reserved then return end

  local stats, err = routes.creator_stats_for(user_row.id, origin)
  if not stats then
    print("[nyxframe] digest: stats query failed for user " .. tostring(user_row.id) .. ": " .. tostring(err))
    return
  end
  if stats.totals.total_views == 0 and #stats.top_posts == 0 then return end

  local fields = {}
  for i = 1, math.min(3, #stats.top_posts) do
    local p = stats.top_posts[i]
    fields[#fields + 1] = {
      name = p.title ~= "" and p.title or "Untitled",
      value = string.format("%d views · %d likes", p.views, p.like_count),
    }
  end

  discord_webhook.send(webhook_url, { {
    title = "Your weekly gallery stats",
    description = string.format(
      "Total views: %d\nTotal likes: %d\nTotal saves: %d",
      stats.totals.total_views, stats.totals.total_likes, stats.totals.total_saves
    ),
    fields = fields,
    color = 0x37c9a7,
  } })
end

local function run_digest()
  local now_t = os.time()
  local week_start = week_start_utc(now_t)
  local origin = settings.public_origin
  for _, user_row in ipairs(creators_with_webhook()) do
    send_digest_for_user(user_row, week_start, origin)
  end
end

local function digest_loop()
  local copas = require("copas")
  while true do
    local ok, err = pcall(function()
      local d = os.date("!*t", os.time())
      if d.wday == settings.digest_send_weekday and d.hour >= settings.digest_send_hour then
        run_digest()
      end
    end)
    if not ok then
      print("[nyxframe] digest loop error: " .. tostring(err))
    end
    copas.pause(21600)
  end
end

function M.start(app_settings)
  settings = app_settings
  local copas = require("copas")
  copas.addthread(digest_loop)
end

return M
