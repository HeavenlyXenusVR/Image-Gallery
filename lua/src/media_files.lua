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

-- ---------------------------------------------------------------------------
-- Perceptual image fingerprinting (average hash + difference hash), for the
-- possible-duplicate-upload warning. Mirrors app/ai_metadata.py's
-- _image_fingerprint/_average_hash/_difference_hash, but via ffmpeg instead
-- of PIL (same rationale as the thumbnail rendering above -- no PIL
-- equivalent in Lua). NOT bit-for-bit identical to Python's hashes (ffmpeg's
-- lanczos scale + its own EXIF-orientation handling differ slightly from
-- PIL's resize()+ImageOps.exif_transpose()), which only matters if directly
-- comparing a Python-computed hash against a Lua-computed one -- this
-- feature only ever compares hashes computed by the same backend that's
-- currently live, and the comparison is already fuzzy (Hamming-distance
-- threshold), so close-enough is fine for an advisory "maybe a duplicate"
-- warning.
local bit = require("bit")

local function ffprobe_bin()
  return os.getenv("GALLERY_FFPROBE_BIN") or "ffprobe"
end

-- Grabs a `w`x`h` grayscale raw frame (1 byte/pixel, row-major) via ffmpeg.
-- Returns the raw byte string, or nil on failure.
local function raw_gray_frame(src_path, w, h)
  local dst = os.tmpname() .. ".raw"
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -vf %s -f rawvideo -pix_fmt gray -frames:v 1 %s </dev/null >/dev/null 2>&1",
    ffmpeg_bin(),
    shell_quote(src_path),
    shell_quote(string.format("scale=%d:%d:flags=lanczos", w, h)),
    shell_quote(dst)
  )
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)
  if not success or not file_exists(dst) then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  if #bytes ~= w * h then return nil end
  return bytes
end

-- Grabs a `w`x`h` RGB24 raw frame (3 bytes/pixel, row-major) via ffmpeg --
-- same pattern as raw_gray_frame above, just a different pix_fmt. Used for
-- cheap dominant-color extraction: downscaling to a small grid first (via
-- ffmpeg's own lanczos scaler) and averaging those few pixels in Lua is
-- effectively a fast box-blur, which is a perfectly good "dominant color"
-- approximation without pulling in a real color-quantization library.
local function raw_rgb_frame(src_path, w, h)
  local dst = os.tmpname() .. ".raw"
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -vf %s -f rawvideo -pix_fmt rgb24 -frames:v 1 %s </dev/null >/dev/null 2>&1",
    ffmpeg_bin(),
    shell_quote(src_path),
    shell_quote(string.format("scale=%d:%d:flags=lanczos", w, h)),
    shell_quote(dst)
  )
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)
  if not success or not file_exists(dst) then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  if #bytes ~= w * h * 3 then return nil end
  return bytes
end

-- Returns "#rrggbb" or nil. 8x8 (not 1x1) so ffmpeg's own lanczos scaler
-- does the heavy lifting of a real weighted downsample instead of ffmpeg
-- picking/blending just one sample point, then Lua averages those 64
-- pixels -- cheap, deterministic, no extra dependency beyond the ffmpeg
-- binary already required for phash/dhash/thumbnails.
local function average_color(src_path)
  local pixels = raw_rgb_frame(src_path, 8, 8)
  if not pixels then return nil end
  local r, g, b, count = 0, 0, 0, 0
  for i = 1, #pixels, 3 do
    r = r + pixels:byte(i)
    g = g + pixels:byte(i + 1)
    b = b + pixels:byte(i + 2)
    count = count + 1
  end
  return string.format("#%02x%02x%02x", math.floor(r / count + 0.5), math.floor(g / count + 0.5), math.floor(b / count + 0.5))
end

-- Packs 64 0/1 bits (MSB-first) into a 16-hex-char string, matching Python's
-- f"{bits:016x}" for a 64-bit integer -- built as two 32-bit halves since
-- Lua 5.1/LuaJIT's `bit` library (and plain Lua number arithmetic) only
-- reliably handles 32 bits at a time.
local function pack_bits_hex(get_bit)
  local hi, lo = 0, 0
  for i = 0, 63 do
    local b = get_bit(i) and 1 or 0
    if i < 32 then
      hi = bit.bor(bit.lshift(hi, 1), b)
    else
      lo = bit.bor(bit.lshift(lo, 1), b)
    end
  end
  return bit.tohex(hi) .. bit.tohex(lo)
end

-- Returns {image_phash, image_dhash, image_width, image_height} or nil.
-- Mirrors _image_fingerprint_for_upload()'s "images only, need the bytes"
-- gate -- callers should only invoke this for in-memory image uploads.
function M.image_fingerprint(content)
  local src = write_temp_file(content, "")

  local width, height
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x %s 2>/dev/null",
    ffprobe_bin(), shell_quote(src)
  ))
  if probe then
    local line = probe:read("*l")
    probe:close()
    if line then width, height = line:match("^(%d+)x(%d+)$") end
  end

  local phash_pixels = raw_gray_frame(src, 8, 8)
  local dhash_pixels = raw_gray_frame(src, 9, 8)
  local dominant_color = average_color(src)
  os.remove(src)
  if not phash_pixels and not dhash_pixels then return nil end

  local image_phash, image_dhash
  if phash_pixels then
    local sum = 0
    for i = 1, #phash_pixels do sum = sum + phash_pixels:byte(i) end
    local avg = sum / #phash_pixels
    image_phash = pack_bits_hex(function(i) return phash_pixels:byte(i + 1) >= avg end)
  end
  if dhash_pixels then
    -- 9-wide x 8-tall: bit(row, col) = pixel(row, col) > pixel(row, col+1),
    -- for col in 0..7 (8 comparisons per row, 9 samples per row).
    image_dhash = pack_bits_hex(function(i)
      local row, col = math.floor(i / 8), i % 8
      local offset = row * 9 + col
      return dhash_pixels:byte(offset + 1) > dhash_pixels:byte(offset + 2)
    end)
  end

  return {
    image_phash = image_phash,
    image_dhash = image_dhash,
    image_width = width and tonumber(width) or nil,
    image_height = height and tonumber(height) or nil,
    dominant_color = dominant_color,
  }
end

-- ---------------------------------------------------------------------------
-- Media dimensions + JPEG preview, used by ai_metadata.lua's heuristic
-- analysis (landscape/portrait/4k tags) and vision-provider calls (a small
-- JPEG preview to send as the image payload). Mirrors app/ai_metadata.py's
-- _media_size/_video_size/_preview_base64/_video_preview_base64, again via
-- ffmpeg/ffprobe instead of PIL -- works uniformly for images and videos
-- (ffprobe/ffmpeg treat a still image as a 1-frame video), so one pair of
-- helpers covers both media kinds instead of Python's separate image/video
-- branches.
-- ---------------------------------------------------------------------------

-- Returns {width, height} or nil.
function M.media_dimensions(content)
  local src = write_temp_file(content, "")
  local width, height
  local probe = io.popen(string.format(
    "%s -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x %s 2>/dev/null",
    ffprobe_bin(), shell_quote(src)
  ))
  if probe then
    local line = probe:read("*l")
    probe:close()
    if line then width, height = line:match("^(%d+)x(%d+)$") end
  end
  os.remove(src)
  if not width or not height then return nil end
  return { tonumber(width), tonumber(height) }
end

-- Returns a base64-encoded JPEG preview (scaled to fit 1600x1600, matching
-- Python's preview.thumbnail((1600, 1600))), or nil on failure.
function M.jpeg_preview_base64(content)
  local sodium = require("luasodium")
  local src = write_temp_file(content, "")
  local dst = os.tmpname() .. ".jpg"
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -frames:v 1 -vf %s -q:v 3 -f mjpeg %s </dev/null >/dev/null 2>&1",
    ffmpeg_bin(), shell_quote(src), shell_quote("scale='min(1600,iw)':'min(1600,ih)':force_original_aspect_ratio=decrease:flags=lanczos"),
    shell_quote(dst)
  )
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)
  os.remove(src)
  if not success or not file_exists(dst) then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  if not bytes or #bytes == 0 then return nil end
  return sodium.sodium_bin2base64(bytes, sodium.sodium_base64_VARIANT_ORIGINAL)
end

-- ---------------------------------------------------------------------------
-- Watermark overlay -- "Watermark / Signature Text" has existed as a saved
-- user_settings field with a real Settings-page input since before this
-- pass, but was never actually applied anywhere: it was pure dead data,
-- silently doing nothing after being saved. Uses ffmpeg's drawtext filter
-- (already the only image-processing tool this backend depends on -- no
-- ImageMagick binary is even installed on this host, despite being listed
-- in the NixOS deps script, so staying on ffmpeg avoids adding a real new
-- dependency for this).
-- ---------------------------------------------------------------------------

local WATERMARK_FONT = os.getenv("GALLERY_WATERMARK_FONT") or "/usr/share/fonts/noto/NotoSans-Regular.ttf"

-- Escapes a file path for use as a drawtext fontfile=/textfile= value --
-- ffmpeg's filtergraph mini-language treats ":" as the option separator
-- and "\" as its own escape character, so both need doubling/escaping even
-- though a real filesystem path (not user-controlled text -- that's the
-- textfile trick above) is very unlikely to contain either in practice.
local function ffmpeg_filter_path_escape(path)
  return (tostring(path):gsub("\\", "\\\\"):gsub(":", "\\:"))
end

local EXT_FOR_MIME = {
  ["image/png"] = "png",
  ["image/webp"] = "webp",
  ["image/jpeg"] = "jpg",
  ["image/jpg"] = "jpg",
}

-- Returns new watermarked bytes, or nil on any failure (missing font,
-- unsupported format, ffmpeg error, ...) -- callers must fail OPEN (serve
-- the original, unwatermarked bytes) rather than error the whole request,
-- since a cosmetic feature breaking should never take down file serving.
function M.apply_watermark(content, mime_type, watermark_text)
  local text = tostring(watermark_text or ""):match("^%s*(.-)%s*$")
  if text == "" or not file_exists(WATERMARK_FONT) then return nil end
  local ext = EXT_FOR_MIME[tostring(mime_type or ""):lower()]
  if not ext then return nil end

  local src = write_temp_file(content, "")
  -- textfile= (not text=) so the user-controlled string never has to be
  -- escaped into ffmpeg's filtergraph mini-language (colons/commas/quotes
  -- in drawtext's inline text= are a real footgun to escape correctly) --
  -- ffmpeg just reads the file's raw bytes as the label instead.
  local text_file = os.tmpname()
  local tf = io.open(text_file, "wb")
  if not tf then os.remove(src); return nil end
  tf:write(text:sub(1, 40))
  tf:close()
  local dst = os.tmpname() .. "." .. ext

  -- Bottom-right corner, semi-transparent white with a soft shadow so it
  -- reads against both light and dark image content; size and margin
  -- scale with image height so it looks proportional on any resolution.
  local filter = string.format(
    "drawtext=fontfile=%s:textfile=%s:fontcolor=white@0.55:fontsize=h/22:x=w-tw-(h/40+12):y=h-th-(h/40+12):shadowcolor=black@0.5:shadowx=2:shadowy=2",
    ffmpeg_filter_path_escape(WATERMARK_FONT), ffmpeg_filter_path_escape(text_file)
  )
  local cmd = string.format(
    "%s -y -hide_banner -loglevel error -i %s -vf %s -frames:v 1 %s </dev/null >/dev/null 2>&1",
    ffmpeg_bin(), shell_quote(src), shell_quote(filter), shell_quote(dst)
  )
  local ok = os.execute(cmd)
  local success = (ok == 0 or ok == true)
  os.remove(src)
  os.remove(text_file)
  if not success or not file_exists(dst) then
    os.remove(dst)
    return nil
  end
  local f = io.open(dst, "rb")
  local bytes = f:read("*a")
  f:close()
  os.remove(dst)
  if not bytes or #bytes == 0 then return nil end
  return bytes
end

return M
