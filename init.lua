-- housetelemosaic : sous-sol avec pad telemosaic pour chaque maison
-- nativevillages éligible, vers grotte, labyrinthe ou île cloudlands.
-- VAGUE 1 : socle (settings, api, hook, basement, file simple).
-- VAGUE 2 : providers cave/maze/sky complets, chaîne de fallback
-- entre providers, LBM + on_generated de reprise, /htmaze.

housetelemosaic = {}
local ht = housetelemosaic

-- Registre des providers de destination (cave/maze/sky), rempli par
-- providers/*.lua juste après
ht.providers = {}

local path = minetest.get_modpath("housetelemosaic") .. "/"

dofile(path .. "settings.lua")
dofile(path .. "api.lua")
dofile(path .. "providers/cave.lua")
dofile(path .. "providers/dungeon.lua")
dofile(path .. "providers/maze.lua")
dofile(path .. "providers/sky.lua")
dofile(path .. "hook.lua")
dofile(path .. "basement.lua")
dofile(path .. "link_queue.lua")
dofile(path .. "debug.lua")

minetest.log("action", "[housetelemosaic] chargé (vague 2 : providers "
    .. "cave/maze/sky, fallbacks, reprise LBM/on_generated). "
    .. "Installation du hook nativevillages à on_mods_loaded.")
