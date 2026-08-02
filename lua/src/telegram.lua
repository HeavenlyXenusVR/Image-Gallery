-- Telegram long-polling control-panel bridge. Mirrors app/telegram.py's
-- generic TelegramPollingService class plus app/main.py's gallery-specific
-- command handler (_handle_telegram_command), health-watch loop
-- (_telegram_health_watch_loop), and startup/db-problem alert plumbing
-- (_send_telegram_alert). Runs as a copas background coroutine within the
-- same event loop as the HTTP server (started via M.start() from main.lua,
-- before httpd.run()) -- the same pattern discord_webhook.lua uses for its
-- own fire-and-forget copas.addthread call, and analogous to Python's
-- asyncio.create_task() for the same service.
--
-- NOT ported: the periodic moderation-digest loop (_moderation_digest_loop)
-- -- a separate feature (new-reports/bans/signups/storage-growth digest)
-- that depends on db.digest_counts_since()/site_settings.last_digest_at,
-- neither of which this rewrite has touched yet. The bridge itself, all 8
-- gallery commands, and the db-health watch + startup alert are fully
-- ported and were verified against the real, live-configured Telegram bot.

local db = require("db")
local cjson = require("cjson.safe")

local M = {}

local status = {
  enabled = false,
  running = false,
  bot_username = "",
  allowed_chat_count = 0,
  last_error = "",
  last_update_at = 0,
}

local settings, token, allowed_chat_ids
local offset = nil

local function api_call(method, params, timeout_seconds)
  local https = require("ssl.https")
  local ltn12 = require("ltn12")
  local url = "https://api.telegram.org/bot" .. token .. "/" .. method
  local body, source
  if params and next(params) then
    local pairs_list = {}
    for k, v in pairs(params) do
      pairs_list[#pairs_list + 1] = k .. "=" .. tostring(v):gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", c:byte())
      end)
    end
    body = table.concat(pairs_list, "&")
    source = ltn12.source.string(body)
  end
  local response_chunks = {}
  local headers = {}
  if body then
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers["Content-Length"] = tostring(#body)
  end
  local ok, code = https.request({
    url = url,
    method = body and "POST" or "GET",
    headers = headers,
    source = source,
    sink = ltn12.sink.table(response_chunks),
    protocol = "any",
    timeout = timeout_seconds or 20,
  })
  if not ok then
    error("Telegram " .. method .. " network error: " .. tostring(code))
  end
  local raw = table.concat(response_chunks)
  local decode_ok, payload = pcall(cjson.decode, raw ~= "" and raw or "{}")
  if not decode_ok or type(payload) ~= "table" then
    error("Telegram " .. method .. " returned invalid JSON.")
  end
  if not payload.ok then
    error(tostring(payload.description or ("Telegram " .. method .. " failed")))
  end
  return payload
end

function M.send_message(chat_id, text)
  local payload = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if payload == "" then return end
  -- Chunk long messages (Telegram's message length limit is ~4096 chars);
  -- cap at 8 chunks like Python's _chunks() does.
  local sent = 0
  local i = 1
  while i <= #payload and sent < 8 do
    local chunk = payload:sub(i, i + 3899)
    local ok, err = pcall(api_call, "sendMessage", {
      chat_id = tostring(chat_id), text = chunk, disable_web_page_preview = "true",
    }, 15)
    if not ok then print("[image-gallery-lua] Telegram sendMessage failed: " .. tostring(err)) end
    i = i + 3900
    sent = sent + 1
  end
end

-- ---------------------------------------------------------------------------
-- Gallery command handler (mirrors _handle_telegram_command +
-- _format_gallery_stats/_format_gallery_health/_fmt_bytes).
-- ---------------------------------------------------------------------------

local function fmt_bytes(n)
  n = math.floor(tonumber(n) or 0)
  for _, unit in ipairs({ "B", "KB", "MB", "GB" }) do
    if n < 1024 then return string.format("%d %s", n, unit) end
    n = math.floor(n / 1024)
  end
  return string.format("%d TB", n)
end

local function command_parts(text)
  local cleaned = tostring(text or ""):match("^%s*(.-)%s*$")
  if cleaned == "" then return "", "" end
  local first, rest = cleaned:match("^(%S+)%s*(.-)$")
  first = (first or ""):match("^([^@]+)"):lower()
  return first, rest or ""
end

local function site_checks()
  local row = db.fetchone([[
    SELECT
      now() AS db_time,
      (SELECT COUNT(*) FROM users) AS users,
      (SELECT COUNT(*) FROM media_items) AS media_total,
      (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NULL) AS media_active,
      (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NOT NULL) AS media_archived,
      (SELECT COUNT(*) FROM media_files) AS db_files,
      (SELECT COUNT(*) FROM media_items WHERE deleted_at IS NULL AND (media_file_id IS NULL OR media_file_id=0)) AS missing_db_files,
      (SELECT COUNT(*) FROM media_items WHERE visibility='private' AND deleted_at IS NULL) AS private_posts,
      (SELECT COUNT(*) FROM media_reports WHERE status='open') AS open_reports
  ]])
  return row or {}
end

local function gallery_stats()
  local users_row = db.fetchone("SELECT COUNT(*) AS n FROM users")
  local categories_row = db.fetchone("SELECT COUNT(*) AS n FROM categories")
  local media_row = db.fetchone("SELECT COUNT(*) AS n, COALESCE(SUM(file_size), 0) AS bytes FROM media_items")
  local likes_row = db.fetchone("SELECT COUNT(*) AS n FROM media_likes")
  return {
    users = db.toint(users_row and users_row.n, 0),
    categories = db.toint(categories_row and categories_row.n, 0),
    media = db.toint(media_row and media_row.n, 0),
    bytes = db.toint(media_row and media_row.bytes, 0),
    likes = db.toint(likes_row and likes_row.n, 0),
  }
end

local function format_gallery_stats(stats)
  return string.format(
    "Image Gallery — Stats\nUsers:      %d\nCategories: %d\nMedia:      %d\nStorage:    %s\nLikes:      %d",
    stats.users, stats.categories, stats.media, fmt_bytes(stats.bytes), stats.likes
  )
end

local function format_gallery_health(checks)
  local db_time = checks.db_time and tostring(checks.db_time):sub(1, 19) or "unknown"
  local missing_files = db.toint(checks.missing_db_files, 0)
  local open_reports = db.toint(checks.open_reports, 0)
  local lines = {
    "Image Gallery — Health",
    "DB time:        " .. db_time,
    "Users:          " .. tostring(db.toint(checks.users, 0)),
    "Media active:   " .. tostring(db.toint(checks.media_active, 0)),
    "Media archived: " .. tostring(db.toint(checks.media_archived, 0)),
    "DB files:       " .. tostring(db.toint(checks.db_files, 0)),
  }
  if missing_files > 0 then
    lines[#lines + 1] = "Missing files:  " .. missing_files .. "  <- WARNING"
  else
    lines[#lines + 1] = "Missing files:  0  OK"
  end
  lines[#lines + 1] = "Private posts:  " .. tostring(db.toint(checks.private_posts, 0))
  if open_reports > 0 then
    lines[#lines + 1] = "Open reports:   " .. open_reports .. "  <- ACTION NEEDED"
  else
    lines[#lines + 1] = "Open reports:   0"
  end
  return table.concat(lines, "\n")
end

local function handle_command(chat_id, text)
  local command = (command_parts(text))

  if command == "/start" or command == "/help" or command == "help" then
    local owner_note = ""
    if #allowed_chat_ids == 0 then
      owner_note = "\n\nNOTE: No GALLERY_TELEGRAM_ALLOWED_CHAT_IDS set — "
        .. "all chats can reach this bot. Use /id to find your chat id "
        .. "and set it in the .env file to restrict access."
    end
    return "Image Gallery Telegram control panel\n\n"
      .. "/status   — Gallery stats (users, media, storage)\n"
      .. "/health   — Database & file integrity check\n"
      .. "/storage  — Detailed storage breakdown\n"
      .. "/recent   — Last 5 public uploads\n"
      .. "/users    — Recent user registrations\n"
      .. "/ai       — AI / vision pipeline status\n"
      .. "/id       — Show this chat's Telegram ID\n"
      .. "/help     — Show this message"
      .. owner_note
  end

  if command == "/id" then
    local allowlisted_set = {}
    for _, id in ipairs(allowed_chat_ids) do allowlisted_set[id] = true end
    local note
    if #allowed_chat_ids == 0 then
      note = "  (no allowlist set — add this id to GALLERY_TELEGRAM_ALLOWED_CHAT_IDS)"
    elseif allowlisted_set[chat_id] then
      note = "  (allowlisted)"
    else
      note = "  (NOT in GALLERY_TELEGRAM_ALLOWED_CHAT_IDS)"
    end
    return "Your Telegram chat id: " .. tostring(chat_id) .. note
  end

  if command == "/status" or command == "status" or command == "/stats" or command == "stats" then
    local ok, result = pcall(gallery_stats)
    if not ok then return "Stats failed: " .. tostring(result):sub(1, 300) end
    return format_gallery_stats(result)
  end

  if command == "/health" or command == "health" then
    local ok, result = pcall(site_checks)
    if not ok then return "Health check failed: " .. tostring(result):sub(1, 300) end
    return format_gallery_health(result)
  end

  if command == "/storage" or command == "storage" then
    local ok, err = pcall(function()
      local stats = gallery_stats()
      local checks = site_checks()
      local media_count = math.max(1, stats.media)
      local avg_bytes = math.floor(stats.bytes / media_count)
      return table.concat({
        "Image Gallery — Storage",
        "Backend:       " .. tostring(settings.storage_backend),
        "Total stored:  " .. fmt_bytes(stats.bytes),
        "DB file rows:  " .. tostring(db.toint(checks.db_files, 0)),
        "Media items:   " .. tostring(stats.media),
        "Avg per item:  " .. fmt_bytes(avg_bytes),
        "Max upload:    " .. fmt_bytes(settings.max_upload_bytes),
      }, "\n")
    end)
    if ok then return err end
    return "Storage info failed: " .. tostring(err):sub(1, 300)
  end

  if command == "/recent" or command == "recent" then
    local ok, rows = pcall(db.fetchall, [[
      SELECT m.title, m.media_kind, m.created_at, u.username, u.display_name
      FROM media_items m JOIN users u ON u.id = m.user_id
      WHERE m.deleted_at IS NULL AND m.visibility='public'
      ORDER BY m.created_at DESC LIMIT 5
    ]])
    if not ok or #rows == 0 then return "No public gallery posts found." end
    local lines = { "Image Gallery — Recent uploads" }
    for _, item in ipairs(rows) do
      local ts = tostring(item.created_at or ""):sub(1, 10)
      local user = item.display_name or item.username or "unknown"
      lines[#lines + 1] = string.format("- [%s] %s (%s) by %s", ts, item.title or "Untitled", item.media_kind or "media", user)
    end
    return table.concat(lines, "\n")
  end

  if command == "/users" or command == "users" then
    local ok, checks = pcall(site_checks)
    if not ok then return "User info failed: " .. tostring(checks):sub(1, 300) end
    return "Image Gallery — Users\nTotal registered: " .. tostring(db.toint(checks.users, 0))
      .. "\n(Use the web panel at " .. tostring(settings.pages_public_url) .. " to manage users)"
  end

  if command == "/ai" or command == "ai" then
    return table.concat({
      "Image Gallery — AI / Vision",
      "AI enabled:     " .. (settings.ai_enabled and "yes" or "no"),
      "Provider:       " .. tostring(settings.ai_provider or "none"),
      "Model:          " .. tostring(settings.ai_model ~= "" and settings.ai_model or "default"),
    }, "\n")
  end

  return "Unknown command. Use /help to see available Image Gallery commands."
end

-- ---------------------------------------------------------------------------
-- Polling loop + health watch (mirrors TelegramPollingService._poll_loop and
-- app/main.py's _telegram_health_watch_loop, run as copas background
-- coroutines started from M.start()).
-- ---------------------------------------------------------------------------

local function trim_text(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function handle_update(update)
  local message = update.message or {}
  local chat = message.chat or {}
  local chat_id = chat.id
  local text = trim_text(message.text)
  if not chat_id or text == "" then return end
  status.last_update_at = os.time()

  if #allowed_chat_ids > 0 then
    local allowed = false
    for _, id in ipairs(allowed_chat_ids) do if id == chat_id then allowed = true; break end end
    if not allowed then
      M.send_message(chat_id, "This Telegram chat is not allowed for this service.")
      return
    end
  end

  local ok, reply = pcall(handle_command, chat_id, text)
  if ok then
    if reply then M.send_message(chat_id, reply) end
  else
    print("[image-gallery-lua] Telegram handler failed: " .. tostring(reply))
    M.send_message(chat_id, "Command failed. Please try again.")
  end
end

local function poll_loop()
  status.running = true
  local backoff = 5
  local copas = require("copas")
  while true do
    local ok, err = pcall(function()
      local params = { timeout = tostring(25), allowed_updates = cjson.encode({ "message" }) }
      if offset ~= nil then params.offset = tostring(offset) end
      local payload = api_call("getUpdates", params, 35)
      for _, update in ipairs(payload.result or {}) do
        local update_id = db.toint(update.update_id, 0)
        offset = math.max(offset or 0, update_id + 1)
        handle_update(update)
      end
      status.last_error = ""
      backoff = 5
    end)
    if not ok then
      status.last_error = tostring(err):sub(1, 240)
      print("[image-gallery-lua] Telegram polling error: " .. tostring(err))
      copas.pause(backoff)
      backoff = math.min(backoff * 2, 120)
    end
  end
end

local _alert_last = {}
local ALERT_COOLDOWN_SECONDS = 900

-- Best-effort proactive alert (startup, db problems). Mirrors
-- _send_telegram_alert(): rate-limited per `key`, silently a no-op if no
-- recipients are configured.
function M.send_alert(key, title, detail)
  if not status.enabled then return end
  local recipients = {}
  if #allowed_chat_ids > 0 then
    recipients = allowed_chat_ids
  elseif settings.telegram_owner_chat_id then
    recipients = { settings.telegram_owner_chat_id }
  end
  if #recipients == 0 then return end
  local now = os.time()
  if _alert_last[key] and (now - _alert_last[key]) < ALERT_COOLDOWN_SECONDS then return end
  _alert_last[key] = now
  local message = tostring(title) .. "\n" .. tostring(detail or ""):sub(1, 1200)
  for _, chat_id in ipairs(recipients) do
    M.send_message(chat_id, message)
  end
end

local function health_watch_loop()
  local copas = require("copas")
  copas.pause(20)
  while true do
    local ok, err = db.ping()
    if not ok then
      print("[image-gallery-lua] Telegram health watch: database ping failed: " .. tostring(err))
      M.send_alert("db", "Image Gallery database problem", tostring(err):sub(1, 240))
    end
    copas.pause(300)
  end
end

function M.snapshot()
  return {
    enabled = status.enabled,
    running = status.running,
    bot_username = status.bot_username,
    allowed_chat_count = status.allowed_chat_count,
    last_error = status.last_error,
    last_update_at = status.last_update_at,
  }
end

-- Starts the bridge as copas background coroutines. Call once from
-- main.lua, before httpd.run(). No-op if no bot token is configured.
function M.start(app_settings)
  settings = app_settings
  token = settings.telegram_bot_token or ""
  allowed_chat_ids = settings.telegram_allowed_chat_ids or {}
  status.enabled = token ~= "" and settings.telegram_polling_enabled
  status.allowed_chat_count = #allowed_chat_ids
  if not status.enabled then return end

  local copas = require("copas")
  copas.addthread(function()
    local ok, info = pcall(api_call, "getMe", nil, 12)
    if ok then
      status.bot_username = tostring((info.result or {}).username or "")
      pcall(api_call, "deleteWebhook", { drop_pending_updates = "false" }, 12)
      pcall(api_call, "setMyCommands", {
        commands = cjson.encode({
          { command = "status", description = "Gallery stats (users, media, storage)" },
          { command = "health", description = "Database & file integrity check" },
          { command = "storage", description = "Detailed storage breakdown" },
          { command = "recent", description = "Last 5 public uploads" },
          { command = "users", description = "User registration stats" },
          { command = "ai", description = "AI / vision pipeline status" },
          { command = "id", description = "Show this chat's Telegram ID" },
          { command = "help", description = "Show available commands" },
        }),
      }, 12)
      print("[image-gallery-lua] Telegram bridge connected as @" .. (status.bot_username ~= "" and status.bot_username or "unknown"))
    else
      status.last_error = tostring(info):sub(1, 240)
      print("[image-gallery-lua] Telegram bridge could not verify token yet: " .. tostring(info))
    end
    M.send_alert("startup", "Image Gallery online", "Telegram bridge, database health checks, and media services are running.")
    poll_loop()
  end)
  copas.addthread(health_watch_loop)
end

return M
