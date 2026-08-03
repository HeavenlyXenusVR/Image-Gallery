-- Adds media_views, the unique-viewer-per-post dedup table backing the
-- view-count fix in lua/src/routes.lua's M.media_detail() (2026-08-03).
--
-- Before this, every GET /api/media/:id unconditionally did
-- `views=views+1` on media_items -- reopening a post, a pull-to-refresh,
-- or a client retry all inflated the count with no dedup at all (true of
-- the original Python backend too, not a rewrite regression, but still a
-- real reported bug). M.media_detail now inserts into this table first
-- and only increments media_items.views when that insert actually adds a
-- new (media_id, viewer_key) row -- i.e. the first time this viewer has
-- ever seen this post. viewer_key is "user:<id>" for a logged-in viewer
-- or "ip:<address>" for an anonymous one (public posts don't require
-- login to view, so there's no user id to key on for those).
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS media_views (
  media_id BIGINT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  viewer_key TEXT NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (media_id, viewer_key)
);

CREATE INDEX IF NOT EXISTS idx_media_views_media ON media_views(media_id);
