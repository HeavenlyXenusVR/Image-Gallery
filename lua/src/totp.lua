-- RFC 6238 TOTP, byte-for-byte compatible with app/totp.py (6-digit codes,
-- 30s period, HMAC-SHA1, +/-1 step verification window).
--
-- Why not reuse luasodium here the way auth.lua does for HMAC-SHA256:
-- libsodium deliberately does not expose SHA-1 (it's considered broken for
-- anything security-load-bearing), but TOTP/RFC 6238 hard-codes HMAC-SHA1 as
-- its default and every mainstream authenticator app (Google Authenticator,
-- Authy, 1Password, ...) only speaks that variant -- there's no "upgrade to
-- SHA-256" option without breaking compatibility with every app a user might
-- already have enrolled. No sha1/openssl rock is installed in this image
-- either (see lua/Dockerfile's rock list), so this file implements SHA-1
-- from scratch using LuaJIT's `bit` library, the same way auth.lua already
-- hand-rolls HMAC-SHA256 on top of libsodium's raw crypto_hash_sha256.
local bit = require("bit")
local band, bor, bxor, lshift, rshift, rol = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.rol

local M = {}

-- ---------------------------------------------------------------------------
-- SHA-1 (FIPS 180-4)
-- ---------------------------------------------------------------------------

local function pack32be(x)
  return string.char(
    band(rshift(x, 24), 0xFF),
    band(rshift(x, 16), 0xFF),
    band(rshift(x, 8), 0xFF),
    band(x, 0xFF)
  )
end

function M.sha1(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local msg_len_bits = #msg * 8

  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do msg = msg .. "\0" end
  -- 64-bit big-endian bit-length; every input this module ever hashes (HMAC
  -- blocks/keys for a TOTP secret) is far under 2^32 bits, so the high word
  -- is always zero.
  msg = msg .. pack32be(0) .. pack32be(msg_len_bits)

  for chunk_start = 1, #msg, 64 do
    local chunk = msg:sub(chunk_start, chunk_start + 63)
    local w = {}
    for i = 0, 15 do
      local o = i * 4
      w[i] = bor(
        lshift(chunk:byte(o + 1), 24),
        lshift(chunk:byte(o + 2), 16),
        lshift(chunk:byte(o + 3), 8),
        chunk:byte(o + 4)
      )
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bit.bnot(b), d)); k = 0x5A827999
      elseif i < 40 then
        f = bxor(bxor(b, c), d); k = 0x6ED9EBA1
      elseif i < 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d)); k = 0x8F1BBCDC
      else
        f = bxor(bxor(b, c), d); k = 0xCA62C1D6
      end
      local temp = bit.tobit(rol(a, 5) + f + e + k + w[i])
      e = d; d = c; c = rol(b, 30); b = a; a = temp
    end

    h0 = bit.tobit(h0 + a)
    h1 = bit.tobit(h1 + b)
    h2 = bit.tobit(h2 + c)
    h3 = bit.tobit(h3 + d)
    h4 = bit.tobit(h4 + e)
  end

  return pack32be(h0) .. pack32be(h1) .. pack32be(h2) .. pack32be(h3) .. pack32be(h4)
end

local BLOCKSIZE = 64

local function xor_pad(key, byte)
  local out = {}
  for i = 1, #key do out[i] = string.char(bxor(key:byte(i), byte)) end
  return table.concat(out)
end

function M.hmac_sha1(key, msg)
  if #key > BLOCKSIZE then key = M.sha1(key) end
  if #key < BLOCKSIZE then key = key .. string.rep("\0", BLOCKSIZE - #key) end
  local ipad, opad = xor_pad(key, 0x36), xor_pad(key, 0x5c)
  return M.sha1(opad .. M.sha1(ipad .. msg))
end

-- ---------------------------------------------------------------------------
-- Base32 (RFC 4648), matching Python's base64.b32encode/b32decode usage in
-- app/totp.py (uppercase alphabet, '=' padding accepted-but-optional on
-- decode, generated secrets have padding stripped same as generate_secret()).
-- ---------------------------------------------------------------------------

local B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

function M.base32_encode(bytes)
  local out = {}
  local bits, value = 0, 0
  for i = 1, #bytes do
    value = bor(lshift(value, 8), bytes:byte(i))
    bits = bits + 8
    while bits >= 5 do
      local idx = band(rshift(value, bits - 5), 0x1F)
      out[#out + 1] = B32_ALPHABET:sub(idx + 1, idx + 1)
      bits = bits - 5
    end
  end
  if bits > 0 then
    local idx = band(lshift(value, 5 - bits), 0x1F)
    out[#out + 1] = B32_ALPHABET:sub(idx + 1, idx + 1)
  end
  return table.concat(out)
end

function M.base32_decode(text)
  text = tostring(text or ""):upper():gsub("[^A-Z2-7]", "")
  local out = {}
  local bits, value = 0, 0
  for i = 1, #text do
    local idx = B32_ALPHABET:find(text:sub(i, i), 1, true)
    if not idx then return nil end
    value = bor(lshift(value, 5), idx - 1)
    bits = bits + 5
    if bits >= 8 then
      local byte = band(rshift(value, bits - 8), 0xFF)
      out[#out + 1] = string.char(byte)
      bits = bits - 8
    end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- HOTP / TOTP (RFC 4226 / RFC 6238)
-- ---------------------------------------------------------------------------

local DIGITS = 6
M.PERIOD_SECONDS = 30

local function hotp(secret, counter)
  local key = M.base32_decode(secret)
  -- 64-bit big-endian counter.
  local hi = math.floor(counter / 4294967296)
  local lo = counter % 4294967296
  local counter_bytes = pack32be(hi) .. pack32be(lo)
  local digest = M.hmac_sha1(key, counter_bytes)
  local offset = band(digest:byte(20), 0x0F)
  local code_int = bor(
    bor(lshift(band(digest:byte(offset + 1), 0x7F), 24), lshift(digest:byte(offset + 2), 16)),
    bor(lshift(digest:byte(offset + 3), 8), digest:byte(offset + 4))
  ) % (10 ^ DIGITS)
  return string.format("%0" .. DIGITS .. "d", code_int)
end

function M.current_code(secret, at)
  return hotp(secret, math.floor(at / M.PERIOD_SECONDS))
end

function M.verify_code(secret, code, at, window)
  window = window or 1
  local digits_only = tostring(code or ""):gsub("%D", "")
  if #digits_only ~= DIGITS then return false end
  local counter = math.floor(at / M.PERIOD_SECONDS)
  for offset = -window, window do
    if hotp(secret, counter + offset) == digits_only then return true end
  end
  return false
end

function M.generate_secret()
  local sodium = require("luasodium")
  local raw = sodium.randombytes_buf(20)
  return M.base32_encode(raw)
end

function M.provisioning_uri(secret, account_name, issuer)
  issuer = issuer or "Image Gallery"
  local function urlenc(s)
    return (tostring(s):gsub("[^%w%-%.%_%~]", function(c) return string.format("%%%02X", c:byte()) end))
  end
  local label = urlenc(issuer .. ":" .. account_name)
  return string.format(
    "otpauth://totp/%s?secret=%s&issuer=%s&algorithm=SHA1&digits=%d&period=%d",
    label, secret, urlenc(issuer), DIGITS, M.PERIOD_SECONDS
  )
end

function M.generate_recovery_codes(count)
  local sodium = require("luasodium")
  count = count or 8
  local codes = {}
  for i = 1, count do
    local a = sodium.sodium_bin2hex(sodium.randombytes_buf(3))
    local b = sodium.sodium_bin2hex(sodium.randombytes_buf(3))
    codes[i] = a .. "-" .. b
  end
  return codes
end

return M
