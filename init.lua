-- housetelemosaic : un sous-sol avec pad telemosaic pour chaque maison
-- nativevillages éligible, vers grotte, donjon, labyrinthe ou île
-- cloudlands.
--
-- Modules (ordre de chargement) :
--   settings.lua   réglages clampés (ht.settings)
--   api.lua        utilitaires : PRNG déterministes, scan de plancher,
--                  emerge gardé, extendeurs, liaison des pads
--   providers/*    destinations cave, dungeon, maze, sky
--   hook.lua       interception du placement nativevillages, choix de
--                  destination, mise en file
--   basement.lua   construction des sous-sols (patch cellier natif,
--                  connexion par le dessous, chambre classique)
--   link_queue.lua file de liaison persistante (materialize + liaison)
--   debug.lua      commandes chat de supervision

housetelemosaic = {}
local ht = housetelemosaic

-- Registre des providers de destination (cave/dungeon/maze/sky),
-- rempli par providers/*.lua juste après
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

minetest.log("action", "[housetelemosaic] chargé ; installation du hook "
    .. "nativevillages à on_mods_loaded")
