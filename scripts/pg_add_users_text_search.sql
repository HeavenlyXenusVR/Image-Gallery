-- Speeds up M.search_users, which previously ran a plain
-- `ILIKE '%...%'` seq scan across username/display_name/bio/
-- profile_headline on every call with zero supporting index.
--
-- A generated tsvector column (media_items' pre-existing text_search
-- pattern) was considered first, but it would have combined all four
-- fields into one always-computed vector regardless of the viewer's
-- privacy setting -- the existing query deliberately only ILIKE-matches
-- display_name/bio/profile_headline for public-profile users (each field
-- individually gated via a CASE WHEN ... ELSE NULL), so a blanket
-- tsvector would let a search match against a private user's bio/
-- headline text that the ILIKE version was specifically written to keep
-- out of search. pg_trgm trigram indexes accelerate the EXISTING ILIKE
-- query's exact wildcard pattern as literally written -- Postgres's
-- planner picks these up automatically, no query rewrite needed, so the
-- privacy-gating logic is untouched.
--
-- Idempotent: safe to re-run.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_users_username_trgm ON users USING gin (username gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_display_name_trgm ON users USING gin (display_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_bio_trgm ON users USING gin (bio gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_profile_headline_trgm ON users USING gin (profile_headline gin_trgm_ops);
