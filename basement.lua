-- basement.lua : construction du sous-sol telemosaic (chambre + puits
-- d'accès + beacon maison + trappe). Cotes exactes (basement_depth
-- effectif = 5 par défaut, minimum structurel) :
--   F            plancher de la maison (intact sauf la trappe du puits)
--   F-1          anneau de couronnement 9x9 (bord seul), centre = échelle
--   F-2          y_ceiling : dalle de plafond 9x9 stonebrick (percée au
--                centre par le puits) ; y_ceiling = y_floor + 4
--   F-5..F-3     intérieur chambre : 3 airs (y_floor+1 .. y_floor+3)
--   F-5          y_floor+1 : sol marchable ; beacon au centre chambre,
--                échelle non marchable au-dessus puis air : destination
--                valide pour le lien retour
--   F-6          y_floor : dalle de sol 9x9 cobble
--   y_floor      = F - basement_depth - 1 (depth 5 -> F-6)
-- Emprise XZ totale : 9x9 (murs stonebrick à +/-4 du centre, intérieur
-- 7x7). Le puits 1x1 perce F-1 et F-2 au (sx, sz) ; l'échelle
-- (default:ladder_wood, wallmounted : param2 = direction du support,
-- table 2=x+ 3=x- 4=z+ 5=z- ; puits plaqué z-, param2 = 5) descend
-- de F-1 jusqu'à y_floor+2 ; un pilier
-- stonebrick à (sx, sz-1) porte l'échelle dans la chambre.
-- Invariant I5 : décalage anti-collision si un sous-sol natif
-- (basements.lua) ou une entrée randungeon occupe déjà la colonne.

local ht = housetelemosaic

local HALF = 4          -- murs à +/-4 : intérieur 7x7, emprise 9x9
local MIN_DEPTH = 5     -- plafond à F-2 minimum, sol à F-6 minimum

--
-- Nodes résolus une fois au chargement, avec chaînes de fallback
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

local N_WALL = pick({"default:stonebrick", "default:stone"}, "murs")
local N_FLOOR = pick({"default:cobble", "default:stone"}, "sol chambre")
local N_LADDER = pick({"default:ladder_wood", "default:ladder"},
    "échelle du puits")
local N_TRAPDOOR = pick({"doors:trapdoor_wood", "doors:trapdoor",
    "doors:trapdoor_steel"}, "trappe du puits")
local N_BEACON = pick({"telemosaic:beacon_off"}, "beacon telemosaic")
local N_TORCH_WALL = pick({"default:torch_wall"}, "torche murale")
local N_TORCH = pick({"default:torch"}, "torche de sol")

local function is_door_name(name)
    return name:find("door", 1, true) ~= nil
end

local function node_name(x, y, z)
    local n = minetest.get_node_or_nil({x = x, y = y, z = z})
    return n and n.name or nil
end

local function is_open(name)
    if name == nil or name == "ignore" then
        return false
    end
    local def = minetest.registered_nodes[name]
    return def ~= nil and not def.walkable
end

-- Invariant I5 : un sous-sol natif (air/aménagement) ou une entrée
-- randungeon (trappes/pré-creusage) occupe-t-il déjà la zone ? Sondage
-- de la colonne centrale + des 4 coins + des 4 milieux de bord de
-- l'emprise 9x9 (9 colonnes : le puits natif 1x2 et ses paliers
-- escamotent rarement les neuf à la fois), de F-3 (sous notre plafond
-- F-2) jusqu'à min(F-14, y_floor-1) ; plus un test de porte/trappe
-- sur la colonne du puits aux niveaux F..F+2.
local function native_collision(cx, cz, F, y_floor)
    local bottom = math.min(F - 14, y_floor - 1)
    local cols = {
        {cx, cz},
        {cx - HALF, cz - HALF}, {cx + HALF, cz - HALF},
        {cx - HALF, cz + HALF}, {cx + HALF, cz + HALF},
        {cx - HALF, cz}, {cx + HALF, cz},
        {cx, cz - HALF}, {cx, cz + HALF},
    }
    for _, col in ipairs(cols) do
        for y = F - 3, bottom, -1 do
            local name = node_name(col[1], y, col[2])
            if name == "air" or name == "default:ladder_wood"
                or name == "default:ladder" then
                return true
            end
        end
    end
    for _, y in ipairs({F, F + 1, F + 2}) do
        local name = node_name(cx, y, cz)
        if name and is_door_name(name) then
            return true
        end
    end
    return false
end

-- Dalle basse d'un éventuel cellier NATIF (réécriture nativevillages
-- de 2026-11-09 : le cellier remplit tout l'intérieur, marge 2, dalles
-- à F-k*5 pour k = 1..3, dalle basse donc entre F-5 et F-15) : le plus
-- profond y de [F-22 .. F-4] tel que node(y) soit une dalle marchable
-- (fenêtre démarrant à F-4, JAMAIS F-2/F-3 : c'est le plancher même
-- de la maison -- un match sur le plancher posait le pad au
-- rez-de-chaussée au lieu du cellier ; la dalle natif la plus haute
-- est à F-5)
-- et node(y+1)/node(y+2) des airs (intérieur du niveau), sonde sur
-- PLUSIEURS colonnes de l'intérieur (centre + anneau) : une colonne
-- unique tomberait souvent sur le puits d'échelle natif, un palier ou
-- un meuble et raterait le cellier entier. En terrain plein sans
-- cellier, aucun y ne matche (fondation compacte garantie par
-- foundation_solid côté natif) ; une grotte résiduelle matcherait —
-- connexion par le dessous d'une grotte reste un atterrissage valide.
local function find_native_cellar_floor(cx, cz, F, box)
    local probes = {
        {cx, cz},
        {cx - 2, cz}, {cx + 2, cz}, {cx, cz - 2}, {cx, cz + 2},
        {cx - 4, cz - 4}, {cx + 4, cz - 4},
        {cx - 4, cz + 4}, {cx + 4, cz + 4},
    }
    local found = nil
    for _, col in ipairs(probes) do
        local px, pz = col[1], col[2]
        -- rester dans l'intérieur de la maison (marge 2, convention
        -- MARGIN de basements.lua) pour ne pas sonder les murs
        if box and (px < box.x1 + 2 or px > box.x2 - 2
            or pz < box.z1 + 2 or pz > box.z2 - 2) then
            -- hors intérieur : colonne ignorée
        else
            for y = F - 4, F - 22, -1 do
                local n0 = node_name(px, y, pz)
                local n1 = node_name(px, y + 1, pz)
                local n2 = node_name(px, y + 2, pz)
                if ht.is_walkable_name(n0 or "")
                    and is_open(n1) and is_open(n2) then
                    if not found or y < found then
                        found = y -- le PLUS PROFOND des matchs
                    end
                    break -- première dalle de cette colonne suffit
                end
            end
        end
    end
    return found
end

-- Colonne d'échelle du cellier natif (pour garder le futur pad à
-- distance) : première colonne ladder trouvée dans l'intérieur du
-- cellier au niveau bas (airs cellar_floor+1..+4). Retourne {x, z}
-- ou nil.
local function find_cellar_ladder(box, cellar_floor)
    local ix1, ix2 = box.x1 + 2, box.x2 - 2
    local iz1, iz2 = box.z1 + 2, box.z2 - 2
    if ix2 < ix1 or iz2 < iz1 then
        return nil
    end
    for x = ix1, ix2 do
        for z = iz1, iz2 do
            for y = cellar_floor + 1, cellar_floor + 4 do
                local n = node_name(x, y, z)
                if n == "default:ladder_wood" or n == "default:ladder" then
                    return {x = x, z = z}
                end
            end
        end
    end
    return nil
end

-- PATCH DIRECT du cellier natif : pose le beacon ENCASTRÉ dans la
-- dalle du niveau le plus bas, dans une cellule libre (2 airs,
-- sol marchable, à >= 3 nodes de l'échelle native). Dalle 3x3
-- cobble de stabilisation (rend la dalle remplaçable par les
-- extendeurs, cf EMBED_FLOOR_OK d'api.lua), 2 torches. Aucune
-- excavation, aucun puits : la trappe et l'échelle natives
-- desservent déjà la maison. Retourne pad_pos ou nil (cellier trop
-- encombré). Synchrone : la zone du cellier est dans l'emprise de la
-- maison, déjà émergée par nativevillages.
local function patch_cellar(job, box, cellar_floor, cx, cz)
    if not N_BEACON then
        return nil
    end
    local lad = find_cellar_ladder(box, cellar_floor)
    local ix1, ix2 = box.x1 + 2, box.x2 - 2
    local iz1, iz2 = box.z1 + 2, box.z2 - 2
    -- candidats : cellules du niveau bas avec 2 airs au-dessus de la
    -- dalle et assez loin de l'échelle native ; un meuble walkable
    -- (coffre, tonneau, tapis) sur la cellule casse le test air
    local best, best_key = nil, -1
    for x = ix1, ix2 do
        for z = iz1, iz2 do
            local a1 = node_name(x, cellar_floor + 1, z)
            local a2 = node_name(x, cellar_floor + 2, z)
            local fl = node_name(x, cellar_floor, z)
            if fl and a1 and a2 and ht.is_walkable_name(fl)
                and is_open(a1) and is_open(a2) then
                local dl = 99
                if lad then
                    dl = math.abs(x - lad.x) + math.abs(z - lad.z)
                end
                if dl >= 3 then
                    -- préférence : loin de l'échelle, près du centre
                    local dcx = x - cx
                    local dcz = z - cz
                    local key = dl * 1000 - (dcx * dcx + dcz * dcz)
                    if key > best_key then
                        best_key = key
                        best = {x = x, z = z}
                    end
                end
            end
        end
    end
    if not best then
        ht.dlog("patch cellier impossible : aucune cellule libre au "
            .. "niveau bas de " .. job.name)
        return nil
    end
    -- dalle 3x3 de stabilisation en cobble (remplace le sol natif
    -- cobble/desert_sand : zone homogène et remplaçable par les
    -- extendeurs)
    if N_FLOOR then
        for dx = -1, 1 do
            for dz = -1, 1 do
                minetest.set_node({x = best.x + dx, y = cellar_floor,
                    z = best.z + dz}, {name = N_FLOOR})
            end
        end
    end
    -- beacon encastré (affleurant la dalle du cellier)
    local pad = {x = best.x, y = cellar_floor, z = best.z}
    minetest.set_node(pad, {name = N_BEACON})
    local meta = minetest.get_meta(pad)
    meta:set_string("housetelemosaic:state", "pending")
    meta:set_string("housetelemosaic:job", minetest.pos_to_string(
        {x = box.x1, y = box.y1, z = box.z1}))
    meta:set_string("housetelemosaic:mode", "patch_cellar")
    -- 2 torches posées aux coins de la dalle
    if N_TORCH then
        for _, d in ipairs({{-1, -1}, {1, 1}}) do
            minetest.set_node({x = best.x + d[1], y = cellar_floor + 1,
                z = best.z + d[2]}, {name = N_TORCH, param2 = 1})
        end
    end
    minetest.log("action", "[housetelemosaic] cellier natif patché pour "
        .. job.name .. " : pad " .. minetest.pos_to_string(pad)
        .. (lad and (" (échelle native à " .. (math.abs(best.x - lad.x)
            + math.abs(best.z - lad.z)) .. " nodes)") or ""))
    return pad
end

-- Élection de la colonne du puits (sx, sz) : décalages ordonnés autour
-- du centre (max +/-2, même marge que basements.lua MARGIN) ; il faut
-- un plancher marchable à F et 2 airs au-dessus (on ne perce pas une
-- cloison centrale), et pas de porte/trappe. Le CENTRE n'est plus
-- candidat : le beacon de la chambre y est encastré (voir dig), le
-- puits atterrit donc toujours à l'écart du pad, jamais au-dessus.
local function shaft_column(cx, cz, F)
    local offsets = {-1, 1, -2, 2}
    for _, dx in ipairs(offsets) do
        for _, dz in ipairs(offsets) do
            local sx, sz = cx + dx, cz + dz
            local f0 = node_name(sx, F, sz)
            local f1 = node_name(sx, F + 1, sz)
            local f2 = node_name(sx, F + 2, sz)
            -- une TRAPPE (native du cellier ou autre) est walkable
            -- fermée mais n'est PAS un plancher perçable : le test
            -- is_door_name la rejette pour f0, et une trappe ouverte
            -- (non walkable) au-dessus échouerait le test f1 walkable
            -- de toute façon ; on exclut aussi f1/f2 trappe (le puits
            -- ne doit jamais déboucher DANS un cellier natif par
            -- l'anneau de couronnement)
            if f0 and f1 and f2 and ht.is_walkable_name(f0)
                and not is_door_name(f0)
                and is_open(f1) and is_open(f2)
                and not is_door_name(f1) and not is_door_name(f2) then
                return sx, sz
            end
        end
    end
    return nil
end

-- Construction effective (zone émergée, 100% des blocs émergés).
-- bx, bz : coin de la dalle où encastrer le beacon (le plus éloigné
-- du puits, calculé par build_basement qui connaît sx/sz).
-- cellar_floor : y de la dalle basse d'un cellier NATIF (mode
-- connexion par le dessous) ou nil (puits classique depuis F).
-- Retourne pad_pos ou nil si un node indispensable manque au dig.
local function dig(job, cx, cz, sx, sz, y_floor, F, bx, bz, cellar_floor)
    if not (N_WALL and N_FLOOR and N_LADDER and N_BEACON) then
        return nil
    end
    local y_ceiling = y_floor + 4

    -- 1) dalle de sol 9x9 en cobble
    for x = cx - HALF, cx + HALF do
        for z = cz - HALF, cz + HALF do
            minetest.set_node({x = x, y = y_floor, z = z},
                {name = N_FLOOR})
        end
    end

    -- 2) niveaux intérieurs y_floor+1 .. y_floor+3 (3 airs) : anneau
    --    mural stonebrick, intérieur air (pilier/beacon/échelle posés
    --    après, pour ne pas être écrasés par ce remplissage)
    for y = y_floor + 1, y_ceiling - 1 do
        for x = cx - HALF, cx + HALF do
            for z = cz - HALF, cz + HALF do
                if x == cx - HALF or x == cx + HALF
                    or z == cz - HALF or z == cz + HALF then
                    minetest.set_node({x = x, y = y, z = z},
                        {name = N_WALL})
                else
                    minetest.set_node({x = x, y = y, z = z},
                        {name = "air"})
                end
            end
        end
    end

    -- 3bis) pilier porteur de l'échelle dans la chambre, à (sx, sz-1)
    --    (mur nord du puits) ; s'il tomberait sur la cellule du beacon
    --    (coin bx,bz de la dalle), on le prend au sud (sz+1)
    local px, pz = sx, sz - 1
    if px == bx and pz == bz then
        pz = sz + 1
    end
    -- le pilier ne doit JAMAIS recouvrir la cellule du beacon
    -- encastré (cas sx==bx && sz-1==bz impossible ci-dessus, mais le
    -- déplacement sud peut retomber dessus : dernier repli au nord)
    if px == bx and pz == bz then
        pz = sz - 1
    end
    for y = y_floor + 1, y_ceiling - 1 do
        minetest.set_node({x = px, y = y, z = pz}, {name = N_WALL})
    end

    -- 4) dalle de plafond 9x9 à y_ceiling (= F-2 en géométrie par
    --    défaut), percée ensuite au puits, puis anneau de couronnement
    --    au niveau F-1 (bord seul : le terrain sous le plancher reste
    --    intact ailleurs, seul le puits le traverse)
    for x = cx - HALF, cx + HALF do
        for z = cz - HALF, cz + HALF do
            minetest.set_node({x = x, y = y_ceiling, z = z},
                {name = N_WALL})
        end
    end
    for x = cx - HALF, cx + HALF do
        for z = cz - HALF, cz + HALF do
            if x == cx - HALF or x == cx + HALF
                or z == cz - HALF or z == cz + HALF then
                minetest.set_node({x = x, y = y_ceiling + 1, z = z},
                    {name = N_WALL})
            end
        end
    end

    -- 5) accès vertical. Mode connexion par le dessous (cellier natif,
    --    cellar_floor ~= nil) : le puits classique est supprimé -- la
    --    trappe native du cellier dessert déjà la maison ; on perce la
    --    dalle basse du cellier à (cx, cellar_floor) et l'échelle y
    --    descend jusqu'à la chambre. Le "pilier porteur" du cellier
    --    (terrain plein sous sa dalle, sauf notre chambre) est le
    --    support : échelle plaquée au nord (z-, param2 = 5) de
    --    y_floor+2 à cellar_floor-1, la dalle cellar_floor et le node
    --    au-dessus deviennent air (passage debout), un mur d'appui est
    --    posé sous la dalle au nord du trou.
    --    Mode classique : échelle de F-1 à y_floor+2 en deux segments
    --    (convention wallmounted = direction du mur de support depuis
    --    l'échelle : 2=x+, 3=x-, 4=z+, 5=z-) :
    --    - segment puits (y_ceiling..F-1) : plaquée au nord (z-,
    --      param2 = 5), contre le terrain natif resté en place à
    --      (sx, sz-1) -- dont le mur de couronnement posé au 5bis à
    --      F-1 ; set_node remplace le terrain de la colonne du puits
    --      par l'échelle : creuser et équiper se font d'un seul passage
    --    - segment chambre (y_floor+2..y_ceiling-1) : plaquée côté du
    --      pilier porteur réel (nord par défaut, sud dans le cas
    --      dégénéré où le pilier nord tomberait sur la cellule beacon
    --      au coin bx,bz)
    if cellar_floor then
        -- pilier d'appui de l'échelle DANS la chambre : l'échelle est
        -- plaquée au nord (param2 = 5) à (cx, cz), or le node nord
        -- (cx, y, cz-1) est l'air de l'intérieur 7x7 -- sans pilier,
        -- l'échelle flotterait sur toute la hauteur de la chambre (le
        -- pilier 3bis est au puits fictif sx/sz, pas ici). Murs pleins
        -- de y_floor+1 à y_ceiling-1 ; au-dessus du plafond
        -- (cellar_floor-2..cellar_floor-1) le terrain natif fait
        -- appui, complété par le bloc du 5bis ci-dessous.
        for y = y_floor + 1, y_ceiling - 1 do
            minetest.set_node({x = cx, y = y, z = cz - 1},
                {name = N_WALL})
        end
        -- échelle : du sol de la chambre (y_floor+1 : le dernier node
        -- d'échelle POSE les pieds sur la dalle, pas de chute finale)
        -- jusqu'à SOUS la dalle native (cellar_floor-1) ; la dalle et
        -- le node au-dessus deviennent air (passage debout côté
        -- cellier). Elle perce aussi notre plafond (y_ceiling =
        -- cellar_floor-2) : creuser et équiper d'un seul passage.
        for y = y_floor + 1, cellar_floor - 1 do
            minetest.set_node({x = cx, y = y, z = cz},
                {name = N_LADDER, param2 = 5})
        end
        minetest.set_node({x = cx, y = cellar_floor, z = cz},
            {name = "air"})
        minetest.set_node({x = cx, y = cellar_floor + 1, z = cz},
            {name = "air"})
        -- appui du haut de l'échelle (terrain plein au nord du trou,
        -- sous la dalle) : l'échelle plaquée z- trouve son mur
        minetest.set_node({x = cx, y = cellar_floor - 1, z = cz - 1},
            {name = N_WALL})
    else
        local p2_chamber = (pz == sz - 1) and 5 or 4
        -- échelle chambre : jusqu'à y_floor+1 (pieds posés sur la
        -- dalle, pas de chute du dernier node)
        for y = y_floor + 1, y_ceiling - 1 do
            minetest.set_node({x = sx, y = y, z = sz},
                {name = N_LADDER, param2 = p2_chamber})
        end
        for y = y_ceiling, F - 1 do
            minetest.set_node({x = sx, y = y, z = sz},
                {name = N_LADDER, param2 = 5})
        end
    end

    -- 5bis) support de l'échelle à F-1, mode classique seulement
    --    (mode cellier : l'appui est le 5) ci-dessus)
    if not cellar_floor then
        minetest.set_node({x = sx, y = F - 1, z = sz - 1}, {name = N_WALL})
    end

    -- 6) trappe dans le plancher de la maison, à (sx, F, sz) : le node
    --    de plancher marchable est remplacé ; sans trappe enregistrée,
    --    on laisse le trou (l'échelle reste visible, garanties du puits
    --    intactes)
    if not cellar_floor and N_TRAPDOOR
        and ht.is_walkable_name(node_name(sx, F, sz) or "") then
        minetest.set_node({x = sx, y = F, z = sz},
            {name = N_TRAPDOOR, param2 = 0})
    end

    -- 7) beacon maison ENCASTRÉ dans la dalle (affleurant) au coin
    --    bx,bz transmis par build_basement (le plus éloigné du puits :
    --    jamais au pied de l'échelle). telemosaic téléporte à
    --    dest.y+0.5, soit juste au ras de la dalle en arrivée retour.
    local pad = {x = bx, y = y_floor, z = bz}
    minetest.set_node(pad, {name = N_BEACON})
    local meta = minetest.get_meta(pad)
    meta:set_string("housetelemosaic:state", "pending")
    meta:set_string("housetelemosaic:job", minetest.pos_to_string(
        {x = job.box.x1, y = job.box.y1, z = job.box.z1}))

    -- 8) torches murales aux 4 points cardinaux (param2 wallmounted =
    --    direction du MUR de support depuis la torche : 2 = x+,
    --    3 = x-, 4 = z+, 5 = z- ; les murs de la chambre sont à +/-4,
    --    les torches à +/-3) ; fallback torche de sol aux 4 coins
    --    (param2 = 1 : y-, posée)
    if N_TORCH_WALL then
        local y = y_floor + 2
        minetest.set_node({x = cx - 3, y = y, z = cz},
            {name = N_TORCH_WALL, param2 = 3})
        minetest.set_node({x = cx + 3, y = y, z = cz},
            {name = N_TORCH_WALL, param2 = 2})
        minetest.set_node({x = cx, y = y, z = cz - 3},
            {name = N_TORCH_WALL, param2 = 5})
        minetest.set_node({x = cx, y = y, z = cz + 3},
            {name = N_TORCH_WALL, param2 = 4})
    elseif N_TORCH then
        for _, dx in ipairs({-3, 3}) do
            for _, dz in ipairs({-3, 3}) do
                minetest.set_node({x = cx + dx, y = y_floor + 1,
                    z = cz + dz}, {name = N_TORCH, param2 = 1})
            end
        end
    end

    ht.last_basement = {pad = pad, F = F}
    return pad
end

--
-- Point d'entrée (appelé par ht.process_house). Retourne pad_pos dès
-- que la géométrie est arrêtée (le dig lui-même attend l'emerge : la
-- zone du sous-sol déborde en dessous de l'emprise schematic que
-- nativevillages a déjà émergée).
--
function ht.build_basement(job, F)
    local box = job.box
    local cx = math.floor((box.x1 + box.x2) / 2)
    local cz = math.floor((box.z1 + box.z2) / 2)

    -- profondeur effective : 5 = géométrie minimale de la spec
    -- (plafond F-2, sol F-6) ; au-delà la chambre s'enfonce d'autant
    local depth = math.max(ht.settings.basement_depth, MIN_DEPTH)
    local y_floor = F - depth - 1

    -- I5 : essais de décalage (0,0) puis (+4,+4) puis (+8,+8), bornés
    -- pour garder la chambre 9x9 sous l'empreinte (marge 2 vers chaque
    -- mur, convention MARGIN de basements.lua, plafonné à 8) ; en
    -- dernier recours on approfondit de 4
    local room_x = math.min(box.x2 - cx, cx - box.x1) - 2
    local room_z = math.min(box.z2 - cz, cz - box.z1) - 2
    local max_dx = math.max(0, math.min(room_x, 8))
    local max_dz = math.max(0, math.min(room_z, 8))
    local offsets = {{0, 0}, {4, 4}, {8, 8}}
    local ox, oz = 0, 0
    local placed = false
    local tried = {}
    for _, off in ipairs(offsets) do
        local dx = math.min(off[1], max_dx)
        local dz = math.min(off[2], max_dz)
        local key = dx .. "," .. dz
        if not tried[key] then
            tried[key] = true
            if not native_collision(cx + dx, cz + dz, F, y_floor) then
                ox, oz = dx, dz
                placed = true
                break
            end
        end
    end
    if not placed then
        -- approfondissement : toute la chambre descendue de 4 (le
        -- plafond passe de F-2 à F-6), dernier essai au centre
        y_floor = y_floor - 4
        if not native_collision(cx, cz, F, y_floor) then
            ox, oz = 0, 0
            placed = true
            ht.dlog("collision sous-sol natif : chambre approfondie "
                .. "de 4 pour " .. job.name)
        end
    end
    local cellar_floor = nil
    if not placed then
        -- Cellier natif détecté (réécriture nativevillages 2026-11-09 :
        -- le cellier remplit tout l'intérieur, aucune chambre 9x9 ne
        -- tient dessous). DEUX stratégies, par ordre de préférence :
        -- 1) PATCH DIRECT (prioritaire, zéro excavation) : le beacon
        --    est encastré dans la dalle du niveau LE PLUS BAS du
        --    cellier, dans une cellule libre loin de l'échelle
        --    native -- le cellier devient la pièce du téléporteur.
        -- 2) sinon (cellier encombré de meubles) : connexion par le
        --    dessous -- chambre 9x9 SOUS la dalle basse, trou
        --    d'échelle percé dans la dalle :
        --    maison -> trappe native -> cellier -> échelle -> chambre.
        cellar_floor = find_native_cellar_floor(cx, cz, F, box)
        if cellar_floor then
            local pad = patch_cellar(job, box, cellar_floor, cx, cz)
            if pad then
                ht.stats.pads_dug = ht.stats.pads_dug + 1
                ht.last_basement = {pad = pad, F = F}
                return pad
            end
            y_floor = cellar_floor - 6
            ox, oz = 0, 0
            placed = true
            ht.dlog("cellier natif détecté (dalle basse y=" .. cellar_floor
                .. ") : chambre connectée par le dessous pour " .. job.name)
        end
    end
    if not placed then
        -- DERNIER RECOURS : descente par paliers de 5 nodes jusqu'à
        -- F-45, à la recherche d'une profondeur libre de TOUTE
        -- collision native. Pourquoi c'est nécessaire avec
        -- basement_chance = 1.0 : les maisons SANS cellier natif sont
        -- précisément celles volées par une entrée randungeon cachée
        -- (randungeon_entrance_chance = 0.5 ici : 50 % des _30_) ou
        -- refusées par le natif -- leur sous-sol proche est occupé
        -- par le puits randungeon (pré-creusé jusqu'à ~y1-18, soit
        -- F-22 par ancrage -4) ; les celliers natifs s'arrêtent à
        -- F-15. À partir de F-27 la zone est vierge dans tous les
        -- cas ; on sonde F-20, F-25, ... F-45 et prend la première
        -- profondeur dégagée, avec le puits classique depuis F (il
        -- n'y a PAS de cellier dans ce chemin, le puits ne peut
        -- croiser que le puits randungeon -- évité par la sonde de
        -- collision elle-même).
        local depth = 20
        while depth <= 45 do
            local test_y = F - depth - 1
            if not native_collision(cx, cz, F, test_y) then
                y_floor = test_y
                ox, oz = 0, 0
                placed = true
                ht.dlog("dernier recours : chambre à F-" .. depth
                    .. " pour " .. job.name)
                break
            end
            depth = depth + 5
        end
    end
    if not placed then
        minetest.log("action", "[housetelemosaic] abandon : sous-sol "
            .. "natif encombrant sous " .. job.name .. " à "
            .. minetest.pos_to_string(job.pos) .. " (sondé jusqu'à F-45)")
        return nil
    end
    cx, cz = cx + ox, cz + oz

    -- colonne du puits (décalage autour du centre si cloison/meuble :
    -- le centre est réservé au... rien du tout, le beacon est au coin).
    -- En mode connexion par le dessous (cellier natif), PAS de puits :
    -- l'accès passe par la trappe native et le trou d'échelle percé
    -- dans la dalle basse (voir dig) ; sx/sz restent utilisés pour le
    -- coin du beacon (le trou est au centre, le beacon au coin opposé).
    local sx, sz = shaft_column(cx, cz, F)
    if not sx then
        if cellar_floor then
            sx, sz = cx - 1, cz - 1 -- coin fictif : beacon opposé (cx+2,cz+2)
        else
            minetest.log("action", "[housetelemosaic] abandon : aucune "
                .. "colonne de puits libre dans " .. job.name .. " à "
                .. minetest.pos_to_string(job.pos))
            return nil
        end
    end

    -- coin du beacon : diagonalement opposé au puits dans l'intérieur
    -- 7x7 (distance maximale à l'échelle), encastré dans la dalle
    local bx, bz = cx + 2, cz + 2
    if sx <= cx then bx = cx - 2 end
    if sz <= cz then bz = cz - 2 end

    local pad = {x = bx, y = y_floor, z = bz}
    local minp = {x = cx - HALF, y = y_floor - 1, z = cz - HALF}
    local maxp = {x = cx + HALF, y = F, z = cz + HALF}
    ht.emerge_and_run(minp, maxp, function()
        local ok, result = pcall(dig, job, cx, cz, sx, sz, y_floor, F,
            bx, bz, cellar_floor)
        if ok and result then
            ht.stats.pads_dug = ht.stats.pads_dug + 1
            minetest.log("action", "[housetelemosaic] sous-sol construit "
                .. "sous " .. job.name .. ", pad "
                .. minetest.pos_to_string(result))
        else
            minetest.log("warning", "[housetelemosaic] dig échoué pour "
                .. job.name .. " : " .. tostring(result))
        end
    end, function()
        minetest.log("warning", "[housetelemosaic] emerge impossible "
            .. "pour le sous-sol de " .. job.name .. " à "
            .. minetest.pos_to_string(job.pos))
    end)
    return pad
end
