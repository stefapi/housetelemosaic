-- settings.lua : lecture unique des réglages (voir settingtypes.txt),
-- clampés à leurs bornes documentées, exportés dans ht.settings.

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

-- Nombre (int ou float) avec défaut et bornes ; une valeur saisie
-- invalide retombe sur le défaut (pattern setting_int de basements.lua)
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

-- Mode de choix : tout ce qui n'est pas "random" vaut "ordered"
local mode = minetest.settings:get("housetelemosaic_dest_mode") or "ordered"
S.dest_mode = (mode == "random") and "random" or "ordered"

-- Liste des destinations : split sur les virgules, trim de chaque
-- token, filtrage des valeurs valides, dédoublonnage ; si la liste
-- finale est vide on garde au moins "maze" (destination toujours
-- constructible, sans dépendance optionnelle)
local valid = { cave = true, dungeon = true, maze = true, sky = true }
local seen = {}
local list = {}
local raw = minetest.settings:get("housetelemosaic_destinations")
    or "cave,maze,sky"
for token in string.gmatch(raw .. ",", "([^,]*),") do
    -- trim manuel (pas de string.trim en Lua 5.1)
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

ht.settings = S
