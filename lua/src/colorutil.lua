-- Small color-math helpers so accent theming can be *computed* server-side
-- instead of the frontend guessing at readable text color or a matching
-- second accent. Pure functions, no deps.
local M = {}

local function clamp01(n) return math.max(0, math.min(1, n)) end

function M.hex_to_rgb(hex)
  hex = tostring(hex or ""):gsub("^#", "")
  if #hex == 3 then hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2) end
  if #hex ~= 6 or not hex:match("^%x+$") then return nil end
  return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

function M.rgb_to_hex(r, g, b)
  return string.format("#%02x%02x%02x", math.floor(clamp01(r / 255) * 255 + 0.5), math.floor(clamp01(g / 255) * 255 + 0.5), math.floor(clamp01(b / 255) * 255 + 0.5))
end

-- WCAG relative luminance -> pick black or white text, whichever gives the
-- higher actual contrast ratio against this accent (not just "is the
-- luminance above some fixed cutoff" -- a flat 0.5 threshold picks white
-- text for plenty of medium-bright colors, e.g. #89b4fa (luminance ~0.45),
-- even though black text reads far better there: ~10:1 contrast vs ~2:1).
function M.contrast_text(hex)
  local r, g, b = M.hex_to_rgb(hex)
  if not r then return "#ffffff" end
  local function lin(c)
    c = c / 255
    if c <= 0.03928 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
  end
  local luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
  local contrast_with_white = 1.05 / (luminance + 0.05)
  local contrast_with_black = (luminance + 0.05) / 0.05
  return (contrast_with_black > contrast_with_white) and "#0b0e18" or "#ffffff"
end

local function rgb_to_hsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local h, s, l = 0, 0, (max + min) / 2
  local d = max - min
  if d ~= 0 then
    s = (l > 0.5) and (d / (2 - max - min)) or (d / (max + min))
    if max == r then h = (g - b) / d + (g < b and 6 or 0)
    elseif max == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, s, l
end

local function hue_to_rgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

local function hsl_to_rgb(h, s, l)
  if s == 0 then return l * 255, l * 255, l * 255 end
  local q = (l < 0.5) and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  return hue_to_rgb(p, q, h + 1 / 3) * 255, hue_to_rgb(p, q, h) * 255, hue_to_rgb(p, q, h - 1 / 3) * 255
end

-- Auto-derives a secondary accent by rotating hue +150deg (roughly
-- complementary but avoiding a jarring exact-opposite hue) and nudging
-- lightness toward mid-range, so gradient/dual-tone UI has something
-- sensible to render even when the user hasn't picked a second color.
function M.auto_secondary(hex)
  local r, g, b = M.hex_to_rgb(hex)
  if not r then return "#7c3aed" end
  local h, s, l = rgb_to_hsl(r, g, b)
  h = (h + 150 / 360) % 1
  l = clamp01(l * 0.7 + 0.5 * 0.3)
  return M.rgb_to_hex(hsl_to_rgb(h, math.max(s, 0.45), l))
end

-- CSS linear-gradient string between two hex colors, for --accent-gradient.
function M.gradient(hex_a, hex_b, angle_deg)
  return string.format("linear-gradient(%ddeg, %s, %s)", angle_deg or 135, hex_a, hex_b)
end

return M
