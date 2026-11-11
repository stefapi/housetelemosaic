-- housetelemosaic: a basement with a telemosaic pad for every
-- eligible biomevillages house, leading to a cave, dungeon, maze
-- or cloudlands island.
--
-- Modules (load order):
--   settings.lua   clamped settings (ht.settings)
--   api.lua        utilities: deterministic PRNGs, floor scan,
--                  guarded emerge, extenders, pad linking
--   providers/*    destinations cave, dungeon, maze, sky
--   hook.lua       interception of biomevillages placement,
--                  destination choice, enqueueing
--   basement.lua   basement construction (native cellar patch,
--                  connect-from-below, classic room)
--   link_queue.lua persistent link queue (materialize + linking)
--   debug.lua      supervision chat commands

housetelemosaic = {}
local ht = housetelemosaic

-- Registry of destination providers (cave/dungeon/maze/sky),
-- filled by providers/*.lua right after
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

minetest.log("action", "[housetelemosaic] loaded; biomevillages hook "
    .. "installation at on_mods_loaded")
