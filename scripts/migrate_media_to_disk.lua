-- One-off migration: move existing media_items rows off Postgres bytea
-- storage (media_files/media_file_chunks) onto content-addressed flat
-- files under GALLERY_UPLOADS_DIR, matching what new uploads now do
-- (see media_files.lua's save_media_file_to_disk). Run once, from lua/:
--   luajit ../scripts/migrate_media_to_disk.lua
--
-- One row at a time -- reads a single file's content into memory, writes
-- it to disk, verifies the sha256 matches, flips storage_path, then moves
-- on. Never holds more than one file at a time. Does NOT delete the
-- original Postgres bytea data -- that stays as a rollback safety net
-- until manually purged later (see the DELETE printed in the summary).
package.path = "./lib/?.lua;./lib/?/init.lua;./src/?.lua;" .. package.path

local db = require("db")
local media_files = require("media_files")
local config = require("config")
local sodium = require("luasodium")

local settings = config.load()
db.init(settings)

local rows = db.fetchall([[
  SELECT id, media_file_id, storage_path, original_filename, mime_type, content_sha256
  FROM media_items
  WHERE media_file_id IS NOT NULL AND deleted_at IS NULL
  ORDER BY id
]])

print(string.format("Found %d row(s) with DB-blob storage to migrate.", #rows))

local migrated, skipped, failed = 0, 0, 0

for _, row in ipairs(rows) do
  local media_id = db.toint(row.id, row.id)
  io.write(string.format("media_id=%s ... ", tostring(media_id)))
  io.flush()

  local full = media_files.get_media_file(media_id)
  if not full or not full.content or #full.content == 0 then
    print("SKIP (no retrievable content -- pre-restore row, already broken)")
    skipped = skipped + 1
  else
    local actual_sha = sodium.sodium_bin2hex(sodium.crypto_hash_sha256(full.content))
    if row.content_sha256 and row.content_sha256 ~= "" and actual_sha ~= row.content_sha256 then
      print(string.format("FAIL (sha256 mismatch: row says %s, content is %s)", row.content_sha256, actual_sha))
      failed = failed + 1
    else
      local ext = (row.original_filename or ""):match("(%.[^./\\]+)$")
      local saved, save_err = media_files.save_media_file_to_disk(settings.uploads_dir, {
        content = full.content,
        sha256 = actual_sha,
        ext = ext,
        original_filename = row.original_filename,
      })
      if not saved then
        print("FAIL (" .. tostring(save_err) .. ")")
        failed = failed + 1
      else
        -- Verify the on-disk file reads back byte-identical before
        -- touching the row -- belt and suspenders given this flips the
        -- read path for real production media.
        local uploads_dir = settings.uploads_dir:gsub("/+$", "")
        local f = io.open(uploads_dir .. "/" .. saved.storage_path, "rb")
        local written = f and f:read("*a")
        if f then f:close() end
        if written ~= full.content then
          print("FAIL (post-write verification mismatch)")
          failed = failed + 1
        else
          local ok, uerr = db.execute(
            "UPDATE media_items SET storage_path=%s, media_file_id=NULL WHERE id=%s",
            saved.storage_path, tostring(media_id)
          )
          if not ok then
            print("FAIL (DB update: " .. tostring(uerr) .. ")")
            failed = failed + 1
          else
            print(string.format("OK -> %s%s", saved.storage_path, saved.duplicate and " (deduped, already existed)" or ""))
            migrated = migrated + 1
          end
        end
      end
    end
  end
end

print(string.format("\nDone. migrated=%d skipped=%d failed=%d", migrated, skipped, failed))
if migrated > 0 then
  print("\nOriginal Postgres bytea content was NOT deleted (kept as a rollback safety net).")
  print("Once you've confirmed everything looks right, it can be freed with:")
  print("  DELETE FROM media_files WHERE id NOT IN (SELECT media_file_id FROM media_items WHERE media_file_id IS NOT NULL);")
end
