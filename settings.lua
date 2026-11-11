-- settings.lua: one-time read of the settings (see settingtypes.txt),
-- clamped to their documented bounds, exported in ht.settings.

local ht = housetelemosaic

local function clamp(n, lo, hi)
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

-- Number (int or float) with default and bounds; an invalid
-- entered value falls back to the default (setting_int pattern of
-- basements.lua)
local function num(name, default, lo, hi)
    return clamp(tonumber(minetest.settings:get(name) or "") or default,
        lo, hi)
end

local S = {}

S.chance = num("housetelemosaic_chance", 1.0, 0.0, 1.0)
S.return_enabled = minetest.settings:get_bool(
    "housetelemosaic_return_enabled", true)
S.cave_artificial_fallback = minetest.settings:get_bool(
    "housetelemosaic_cave_artificial_fallback", true)
S.cave_depth = num("housetelemosaic_cave_depth", 30, 10, 200)
S.cave_radius = num("housetelemosaic_cave_radius", 48, 16, 256)
S.maze_depth = num("housetelemosaic_maze_depth", 25, 5, 100)
S.maze_width = num("housetelemosaic_maze_width", 21, 9, 51)
S.maze_height = num("housetelemosaic_maze_height", 5, 3, 10)
S.basement_depth = num("housetelemosaic_basement_depth", 5, 3, 15)
S.sky_search_radius = num("housetelemosaic_sky_search_radius", 512, 0, 2048)
S.max_extenders = num("housetelemosaic_max_extenders", 12, 0, 64)
S.debug = minetest.settings:get_bool("housetelemosaic_debug", false)

-- Interlink feature: with a probability, a dungeon that just
-- received a house link also gets a second beacon pointing to
-- another structure (see interlink.lua)
S.interlink_enabled = minetest.settings:get_bool(
    "housetelemosaic_interlink_enabled", true)
S.interlink_min_dist = num("housetelemosaic_interlink_min_dist",
    32, 16, 256)
S.interlink_min_chain = num("housetelemosaic_interlink_min_chain",
    2, 1, 8)
S.interlink_max_chain = num("housetelemosaic_interlink_max_chain",
    4, 1, 16)
S.interlink_branches = num("housetelemosaic_interlink_branches",
    1, 1, 4)
if S.interlink_max_chain < S.interlink_min_chain then
    S.interlink_max_chain = S.interlink_min_chain
end

-- Choice mode: anything other than "random" means "ordered"
local mode = minetest.settings:get("housetelemosaic_dest_mode") or "ordered"
S.dest_mode = (mode == "random") and "random" or "ordered"

-- Destination list: split on commas, trim each token, filter
-- valid values, deduplicate; if the final list is empty we keep at
-- least "maze" (an always buildable destination, with no optional
-- dependency)
local valid = { cave = true, dungeon = true, maze = true, sky = true }
local seen = {}
local list = {}
local raw = minetest.settings:get("housetelemosaic_destinations")
    or "cave,maze,sky"
for token in string.gmatch(raw .. ",", "([^,]*),") do
    -- manual trim (no string.trim in Lua 5.1)
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if valid[token] and not seen[token] then
        seen[token] = true
        list[#list + 1] = token
    end
end
if #list == 0 then
    list[1] = "maze"
end
S.destinations = list

-- Interlink target list: same parsing, but restricted to
-- dungeon/cave/sky (an interlink always starts FROM a dungeon;
-- cave<->sky links are out of scope). An empty list simply
-- disables the feature (no forced default)
local valid_ilink = { dungeon = true, cave = true, sky = true }
local seen_ilink = {}
local ilist = {}
local raw_ilink = minetest.settings:get(
    "housetelemosaic_interlink_targets") or "dungeon,cave,sky"
for token in string.gmatch(raw_ilink .. ",", "([^,]*),") do
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if valid_ilink[token] and not seen_ilink[token] then
        seen_ilink[token] = true
        ilist[#ilist + 1] = token
    end
end
S.interlink_targets = ilist

ht.settings = S
