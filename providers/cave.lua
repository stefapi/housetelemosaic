-- providers/cave.lua : destination "grotte".
-- Phase 1 (get_destination) : plan léger sérialisable = fenêtre de scan
-- (rayon ht.settings.cave_radius autour du centre XZ de la maison, de
-- box.y1-60 à box.y1-20, clampée y >= -200 et y <= -1) + niveau de
-- secours floor_y_fallback (box.y1 - cave_depth, clampé > -300 et
-- au moins 26 sous la base de la maison : le sous-sol du mod descend
-- au pire à y1-16, l'entrée randungeon à y1-18) + rng_seed borné à
-- 2^31-1 pour trancher les égalités de distance de façon déterministe
-- ET rester exact après sérialisation JSON (un entier 64 bits perdrait
-- sa précision).
-- Phase 2 (materialize) : emerge_and_run de l'union fenêtre + salle
-- de secours, PUIS une seule passe VoxelManip en LECTURE SEULE qui
-- repère les "poches d'air" habitables ; si aucune poche (ou fallback
-- seul possible) : salle 9x9 creusée/construite en une passe VoxelManip
-- d'écriture. La décision naturelle/artificielle est ainsi prise sur
-- l'état RÉEL du terrain après émergence, pas sur un pronostic.

local ht = housetelemosaic

--
-- Nodes résolus une fois au chargement (pattern basement.lua : chaîne
-- de fallback + warning si absent)
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

local N_BEACON = pick({"telemosaic:beacon_off"}, "beacon grotte")
local N_STONE = pick({"default:stone"}, "murs grotte artificielle")
local N_COBBLE = pick({"default:cobble", "default:stone"},
    "sol grotte artificielle")
local N_TORCH_WALL = pick({"default:torch_wall"}, "torche murale grotte")
local N_TORCH = pick({"default:torch"}, "torche de sol grotte")

-- Tables content_id -> {walkable, liquid}, construites À LA DEMANDE
-- (lazy : au premier materialize, donc après on_mods_loaded, tous les
-- nodes des autres mods sont enregistrés). Un cid absent de la table
-- (mod désinstallé) est traité comme non marchable/non liquide.
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

-- Directions horizontales {dx, dz, param2} : la torche est posée à
-- (pos + d) et le mur attendu à (pos + 2*d). Convention wallmounted
-- officielle (cf. nativevillages basements.lua ring_wallmounted,
-- et default dir_to_wallmounted) : param2 = direction du MUR de
-- support DEPUIS la torche -- 2 = x+, 3 = x-, 4 = z+, 5 = z- ;
-- un mur à l'est (+X) de la torche -> param2 = 2.
local WALL_DIRS = {
    {1, 0, 2},   -- mur à l'est   (+X) -> param2 2
    {-1, 0, 3},  -- mur à l'ouest (-X) -> param2 3
    {0, 1, 4},   -- mur au sud    (+Z) -> param2 4
    {0, -1, 5},  -- mur au nord   (-Z) -> param2 5
}

-- Torche murale sur le premier mur plein trouvé autour de pos, sinon
-- torche de sol posée à (pos + ox/oz) si le dessous est marchable.
-- Retourne true si une torche a été posée.
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
-- Scan VoxelManip lecture seule : poches d'air habitables.
-- Chaque colonne (x,z) échantillonnée est parcourue de haut en bas en
-- indices précalculés (idx -= ystride) : pas de find_nodes_in_area,
-- aucun appel par node. Une SÉRIE d'au moins 3 nodes ouverts (non
-- marchables et non liquides) consécutifs devient candidate si :
--   - le node qui termine la série en descendant (le sol) est
--     marchable et non liquide,
--   - le node SOUS le sol (idx + ystride, sous le
--     node bloquant) est non liquide (sol sec,
--     poches inondées rejetées),
--   - le PLAFOND (node au-dessus de la série, idx +
--     (air_run+1)*ystride) est marchable et non
--     liquide,
--   - un carré 3x3 aux niveaux sol+1/sol+2 est entièrement ouvert
--     (surface de pose du beacon ; garantit aussi les 2 nodes non
--     marchables au-dessus qu'exige telemosaic.is_valid_destination).
-- "Ouvert" plutôt que strictement "air" : l'herbe et les plantes de
-- grotte restent des surfaces d'arrivée valides, seul compte le
-- prédicat marchable/liquide. Un index qui sortirait du VoxelArea
-- (série touchant le bord émergé) donne data[hors bornes] = nil ->
-- prédicat nil -> candidat ignoré, sans erreur Lua.
--
local function scan_pockets(plan)
    local info = ensure_cid_info()
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(plan.minp, plan.maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()

    local cx, cz = plan.center.x, plan.center.z
    local y_top = plan.scan_max_y
    local y_bot = plan.scan_min_y

    -- échantillonnage : pas 2 si le côté dépasse ~48, pas 4 au-delà
    -- de ~96 (au réglage extrême 512x512x40 : ~1,6 M colonnes-nodes
    -- testées au lieu de 10 M ; le pas ne dépend que des bornes du
    -- plan, il reste déterministe). Le carré 3x3, lui, lit TOUJOURS
    -- les colonnes voisines réelles (x-1..x+1), échantillonnées ou
    -- non.
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
            -- fenêtre vide (maison très haute) : boucle interne
            -- zéro itération, aucune candidate
            local idx = area:index(x, y_top, z)
            local air_run = 0
            for y = y_top, y_bot, -1 do
                local inf = info[data[idx]]
                if inf and not inf.walkable and not inf.liquid then
                    air_run = air_run + 1
                else
                    -- node bloquant à y : sol potentiel de la poche
                    -- terminée (airs occupent y+1 .. y+air_run)
                    if air_run >= 3 and inf and inf.walkable
                        and not inf.liquid then
                        -- plafond : node au-DESSUS de la série d'air
                        -- (les indices CROISSENT avec y) ; sous-sol :
                        -- node sous le sol candidat (idx + ystride)
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

--
-- Ancrage d'un candidat naturel (zone déjà émergée, set_node) :
-- beacon, 2 airs forcés, sol 3x3 complété en cobble si un voisin du
-- sol est non marchable (sol irrégulier), 2 torches (murales avec
-- repli torche de sol).
--
local function anchor_candidate(c)
    if not N_BEACON then
        return nil
    end
    local floor_y = c.y - 1
    if N_COBBLE then
        for lx = c.x - 1, c.x + 1 do
            for lz = c.z - 1, c.z + 1 do
                local n = minetest.get_node_or_nil(
                    {x = lx, y = floor_y, z = lz})
                if not n or not ht.is_walkable_name(n.name) then
                    minetest.set_node({x = lx, y = floor_y, z = lz},
                        {name = N_COBBLE})
                end
            end
        end
    end
    minetest.set_node({x = c.x, y = c.y, z = c.z}, {name = N_BEACON})
    -- 2 airs garantis au-dessus du beacon (exigence telemosaic)
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
    place_torch({x = c.x + 1, y = c.y, z = c.z}, floor_y, 1, 0)
    place_torch({x = c.x - 1, y = c.y, z = c.z}, floor_y, 0, 1)
    return {x = c.x, y = c.y, z = c.z}
end

--
-- Salle artificielle de secours : intérieur 7x7, emprise 9x9, creusée
-- et habillée en UNE SEULE passe VoxelManip (set_data +
-- write_to_map(true)) à plan.floor_y_fallback :
--   floor_y        dalle de sol 9x9 cobble
--   floor_y+1..+3  anneau mural stone, intérieur air
--   floor_y+4      plafond stone
-- Le volume est déjà émergé (minp/maxp du plan couvrent l'union
-- fenêtre de scan + salle) : read_from_map y est synchrone et le
-- mapgen ne réécrira pas ces blocs (déjà générés). Beacon et torches
-- en set_node après write_to_map.
--
local function build_artificial(plan)
    if not ht.settings.cave_artificial_fallback then
        ht.dlog("cave : aucune poche trouvée et fallback artificiel "
            .. "désactivé")
        return nil
    end
    if not (N_BEACON and N_STONE and N_COBBLE) then
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
    local c_stone = minetest.get_content_id(N_STONE)
    local c_cobble = minetest.get_content_id(N_COBBLE)
    local c_air = minetest.get_content_id("air")

    for y = fy, fy + 4 do
        for x = cx - 4, cx + 4 do
            for z = cz - 4, cz + 4 do
                local i = area:index(x, y, z)
                local border = x == cx - 4 or x == cx + 4
                    or z == cz - 4 or z == cz + 4
                if y == fy then
                    data[i] = c_cobble
                elseif y == fy + 4 then
                    data[i] = c_stone
                elseif border then
                    data[i] = c_stone
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
    -- torches plaquées aux murs certains (bord à +/-4 en stone) :
    -- torche ouest (cx-3) -> mur support à x- -> param2 3 ; torche
    -- est (cx+3) -> mur à x+ -> param2 2 (convention : param2 =
    -- direction du mur depuis la torche)
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
-- Travail complet une fois la zone émergée : scan, sélection
-- déterministe (tri par distance au centre maison, tie-break parmi
-- les 3 meilleurs via PcgRandom(plan.rng_seed) : le même plan choisit
-- toujours le même candidat), ancrage naturel ou salle artificielle.
--
local function work_emerged(plan)
    local candidates = scan_pockets(plan)
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
            ht.dlog("cave : grotte naturelle ancrée à "
                .. minetest.pos_to_string(dest) .. " (" .. #candidates
                .. " poche(s) trouvée(s))")
            return dest
        end
    end
    local dest = build_artificial(plan)
    if dest then
        ht.dlog("cave : salle artificielle creusée à "
            .. minetest.pos_to_string(dest))
    end
    return dest
end

ht.providers.cave = {
    -- toujours disponible : le fallback artificiel est interne au
    -- provider (et reste conditionné au setting
    -- housetelemosaic_cave_artificial_fallback au moment de bâtir)
    is_available = function(job)
        return true
    end,

    -- Plan léger sérialisable JSON (positions plates + nombres).
    -- Une maison posée très haut (y1 > 59) donne une fenêtre de scan
    -- vide -> seule la salle artificielle (y1 - cave_depth, creusée
    -- dans la montagne) est possible ; c'est représenté par
    -- scan_max_y < scan_min_y (la boucle de scan ne tourne pas).
    get_destination = function(job, rng)
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local r = math.floor(ht.settings.cave_radius)

        -- fenêtre de scan : [y1-60 ; y1-20], clampée >= -200 (borne
        -- basse implicite) et <= -1 (toujours sous la surface)
        local y_high = math.min(box.y1 - 20, -1)
        local y_low = math.max(box.y1 - 60, -200)

        -- niveau de secours : cave_depth sous box.y1, clampé > -300
        -- et au moins 26 sous la base de la maison (anti-collision
        -- sous-sol mod / randungeon)
        local fy = box.y1 - ht.settings.cave_depth
        if fy > box.y1 - 26 then
            fy = box.y1 - 26
        end
        if fy < -296 then
            fy = -296
        end

        return {
            kind = "cave",
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
            -- fenêtre de scan réelle (minp/maxp peuvent avoir été
            -- étendus en y pour couvrir la salle de secours)
            scan_min_y = y_low,
            scan_max_y = y_high,
            center = {x = cx, y = box.y1, z = cz},
            floor_y_fallback = fy,
            -- borné à 2^31-1 : stable après un aller-retour JSON
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
                    minetest.log("warning", "[housetelemosaic] cave : "
                        .. "échec de matérialisation : " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
