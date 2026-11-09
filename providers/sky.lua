-- providers/sky.lua : destination "île cloudlands" (mod optionnel).
-- API cloudlands utilisée (vérifiée dans cloudlands.lua:1574-1611) :
--   cloudlands.find_nearest_island(x, z, search_radius) -> table
--     {x, z, radius, ...} ou nil
--   cloudlands.get_height_at(x, z, [coreList]) -> y, isWater ou nil
--     (y = altitude du SOL de l'île ; calcul noise déterministe)
-- setting cloudlands_altitude : défaut RÉEL 180 (settingtypes.txt du
-- mod cloudlands, PAS 200 comme l'annonçait l'ébauche de spec).
--
-- RAISONNEMENT EMERGE/GÉNÉRATION (SPEC §9, documenté) :
-- cloudlands écrit ses îles dans SON register_on_generated. Un
-- chunk d'île pas encore généré au moment de la liaison maison
-- pourrait sembler devoir écraser une plateforme posée trop tôt.
-- MAIS emerge_area GÉNÈRE les mapblocks non générés (et déclenche
-- donc les on_generated, celui de cloudlands compris) avant de
-- rendre la main : après ht.emerge_and_run, le terrain de l'île est
-- TOUJOURS présent si le calcul noise la place là. La seule vraie
-- incertitude est "l'île passe-t-elle exactement par ce (x,z) et à
-- quel y" -> on ne décide RIEN à l'avance : après emerge, on relit
-- le node à island_ground_y :
--   walkable      -> l'île est bien là : plateforme stabilisante
--                    3x3 + beacon + 4 torches ;
--   air/non-walk. -> pas d'île à cet endroit (cas réel : île
--                    retirée par removeUnwantedIslands, ou arrondi
--                    de calcul au bord) -> plateforme ARTIFICIELLE
--                    7x7 posée MAINTENANT : le chunk est généré,
--                    aucune écriture future du mapgen ne l'écrasera
--                    (le mapgen n'écrit que les chunks non générés,
--                    et la seule fenêtre "entre emerge et set_node"
--                    ne peut pas voir passer un mapgen : emerge ne
--                    rend la main qu'une fois tous les blocs générés).
-- Aucune fenêtre de risque : documenté et tranché.
--
-- is_available : cloudlands présent, maison sans "_cloudlands",
-- rayon de recherche > 0, maison en dessous de l'altitude des îles
-- moins une tolérance de 80 (les maisons îles sont déjà exclues par
-- le préfixe dans hook.lua, la garde reste une sécurité).

local ht = housetelemosaic

--
-- Nodes résolus une fois au chargement (pattern basement.lua)
--
local function pick(names, what)
    for _, n in ipairs(names) do
        if minetest.registered_nodes[n] then
            return n
        end
    end
    minetest.log("warning", "[housetelemosaic] node indisponible pour "
        .. what .. " (essayés : " .. table.concat(names, ", ") .. ")")
    return nil
end

local N_BEACON = pick({"telemosaic:beacon_off"}, "beacon cloudlands")
local N_PLAT = pick({"default:stone_block", "default:stone"},
    "plateforme cloudlands")
local N_SNOW = pick({"default:snowblock", "default:snow"},
    "garde-corps plateforme")
local N_TORCH_WALL = pick({"default:torch_wall"}, "torche murale sky")
local N_TORCH = pick({"default:torch"}, "torche de sol sky")

-- Altitude moyenne des îles : setting réel du mod, défaut 180
local function island_altitude()
    return tonumber(minetest.settings:get("cloudlands_altitude"))
        or 180
end

--
-- Recherche d'un point d'arrivée SEC sur l'île : centre puis
-- décalages ±radius/3 dans les 4 directions (get_height_at signale
-- l'eau par isWater ; l'échantillonnage évite les étangs ; un seul
-- appel par offset, noise déterministe peu coûteux).
-- Retourne {x, y, z} (y = SOL de l'île) ou nil.
--
local function find_land(island)
    local offsets = {
        {0, 0},
        {island.radius / 3, 0},
        {0, island.radius / 3},
        {-island.radius / 3, 0},
        {0, -(island.radius / 3)},
    }
    for _, off in ipairs(offsets) do
        local x = math.floor(island.x + off[1] + 0.5)
        local z = math.floor(island.z + off[2] + 0.5)
        local y, isWater = cloudlands.get_height_at(x, z)
        if y and not isWater then
            return {x = x, y = y, z = z}
        end
    end
    return nil
end

--
-- Torche posée à p si p est air et son dessous marchable : muret
-- torch_wall sur le bord cherché sinon simple torche de sol.
-- Retourne true si posée.
--
local function torch_here(p)
    local n = minetest.get_node_or_nil(p)
    local below = minetest.get_node_or_nil(
        {x = p.x, y = p.y - 1, z = p.z})
    if n and below and n.name == "air"
        and ht.is_walkable_name(below.name) then
        if N_TORCH then
            minetest.set_node(p, {name = N_TORCH, param2 = 1})
            return true
        end
    end
    return false
end

--
-- Équipement commun (zone émergée) : beacon + 2 airs garantis +
-- 4 torches aux coins (plateforme artificielle : coins à +/-3 de la
-- dalle 7x7 ; sol naturel : torches autour du beacon à +/-2, posées
-- seulement si le dessous est solide -- au bord d'une île en pente
-- une torche peut être sautée, sans gravité).
--
local function equip_platform(platform)
    if not N_BEACON then
        return nil
    end
    minetest.set_node(platform, {name = N_BEACON})
    for dy = 1, 2 do
        local p = {x = platform.x, y = platform.y + dy, z = platform.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name ~= "air" then
            local def = minetest.registered_nodes[n.name]
            if def == nil or def.walkable then
                minetest.set_node(p, {name = "air"})
            end
        end
    end
    local corners = {{2, 2}, {-2, 2}, {2, -2}, {-2, -2}}
    for _, c in ipairs(corners) do
        torch_here({x = platform.x + c[1], y = platform.y,
            z = platform.z + c[2]})
    end
    return platform
end

--
-- Plateforme artificielle 7x7 : UNE passe VoxelManip -- dalle
-- stone_block à ground_y, 2 niveaux d'air au-dessus (le beacon et
-- les torches suivent en set_node) -- puis garde-corps neigeux aux
-- 4 coins. Le joueur arrive au-dessus du vide éventuel mais sur du
-- solide, au niveau calculé de l'île manquante.
--
local function build_artificial_platform(platform, ground_y)
    if not (N_BEACON and N_PLAT) then
        return nil
    end
    local minp = {x = platform.x - 3, y = ground_y, z = platform.z - 3}
    local maxp = {x = platform.x + 3, y = ground_y + 2,
        z = platform.z + 3}
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local c_plat = minetest.get_content_id(N_PLAT)
    local c_air = minetest.get_content_id("air")

    for x = minp.x, maxp.x do
        for z = minp.z, maxp.z do
            data[area:index(x, ground_y, z)] = c_plat
            data[area:index(x, ground_y + 1, z)] = c_air
            data[area:index(x, ground_y + 2, z)] = c_air
        end
    end
    vm:set_data(data)
    vm:write_to_map(true)

    -- garde-corps neigeux aux 4 coins (à +/-3 : sur la dalle)
    if N_SNOW then
        local corners = {{3, 3}, {-3, 3}, {3, -3}, {-3, -3}}
        for _, c in ipairs(corners) do
            minetest.set_node({x = platform.x + c[1], y = platform.y,
                z = platform.z + c[2]}, {name = N_SNOW})
        end
    end
    return equip_platform(platform)
end

--
-- Travail une fois émergé : relire le sol (raisonnement §9 ci-dessus).
-- platform.y = island_ground_y + 1 -> le sol attendu est à
-- platform.y - 1.
--
local function work_emerged(plan)
    local platform = plan.platform
    local ground_y = platform.y - 1
    local n = minetest.get_node_or_nil(
        {x = platform.x, y = ground_y, z = platform.z})
    if n and ht.is_walkable_name(n.name) then
        -- île présente : plateforme stabilisante 3x3 stone_block
        -- posée par set_node à ground_y (sol local remplacé pour
        -- une arrivée propre, l'île reste intacte ailleurs)
        if N_PLAT then
            for lx = platform.x - 1, platform.x + 1 do
                for lz = platform.z - 1, platform.z + 1 do
                    minetest.set_node({x = lx, y = ground_y, z = lz},
                        {name = N_PLAT})
                end
            end
        end
        ht.dlog("sky : arrivée stabilisée sur l'île à "
            .. minetest.pos_to_string(platform))
        return equip_platform(platform)
    end
    ht.dlog("sky : sol absent après emerge, plateforme artificielle "
        .. "à " .. minetest.pos_to_string(platform))
    return build_artificial_platform(platform, ground_y)
end

ht.providers.sky = {
    is_available = function(job)
        if not minetest.global_exists("cloudlands") then
            return false
        end
        if ht.settings.sky_search_radius <= 0 then
            return false
        end
        if job and job.name and job.name:find("_cloudlands", 1, true) then
            return false
        end
        -- la maison doit être nettement SOUS l'altitude des îles
        if job and job.box and job.box.y1 > island_altitude() - 80 then
            return false
        end
        return true
    end,

    -- Plan sérialisable : position calculée UNE fois (noise
    -- déterministe : un recalcul redonnerait le même y). link_direct
    -- = île déjà CHARGÉE au moment du plan ; get_node_or_nil ne
    -- distingue pas "généré-déchargé" de "jamais généré" -> drapeau
    -- purement informatif, la vérité est lue après emerge dans
    -- materialize (voir §9 en tête de fichier).
    get_destination = function(job, rng)
        if not N_BEACON then
            return nil
        end
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local island = cloudlands.find_nearest_island(cx, cz,
            math.floor(ht.settings.sky_search_radius))
        if not island then
            ht.dlog("sky : aucune île dans un rayon de "
                .. ht.settings.sky_search_radius)
            return nil
        end
        local land = find_land(island)
        if not land then
            ht.dlog("sky : île la plus proche sans point sec "
                .. "(rayon " .. ht.settings.sky_search_radius .. ")")
            return nil
        end
        local n = minetest.get_node_or_nil(land)
        local link_direct = (n ~= nil and n.name ~= "air"
            and n.name ~= "ignore")
        return {
            kind = "sky",
            platform = {x = land.x, y = land.y + 1, z = land.z},
            island = {x = island.x, z = island.z,
                radius = island.radius},
            link_direct = link_direct,
        }
    end,

    materialize = function(job, plan, callback)
        local p = plan.platform
        -- ±6 en xz / ±3 en y autour de la plateforme : couvre la
        -- dalle 7x7, les garde-corps et les lectures de sol
        local minp = {x = p.x - 6, y = p.y - 3, z = p.z - 6}
        local maxp = {x = p.x + 6, y = p.y + 3, z = p.z + 6}
        ht.emerge_and_run(minp, maxp, function()
            local ok, dest = pcall(work_emerged, plan)
            if ok and dest then
                callback(true, dest)
            else
                if not ok then
                    minetest.log("warning", "[housetelemosaic] sky : "
                        .. "échec de matérialisation : " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
