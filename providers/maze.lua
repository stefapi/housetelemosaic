-- providers/maze.lua : destination "labyrinthe".
-- Générateur DÉTERMINISTE recursive backtracker sur une grille de
-- cellules W x H (settings maze_width/maze_height en CELLULES) :
-- emprise en nodes (2W+1) x (2H+1). Numérotation BASE 1 : cellule
-- (cx,cy) -> node (2cx, 2cy), mur entre cellules adjacentes -> node
-- intermédiaire (2cx+dx, 2cy+dy). Entrée = cellule (1,1) -> node
-- (2,2) ; l'enceinte nord est ouverte au node (2,1) (au-dessus de
-- l'entrée, toujours, spec) ; le beacon est POSÉ à l'entrée.
-- Flux PcgRandom(seed, x1, z1) où seed = rng:next() capturé dans le
-- plan : le même plan régénère EXACTEMENT le même labyrinthe à chaque
-- re-materialize (grille booléenne reconstruite depuis les graines).
-- Cohérence verticale (doc) : labyrinthe à F - maze_depth (déf 25),
-- grotte artificielle à y1 - cave_depth (déf 30, plancher forcé à 26
-- sous y1) : profondeurs différentes par défaut, jamais superposés ;
-- si l'utilisateur règle maze_depth == cave_depth les deux creusent
-- au même niveau mais une maison n'a qu'UNE destination : sans
-- incidence. Clamp par sécurité y >= -280.
-- Convention cotes : origin.y = y du SOL du labyrinthe ; couloirs en
-- air de origin.y+1 à origin.y+maze_height ; murs/enceinte pleins sur
-- la même hauteur ; plafond à origin.y+maze_height+1 ; beacon à
-- l'entrée (node (2,2)) y = origin.y+1, 2 airs garantis au-dessus
-- (exigence telemosaic.is_valid_destination).

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

local N_BEACON = pick({"telemosaic:beacon_off"}, "beacon labyrinthe")
local N_FLOOR = pick({"default:stone_block", "default:stone"},
    "sol labyrinthe")
local N_WALL = pick({"default:stone"}, "murs labyrinthe")
local N_FENCE = pick({"default:desert_stone", "default:stone"},
    "enceinte labyrinthe")
local N_TORCH_WALL = pick({"default:torch_wall"}, "torche murale maze")
local N_TORCH = pick({"default:torch"}, "torche de sol maze")

-- Directions {dx, dz, param2} : torche posée à (pos + d), mur attendu
-- à (pos + 2d). Convention wallmounted officielle (cf. nativevillages
-- basements.lua ring_wallmounted, et default dir_to_wallmounted) :
-- param2 = direction du MUR de support DEPUIS la torche -- 2 = x+,
-- 3 = x-, 4 = z+, 5 = z- ; mur à l'est (+X) de la torche -> 2.
local WALL_DIRS = {
    {1, 0, 2},   -- mur à l'est   (+X)
    {-1, 0, 3},  -- mur à l'ouest (-X)
    {0, 1, 4},   -- mur au sud    (+Z)
    {0, -1, 5},  -- mur au nord   (-Z)
}

-- Torche murale sur le premier mur plein trouvé autour de ref, sinon
-- torche de sol à ref si son dessous est marchable. Retourne true si
-- posée.
local function place_torch(ref)
    for _, d in ipairs(WALL_DIRS) do
        local t = {x = ref.x + d[1], y = ref.y, z = ref.z + d[2]}
        local m = {x = ref.x + 2 * d[1], y = ref.y, z = ref.z + 2 * d[2]}
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
        local below = minetest.get_node_or_nil(
            {x = ref.x, y = ref.y - 1, z = ref.z})
        local n = minetest.get_node_or_nil(ref)
        if below and ht.is_walkable_name(below.name) and n
            and n.name == "air" then
            minetest.set_node(ref, {name = N_TORCH, param2 = 1})
            return true
        end
    end
    return false
end

--
-- Génération de la grille de murs (backtracker seedé + carotte).
-- walls[gz][gx] : true = mur plein, false = passage ; gx/gz en NODES
-- base 1, 1..2W+1 / 1..2H+1. Le bord (enceinte) reste toujours mur.
-- Retourne nil si les nodes de construction manquent.
--
local function gen_walls(W, H, seed, x1, z1, carrot_seed)
    if not (N_WALL and N_FENCE and N_FLOOR) then
        return nil
    end
    local gw, gh = 2 * W + 1, 2 * H + 1
    local walls = {}
    for gz = 1, gh do
        local row = {}
        for gx = 1, gw do
            row[gx] = true
        end
        walls[gz] = row
    end

    local rng = PcgRandom(seed, x1, z1)
    -- visited : clé cy * W + cx (cx dans 1..W, cy dans 1..H :
    -- injectif), pile du backtracker
    local visited = {}
    local stack = {}
    local cx, cy = 1, 1
    visited[cy * W + cx] = true
    stack[#stack + 1] = {cx, cy}
    walls[2 * cy][2 * cx] = false -- node (2,2) : cellule entrée

    local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
    while #stack > 0 do
        local top = stack[#stack]
        cx, cy = top[1], top[2]
        local neigh = {}
        for _, d in ipairs(DIRS) do
            local nx, ny = cx + d[1], cy + d[2]
            if nx >= 1 and nx <= W and ny >= 1 and ny <= H
                and not visited[ny * W + nx] then
                neigh[#neigh + 1] = {nx, ny, d[1], d[2]}
            end
        end
        if #neigh == 0 then
            stack[#stack] = nil
        else
            local ch = neigh[rng:next(1, #neigh)]
            -- mur intermédiaire puis cellule cible
            walls[2 * cy + ch[4]][2 * cx + ch[3]] = false
            cx, cy = ch[1], ch[2]
            walls[2 * cy][2 * cx] = false
            visited[cy * W + cx] = true
            stack[#stack + 1] = {cx, cy}
        end
    end

    -- carotte (boucles) : retirer floor(W*H*0.08) murs séparateurs
    -- aléatoires. Un mur séparateur a exactement une coordonnée paire
    -- (gx pair & gz impair, ou gx impair & gz pair) : jamais les deux
    -- paires (pilier d'angle), jamais les deux impaires (cellule).
    -- Tirage par rejet : déterministe pour un carrot_seed donné.
    local carrot = math.floor(W * H * 0.08)
    local rng2 = PcgRandom(carrot_seed, x1, z1)
    for _ = 1, carrot do
        local gx = rng2:next(2, gw - 1)
        local gz = rng2:next(2, gh - 1)
        local is_sep = (gx % 2 == 0 and gz % 2 == 1)
            or (gx % 2 == 1 and gz % 2 == 0)
        if is_sep and walls[gz][gx] then
            walls[gz][gx] = false
        end
    end
    return walls
end

-- Exposé pour /htmaze (debug.lua) : grille complète pour un essai
function ht.maze_grid(W, H, seed, x1, z1, carrot_seed)
    return gen_walls(W, H, seed, x1, z1, carrot_seed)
end

--
-- Écriture en UNE SEULE passe VoxelManip (volume déjà émergé) :
--   sol    : N_FLOOR à origin.y sur TOUTE l'emprise
--   corps  : walls true -> N_WALL (intérieur) / N_FENCE (enceinte) ;
--            walls false -> air, de origin.y+1 à origin.y+hauteur
--   plafond : N_WALL à origin.y+hauteur+1 sur toute l'emprise
-- Puis ouverture de l'enceinte nord au node (2,1) (au-dessus de
-- l'entrée), sur la hauteur des couloirs. Beacon + torches en
-- set_node après write_to_map. Retourne la position du beacon.
--
local function write_maze(plan, walls)
    local W, H = plan.w, plan.h
    local gw, gh = 2 * W + 1, 2 * H + 1
    local o = plan.origin
    -- hauteur des couloirs figée dans le plan (re-materialize
    -- identique même si le setting change entre-temps)
    local ch = plan.corridor_h or math.floor(ht.settings.maze_height)

    local minp = {x = o.x, y = o.y, z = o.z}
    local maxp = {x = o.x + gw - 1, y = o.y + ch + 1, z = o.z + gh - 1}
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local c_floor = minetest.get_content_id(N_FLOOR)
    local c_wall = minetest.get_content_id(N_WALL)
    local c_fence = minetest.get_content_id(N_FENCE)
    local c_air = minetest.get_content_id("air")

    for gz = 1, gh do
        for gx = 1, gw do
            local x = o.x + gx - 1
            local z = o.z + gz - 1
            local border = gx == 1 or gx == gw or gz == 1 or gz == gh
            local is_wall = walls[gz][gx]
            data[area:index(x, o.y, z)] = c_floor
            for y = o.y + 1, o.y + ch do
                local i = area:index(x, y, z)
                if is_wall then
                    data[i] = border and c_fence or c_wall
                else
                    data[i] = c_air
                end
            end
            data[area:index(x, o.y + ch + 1, z)] = c_wall
        end
    end

    -- ouverture de l'enceinte nord au node (2,1) : au-dessus de
    -- l'entrée, sur la hauteur des couloirs (le plafond reste plein)
    for y = o.y + 1, o.y + ch do
        data[area:index(o.x + 1, y, o.z)] = c_air
    end

    vm:set_data(data)
    vm:write_to_map(true)

    -- beacon à l'entrée (node (2,2)) : le passage est déjà air sur
    -- toute la hauteur, mais si maze_height < 3 on force les 2 airs
    -- au-dessus du beacon (exigence telemosaic)
    if not N_BEACON then
        return nil
    end
    local entry = {x = o.x + 1, y = o.y + 1, z = o.z + 1}
    minetest.set_node(entry, {name = N_BEACON})
    for dy = 1, 2 do
        local p = {x = entry.x, y = entry.y + dy, z = entry.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name ~= "air" then
            local def = minetest.registered_nodes[n.name]
            if def == nil or def.walkable then
                minetest.set_node(p, {name = "air"})
            end
        end
    end

    -- torches (murales sinon sol) : entrée, centre, coin opposé.
    -- place_torch cherche un mur plein dans les 4 directions ; depuis
    -- une cellule de labyrinthe au moins un mur sépare d'une voisine
    -- (sauf carotte extrême : la pose est alors simplement sautée)
    place_torch(entry)
    place_torch({
        x = o.x + math.floor(gw / 2),
        y = o.y + 1,
        z = o.z + math.floor(gh / 2),
    })
    place_torch({x = o.x + gw - 2, y = o.y + 1, z = o.z + gh - 2})

    return entry
end

--
-- Travail une fois émergé : régénérer la grille depuis le plan (même
-- backtracker, mêmes graines = même labyrinthe), écrire, ancrer.
--
local function work_emerged(plan)
    local walls = gen_walls(plan.w, plan.h, plan.seed, plan.origin.x,
        plan.origin.z, plan.carrot_seed)
    if not walls then
        return nil
    end
    local dest = write_maze(plan, walls)
    if dest then
        ht.dlog("maze : labyrinthe " .. plan.w .. "x" .. plan.h
            .. " écrit, entrée " .. minetest.pos_to_string(dest))
    end
    return dest
end

ht.providers.maze = {
    -- toujours disponible : indépendant du terrain (on creuse)
    is_available = function(job)
        return true
    end,

    -- Plan sérialisable complet : tout ce qu'il faut pour RÉGÉNÉRER
    -- (dimensions, origine, graines, entrée). W/H capturés au moment
    -- du plan : changer le setting ensuite ne casse pas une entrée de
    -- file déjà sérialisée.
    get_destination = function(job, rng)
        if not N_BEACON then
            return nil
        end
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)

        -- F = niveau du plancher recalculé si possible, sinon
        -- convention offset -4 + 1 -> y1 + 5 (spec)
        local F = ht.scan_floor_y(box) or (box.y1 + 5)

        -- décalage déterministe anti-colonne puits/sous-sol natif
        local ox = rng:next(-10, 10)
        local oz = rng:next(-10, 10)

        -- Grille carrée W x W : maze_width est la dimension en
        -- CELLULES ; maze_height est la hauteur VERTICALE des
        -- couloirs (settingtypes.txt vague 1 : "Hauteur des
        -- couloirs", bornes 3..10 -- incompatible avec une dimension
        -- de grille ; écart documenté vs ébauche de spec vague 2 qui
        -- parlait de "W x H déf 15x15")
        local W = math.floor(ht.settings.maze_width)
        local H = W
        local gw = 2 * W + 1
        local gh = 2 * H + 1

        -- y du SOL du labyrinthe : F - maze_depth, clampé >= -280
        local y = F - math.floor(ht.settings.maze_depth)
        if y < -280 then
            y = -280
        end
        -- origin = coin nord-ouest (node (1,1)) : l'emprise gw x gh
        -- est centrée sur (cx+ox, cz+oz)
        local origin = {
            x = cx + ox - math.floor(gw / 2),
            y = y,
            z = cz + oz - math.floor(gh / 2),
        }

        return {
            kind = "maze",
            origin = origin,
            w = W,
            h = H,
            -- hauteur des couloirs capturée AUSSI : un re-materialize
            -- (LBM, file) reconstruit exactement le même volume même
            -- si le setting a changé entre-temps
            corridor_h = math.floor(ht.settings.maze_height),
            -- graines complètes du PcgRandom (capturées UNE fois :
            -- chaque re-materialize régénère le même labyrinthe)
            seed = rng:next(0, 2147483647),
            carrot_seed = rng:next(0, 2147483647),
            -- entrée = node (2,2) : cellule (1,1)
            entry = {x = origin.x + 1, y = origin.y + 1,
                z = origin.z + 1},
        }
    end,

    materialize = function(job, plan, callback)
        local o = plan.origin
        local ch = plan.corridor_h or math.floor(ht.settings.maze_height)
        -- +1 de marge autour de l'emprise pour les set_node d'équipement
        local minp = {x = o.x - 1, y = o.y - 1, z = o.z - 1}
        local maxp = {
            x = o.x + 2 * plan.w + 1,
            y = o.y + ch + 2,
            z = o.z + 2 * plan.h + 1,
        }
        ht.emerge_and_run(minp, maxp, function()
            local ok, dest = pcall(work_emerged, plan)
            if ok and dest then
                callback(true, dest)
            else
                if not ok then
                    minetest.log("warning", "[housetelemosaic] maze : "
                        .. "échec de matérialisation : " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
