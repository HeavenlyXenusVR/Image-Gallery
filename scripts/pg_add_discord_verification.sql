-- Adds Discord account verification: users.discord_user_id/discord_username/
-- discord_verified_at (the verified-identity result), and
-- discord_verifications (the pending-code state machine) backing
-- lua/src/routes.lua's POST /api/me/discord/verify/start|confirm and
-- POST /api/me/discord/unlink (2026-08-10).
--
-- Two delivery methods for the verification code, both landing in the same
-- table/columns: "dm" (via discord_bot.lua's real bot, opens a DM with the
-- Discord User ID the user provides) and "webhook" (posts to the user's
-- already-configured discord_webhook_url, users.user_settings ->>
-- 'discord_webhook_url' -- the same per-creator setting upload notifications
-- already use).
--
-- Idempotent: safe to re-run.

ALTER TABLE users ADD COLUMN IF NOT EXISTS discord_user_id VARCHAR(32);
ALTER TABLE users ADD COLUMN IF NOT EXISTS discord_username VARCHAR(120);
ALTER TABLE users ADD COLUMN IF NOT EXISTS discord_verified_at TIMESTAMP;

CREATE TABLE IF NOT EXISTS discord_verifications (
  user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  code_hash CHAR(64) NOT NULL,
  method VARCHAR(20) NOT NULL,
  target VARCHAR(255) NOT NULL,
  attempts INT NOT NULL DEFAULT 0,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now()
);
