-- api.lua : utilitaires partagés (PRNG déterministes, scans, extendeurs,
-- liaison des deux pads). ht.link_pads est consommé par link_queue.lua.

local ht = housetelemosaic

--
-- Graines des tirages déterministes (convention basements.lua : un flux
-- PcgRandom par usage, mélangé à la graine du monde)
--
ht.BASE_SEED = 0xBA5E4E7   -- flux générique du mod
ht.HOUSE_SEED = 0x4A0E5EED -- tirage chance par maison
ht.MAZE_SEED = 0xAB1E      -- flux du générateur de labyrinthe

-- Graine du monde, lue à la demande (peut changer entre mondes)
function ht.world_seed()
    return tonumber(minetest.get_mapgen_setting("seed")) or 0
end

-- PRNG déterministe par site : même monde + même empreinte = mêmes
-- tirages, un chunk régénéré reconstruit le même sous-sol
function ht.house_rng(x1, y1, z1, salt)
    return PcgRandom(ht.world_seed() + salt, x1, y1, z1)
end

-- Compteurs de session (photo du run courant, NON persistés ; les
-- compteurs durables restent dans le mod storage, cf /htstats).
-- /htcheck les affiche pour localiser où le pipeline s'arrête :
-- chaque étape (appel wrapper -> éligible -> tirage -> plancher ->
-- pad -> creusé -> file -> liaison) a son compteur.
ht.stats = {
    calls = 0,            -- appels du wrapper (tout bâtiment posé)
    ineligible = 0,       -- bâtiments non maison (étables, puits...)
    eligible = 0,         -- maisons éligibles vues
    chance_skip = 0,      -- éligibles écartées au tirage chance
    floors = 0,           -- planchers détectés
    no_floor = 0,         -- abandons "pas de plancher"
    pads = 0,             -- pads programmés (process_house)
    pads_dug = 0,         -- sous-sols RÉELLEMENT creusés (après emerge)
    queued = 0,           -- entrées mises en file
    linked = 0,           -- liaisons établies
    mat_fail = 0,         -- échecs materialize/liaison (essais)
    provider_switch = 0,  -- bascules de provider de secours
    unlinked = 0,         -- abandons définitifs (session)
    -- répartition des décisions de build_basement (diagnostic
    -- "chance 1.0 mais pads rares" : qui prend la décision, et où
    -- elle échoue) -- /htcheck
    decisions = {
        patch_cellar = 0,   -- pad posé DANS le cellier natif
        under_cellar = 0,   -- chambre sous le cellier (par le dessous)
        classic = 0,        -- chambre classique sous maison sans cellier
        deep_fallback = 0,  -- dernier recours F-20..F-45
        giveup_native = 0,  -- abandon : sous-sol natif encombrant
        giveup_shaft = 0,   -- abandon : aucune colonne de puits
        dig_fail = 0,       -- dig a échoué après emerge
    },
}

-- Copie profonde (le job natif ne doit jamais être muté par erreur)
function ht.deep_copy(t)
    if type(t) ~= "table" then
        return t
    end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = ht.deep_copy(v)
    end
    return copy
end

-- Log de debug (uniquement si housetelemosaic_debug)
function ht.dlog(msg)
    if ht.settings.debug then
        minetest.log("action", "[housetelemosaic] " .. tostring(msg))
    end
end

--
-- emerge_area gardé : on_ok seulement si 100 % des blocs émergés
-- avec succès. Succès = action >= EMERGE_FROM_MEMORY (bloc chargé de
-- la mémoire, du disque ou généré -- la constante EMERGE_OK
-- n'existe pas dans l'API Luanti, ne pas l'utiliser) ; échec =
-- EMERGE_CANCELLED / EMERGE_ERRORED. Signature du callback :
-- callback(blockpos, action, calls_remaining).
--
local EMERGE_FROM_MEMORY = core.EMERGE_FROM_MEMORY or 2

local function emerge_action_ok(action)
    return action ~= nil and action ~= core.EMERGE_CANCELLED
        and action ~= core.EMERGE_ERRORED
        and action >= EMERGE_FROM_MEMORY
end

-- Une erreur dans un callback emerge est FATALE pour le serveur
-- (AsyncErr on_emerge_area_completion) : on_ok et on_fail sont
-- toujours exécutés sous pcall. Si on_ok échoue : log error +
-- traceback puis on_fail tenté UNE fois (protégé) ; si on_fail
-- échoue : log seul. Jamais de reboucle.
--
function ht.emerge_and_run(minp, maxp, on_ok, on_fail)
    local ok_count = 0
    local total = 0
    minetest.emerge_area(minp, maxp, function(blockpos, action, calls_remaining)
        total = total + 1
        if emerge_action_ok(action) then
            ok_count = ok_count + 1
        end
        if calls_remaining <= 0 then
            if ok_count == total then
                local ok, err = pcall(on_ok)
                if not ok then
                    minetest.log("error", "[housetelemosaic] on_ok a "
                        .. "échoué après emerge : " .. tostring(err)
                        .. "\n" .. debug.traceback())
                    if on_fail then
                        local ok2, err2 = pcall(on_fail)
                        if not ok2 then
                            minetest.log("error", "[housetelemosaic] "
                                .. "on_fail a aussi échoué : "
                                .. tostring(err2))
                        end
                    end
                end
            elseif on_fail then
                local ok, err = pcall(on_fail)
                if not ok then
                    minetest.log("error", "[housetelemosaic] on_fail a "
                        .. "échoué (emerge partiel " .. ok_count .. "/"
                        .. total .. " blocs) : " .. tostring(err)
                        .. "\n" .. debug.traceback())
                end
            else
                minetest.log("warning", "[housetelemosaic] emerge partiel ("
                    .. ok_count .. "/" .. total .. " blocs) autour de "
                    .. minetest.pos_to_string(minp))
            end
        end
    end)
end

--
-- Prédicats de nodes (gardes nil systématiques)
--

function ht.is_walkable_name(name)
    local def = minetest.registered_nodes[name]
    return def ~= nil and def.walkable == true
end

local function is_open_name(name)
    if name == "ignore" then
        return false
    end
    local def = minetest.registered_nodes[name]
    return def ~= nil and not def.walkable
end

-- Meubles / escaliers : un candidat "sol" portant l'un de ces préfixes
-- est un objet POSÉ sur le plancher, pas le plancher (le piège documenté
-- de scan_floor_y dans biomevillages/basements.lua : tapis, lits,
-- coffres, escaliers élus un nœud trop haut)
local FURNITURE_PREFIXES = {
    "stairs:", "default:furnace", "default:chest", "default:bookshelf",
    "vessels:", "biomevillages:", "wool:", "carpets:",
}

local function is_furniture_name(name)
    for _, prefix in ipairs(FURNITURE_PREFIXES) do
        if name:sub(1, #prefix) == prefix then
            return true
        end
    end
    local def = minetest.registered_nodes[name]
    if def and def.groups and (def.groups.door or 0) > 0 then
        return true
    end
    return false
end

--
-- Niveau du REZ-DE-CHAUSSÉE de la maison. Sondes : centre, anneaux
-- ±1/±2/±3 en croix et diagonales ±1 (certains tapis 5x5 couvrent
-- le centre). Candidat valide (filtres du scan natif) : marchable,
-- non meuble, node dessous non meuble aussi, 2 airs au-dessus,
-- 1 marchable dessous, et fondation compacte (garde anti-grotte).
-- Retourne le y du nœud plancher, ou nil + la raison (logs /htcheck).
--
function ht.scan_floor_y(box)
    local cx = math.floor((box.x1 + box.x2) / 2)
    local cz = math.floor((box.z1 + box.z2) / 2)
    local columns = {
        {cx, cz},
        {cx - 1, cz}, {cx + 1, cz}, {cx, cz - 1}, {cx, cz + 1},
        {cx - 2, cz}, {cx + 2, cz}, {cx, cz - 2}, {cx, cz + 2},
        {cx - 3, cz}, {cx + 3, cz}, {cx, cz - 3}, {cx, cz + 3},
        {cx - 1, cz - 1}, {cx + 1, cz + 1},
    }
    -- Fenêtre native y0-5 .. y0+3 (y0 = y1-4, ancrage -4), balayée en
    -- ASCENDANT : le premier candidat rencontré est le plancher le
    -- plus bas (un plancher d'étage est au-dessus de la borne haute
    -- et ne peut jamais être élu). Ne pas élargir vers le bas : les
    -- dalles des celliers natifs (F-5k) y vivent -- un scan plus
    -- profond les élirait comme "plancher" ; les maisons sans aucune
    -- sonde valide (cellier meublé) passent par le mode sans-plancher
    -- de process_house (patch direct du cellier).
    -- Garde anti-grotte (foundation_solid natif simplifié) : >= 3
    -- nodes pleins sur les 4 sous le candidat, sinon on monte vers
    -- le candidat suivant de la colonne.
    local y0 = box.y1 - 4
    local saw_ignore = false
    for _, col in ipairs(columns) do
        local x, z = col[1], col[2]
        for y = y0 - 5, y0 + 3 do
            local n = minetest.get_node_or_nil({x = x, y = y, z = z})
            if n then
                if n.name == "ignore" then
                    saw_ignore = true
                end
                local name = n.name
                local above1 = minetest.get_node_or_nil(
                    {x = x, y = y + 1, z = z})
                local above2 = minetest.get_node_or_nil(
                    {x = x, y = y + 2, z = z})
                local below1 = minetest.get_node_or_nil(
                    {x = x, y = y - 1, z = z})
                if above1 and above2 and below1
                    and ht.is_walkable_name(name)
                    and not is_furniture_name(name)
                    and not is_furniture_name(below1.name)
                    and is_open_name(above1.name)
                    and is_open_name(above2.name)
                    and ht.is_walkable_name(below1.name) then
                    -- fondation compacte ? (4 nodes dessous pleins)
                    local solid = 0
                    for dy = 1, 4 do
                        local b = minetest.get_node_or_nil(
                            {x = x, y = y - dy, z = z})
                        if b and b.name ~= "air"
                            and b.name ~= "ignore"
                            and ht.is_walkable_name(b.name) then
                            solid = solid + 1
                        end
                    end
                    if solid >= 3 then
                        return y
                    end
                    -- sol de grotte : candidat suivant (on monte)
                end
            end
        end
    end
    if saw_ignore then
        return nil, "nodes ignore dans la fenêtre (chunk non émergé)"
    end
    return nil, "aucun plancher valide dans la fenêtre y0-5..y0+3"
end

--
-- Extendeurs telemosaic
--

-- Palier d'extendeur disponible : three (portée 80) sinon two (20)
-- sinon one (5) ; la formule du besoin garde la portée correspondante
local function resolve_extender()
    local tiers = {
        {"telemosaic:extender_three", telemosaic.extender_ranges[3] or 80},
        {"telemosaic:extender_two", telemosaic.extender_ranges[2] or 20},
        {"telemosaic:extender_one", telemosaic.extender_ranges[1] or 5},
    }
    for _, tier in ipairs(tiers) do
        if minetest.registered_nodes[tier[1]] then
            return tier[1], tier[2]
        end
    end
    return nil, 0
end

-- Nombre d'extendeurs nécessaires pour couvrir dist depuis la portée
-- de base du beacon ; clampé par max_extenders (0 = illimité). Le clamp
-- peut rendre la liaison impossible (portée insuffisante) : warning.
function ht.compute_extenders_needed(dist)
    local range = telemosaic.beacon_range or 20
    if dist <= range then
        return 0
    end
    local _, tier_range = resolve_extender()
    if tier_range <= 0 then
        return 0
    end
    local needed = math.ceil((dist - range) / tier_range)
    local max_n = ht.settings.max_extenders
    if max_n > 0 and needed > max_n then
        minetest.log("warning", "[housetelemosaic] " .. needed
            .. " extendeurs nécessaires pour une liaison à "
            .. string.format("%.0f", dist) .. " nœuds, clampé à "
            .. max_n .. " (liaison possiblement impossible)")
        needed = max_n
    end
    return needed
end

-- Ordre spiral (du centre vers l'extérieur) des 48 cases de la zone
-- 7x7 autour du beacon, centre exclu -- check_beacon de telemosaic ne
-- compte que les extendeurs à +/-3 XZ et y-1..y du beacon
local SPIRAL = {}
do
    local by_ring = {}
    for dx = -3, 3 do
        for dz = -3, 3 do
            if not (dx == 0 and dz == 0) then
                local ring = math.max(math.abs(dx), math.abs(dz))
                by_ring[ring] = by_ring[ring] or {}
                table.insert(by_ring[ring], {dx, dz})
            end
        end
    end
    for ring = 1, 3 do
        local cells = by_ring[ring] or {}
        table.sort(cells, function(a, b)
            local da = math.abs(a[1]) + math.abs(a[2])
            local db = math.abs(b[1]) + math.abs(b[2])
            if da ~= db then
                return da < db
            end
            if a[1] ~= b[1] then
                return a[1] < b[1]
            end
            return a[2] < b[2]
        end)
        for _, cell in ipairs(cells) do
            SPIRAL[#SPIRAL + 1] = cell
        end
    end
end

-- Matériaux de dalle posés par CE mod (basement : cobble ; maze/sky :
-- stone_block). Les pads encastrés exigent des extendeurs affleurants
-- eux aussi : une cellule de notre propre dalle est donc remplaçable.
-- STRICTEMENT limité à ces deux noms : jamais la roche naturelle ni
-- les murs (un extender dans un mur y ferait une blessure visuelle et
-- un trou possible si le node n'est pas walkable).
local EMBED_FLOOR_OK = {
    ["default:cobble"] = true,
    ["default:stone_block"] = true,
}

-- Pose count extendeurs en spirale carrée autour de pos, au même y,
-- dans les nœuds constructibles (air / buildable_to) ou dans une
-- cellule de dalle posée par le mod (pad encastré, cf EMBED_FLOOR_OK).
-- Retourne le nombre réellement posé.
function ht.place_extenders_around(pos, count)
    if count <= 0 then
        return 0
    end
    local name = resolve_extender()
    if not name then
        minetest.log("warning", "[housetelemosaic] aucun extendeur "
            .. "telemosaic enregistré, liaison courte seulement")
        return 0
    end
    local placed = 0
    for _, cell in ipairs(SPIRAL) do
        if placed >= count then
            break
        end
        local p = {x = pos.x + cell[1], y = pos.y, z = pos.z + cell[2]}
        local node = minetest.get_node_or_nil(p)
        if node then
            local def = minetest.registered_nodes[node.name]
            local free = node.name == "air"
                or (def ~= nil and def.buildable_to)
                or EMBED_FLOOR_OK[node.name] == true
            if free then
                minetest.set_node(p, {name = name})
                placed = placed + 1
            end
        end
    end
    return placed
end

--
-- Liaison des deux pads : extendeurs posés des deux côtés selon la
-- distance, destinations programmées dans les deux sens (si
-- return_enabled), vérification get_destination après chaque écriture.
-- Retourne true si les deux liaisons demandées sont en place.
--
function ht.link_pads(pad, dest)
    local dist = vector.distance(pad, dest)
    local needed = ht.compute_extenders_needed(dist)
    if needed > 0 then
        local n1 = ht.place_extenders_around(pad, needed)
        local n2 = ht.place_extenders_around(dest, needed)
        ht.dlog("extendeurs posés : " .. n1 .. " (maison) + " .. n2
            .. " (destination) pour " .. string.format("%.0f", dist)
            .. " nœuds")
    end
    local ok = true
    pcall(telemosaic.set_destination, pad, dest)
    if not telemosaic.get_destination(pad) then
        minetest.log("warning", "[housetelemosaic] destination non "
            .. "enregistrée sur le pad maison "
            .. minetest.pos_to_string(pad))
        ok = false
    end
    if ht.settings.return_enabled then
        pcall(telemosaic.set_destination, dest, pad)
        if not telemosaic.get_destination(dest) then
            minetest.log("warning", "[housetelemosaic] lien retour non "
                .. "enregistré sur le pad destination "
                .. minetest.pos_to_string(dest))
            ok = false
        end
    end
    return ok
end
