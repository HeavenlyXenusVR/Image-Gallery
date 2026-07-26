-- DB-backed blob storage + legacy on-disk fallback + ffmpeg-based thumbnail /
-- preview rendering, mirroring app/db/media_storage.py + the byte-serving
-- logic in app/routers/media_streaming.py.
--
-- STORAGE MODEL (confirmed against the live, April-29-restored Postgres
-- data, NOT the content-addressed-on-disk model originally assumed for this
-- task): GALLERY_STORAGE_BACKEND=database is what's actually configured, so
-- every media_items row has storage_path='db://media/<media_file_id>' and
-- its bytes live in media_files.content (bytea), chunked into
-- media_file_chunks for large uploads. The on-disk uploads/media/<hh>/<hash>
-- tree (8 files) is leftover from an earlier filesystem-backend period and
-- does not correspond to any current media_items row by content_sha256 (was
-- verified directly against the DB before writing this file) -- so
-- _legacy_upload_path below is real, faithfully-ported code that is simply
-- unreachable for all 540 rows in the current dataset (every storage_path
-- starts with "db://"). Right now media_files/media_file_chunks are BOTH
-- EMPTY (the April 29 backup/restore did not include the BLOB tables), so
-- get_media_file()/get_media_file_info() correctly return nil for all 540
-- items and callers must 404 cleanly -- this is expected, not a bug.
--
-- No PIL equivalent exists in Lua, so image/video thumbnail and preview
-- rendering shells out to ffmpeg (already required in lua/Dockerfile) for
-- both jobs instead of an image-decoding library: `ffmpeg -i <src> -vf
-- scale=... -c:v libwebp <dst>` handles a single still image exactly like a
-- 1-frame video, so the same helper serves both call sites. This blocks
-- copas' single-threaded event loop for the duration of the ffmpeg process
-- (io.popen/os.execute have no async variant without extra rocks) -- fine
-- for this deployment's traffic level, but a real scaling concern flagged
-- here rather than silently accepted.

local db = require("db")

local M = {}

-- ---------------------------------------------------------------------------
-- DB blob reads (mirrors app/db/media_storage.py)
-- ---------------------------------------------------------------------------

-- Metadata only, no content -- mirrors get_media_file_info().
function M.get_media_file_info(media_id)
  local row = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size,
           octet_length(f.content) AS inline_size
    FROM media_files f
    JOIN media_items m ON m.media_file_id = f.id
    WHERE m.id = %s
  ]], media_id)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.file_size = db.toint(row.file_size, 0)
  row.inline_size = db.toint(row.inline_size, 0)
  return row
end

-- Full content, assembling media_file_chunks if the row's own `content` is
-- shorter than file_size (large chunked upload) -- mirrors get_media_file().
function M.get_media_file(media_id)
  local row = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.media_kind, f.file_size, f.content
    FROM media_files f
    JOIN media_items m ON m.media_file_id = f.id
    WHERE m.id = %s
  ]], media_id)
  if not row then return nil end
  row.id = db.toint(row.id, row.id)
  row.file_size = db.toint(row.file_size, 0)
  local content = row.content or ""
  if #content ~= row.file_size then
    local chunks = db.fetchall(
      "SELECT content FROM media_file_chunks WHERE file_id=%s ORDER BY chunk_index ASC",
      row.id
    )
    if chunks and #chunks > 0 then
      local parts = {}
      for _, c in ipairs(chunks) do parts[#parts + 1] = c.content or "" end
      row.content = table.concat(parts)
    end
  end
  return row
end

function M.get_avatar_file(user_id)
  local row = db.fetchone([[
    SELECT f.id, f.sha256, f.mime_type, f.original_filename, f.file_size, f.content
    FROM user_avatar_files f
    JOIN users u ON u.avatar_file_id = f.id
    WHERE u.id = %s
  ]], user_id)
  if row then
    row.id = db.toint(row.id, row.id)
    row.file_size = db.toint(row.file_size, 0)
  end
  return row
end

-- ---------------------------------------------------------------------------
-- Legacy on-disk fallback (mirrors _legacy_upload_path in app/routers/_shared.py)
-- ---------------------------------------------------------------------------

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Returns an absolute path string if `storage_path` resolves to a real file
-- strictly inside uploads_dir, else nil. storage_path values starting with
-- "db://" or "avatar-db://" are DB-backed by definition and never resolve
-- here (matches Python's early-return).
function M.legacy_upload_path(uploads_dir, storage_path)
  if not storage_path or storage_path == "" then return nil end
  if storage_path:match("^db://") or storage_path:match("^avatar%-db://") then return nil end
  local raw = storage_path:gsub("\\", "/"):gsub("^/+", "")
  if raw:match("%.%.") then return nil end -- reject any ".." path-traversal segment
  uploads_dir = uploads_dir:gsub("/+$", "")
  local path = uploads_dir .. "/" .. raw
  if not file_exists(path) then return nil end
  return path
end

-- ---------------------------------------------------------------------------
-- ffmpeg-backed thumbnail / preview rendering
-- ---------------------------------------------------------------------------

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function write_temp_file(content, suffix)
  local path = os.tmpname() .. (suffix or "")
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
  return path
end

local function ffmpeg_bin()
  return os.getenv("GALLERY_FFMPEG_BIN") or "ffmpeg"
end

-- Renders `src_path` (any image OR video ffmpeg can demux -- a single still
-- image behaves like a 1-frame video for this purpose, so one helper covers
-- both serve_media_thumb's image branch and _render_video_frame_thumb) to a
-- WEBP thumbnail/preview at `dst_path`. `seek` (seconds, video only) mirrors
-- _render_video_frame_thumb's "-ss 0.35" grab-a-real-frame-not-just-frame-0
-- behavior. Returns true on success.
function M.render_webp(src_path, dst_path, max_edge, quality, seek)
  -- IMPORTANT: the temp file must end in ".webp" (not e.g. dst_path..".tmp"),
  -- or ffmpeg's output-format auto-detection (which goes purely off the
  -- filename extension) fails with "Unable to choose an output format" --
  -- discovered by actually running this against a live sample file, not
  -- assumed. "-f webp" is also passed explicitly as a second safety net.
  local tmp_dst = dst_path .. ".tmp.webp"
  local seek_args = seek and (" -ss " .. tostring(seek)) or ""
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error%s -i %s -frames:v 1 -vf %s -c:v libwebp -compression_level 5 -quality %d -f webp %s </dev/null >/dev/null 2>&1",
    ffmpeg_bin(),
    seek_args,
    shell_quote(src_path),
    shell_quote(string.format("scale='min(%d,iw)':-2:flags=lanczos", max_edge)),
    math.floor(quality),
    shell_quote(tmp_dst)
  )
  local ok = os.execute(cmd)
  -- Lua 5.1/LuaJIT's os.execute returns the raw OS exit status (0 == success);
  -- Lua 5.2+ returns (true, "exit", 0). Accept either convention.
  local success = (ok == 0 or ok == true)
  if success and file_exists(tmp_dst) then
    os.rename(tmp_dst, dst_path)
    return true
  end
  os.remove(tmp_dst)
  return false
end

-- Convenience wrapper: render a WEBP thumb/preview straight from in-memory
-- blob bytes (DB-backed content) via a scratch temp file, cleaned up after.
function M.render_webp_from_bytes(content, max_edge, quality, seek)
  local src = write_temp_file(content, "")
  local dst = os.tmpname() .. ".webp"
  local ok = M.render_webp(src, dst, max_edge, quality, seek)
  os.remove(src)
  if not ok then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  return bytes
end

-- Plain SVG placeholder for a video thumbnail when no source frame can be
-- extracted (mirrors the SVG fallback branch inside Python's own
-- _render_video_placeholder_thumb, used here as the primary implementation
-- since Lua has no PIL-equivalent to draw the fancier gradient+play-button
-- PNG Python renders first).
function M.video_placeholder_svg(width)
  width = math.floor(width or 480)
  local height = math.max(120, math.floor(width * 9 / 16))
  return string.format(
    "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d'>"
      .. "<rect width='100%%' height='100%%' fill='#18212d'/>"
      .. "<circle cx='50%%' cy='50%%' r='48' fill='none' stroke='rgba(255,255,255,.62)' stroke-width='4'/>"
      .. "<path d='M46%% 42%%v16l16-8z' fill='rgba(255,255,255,.72)'/></svg>",
    width, height, width, height
  )
end

return M
