-- Filename/title keyword-based category+subcategory inference, ported
-- faithfully from app/classification.py (pure string/set logic, no network
-- calls, no image decoding -- the one piece of the AI pipeline that's fully
-- self-contained and cheap to port in full). Used standalone as the
-- heuristic fallback whenever the real AI vision pipeline
-- (app/ai_metadata.py, NOT yet ported -- see the Lua rewrite's final report)
-- is disabled, unavailable, or low-confidence.
local M = {}

local function lower_words(...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    if v ~= nil and v ~= "" then parts[#parts + 1] = tostring(v):lower() end
  end
  return table.concat(parts, " ")
end

-- Mirrors clean_tokens(): lowercase, non-alnum runs -> single space, then
-- extract tokens of 2+ [a-z0-9] chars.
function M.clean_tokens(...)
  local raw = lower_words(...)
  local normalized = raw:gsub("[^%a%d]+", " ")
  local tokens = {}
  for tok in normalized:gmatch("%a%a+") do tokens[#tokens + 1] = tok end
  for tok in normalized:gmatch("%d%d+") do tokens[#tokens + 1] = tok end
  -- Python's regex `[a-z0-9]{2,}` allows mixed alnum runs (e.g. "ff7"); the
  -- two gmatch passes above miss those, so also scan generically.
  tokens = {}
  for tok in normalized:gmatch("[%a%d][%a%d]+") do tokens[#tokens + 1] = tok end
  return tokens
end

local function token_set(...)
  local set = {}
  for _, tok in ipairs(M.clean_tokens(...)) do set[tok] = true end
  return set
end

local function has_any(tokens, values)
  for v, _ in pairs(values) do
    if tokens[v] then return true end
  end
  return false
end

local function to_set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

local function single_match(tokens, mapping)
  for _, entry in ipairs(mapping) do
    if has_any(tokens, entry[2]) then return entry[1] end
  end
  return nil
end

local function matches_all(tokens, ...)
  for _, v in ipairs({ ... }) do
    if not tokens[v] then return false end
  end
  return true
end

local DIRECT_MAP = {
  ["Aria Blaze (Solo)"] = { "My Little Pony", "Aria Blaze" },
  ["Sonata Dusk"] = { "My Little Pony", "Sonata Dusk" },
  ["Dazzlings"] = { "My Little Pony", "Dazzlings" },
  ["My Little Pony (Fluttershy)"] = { "My Little Pony", "Fluttershy" },
  ["My Little Pony (Mane 6)"] = { "My Little Pony", "Mane 6" },
  ["My Little Pony (Equestria Girls)"] = { "My Little Pony", "Equestria Girls" },
  ["KPOP Demon Hunters (Huntrix)"] = { "KPOP Demon Hunters", "Huntrix" },
  ["KPOP Demon Hunters (Mira)"] = { "KPOP Demon Hunters", "Mira" },
  ["Resident Evil (Leon)"] = { "Resident Evil", "Leon" },
  ["Final Fantasy (Cloud)"] = { "Final Fantasy", "Cloud Strife" },
}

local function trim_collapse(s)
  s = tostring(s or "")
  s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  return s
end

-- Mirrors canonical_category_pair().
function M.canonical_category_pair(category, subcategory)
  local main = trim_collapse(category):sub(1, 80)
  local sub = trim_collapse(subcategory):sub(1, 80)
  if main == "" then main = nil end
  if sub == "" then sub = nil end
  if not main then return nil, sub end
  local mapped = DIRECT_MAP[main]
  if mapped then return mapped[1], mapped[2] end
  return main, sub
end

local function stem_of(filename)
  filename = tostring(filename or "")
  local base = filename:match("([^/\\]+)$") or filename
  local stem = base:match("^(.*)%.[^.]+$") or base
  return stem:lower()
end

local function ext_of(filename)
  filename = tostring(filename or "")
  local base = filename:match("([^/\\]+)$") or filename
  return (base:match("(%.[^.]+)$") or ""):lower()
end

-- Mirrors infer_category_pair(). Returns (category_name, subcategory_name|nil).
function M.infer_category_pair(opts)
  local filename = opts.filename or ""
  local media_kind = opts.media_kind or ""
  local title = opts.title
  local current_category = opts.current_category
  local size = opts.size -- {width, height} or nil

  local current_main, current_sub = M.canonical_category_pair(current_category)
  local tokens = token_set(stem_of(filename), title, current_main, current_sub)

  local mlp_tokens = to_set({
    "mlp", "pony", "ponies", "equestria", "rainbooms", "mane", "cutie", "cmc",
    "twilight", "pinkie", "fluttershy", "rarity", "applejack", "scootaloo",
    "rainbow", "dash", "derpy", "sunset", "starlight", "trixie", "celestia",
    "luna", "discord", "spike",
  })
  local dazzlings_tokens = to_set({ "dazzlings", "adagio", "aria", "sonata" })
  local fnaf_tokens = to_set({
    "fnaf", "freddy", "bonnie", "chica", "foxy", "roxanne", "roxy", "fazbear",
    "animatronic", "frenni", "bonfie",
  })
  local neptunia_tokens = to_set({ "neptunia", "neptune", "nepgear", "noire", "blanc", "vert", "uzume", "plutia" })
  local xenoblade_tokens = to_set({ "xenoblade", "pyra", "mythra", "nia", "mio", "eunie", "taion", "lanz", "noah" })
  local sonic_tokens = to_set({ "sonic", "tails", "amy", "shadow", "knuckles", "rouge" })
  local resident_evil_tokens = to_set({ "resident", "evil", "leon", "ada", "jill", "claire", "wesker", "ashley" })
  local final_fantasy_tokens = to_set({ "final", "fantasy", "cloud", "strife", "tifa", "aerith", "sephiroth", "ff7", "ffvii" })
  local kpop_demon_hunters_tokens = to_set({ "kpop", "demon", "hunters", "huntrix", "mira", "zoey", "rumi" })
  local cartoon_tokens = to_set({ "boondocks", "cartoon", "anime" })
  local meme_tokens = to_set({ "meme", "memes", "funny", "reaction" })

  local mlp_subcategories = {
    { "Aria Blaze", to_set({ "aria" }) },
    { "Sonata Dusk", to_set({ "sonata" }) },
    { "Adagio Dazzle", to_set({ "adagio" }) },
    { "Fluttershy", to_set({ "fluttershy", "flutter", "fluttertone", "flutterwitch", "flutterfrolic", "appleshy" }) },
    { "Twilight Sparkle", to_set({ "twilight", "twilights" }) },
    { "Rainbow Dash", to_set({ "dashie", "rainbowdash" }) },
    { "Pinkie Pie", to_set({ "pinkie" }) },
    { "Rarity", to_set({ "rarity" }) },
    { "Applejack", to_set({ "applejack" }) },
    { "Sunset Shimmer", to_set({ "sunset" }) },
    { "Starlight Glimmer", to_set({ "starlight" }) },
    { "Scootaloo", to_set({ "scootaloo" }) },
    { "Derpy", to_set({ "derpy" }) },
    { "Trixie", to_set({ "trixie" }) },
    { "Princess Celestia", to_set({ "celestia" }) },
    { "Princess Luna", to_set({ "luna" }) },
    { "Discord", to_set({ "discord" }) },
    { "Spike", to_set({ "spike" }) },
  }
  local neptunia_subcategories = {
    { "Neptune", to_set({ "neptune" }) }, { "Nepgear", to_set({ "nepgear" }) },
    { "Noire", to_set({ "noire" }) }, { "Blanc", to_set({ "blanc" }) },
    { "Vert", to_set({ "vert" }) }, { "Uzume", to_set({ "uzume" }) }, { "Plutia", to_set({ "plutia" }) },
  }
  local xenoblade_subcategories = {
    { "Pyra", to_set({ "pyra" }) }, { "Mythra", to_set({ "mythra" }) }, { "Nia", to_set({ "nia" }) },
    { "Mio", to_set({ "mio" }) }, { "Eunie", to_set({ "eunie" }) }, { "Taion", to_set({ "taion" }) },
    { "Lanz", to_set({ "lanz" }) }, { "Noah", to_set({ "noah" }) },
  }
  local sonic_subcategories = {
    { "Sonic", to_set({ "sonic" }) }, { "Shadow", to_set({ "shadow" }) }, { "Amy", to_set({ "amy" }) },
    { "Tails", to_set({ "tails" }) }, { "Knuckles", to_set({ "knuckles" }) }, { "Rouge", to_set({ "rouge" }) },
  }
  local resident_evil_subcategories = {
    { "Leon", to_set({ "leon" }) }, { "Ada Wong", to_set({ "ada" }) }, { "Jill Valentine", to_set({ "jill" }) },
    { "Claire Redfield", to_set({ "claire" }) }, { "Albert Wesker", to_set({ "wesker" }) }, { "Ashley Graham", to_set({ "ashley" }) },
  }
  local final_fantasy_subcategories = {
    { "Cloud Strife", to_set({ "cloud", "strife" }) }, { "Tifa Lockhart", to_set({ "tifa" }) },
    { "Aerith Gainsborough", to_set({ "aerith" }) }, { "Sephiroth", to_set({ "sephiroth" }) },
  }
  local kpop_subcategories = {
    { "Huntrix", to_set({ "huntrix" }) }, { "Mira", to_set({ "mira" }) },
    { "Zoey", to_set({ "zoey" }) }, { "Rumi", to_set({ "rumi" }) },
  }

  if ext_of(filename) == ".gif" then return "GIFs", nil end

  if has_any(tokens, kpop_demon_hunters_tokens) or current_main == "KPOP Demon Hunters" then
    return "KPOP Demon Hunters", single_match(tokens, kpop_subcategories)
  end
  if has_any(tokens, resident_evil_tokens) or current_main == "Resident Evil" then
    return "Resident Evil", single_match(tokens, resident_evil_subcategories)
  end
  if has_any(tokens, final_fantasy_tokens) or current_main == "Final Fantasy" then
    return "Final Fantasy", single_match(tokens, final_fantasy_subcategories)
  end
  if has_any(tokens, neptunia_tokens) or current_main == "Hyperdimension Neptunia" then
    local hits = {}
    for _, e in ipairs(neptunia_subcategories) do if has_any(tokens, e[2]) then hits[#hits + 1] = e[1] end end
    if #hits > 1 then return "Hyperdimension Neptunia", nil end
    return "Hyperdimension Neptunia", hits[1]
  end
  if has_any(tokens, xenoblade_tokens) or current_main == "Xenoblade" then
    local hits = {}
    for _, e in ipairs(xenoblade_subcategories) do if has_any(tokens, e[2]) then hits[#hits + 1] = e[1] end end
    if #hits > 1 then return "Xenoblade", nil end
    return "Xenoblade", hits[1]
  end
  if has_any(tokens, fnaf_tokens) or current_main == "FNAF" then
    local hits = {}
    for _, e in ipairs({
      { "Freddy", to_set({ "freddy" }) }, { "Bonnie", to_set({ "bonnie", "bonfie" }) },
      { "Chica", to_set({ "chica" }) }, { "Foxy", to_set({ "foxy" }) },
      { "Frenni", to_set({ "frenni" }) }, { "Roxanne Wolf", to_set({ "roxanne", "roxy" }) },
    }) do if has_any(tokens, e[2]) then hits[#hits + 1] = e[1] end end
    if #hits > 1 then return "FNAF", nil end
    return "FNAF", hits[1]
  end
  if (has_any(tokens, sonic_tokens) and has_any(tokens, mlp_tokens)) or current_main == "Crossovers" then
    return "Crossovers", single_match(tokens, sonic_subcategories) or single_match(tokens, mlp_subcategories)
  end

  if has_any(tokens, mlp_tokens) or has_any(tokens, dazzlings_tokens) or current_main == "My Little Pony" then
    local dazzling_hits = {}
    if tokens["aria"] then dazzling_hits[#dazzling_hits + 1] = "Aria Blaze" end
    if tokens["sonata"] then dazzling_hits[#dazzling_hits + 1] = "Sonata Dusk" end
    if tokens["adagio"] then dazzling_hits[#dazzling_hits + 1] = "Adagio Dazzle" end
    if has_any(tokens, dazzlings_tokens) then
      if #dazzling_hits > 1 or tokens["dazzlings"] then return "My Little Pony", "Dazzlings" end
      if #dazzling_hits > 0 then return "My Little Pony", dazzling_hits[1] end
    end

    if matches_all(tokens, "equestria", "girls") or matches_all(tokens, "equestrian", "girls")
      or tokens["eqg"] or matches_all(tokens, "rainbow", "rocks") or matches_all(tokens, "crystal", "prep") then
      if #dazzling_hits > 0 then return "My Little Pony", "Dazzlings" end
      return "My Little Pony", "Equestria Girls"
    end

    local mlp_character_hits = {}
    if (matches_all(tokens, "rainbow", "dash") or tokens["dashie"] or tokens["rainbowdash"] or tokens["dash"])
      and not matches_all(tokens, "rainbow", "rocks") then
      mlp_character_hits[#mlp_character_hits + 1] = "Rainbow Dash"
    end
    for _, e in ipairs(mlp_subcategories) do
      if e[1] ~= "Rainbow Dash" and has_any(tokens, e[2]) then mlp_character_hits[#mlp_character_hits + 1] = e[1] end
    end
    if matches_all(tokens, "cutie", "mark", "crusaders") or tokens["crusaders"] or tokens["cmc"] then
      return "My Little Pony", "Cutie Mark Crusaders"
    end
    if matches_all(tokens, "mane", "6") or matches_all(tokens, "mane", "six") then
      return "My Little Pony", "Mane 6"
    end
    local core_hits = {}
    local core_set = to_set({ "Fluttershy", "Twilight Sparkle", "Rainbow Dash", "Pinkie Pie", "Rarity", "Applejack" })
    local seen_core = {}
    for _, h in ipairs(mlp_character_hits) do
      if core_set[h] and not seen_core[h] then seen_core[h] = true; core_hits[#core_hits + 1] = h end
    end
    if #core_hits >= 2 then return "My Little Pony", "Mane 6" end
    if #mlp_character_hits > 0 then
      local unique_hits, seen = {}, {}
      for _, h in ipairs(mlp_character_hits) do
        if not seen[h] then seen[h] = true; unique_hits[#unique_hits + 1] = h end
      end
      if #unique_hits == 1 then return "My Little Pony", unique_hits[1] end
      if #unique_hits > 1 then return "My Little Pony", nil end
    end
    return "My Little Pony", nil
  end

  if has_any(tokens, sonic_tokens) or current_main == "Sonic" then
    return "Sonic", single_match(tokens, sonic_subcategories)
  end
  if has_any(tokens, cartoon_tokens) or current_main == "Cartoon" then return "Cartoon", nil end
  if has_any(tokens, meme_tokens) or current_main == "Memes" then return "Memes", nil end

  if size and size[1] and size[2] and size[1] > 0 and size[2] > 0 then
    local ratio = size[1] / math.max(1, size[2])
    if ratio >= 0.9 and ratio <= 1.1 and math.max(size[1], size[2]) <= 2048 then
      return "Profile Pictures", nil
    elseif ratio < 0.85 then
      return "Phone Backgrounds", nil
    elseif ratio >= 1.2 then
      return "Desktop Backgrounds", nil
    end
  end

  if media_kind == "video" then return current_main or "Videos", current_sub end
  if current_main then return current_main, current_sub end
  return "Wallpapers", nil
end

return M
