-- Adds digest_sends, the idempotency marker table backing the weekly
-- per-creator Discord stats digest in lua/src/digest.lua (2026-08-09).
--
-- The digest loop wakes every 6h and checks whether it's past the
-- configured weekly send time (config.lua's digest_send_weekday/hour), but
-- that check alone would fire repeatedly across the same week's wakeups
-- (and again after any restart). This table makes "at most one send per
-- creator per week" durable: send_digest_for_user() reserves a
-- (user_id, week_start) row via INSERT ... ON CONFLICT DO NOTHING RETURNING
-- before doing any work, mirroring media_views' own dedup INSERT.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS digest_sends (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_start DATE NOT NULL,
  sent_at TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, week_start)
);
