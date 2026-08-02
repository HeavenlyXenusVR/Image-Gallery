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
-- DB blob writes (mirrors save_media_file() in app/db/media_storage.py)
-- ---------------------------------------------------------------------------

-- Precomputed byte->hex-pair table so encoding a multi-MB chunk is one
-- gsub() call instead of a manual per-byte string.format loop.
local HEX_BYTE = {}
for i = 0, 255 do HEX_BYTE[string.char(i)] = string.format("%02x", i) end

-- Postgres bytea values must travel as a plain-ASCII hex-format literal
-- (`\x4865...`) inside the single SQL string db.lua builds via
-- escape_literal -- raw binary (including NUL bytes) can't safely ride
-- inside a %-formatted SQL string otherwise. pgmoon's escape_literal only
-- quotes/escapes the resulting ASCII text, so this must happen first.
local function bytea_literal(bytes)
  return "\\x" .. (bytes:gsub(".", HEX_BYTE))
end

local DEFAULT_CHUNK_BYTES = 8 * 1024 * 1024

-- Chunked insert mirroring save_media_file(): dedups by sha256 first: if a
-- media_files row already has this content, returns it with duplicate=true
-- instead of storing the bytes again. `content` must be the full blob
-- already in memory (see the multipart-parsing note in httpd.lua for why
-- this port doesn't stream multi-GB uploads to disk the way Python does).
function M.save_media_file(opts)
  local existing = db.fetchone(
    "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE sha256=%s",
    opts.sha256
  )
  if existing then
    existing.id = db.toint(existing.id, existing.id)
    existing.file_size = db.toint(existing.file_size, existing.file_size)
    existing.duplicate = true
    return existing
  end

  local content = opts.content or ""
  local total_size = opts.file_size or #content
  local chunk_bytes = math.max(1024 * 1024, math.min(opts.chunk_bytes or DEFAULT_CHUNK_BYTES, 16 * 1024 * 1024))

  local row, err = db.fetchone(
    "INSERT INTO media_files (sha256, mime_type, original_filename, media_kind, file_size, content, created_by) VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id",
    opts.sha256, opts.mime_type:sub(1, 120), opts.original_filename:sub(1, 255), opts.media_kind, tostring(total_size), "", tostring(opts.user_id)
  )
  if not row then return nil, err end
  local media_file_id = db.toint(row.id, row.id)

  local ok, insert_err = pcall(function()
    local chunk_index = 0
    local offset = 0
    while offset < #content do
      local chunk = content:sub(offset + 1, offset + chunk_bytes)
      local ok2, chunk_err = db.execute(
        "INSERT INTO media_file_chunks (file_id, chunk_index, content) VALUES (%s,%s,%s)",
        tostring(media_file_id), tostring(chunk_index), bytea_literal(chunk)
      )
      if not ok2 then error(chunk_err or "chunk insert failed") end
      chunk_index = chunk_index + 1
      offset = offset + chunk_bytes
    end
  end)
  if not ok then
    db.execute("DELETE FROM media_files WHERE id=%s", tostring(media_file_id))
    return nil, insert_err
  end

  local final = db.fetchone(
    "SELECT id, sha256, mime_type, original_filename, media_kind, file_size, created_by, created_at FROM media_files WHERE id=%s",
    tostring(media_file_id)
  )
  if final then
    final.id = db.toint(final.id, final.id)
    final.file_size = db.toint(final.file_size, final.file_size)
    final.duplicate = false
  end
  return final
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
