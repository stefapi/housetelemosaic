-- providers/dungeon.lua : destination "donjon".
-- Cible : un donjon NATIF du mapgen (mg_flags dungeons), celui-là même
-- que dungeonsplus décore de ses features (forge, bibliothèque,
-- prison, alchemy lab...) et dont il remplace le loot quand il est
-- actif -- pointer "vers dungeonsplus", c'est pointer vers une salle
-- de donjon natif. randungeon est un second avis : si aucun donjon
-- natif n'est trouvé au scan, un donjon randungeon complet est
-- généré via randungeon.make_dungeon (API publique, build_dungeon_
-- from_blocks.lua:1000) ; en dernier recours une salle voûtée
-- mossycobble est construite.
-- Signature d'un donjon natif au scan : sol en cobble / mossycobble /
-- stonebrick (les couloirs de grotte naturelle, eux, sont en roche
-- brute) surmonté d'au moins 3 nodes d'air -- exactement la signature
-- utilisée par dungeonsplus pour trouver ses salles (gennotify
-- dungeon + sols, init.lua:151).
-- Pattern général : clone de providers/cave.lua (plan léger
-- sérialisable, emerge_and_run, VoxelManip lecture seule, ancrage
-- beacon, fallbacks en cascade).

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

local N_BEACON = pick({"telemosaic:beacon_off"}, "beacon donjon")
local N_MOSSY = pick({"default:mossycobble", "default:cobble"},
    "sol donjon de secours")
local N_COBBLE = pick({"default:cobble", "default:stone"},
    "sol donjon de secours (bord)")
local N_WALL = pick({"default:stonebrick", "default:stone"},
    "murs donjon de secours")
local N_TORCH_WALL = pick({"default:torch_wall"}, "torche murale donjon")
local N_TORCH = pick({"default:torch"}, "torche de sol donjon")

-- randungeon est-il présent ? (dépendance optionnelle)
local RANDUNGEON = minetest.get_modpath("randungeon") ~= nil
    and type(randungeon) == "table"
    and type(randungeon.make_dungeon) == "function"

-- Donjons natifs activés dans mg_flags ?
local function native_dungeons_on()
    local flags = minetest.get_mapgen_setting("mg_flags") or ""
    return flags:find("dungeons", 1, true) ~= nil
end

-- Sols caractéristiques des donjons natifs : content_ids résolus à la
-- demande (lazy : après on_mods_loaded). Un mod de remplacement de
-- nodes (loottest0 etc.) peut renommer ces nodes : on accepte donc
-- TOUT node enregistré dont le nom contient "mossycobble" ou qui est
-- exactement default:cobble / default:stonebrick, plus les variants
-- "desert_" et "sandstone" des donjons natifs.
local floor_cids = nil

local function ensure_floor_cids()
    if floor_cids then
        return floor_cids
    end
    floor_cids = {}
    local function add(name)
        local id = minetest.get_content_id(name)
        if id then
            floor_cids[id] = true
        end
    end
    add("default:cobble")
    add("default:mossycobble")
    add("default:stonebrick")
    add("default:desert_cobble")
    add("default:sandstonebrick")
    add("default:desert_sandstone_brick")
    add("default:silver_sandstone_brick")
    -- toute variante de remplacement nommée *mossycobble*
    for name in pairs(minetest.registered_nodes) do
        if name:find("mossycobble", 1, true) then
            add(name)
        end
    end
    return floor_cids
end

-- Tables content_id -> {walkable, liquid} (pattern cave.lua)
local cid_info = nil

local function ensure_cid_info()
    if cid_info then
        return cid_info
    end
    cid_info = {}
    for name, def in pairs(minetest.registered_nodes) do
        cid_info[minetest.get_content_id(name)] = {
            walkable = def.walkable == true,
            liquid = def.liquidtype ~= nil and def.liquidtype ~= "none",
        }
    end
    return cid_info
end

-- Directions horizontales {dx, dz, param2} : convention wallmounted,
-- param2 = direction du MUR de support DEPUIS la torche (2 = x+,
-- 3 = x-, 4 = z+, 5 = z-)
local WALL_DIRS = {
    {1, 0, 2},   -- mur à l'est   (+X) -> param2 2
    {-1, 0, 3},  -- mur à l'ouest (-X) -> param2 3
    {0, 1, 4},   -- mur au sud    (+Z) -> param2 4
    {0, -1, 5},  -- mur au nord   (-Z) -> param2 5
}

-- Torche murale sur le premier mur plein trouvé autour de pos, sinon
-- torche de sol si le dessous est marchable (clone cave.lua)
local function place_torch(pos, floor_y, ox, oz)
    for _, d in ipairs(WALL_DIRS) do
        local t = {x = pos.x + d[1], y = pos.y, z = pos.z + d[2]}
        local m = {x = pos.x + 2 * d[1], y = pos.y, z = pos.z + 2 * d[2]}
        local tn = minetest.get_node_or_nil(t)
        local mn = minetest.get_node_or_nil(m)
        if tn and mn and tn.name == "air"
            and ht.is_walkable_name(mn.name) then
            if N_TORCH_WALL then
                minetest.set_node(t, {name = N_TORCH_WALL, param2 = d[3]})
                return true
            elseif N_TORCH then
                minetest.set_node(t, {name = N_TORCH, param2 = 1})
                return true
            end
        end
    end
    if N_TORCH then
        local p = {x = pos.x + ox, y = floor_y + 1, z = pos.z + oz}
        local below = minetest.get_node_or_nil(
            {x = p.x, y = floor_y, z = p.z})
        if below and ht.is_walkable_name(below.name) then
            minetest.set_node(p, {name = N_TORCH, param2 = 1})
            return true
        end
    end
    return false
end

--
-- Scan VoxelManip lecture seule : salles de donjon natif.
-- Même squelette que cave.lua scan_pockets, avec le prédicat de sol
-- spécifique : le node qui termine une série d'au moins 3 airs (en
-- descendant) doit être un SOL DE DONJON (floor_cids) et le node
-- sous le sol non liquide ; le plafond (node au-dessus de la série)
-- marchable et non liquide ; carré 3x3 ouvert aux niveaux sol+1 et
-- sol+2 (pose du beacon + exigence telemosaic).
--
local function scan_dungeon_floors(plan)
    local info = ensure_cid_info()
    local floors = ensure_floor_cids()
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(plan.minp, plan.maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()

    local cx, cz = plan.center.x, plan.center.z
    local y_top = plan.scan_max_y
    local y_bot = plan.scan_min_y

    -- échantillonnage identique à cave.lua : la fenêtre donjon est
    -- bornée à 48 de rayon au plan, le pas reste léger
    local side = plan.maxp.x - plan.minp.x + 1
    local step = 1
    if side > 48 then
        step = 2
    end
    if side > 96 then
        step = 4
    end

    local ystride = area.ystride
    local candidates = {}

    for x = plan.minp.x, plan.maxp.x, step do
        for z = plan.minp.z, plan.maxp.z, step do
            local idx = area:index(x, y_top, z)
            local air_run = 0
            for y = y_top, y_bot, -1 do
                local inf = info[data[idx]]
                if inf and not inf.walkable and not inf.liquid then
                    air_run = air_run + 1
                else
                    if air_run >= 3 and inf and inf.walkable
                        and not inf.liquid
                        and floors[data[idx]] then
                        local ceil = info[
                            data[idx + (air_run + 1) * ystride]]
                        local under = info[data[idx + ystride]]
                        if ceil and under and ceil.walkable
                            and not ceil.liquid
                            and not under.liquid then
                            local ok = true
                            for ly = y + 1, y + 2 do
                                for lx = x - 1, x + 1 do
                                    for lz = z - 1, z + 1 do
                                        local o = info[
                                            data[area:index(lx, ly, lz)]]
                                        if not o or o.walkable
                                            or o.liquid then
                                            ok = false
                                            break
                                        end
                                    end
                                    if not ok then
                                        break
                                    end
                                end
                                if not ok then
                                    break
                                end
                            end
                            if ok then
                                local dx = x - cx
                                local dz = z - cz
                                candidates[#candidates + 1] = {
                                    x = x, y = y + 1, z = z,
                                    d2 = dx * dx + dz * dz,
                                }
                                if #candidates >= 128 then
                                    return candidates
                                end
                            end
                        end
                    end
                    air_run = 0
                end
                idx = idx - ystride
            end
        end
    end
    return candidates
end

-- Ancrage d'un candidat : beacon + 2 airs garantis (le 3x3 a déjà été
-- validé au scan, on force au cas où le terrain aurait bougé entre le
-- scan et la pose -- écart nul en pratique, défense en profondeur)
local function anchor_candidate(c)
    if not N_BEACON then
        return nil
    end
    local dest = {x = c.x, y = c.y, z = c.z}
    minetest.set_node(dest, {name = N_BEACON})
    for ly = c.y + 1, c.y + 2 do
        local p = {x = c.x, y = ly, z = c.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name ~= "air" then
            local def = minetest.registered_nodes[n.name]
            if def == nil or def.walkable then
                minetest.set_node(p, {name = "air"})
            end
        end
    end
    place_torch({x = c.x + 1, y = c.y, z = c.z}, c.y - 1, 1, 0)
    place_torch({x = c.x - 1, y = c.y, z = c.z}, c.y - 1, -1, 0)
    return dest
end

--
-- Donjon randungeon de secours : appel de l'API publique make_dungeon
-- (synchronome si la zone est chargée -- notre emerge_and_run préalable
-- l'a émergie -- sinon elle reprend via son emerge interne et le
-- callback de la file retiendra l'essai). Paramètres modestes pour
-- rester rapide : width 4 (40x40), 3 niveaux, matériaux aléatoires.
-- L'entrée du donjon (pos + quelques niveaux) reçoit le beacon ; la
-- position d'arrivée exacte du joueur est gérée par telemosaic
-- (dest.y+0.5) sur le sol du palier d'entrée.
--
local function build_randungeon(plan)
    if not RANDUNGEON then
        return nil
    end
    -- point d'ancrage du donjon : centre de la fenêtre, sous le
    -- niveau de scan (le donjon creuse vers le bas depuis pos.y)
    local pos = {
        x = plan.center.x,
        y = plan.scan_min_y + 10,
        z = plan.center.z,
    }
    -- zone émergée par le materialize (fenêtre + marge make_dungeon
    -- de 60 : émerge déjà large, on garde la fenêtre du plan)
    local ok, err = pcall(randungeon.make_dungeon, pos,
        4,                    -- width (4 blocs = 40 nodes)
        nil, nil, nil, nil, nil, nil, -- matériaux : aléatoires
        12,                   -- dungeon_deph
        true,                 -- rim_sealed
        3,                    -- dungeon_levels
        40, 60,               -- bottom_deph, top_deph
        true,                 -- random_materials
        30,                   -- cave_percentage
        true,                 -- light_up_corridors
        true,                 -- gold_pools
        "randungeon:dungeon_treasure", -- treasure_block
        nil)                  -- dungeon_id
    if not ok then
        minetest.log("warning", "[housetelemosaic] dungeon : "
            .. "randungeon.make_dungeon a échoué : " .. tostring(err))
        return nil
    end
    -- palier d'arrivée : quelques nodes sous le point d'ancrage, au
    -- centre du donjon ; make_dungeon creuse son entrée à pos.y -
    -- top_deph ; on pose le beacon sur le premier sol plein trouvé en
    -- descendant depuis pos.y - 2 (le toit du donjon est à ~top_deph)
    for dy = 2, 80 do
        local y = pos.y - dy
        local n = minetest.get_node_or_nil(
            {x = pos.x, y = y, z = pos.z})
        if n and ht.is_walkable_name(n.name) then
            -- sol trouvé : beacon posé dessus (le donjon randungeon
            -- est décoré de torches par lui-même, on n'en ajoute pas)
            if N_BEACON then
                local dest = {x = pos.x, y = y + 1, z = pos.z}
                minetest.set_node(dest, {name = N_BEACON})
                return dest
            end
            return nil
        end
    end
    return nil
end

--
-- Salle voûtée de dernier recours : intérieur 7x7 (emprise 9x9), sol
-- mossycobble, murs/plafond stonebrick -- l'esthétique donjon natif.
-- Une seule passe VoxelManip (pattern cave.lua build_artificial).
--
local function build_fallback_room(plan)
    if not (N_BEACON and N_MOSSY and N_WALL) then
        return nil
    end
    local cx, cz = plan.center.x, plan.center.z
    local fy = plan.floor_y_fallback
    local minp = {x = cx - 4, y = fy, z = cz - 4}
    local maxp = {x = cx + 4, y = fy + 4, z = cz + 4}
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local c_wall = minetest.get_content_id(N_WALL)
    local c_floor = minetest.get_content_id(N_MOSSY)
    local c_air = minetest.get_content_id("air")

    for y = fy, fy + 4 do
        for x = cx - 4, cx + 4 do
            for z = cz - 4, cz + 4 do
                local i = area:index(x, y, z)
                local border = x == cx - 4 or x == cx + 4
                    or z == cz - 4 or z == cz + 4
                if y == fy then
                    data[i] = c_floor
                elseif y == fy + 4 then
                    data[i] = c_wall
                elseif border then
                    data[i] = c_wall
                else
                    data[i] = c_air
                end
            end
        end
    end
    vm:set_data(data)
    vm:write_to_map(true)

    local dest = {x = cx, y = fy + 1, z = cz}
    minetest.set_node(dest, {name = N_BEACON})
    if N_TORCH_WALL then
        minetest.set_node({x = cx - 3, y = fy + 2, z = cz},
            {name = N_TORCH_WALL, param2 = 3})
        minetest.set_node({x = cx + 3, y = fy + 2, z = cz},
            {name = N_TORCH_WALL, param2 = 2})
    elseif N_TORCH then
        minetest.set_node({x = cx - 3, y = fy + 1, z = cz},
            {name = N_TORCH, param2 = 1})
        minetest.set_node({x = cx + 3, y = fy + 1, z = cz},
            {name = N_TORCH, param2 = 1})
    end
    return dest
end

--
-- Travail complet une fois émergé : scan donjons natifs, puis
-- randungeon, puis salle voûtée. Sélection déterministe (clone
-- cave.lua : tri par distance, tie-break PcgRandom(plan.rng_seed)).
--
local function work_emerged(plan)
    local candidates = scan_dungeon_floors(plan)
    if #candidates > 0 then
        table.sort(candidates, function(a, b)
            return a.d2 < b.d2
        end)
        local rng = PcgRandom(plan.rng_seed)
        local n = math.min(3, #candidates)
        local chosen = candidates[1]
        if n > 1 then
            chosen = candidates[rng:next(1, n)]
        end
        local dest = anchor_candidate(chosen)
        if dest then
            ht.dlog("dungeon : donjon natif ancré à "
                .. minetest.pos_to_string(dest) .. " (" .. #candidates
                .. " salle(s) trouvée(s))")
            return dest
        end
    end
    local dest = build_randungeon(plan)
    if dest then
        ht.dlog("dungeon : donjon randungeon généré, entrée "
            .. minetest.pos_to_string(dest))
        return dest
    end
    dest = build_fallback_room(plan)
    if dest then
        ht.dlog("dungeon : salle voûtée de secours à "
            .. minetest.pos_to_string(dest))
    end
    return dest
end

ht.providers.dungeon = {
    -- disponible si les donjons natifs existent (mg_flags dungeons,
    -- décorés par dungeonsplus s'il est actif) OU si randungeon peut
    -- en générer un
    is_available = function(job)
        return native_dungeons_on() or RANDUNGEON
    end,

    -- Plan léger sérialisable JSON (clone cave.lua). Fenêtre de scan
    -- bornée à 48 de rayon (les donjons natifs sont courants, inutile
    -- de scanner loin : une salle suffit), profondeur [y1-200 ;
    -- y1-25] clampée >= -280 / <= -10 (les donjons natifs vivent
    -- entre ~-2550 et la surface, la fenêtre reste raisonnable).
    get_destination = function(job, rng)
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local r = math.min(math.floor(ht.settings.cave_radius), 48)

        local y_high = math.min(box.y1 - 25, -10)
        local y_low = math.max(box.y1 - 200, -280)

        -- niveau de la salle/randungeon de secours : sous la fenêtre
        -- de scan, au moins 40 sous la base (anti-collision grotte
        -- artificielle à y1-30 : on descend plus bas)
        local fy = math.max(y_low - 40, -300)
        if fy > box.y1 - 40 then
            fy = box.y1 - 40
        end
        if fy < -300 then
            fy = -300
        end

        return {
            kind = "dungeon",
            minp = {
                x = cx - r,
                y = math.min(y_low, fy - 1),
                z = cz - r,
            },
            maxp = {
                x = cx + r,
                y = math.max(y_high, fy + 5),
                z = cz + r,
            },
            scan_min_y = y_low,
            scan_max_y = y_high,
            center = {x = cx, y = box.y1, z = cz},
            floor_y_fallback = fy,
            rng_seed = rng:next(0, 2147483647),
        }
    end,

    materialize = function(job, plan, callback)
        ht.emerge_and_run(plan.minp, plan.maxp, function()
            local ok, dest = pcall(work_emerged, plan)
            if ok and dest then
                callback(true, dest)
            else
                if not ok then
                    minetest.log("warning", "[housetelemosaic] dungeon : "
                        .. "échec de matérialisation : " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
