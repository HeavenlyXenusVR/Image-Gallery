-- Image Gallery: Postgres schema correctness fixups.
--
-- Context: the MariaDB -> Postgres migration for `image_gallery` only ever
-- carried over PRIMARY KEYs. Every UNIQUE constraint, every secondary index,
-- every column DEFAULT, every FOREIGN KEY, and every CHECK constraint present
-- in the authoritative MariaDB schema (see ../mariadb_full_schema.sql, pulled
-- live via SHOW CREATE TABLE on 2026-07-26) was missing from Postgres.
--
-- Both databases currently hold effectively zero rows (only `categories`=9
-- and `site_settings`=1 seed rows), so this runs cleanly with no duplicate-key
-- conflicts. If this is ever re-run against a populated Postgres database,
-- de-duplicate natural keys BEFORE the UNIQUE-constraint section, and backfill
-- any NULL columns the new NOT NULL defaults would otherwise choke on first.
--
-- Idempotent: every statement uses IF NOT EXISTS / guards so it is safe to
-- re-run.

BEGIN;

-- =====================================================================
-- 1. Column DEFAULTs (dropped entirely by the original migration)
-- =====================================================================

ALTER TABLE ai_media_learning_state
  ALTER COLUMN last_scan_status SET DEFAULT 'pending',
  ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE ai_vision_training_examples
  ALTER COLUMN corrected_is_adult SET DEFAULT false,
  ALTER COLUMN training_confidence SET DEFAULT 0.72,
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE api_rate_limits
  ALTER COLUMN window_start SET DEFAULT now(),
  ALTER COLUMN event_count SET DEFAULT 0,
  ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE auth_attempts
  ALTER COLUMN successful SET DEFAULT false,
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE categories
  ALTER COLUMN media_kind SET DEFAULT 'mixed',
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE friend_requests
  ALTER COLUMN status SET DEFAULT 'pending',
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_bookmarks
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_collection_items
  ALTER COLUMN added_at SET DEFAULT now();

ALTER TABLE media_collections
  ALTER COLUMN is_public SET DEFAULT true,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN is_smart SET DEFAULT false;

ALTER TABLE media_comments
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_file_chunks
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_files
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_item_subcategories
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_items
  ALTER COLUMN views SET DEFAULT 0,
  ALTER COLUMN downloads SET DEFAULT 0,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN visibility SET DEFAULT 'public',
  ALTER COLUMN comments_enabled SET DEFAULT true,
  ALTER COLUMN downloads_enabled SET DEFAULT true,
  ALTER COLUMN is_adult SET DEFAULT false,
  ALTER COLUMN adult_marked_by_user SET DEFAULT false,
  ALTER COLUMN adult_marked_by_ai SET DEFAULT false,
  ALTER COLUMN moderation_status SET DEFAULT 'clear',
  ALTER COLUMN moderation_score SET DEFAULT 0;

ALTER TABLE media_likes
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_reactions
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE media_reports
  ALTER COLUMN status SET DEFAULT 'open',
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE message_thread_members
  ALTER COLUMN joined_at SET DEFAULT now();

ALTER TABLE message_threads
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE moderation_audit_log
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE notifications
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE saved_searches
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE site_settings
  ALTER COLUMN announcement_level SET DEFAULT 'info',
  ALTER COLUMN announcement_active SET DEFAULT false,
  ALTER COLUMN maintenance_mode SET DEFAULT false,
  ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE subcategories
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE thread_messages
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE user_avatar_files
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE user_blocks
  ALTER COLUMN kind SET DEFAULT 'block',
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE user_follows
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE user_messages
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE users
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN profile_color SET DEFAULT '#37c9a7',
  ALTER COLUMN public_profile SET DEFAULT true,
  ALTER COLUMN show_liked_count SET DEFAULT true,
  ALTER COLUMN show_collections SET DEFAULT true,
  ALTER COLUMN show_recent_uploads SET DEFAULT true,
  ALTER COLUMN show_friends SET DEFAULT true,
  ALTER COLUMN adult_content_consent SET DEFAULT false,
  ALTER COLUMN updated_at SET DEFAULT now();

-- =====================================================================
-- 2. UNIQUE constraints (natural-key duplicate protection — lesson #5)
-- =====================================================================

ALTER TABLE categories ADD CONSTRAINT categories_name_key UNIQUE (name);
ALTER TABLE categories ADD CONSTRAINT categories_slug_key UNIQUE (slug);

ALTER TABLE users ADD CONSTRAINT users_username_key UNIQUE (username);
ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);

ALTER TABLE media_files ADD CONSTRAINT media_files_sha256_key UNIQUE (sha256);

ALTER TABLE ai_vision_training_examples
  ADD CONSTRAINT ai_training_dedupe_key UNIQUE (dedupe_key);

ALTER TABLE subcategories
  ADD CONSTRAINT subcategories_category_name_key UNIQUE (category_id, name);
ALTER TABLE subcategories
  ADD CONSTRAINT subcategories_category_slug_key UNIQUE (category_id, slug);

ALTER TABLE friend_requests
  ADD CONSTRAINT friend_requests_pair_key UNIQUE (requester_id, addressee_id);

ALTER TABLE media_reactions
  ADD CONSTRAINT media_reactions_media_user_key UNIQUE (media_id, user_id);

ALTER TABLE media_reports
  ADD CONSTRAINT media_reports_media_user_key UNIQUE (media_id, user_id);

ALTER TABLE user_blocks
  ADD CONSTRAINT user_blocks_triplet_key UNIQUE (blocker_id, blocked_id, kind);

ALTER TABLE user_avatar_files
  ADD CONSTRAINT user_avatar_files_user_hash_key UNIQUE (user_id, sha256);

ALTER TABLE media_item_subcategories
  ADD CONSTRAINT media_item_subcategories_media_sub_key UNIQUE (media_id, subcategory_id);

-- =====================================================================
-- 3. Secondary (non-unique) indexes — dropped entirely by the migration
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_ai_media_learning_status ON ai_media_learning_state (last_scan_status, last_scanned_at);
CREATE INDEX IF NOT EXISTS idx_ai_media_learning_user ON ai_media_learning_state (user_id, updated_at);

CREATE INDEX IF NOT EXISTS idx_ai_training_user_time ON ai_vision_training_examples (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_ai_training_phash ON ai_vision_training_examples (image_phash);
CREATE INDEX IF NOT EXISTS idx_ai_training_media ON ai_vision_training_examples (media_id);

CREATE INDEX IF NOT EXISTS idx_api_rate_limits_updated ON api_rate_limits (updated_at);

CREATE INDEX IF NOT EXISTS idx_auth_attempts_ip_time ON auth_attempts (ip_address, created_at);
CREATE INDEX IF NOT EXISTS idx_auth_attempts_user_time ON auth_attempts (username, created_at);

CREATE INDEX IF NOT EXISTS idx_categories_created_by ON categories (created_by);

CREATE INDEX IF NOT EXISTS idx_friend_addressee_status ON friend_requests (addressee_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_friend_requester_status ON friend_requests (requester_id, status, created_at);

CREATE INDEX IF NOT EXISTS idx_bookmarks_media ON media_bookmarks (media_id);

CREATE INDEX IF NOT EXISTS idx_collection_items_media ON media_collection_items (media_id);

CREATE INDEX IF NOT EXISTS idx_collections_user ON media_collections (user_id, created_at);

CREATE INDEX IF NOT EXISTS idx_comments_media ON media_comments (media_id, created_at);
CREATE INDEX IF NOT EXISTS idx_comments_user ON media_comments (user_id);
CREATE INDEX IF NOT EXISTS idx_comments_parent ON media_comments (parent_comment_id);

CREATE INDEX IF NOT EXISTS idx_media_files_kind ON media_files (media_kind);
CREATE INDEX IF NOT EXISTS idx_media_files_user ON media_files (created_by);

CREATE INDEX IF NOT EXISTS idx_media_item_subcategories_subcategory ON media_item_subcategories (subcategory_id, media_id);

CREATE INDEX IF NOT EXISTS idx_media_created ON media_items (created_at);
CREATE INDEX IF NOT EXISTS idx_media_kind ON media_items (media_kind);
CREATE INDEX IF NOT EXISTS idx_media_category ON media_items (category_id);
CREATE INDEX IF NOT EXISTS idx_media_adult ON media_items (is_adult, created_at);
CREATE INDEX IF NOT EXISTS idx_media_subcategory ON media_items (subcategory_id);
CREATE INDEX IF NOT EXISTS idx_media_items_perf_main ON media_items (deleted_at, visibility, pinned_at, created_at);
CREATE INDEX IF NOT EXISTS idx_media_items_perf_kind_created ON media_items (media_kind, created_at);
CREATE INDEX IF NOT EXISTS idx_media_items_perf_category_created ON media_items (category_id, created_at);
CREATE INDEX IF NOT EXISTS idx_media_items_perf_user_created ON media_items (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_media_items_perf_size ON media_items (file_size);
CREATE INDEX IF NOT EXISTS idx_media_items_user_deleted ON media_items (user_id, deleted_at, created_at);

CREATE INDEX IF NOT EXISTS idx_media_likes_media_user ON media_likes (media_id, user_id);

CREATE INDEX IF NOT EXISTS idx_media_reactions_media ON media_reactions (media_id);
CREATE INDEX IF NOT EXISTS idx_media_reactions_user ON media_reactions (user_id);

CREATE INDEX IF NOT EXISTS idx_reports_media ON media_reports (media_id, created_at);
CREATE INDEX IF NOT EXISTS idx_reports_user ON media_reports (user_id);

CREATE INDEX IF NOT EXISTS idx_thread_members_user ON message_thread_members (user_id, thread_id);

CREATE INDEX IF NOT EXISTS idx_message_threads_creator ON message_threads (created_by, created_at);

CREATE INDEX IF NOT EXISTS idx_audit_log_created ON moderation_audit_log (created_at);
CREATE INDEX IF NOT EXISTS idx_audit_log_target ON moderation_audit_log (target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor ON moderation_audit_log (actor_id);

CREATE INDEX IF NOT EXISTS idx_notifications_recipient ON notifications (recipient_id, read_at, created_at);
CREATE INDEX IF NOT EXISTS idx_notifications_actor ON notifications (actor_id);
CREATE INDEX IF NOT EXISTS idx_notifications_media ON notifications (media_id);

CREATE INDEX IF NOT EXISTS idx_saved_searches_user ON saved_searches (user_id, created_at);

CREATE INDEX IF NOT EXISTS idx_site_settings_updated_by ON site_settings (updated_by);

CREATE INDEX IF NOT EXISTS idx_subcategories_category ON subcategories (category_id, created_at);
CREATE INDEX IF NOT EXISTS idx_subcategories_created_by ON subcategories (created_by);

CREATE INDEX IF NOT EXISTS idx_thread_messages_thread ON thread_messages (thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_thread_messages_sender ON thread_messages (sender_id);

CREATE INDEX IF NOT EXISTS idx_avatar_user ON user_avatar_files (user_id, created_at);

CREATE INDEX IF NOT EXISTS idx_user_blocks_blocked ON user_blocks (blocked_id, kind);

CREATE INDEX IF NOT EXISTS idx_followed ON user_follows (followed_id, created_at);

CREATE INDEX IF NOT EXISTS idx_messages_sender ON user_messages (sender_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_recipient ON user_messages (recipient_id, read_at, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_thread ON user_messages (sender_id, recipient_id, created_at);

-- Fulltext equivalent of MariaDB's FULLTEXT KEY ft_media_text (title, description).
-- MariaDB used MATCH...AGAINST; Postgres has no drop-in equivalent, so the Lua
-- rewrite's search endpoint must use to_tsvector/plainto_tsquery against this
-- generated column instead of trying to port MATCH AGAINST syntax literally.
ALTER TABLE media_items ADD COLUMN IF NOT EXISTS text_search tsvector
  GENERATED ALWAYS AS (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(description, ''))) STORED;
CREATE INDEX IF NOT EXISTS idx_media_items_text_search ON media_items USING GIN (text_search);

-- =====================================================================
-- 4. FOREIGN KEY constraints (referential integrity — none existed)
-- =====================================================================

ALTER TABLE ai_media_learning_state
  ADD CONSTRAINT fk_ai_media_learning_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_ai_media_learning_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE ai_vision_training_examples
  ADD CONSTRAINT fk_ai_training_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_ai_training_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE categories
  ADD CONSTRAINT fk_categories_user FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL;

ALTER TABLE friend_requests
  ADD CONSTRAINT fk_friend_addressee FOREIGN KEY (addressee_id) REFERENCES users (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_friend_requester FOREIGN KEY (requester_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_bookmarks
  ADD CONSTRAINT fk_bookmarks_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_bookmarks_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_collection_items
  ADD CONSTRAINT fk_collection_items_collection FOREIGN KEY (collection_id) REFERENCES media_collections (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_collection_items_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE;

ALTER TABLE media_collections
  ADD CONSTRAINT fk_collections_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_comments
  ADD CONSTRAINT fk_comments_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_comments_parent FOREIGN KEY (parent_comment_id) REFERENCES media_comments (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_comments_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_file_chunks
  ADD CONSTRAINT fk_media_file_chunks_file FOREIGN KEY (file_id) REFERENCES media_files (id) ON DELETE CASCADE;

ALTER TABLE media_files
  ADD CONSTRAINT fk_media_files_user FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL;

ALTER TABLE media_item_subcategories
  ADD CONSTRAINT fk_media_item_subcategories_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_media_item_subcategories_subcategory FOREIGN KEY (subcategory_id) REFERENCES subcategories (id) ON DELETE CASCADE;

ALTER TABLE media_items
  ADD CONSTRAINT fk_media_category FOREIGN KEY (category_id) REFERENCES categories (id),
  ADD CONSTRAINT fk_media_subcategory FOREIGN KEY (subcategory_id) REFERENCES subcategories (id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_media_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_likes
  ADD CONSTRAINT fk_likes_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_likes_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_reactions
  ADD CONSTRAINT fk_media_reactions_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_media_reactions_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE media_reports
  ADD CONSTRAINT fk_reports_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_reports_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE message_thread_members
  ADD CONSTRAINT fk_thread_members_thread FOREIGN KEY (thread_id) REFERENCES message_threads (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_thread_members_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE message_threads
  ADD CONSTRAINT fk_message_threads_creator FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE moderation_audit_log
  ADD CONSTRAINT fk_audit_log_actor FOREIGN KEY (actor_id) REFERENCES users (id) ON DELETE SET NULL;

ALTER TABLE notifications
  ADD CONSTRAINT fk_notifications_actor FOREIGN KEY (actor_id) REFERENCES users (id) ON DELETE SET NULL,
  ADD CONSTRAINT fk_notifications_media FOREIGN KEY (media_id) REFERENCES media_items (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_notifications_recipient FOREIGN KEY (recipient_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE saved_searches
  ADD CONSTRAINT fk_saved_searches_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE site_settings
  ADD CONSTRAINT fk_site_settings_updated_by FOREIGN KEY (updated_by) REFERENCES users (id) ON DELETE SET NULL;

ALTER TABLE subcategories
  ADD CONSTRAINT fk_subcategories_category FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_subcategories_user FOREIGN KEY (created_by) REFERENCES users (id) ON DELETE SET NULL;

ALTER TABLE thread_messages
  ADD CONSTRAINT fk_thread_messages_sender FOREIGN KEY (sender_id) REFERENCES users (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_thread_messages_thread FOREIGN KEY (thread_id) REFERENCES message_threads (id) ON DELETE CASCADE;

ALTER TABLE user_avatar_files
  ADD CONSTRAINT fk_avatar_files_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE user_blocks
  ADD CONSTRAINT fk_user_blocks_blocked FOREIGN KEY (blocked_id) REFERENCES users (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_user_blocks_blocker FOREIGN KEY (blocker_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE user_follows
  ADD CONSTRAINT fk_follows_followed FOREIGN KEY (followed_id) REFERENCES users (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_follows_follower FOREIGN KEY (follower_id) REFERENCES users (id) ON DELETE CASCADE;

ALTER TABLE user_messages
  ADD CONSTRAINT fk_messages_recipient FOREIGN KEY (recipient_id) REFERENCES users (id) ON DELETE CASCADE,
  ADD CONSTRAINT fk_messages_sender FOREIGN KEY (sender_id) REFERENCES users (id) ON DELETE CASCADE;

-- =====================================================================
-- 5. CHECK constraints
-- =====================================================================

ALTER TABLE friend_requests ADD CONSTRAINT chk_no_self_friend CHECK (requester_id <> addressee_id);
ALTER TABLE user_follows ADD CONSTRAINT chk_no_self_follow CHECK (follower_id <> followed_id);
ALTER TABLE user_messages ADD CONSTRAINT chk_no_self_message CHECK (sender_id <> recipient_id);
ALTER TABLE media_item_subcategories ADD CONSTRAINT chk_media_item_subcategories_position CHECK (position BETWEEN 1 AND 3);

-- json_valid(...) equivalents (Postgres: cast to json to validate; NULL always passes)
ALTER TABLE media_items ADD CONSTRAINT chk_media_items_tags_json CHECK (tags IS NULL OR tags::json IS NOT NULL);
ALTER TABLE ai_vision_training_examples ADD CONSTRAINT chk_ai_training_source_tags_json CHECK (source_tags IS NULL OR source_tags::json IS NOT NULL);
ALTER TABLE ai_vision_training_examples ADD CONSTRAINT chk_ai_training_corrected_tags_json CHECK (corrected_tags IS NULL OR corrected_tags::json IS NOT NULL);
ALTER TABLE users ADD CONSTRAINT chk_users_featured_tags_json CHECK (featured_tags IS NULL OR featured_tags::json IS NOT NULL);
ALTER TABLE users ADD CONSTRAINT chk_users_settings_json CHECK (user_settings IS NULL OR user_settings::json IS NOT NULL);
ALTER TABLE users ADD CONSTRAINT chk_users_recovery_codes_json CHECK (totp_recovery_codes IS NULL OR totp_recovery_codes::json IS NOT NULL);

COMMIT;
