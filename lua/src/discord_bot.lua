-- Discord bot REST client for DM-based account verification
-- (POST /api/me/discord/verify/start, method="dm"). Distinct from
-- discord_webhook.lua (outbound-only, per-creator, posts to a channel the
-- user configured) -- this is a real bot identity that can open a DM
-- channel directly with any Discord user who shares a server with it and
-- allows DMs from server members (Discord does not allow bots to message
-- arbitrary strangers with no shared server -- there is no way around that
-- from this side).
--
-- Uses copas.http (like telegram.lua's api_call) so a slow Discord response
-- yields back to the shared event loop instead of blocking every other
-- in-flight request -- same reasoning as telegram.lua's own header comment
-- about why plain ssl.https/socket.http must never be used here.
--
-- No bot token is configured out of the box (GALLERY_DISCORD_BOT_TOKEN is
-- blank by default, config.lua) -- every function below reports
-- "not configured" rather than erroring until one is set.

local M = {}
local token = ""

function M.init(settings)
  token = (settings and settings.discord_bot_token) or ""
end

function M.enabled()
  return token ~= ""
end

local function api_call(method, path, body_table)
  local copas_http = require("copas.http")
  local ltn12 = require("ltn12")
  local cjson = require("cjson.safe")

  local body = body_table and cjson.encode(body_table) or nil
  local headers = {
    ["Authorization"] = "Bot " .. token,
    ["User-Agent"] = "ImageGalleryBot (https://github.com/HeavenlyXenusVR/Image-Gallery, 1.0)",
  }
  if body then
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#body)
  end
  local response_chunks = {}
  local ok, code = copas_http.request({
    url = "https://discord.com/api/v10" .. path,
    method = method,
    headers = headers,
    source = body and ltn12.source.string(body) or nil,
    sink = ltn12.sink.table(response_chunks),
    timeout = 12,
  })
  local raw = table.concat(response_chunks)
  local decode_ok, payload = pcall(cjson.decode, raw ~= "" and raw or "{}")
  return ok, code, (decode_ok and type(payload) == "table") and payload or {}
end

-- Opens (or reuses) a DM channel with discord_user_id and sends `content`.
-- Returns true on success, or false + a user-facing error message. Fails
-- closed on any ambiguity (network error, non-2xx, missing channel id)
-- rather than reporting false success.
function M.send_dm(discord_user_id, content)
  if token == "" then
    return false, "Discord verification isn't configured on this server yet."
  end
  local digits = tostring(discord_user_id or ""):match("^%d+$")
  if not digits then
    return false, "That doesn't look like a valid Discord User ID (numbers only)."
  end

  local ok1, code1, channel = api_call("POST", "/users/@me/channels", { recipient_id = digits })
  if not ok1 or not channel.id then
    return false, "Could not reach Discord: " .. tostring(code1)
  end
  local status1 = tonumber(code1) or 0
  if status1 < 200 or status1 >= 300 or not channel.id then
    return false, "Could not open a DM with that account -- make sure you share a server with the bot and allow direct messages from server members."
  end

  local ok2, code2 = api_call("POST", "/channels/" .. channel.id .. "/messages", { content = content })
  local status2 = tonumber(code2) or 0
  if not ok2 or status2 < 200 or status2 >= 300 then
    return false, "Discord rejected the message: " .. tostring(code2)
  end
  return true, nil
end

-- Best-effort username lookup (for display only, e.g. "Verified as
-- @handle") -- returns nil on any failure rather than erroring, since a
-- successful DM-based verification must never be undone by a follow-up API
-- hiccup on this purely cosmetic enrichment.
function M.get_user(discord_user_id)
  if token == "" then return nil end
  local ok, code, payload = api_call("GET", "/users/" .. tostring(discord_user_id))
  local status = tonumber(code) or 0
  if not ok or status < 200 or status >= 300 then return nil end
  return payload.global_name or payload.username
end

return M
