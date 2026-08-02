-- Outbound Discord webhook notifications for per-creator upload alerts.
-- Mirrors app/discord_webhook.py.
--
-- Delivery runs on a copas.addthread background coroutine so a slow/broken
-- webhook never delays the HTTP response that triggered it (mirrors
-- Python's fire-and-forget asyncio.create_task). The request itself is a
-- plain blocking ssl.https call inside that coroutine -- same "blocks the
-- shared single-threaded event loop for the duration of the call" tradeoff
-- already accepted elsewhere in this port for ffmpeg shell-outs (see
-- media_files.lua's module docstring); acceptable for one webhook POST at
-- this deployment's traffic level.

local M = {}

-- Only Discord's own webhook endpoints are allowed as a target: a user can
-- configure an arbitrary URL here, so restricting the host prevents this
-- server from being used as an open server-side request forwarder.
local ALLOWED_PREFIXES = {
  "https://discord.com/api/webhooks/",
  "https://discordapp.com/api/webhooks/",
}

function M.is_valid_url(url)
  if type(url) ~= "string" then return false end
  for _, prefix in ipairs(ALLOWED_PREFIXES) do
    if url:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function deliver(webhook_url, embeds)
  local ok, err = pcall(function()
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local cjson = require("cjson.safe")
    local body = cjson.encode({ embeds = embeds })
    local response_chunks = {}
    local _, status = https.request({
      url = webhook_url,
      method = "POST",
      headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body) },
      source = ltn12.source.string(body),
      sink = ltn12.sink.table(response_chunks),
      protocol = "any",
    })
    if status and (status < 200 or status >= 300) then
      error("Discord webhook responded with HTTP " .. tostring(status))
    end
  end)
  if not ok then
    print("[image-gallery-lua] Discord webhook delivery failed: " .. tostring(err))
  end
end

-- Best-effort: never raises into the caller, so a broken/rate-limited
-- webhook can't affect the upload request that triggered it.
function M.send(webhook_url, embeds)
  if not M.is_valid_url(webhook_url) then return end
  local ok, copas = pcall(require, "copas")
  if ok and copas.addthread then
    copas.addthread(deliver, webhook_url, embeds)
  else
    deliver(webhook_url, embeds)
  end
end

return M
