-- debug.lua : commandes chat de supervision. /htstats est libre ;
-- /htrelink, /htmaze et /htdebug demandent le privilège "server".
-- /htmaze passe par le VRAI chemin du provider (materialize avec un
-- plan de la même forme que get_destination) : ce qui est validé en
-- jeu est exactement ce que les maisons recevront.

local ht = housetelemosaic

-- Compteur persistant de pads "unlinked" : les entrées purgées ne
-- sont plus dans le storage et les metas ne sont pas énumérables
-- sans parcourir la carte -> un simple champ de storage, incrémenté
-- par la file au moment de la purge unlinked.
-- NB : get_mod_storage() ne rend un StorageRef valide QUE pendant
-- le chargement du mod -- au runtime on lit la référence partagée
-- ht.mod_storage (capturée au chargement par link_queue.lua) ; le
-- code reste défensif : appelé depuis un callback emerge asynchrone,
-- il ne doit jamais crasher.
local function bump_unlinked()
    local storage = ht.mod_storage
    if not storage then
        ht.dlog("note_unlinked : mod storage indisponible, compteur "
            .. "non incrémenté")
        return
    end
    storage:set_int("stats:unlinked",
        storage:get_int("stats:unlinked") + 1)
end

-- hook appelé par link_queue (purge unlinked) : branché ici pour
-- garder le compteur cohérent sans que la file connaisse debug
ht.note_unlinked = bump_unlinked

local function storage_stats()
    local total = 0
    local by_provider = {}
    -- ht.mod_storage (référence de chargement) et non
    -- core.get_mod_storage(), qui rend nil au runtime
    local storage = ht.mod_storage
    if not storage then
        return 0, {}, 0
    end
    -- stats:* exclu du décompte : ce sont des compteurs, pas des
    -- entrées de file
    for key, raw in pairs(storage:to_table().fields) do
        if raw ~= "" and key:sub(1, 6) ~= "stats:" then
            total = total + 1
            local ok, entry = pcall(core.parse_json, raw)
            if ok and type(entry) == "table" then
                local p = tostring(entry.provider)
                by_provider[p] = (by_provider[p] or 0) + 1
            end
        end
    end
    return total, by_provider, storage:get_int("stats:unlinked")
end

minetest.register_chatcommand("htstats", {
    description = "housetelemosaic : état de la file de liaison",
    func = function(name)
        local total, by_provider, unlinked = storage_stats()
        local lines = { "[housetelemosaic] file : " .. total
            .. " entrée(s), " .. unlinked .. " abandon(s) cumulé(s)" }
        for p, n in pairs(by_provider) do
            lines[#lines + 1] = "  provider " .. p .. " : " .. n
        end
        if ht.last_basement and ht.last_basement.pad then
            local meta = minetest.get_meta(ht.last_basement.pad)
            lines[#lines + 1] = "  dernier pad "
                .. minetest.pos_to_string(ht.last_basement.pad)
                .. " (F=" .. ht.last_basement.F .. ") : état "
                .. meta:get_string("housetelemosaic:state")
        else
            lines[#lines + 1] = "  aucun sous-sol construit dans cette "
                .. "session"
        end
        lines[#lines + 1] = "  hook : " .. tostring(ht._patched)
        return true, table.concat(lines, "\n")
    end,
})

minetest.register_chatcommand("htrelink", {
    description = "housetelemosaic : force le traitement de la file",
    privs = { server = true },
    func = function(name)
        -- référence de chargement (ht.mod_storage) : jamais
        -- core.get_mod_storage() au runtime
        local storage = ht.mod_storage
        if not storage then
            return false, "[housetelemosaic] mod storage indisponible"
        end
        local n = 0
        for id, raw in pairs(storage:to_table().fields) do
            if raw ~= "" and id:sub(1, 6) ~= "stats:"
                and ht.queue.process_entry(id) then
                n = n + 1
            end
        end
        return true, "[housetelemosaic] re-traitement de " .. n
            .. " entrée(s) déclenché par " .. name
    end,
})

-- /htcheck : diagnostic d'installation du pipeline, pas à pas. Les
-- compteurs de session (ht.stats, api.lua) disent OÙ la chaîne
-- s'arrête : si calls = 0, le hook n'est jamais déclenché (terrain
-- déjà généré : nativevillages ne construit que sur NOUVEAUX chunks,
-- utiliser /htforce) ; si eligible = 0 mais calls > 0, préfixes en
-- cause ; si pads > 0 mais pads_dug = 0, l'emerge échoue, etc.
minetest.register_chatcommand("htcheck", {
    description = "housetelemosaic : diagnostic d'installation "
        .. "(hook, source, compteurs de session)",
    func = function(name)
        local s = ht.stats
        local lines = { "[housetelemosaic] diagnostic :" }
        lines[#lines + 1] = "  mod chargé : oui"
        lines[#lines + 1] = "  hook : "
            .. (ht._patched and ("installé sur nativevillages."
                .. tostring(ht._patched)) or "NON installé")
        lines[#lines + 1] = "  source nativevillages : "
            .. (ht._source or "inconnue")
        lines[#lines + 1] = "  destinations : "
            .. table.concat(ht.settings.destinations, ",")
            .. " (mode " .. ht.settings.dest_mode .. ")"
        lines[#lines + 1] = "  chance=" .. ht.settings.chance
        lines[#lines + 1] = "  wrapper appelé : " .. s.calls .. " fois"
        lines[#lines + 1] = "  maisons éligibles : " .. s.eligible
            .. " (non-éligibles : " .. s.ineligible
            .. ", écartées au tirage : " .. s.chance_skip .. ")"
        lines[#lines + 1] = "  planchers détectés : " .. s.floors
            .. " (abandons sans plancher : " .. s.no_floor .. ")"
        lines[#lines + 1] = "  pads programmés : " .. s.pads
            .. ", RÉELLEMENT creusés : " .. s.pads_dug
        local qtotal = 0
        if ht.queue and ht.queue.count then
            qtotal = ht.queue.count()
        end
        local _, _, unlinked_total = storage_stats()
        lines[#lines + 1] = "  entrées file (storage) : " .. qtotal
            .. ", mises en file : " .. s.queued
        lines[#lines + 1] = "  liaisons établies : " .. s.linked
            .. ", échecs d'essai : " .. s.mat_fail
            .. ", bascules : " .. s.provider_switch
            .. ", unlinked (cumul storage) : " .. unlinked_total
        local d = s.decisions or {}
        lines[#lines + 1] = "  décisions sous-sol : cellier patché "
            .. (d.patch_cellar or 0) .. ", sous cellier "
            .. (d.under_cellar or 0) .. ", classique "
            .. (d.classic or 0) .. ", profond "
            .. (d.deep_fallback or 0) .. " | abandons : natif "
            .. (d.giveup_native or 0) .. ", puits "
            .. (d.giveup_shaft or 0) .. ", dig " .. (d.dig_fail or 0)
        if s.calls == 0 then
            lines[#lines + 1] = "  >> wrapper jamais appelé : le terrain "
                .. "exploré était déjà généré, ou aucun village. "
                .. "Testez /htforce sous vos pieds puis explorez du "
                .. "NOUVEAU terrain."
        elseif s.pads_dug == 0 and s.pads > 0 then
            lines[#lines + 1] = "  >> pads programmés mais jamais creusés "
                .. ": voir les warnings emerge dans debug.txt"
        end
        -- le rapport est AUSSI écrit dans un fichier du monde :
        -- ouvrable dans n'importe quel éditeur de texte (la copie
        -- depuis le chat Luanti n'est pas toujours possible)
        local ok, err = pcall(function()
            local worldpath = minetest.get_worldpath()
            local f = io.open(worldpath .. "/htcheck_report.txt", "w")
            if not f then
                error("impossible d'ouvrir htcheck_report.txt")
            end
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
        end)
        if ok then
            lines[#lines + 1] = "  rapport écrit : "
                .. minetest.get_worldpath() .. "/htcheck_report.txt"
        else
            lines[#lines + 1] = "  (écriture du rapport impossible : "
                .. tostring(err) .. ")"
        end
        return true, table.concat(lines, "\n")
    end,
})

-- /htforce : teste TOUT le pipeline à la position du joueur, sans
-- attendre la génération d'un nouveau village. Fabrique le job
-- synthétique {box 9x6x9 posée au sol sous le joueur,
-- name="grasslandhouse1", biome_name="unknown"} et déroule
-- process_house complet (plancher -> sous-sol -> file -> liaison).
-- Le chat rapporte chaque étape (les mêmes logs action que le
-- pipeline naturel, rejoués vers le joueur).
minetest.register_chatcommand("htforce", {
    description = "housetelemosaic : force un sous-sol + pad telemosaic "
        .. "sous la position du joueur (test complet du pipeline)",
    privs = { server = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[housetelemosaic] joueur introuvable"
        end
        local pp = player:get_pos()
        -- sol : premier node marchable sous les pieds du joueur
        local ground = nil
        for dy = 0, 40 do
            local y = math.floor(pp.y) - dy
            local n = minetest.get_node_or_nil(
                {x = math.floor(pp.x), y = y, z = math.floor(pp.z)})
            if n and ht.is_walkable_name(n.name) then
                ground = y
                break
            end
        end
        if not ground then
            return false, "[housetelemosaic] aucun sol trouvé sous "
                .. name .. " sur 40 nodes"
        end
        -- job synthétique : box 9x6x9 centrée sur le joueur, posée au
        -- sol (y1 = ground + 1 : l'intérieur au-dessus du sol, comme
        -- une maison ancrée à offset -4 dont le plancher est ~y1+4 ;
        -- F sera retrouvé par scan_floor_y ; scan_floor_y descend
        -- jusqu'à y1-8, le sol du joueur reste dans la fenêtre)
        local cx = math.floor(pp.x)
        local cz = math.floor(pp.z)
        local y1 = ground + 1
        local job = {
            name = "grasslandhouse1",
            pos = {x = cx - 4, y = y1, z = cz - 4},
            box = {
                x1 = cx - 4, y1 = y1, z1 = cz - 4,
                x2 = cx + 4, y2 = y1 + 5, z2 = cz + 4,
            },
            biome_name = "unknown",
        }
        minetest.chat_send_player(name, "[housetelemosaic] /htforce : sol "
            .. "détecté à y=" .. ground .. ", box 9x6x9 à ("
            .. (cx - 4) .. "," .. y1 .. "," .. (cz - 4) .. ")")
        -- déroulé complet du pipeline en relançant les étapes une à
        -- une pour le chat : plancher, puis process_house (qui logge
        -- pad + file), puis la file se déroule en asynchrone (ses
        -- logs action partent au journal ; /htstats en donne l'état)
        local F, why = ht.scan_floor_y(job.box)
        if not F then
            return false, "[housetelemosaic] pas de plancher dans la box "
                .. "de test : " .. tostring(why)
        end
        minetest.chat_send_player(name, "[housetelemosaic] plancher F=" .. F)
        local ok, err = pcall(ht.process_house, job)
        if not ok then
            return false, "[housetelemosaic] process_house a échoué : "
                .. tostring(err)
        end
        if ht.last_pad_planned then
            minetest.chat_send_player(name, "[housetelemosaic] pad prévu "
                .. minetest.pos_to_string(ht.last_pad_planned)
                .. " : creusage dès l'emerge (~1 s), puis liaison par la "
                .. "file (provider en tête de "
                .. table.concat(ht.settings.destinations, ",")
                .. "). Creusez/regardez sous vos pieds ; /htstats pour "
                .. "l'état, /htcheck pour les compteurs")
            return true, "[housetelemosaic] pipeline complet déclenché "
                .. "(suivi dans debug.txt)"
        end
        return false, "[housetelemosaic] pad non programmé (raison dans "
            .. "debug.txt : collision native, pas de colonne de puits...)"
    end,
})

-- /htmaze <x> <y> <z> [<w> [<h>]] : labyrinthe de test à la
-- position (w x h CELLULES, défauts 15x15 ; ce sont des comptes de
-- cellules, la parité n'importe pas). Graines FIXES (monde +
-- MAZE_SEED) pour reproductibilité visuelle. (priv server)
minetest.register_chatcommand("htmaze", {
    description = "housetelemosaic : labyrinthe de test en <x> <y> "
        .. "<z> [<w> [<h>]]",
    privs = { server = true },
    func = function(name, param)
        local xs, ys, zs, ws, hs = param:match(
            "^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(%d+)%s+(%d+)%s*$")
        if not xs then
            xs, ys, zs, ws = param:match(
                "^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s+(%d+)%s*$")
            hs = nil
        end
        if not xs then
            xs, ys, zs = param:match(
                "^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$")
            ws, hs = nil, nil
        end
        if not xs then
            return false, "usage : /htmaze <x> <y> <z> [<w> [<h>]] "
                .. "(cellules, déf 15 15)"
        end
        local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
        local W = math.max(3, math.min(tonumber(ws) or 15, 51))
        local H = math.max(3, math.min(tonumber(hs) or W, 51))
        -- plan de la même forme que get_destination (graines fixes)
        local origin = {x = x, y = y, z = z}
        local plan = {
            kind = "maze",
            origin = origin,
            w = W,
            h = H,
            seed = ht.world_seed() + ht.MAZE_SEED,
            carrot_seed = ht.world_seed() + ht.MAZE_SEED + 1,
            entry = {x = origin.x + 1, y = origin.y + 1,
                z = origin.z + 1},
        }
        ht.providers.maze.materialize(nil, plan, function(ok, dest)
            if ok then
                minetest.chat_send_player(name,
                    "[housetelemosaic] labyrinthe " .. W .. "x" .. H
                    .. " généré, entrée "
                    .. minetest.pos_to_string(dest))
            else
                minetest.chat_send_player(name,
                    "[housetelemosaic] échec de génération (voir log)")
            end
        end)
        return true, "[housetelemosaic] génération lancée à ("
            .. x .. ", " .. y .. ", " .. z .. ")"
    end,
})

minetest.register_chatcommand("htdebug", {
    description = "housetelemosaic : bascule le mode debug",
    privs = { server = true },
    func = function()
        ht.settings.debug = not ht.settings.debug
        local state = ht.settings.debug and "activé" or "désactivé"
        return true, "[housetelemosaic] debug " .. state
    end,
})

-- /htaudit [<rayon>] [fix|report] : audite (et par défaut répare) les
-- sous-sols du mod déjà construits autour du joueur. Cible les pads
-- MAISON (meta housetelemosaic:state) -- les beacons d'arrivée des
-- providers n'ont pas cette meta. Réparations :
--  R1 échelle : rungs manquants complétés jusqu'à y_floor+1
--  R2 puits : échelle complétée jusqu'à F-1 (premier plancher marchable
--     au-dessus), trappe posée si le plancher F est resté plein
--  R3 mode cellier : passage air x2 au-dessus du haut d'échelle quand
--     le node au-dessus est une dalle, mur d'appui au nord
--  R4 beacon posé SUR la dalle et non lié -> encastré (meta recopiée)
-- "report" : diagnostic sans écrire. (priv server)
local LADDER_NAMES = {
    ["default:ladder_wood"] = true,
    ["default:ladder"] = true,
}

minetest.register_chatcommand("htaudit", {
    description = "housetelemosaic : audite/répare les sous-sols déjà "
        .. "construits autour du joueur (/htaudit [rayon] [fix|report])",
    privs = { server = true },
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[housetelemosaic] joueur introuvable"
        end
        local radius = 96
        local fix = true
        for tok in param:gmatch("%S+") do
            tok = tok:lower()
            local n = tonumber(tok)
            if n then
                radius = math.max(16, math.min(math.floor(n), 192))
            elseif tok == "report" then
                fix = false
            elseif tok == "fix" then
                fix = true
            end
        end
        local pp = player:get_pos()
        local minp = {x = pp.x - radius, y = pp.y - 48, z = pp.z - radius}
        local maxp = {x = pp.x + radius, y = pp.y + 48, z = pp.z + radius}
        local found = minetest.find_nodes_in_area(minp, maxp,
            {"group:telemosaic"})
        if not found or #found == 0 then
            return true, "[housetelemosaic] aucun beacon telemosaic "
                .. "dans un rayon de " .. radius
        end
        local lines = { "[housetelemosaic] audit de " .. #found
            .. " beacon(s) (mode " .. (fix and "FIX" or "REPORT") .. ") :" }
        local pads = 0
        for _, pos in ipairs(found) do
            if pads >= 20 then
                lines[#lines + 1] = "  (limite de 20 pads : relancez "
                    .. "ailleurs)"
                break
            end
            local state = minetest.get_meta(pos):get_string(
                "housetelemosaic:state")
            if state ~= "" then
                pads = pads + 1
                local bx, by, bz = pos.x, pos.y, pos.z
                local linked = minetest.get_meta(pos):get_string(
                    "telemosaic:dest") ~= ""
                local notes = {}
                local function N(fmt)
                    notes[#notes + 1] = fmt
                end
                -- y_floor : beacon encastré (voisin = dalle) ou posé
                -- (dessous = dalle)
                local side = minetest.get_node_or_nil(
                    {x = bx + 1, y = by, z = bz})
                local below = minetest.get_node_or_nil(
                    {x = bx, y = by - 1, z = bz})
                local y_floor
                if side and ht.is_walkable_name(side.name) then
                    y_floor = by -- encastré dans la dalle
                elseif below and ht.is_walkable_name(below.name) then
                    y_floor = by - 1 -- posé sur la dalle
                    if fix and not linked then
                        -- R4 : encastrer le beacon non lié
                        local newp = {x = bx, y = y_floor, z = bz}
                        minetest.set_node(newp,
                            {name = "telemosaic:beacon_off"})
                        local m2 = minetest.get_meta(newp)
                        m2:set_string("housetelemosaic:state", state)
                        N("beacon encastré dans la dalle")
                    else
                        N("beacon posé SUR la dalle"
                            .. (linked and " (lié, non déplacé)" or ""))
                    end
                else
                    N("beacon sans dalle identifiable : ignoré")
                end
                if y_floor then
                    -- centre chambre : coin diagonalement opposé au
                    -- beacon, celui dont le plancher 9x9 est le plus
                    -- plein
                    local best_c, best_n = nil, -1
                    for _, d in ipairs({{2, 2}, {2, -2}, {-2, 2},
                            {-2, -2}}) do
                        local ccx, ccz = bx + d[1], bz + d[2]
                        local n = 0
                        for x = ccx - 4, ccx + 4 do
                            for z = ccz - 4, ccz + 4 do
                                local nd = minetest.get_node_or_nil(
                                    {x = x, y = y_floor, z = z})
                                if nd and ht.is_walkable_name(nd.name) then
                                    n = n + 1
                                end
                            end
                        end
                        if n > best_n then
                            best_n = n
                            best_c = {x = ccx, z = ccz}
                        end
                    end
                    if best_n < 60 then
                        N("chambre non identifiée (" .. best_n
                            .. "/81 cellules de dalle)")
                    else
                        -- colonnes d'échelle de l'intérieur 7x7
                        local cols = {}
                        for x = best_c.x - 3, best_c.x + 3 do
                            for z = best_c.z - 3, best_c.z + 3 do
                                local lo, hi, p2
                                for y = y_floor + 1, y_floor + 3 do
                                    local nd = minetest.get_node_or_nil(
                                        {x = x, y = y, z = z})
                                    if nd and LADDER_NAMES[nd.name] then
                                        if not lo then
                                            lo = y
                                            p2 = nd.param2
                                        end
                                        hi = y
                                    end
                                end
                                if lo then
                                    cols[#cols + 1] =
                                        {x = x, z = z, lo = lo, hi = hi,
                                            p2 = p2}
                                end
                            end
                        end
                        if #cols == 0 then
                            N("aucune échelle dans la chambre")
                        end
                        for _, c in ipairs(cols) do
                            -- R5 : mur d'appui manquant derrière les
                            -- rungs (param2 = direction du MUR depuis
                            -- l'échelle : 2 = x+, 3 = x-, 4 = z+,
                            -- 5 = z-) ; un node non marchable derrière
                            -- un rung = échelle flottante, on pose un
                            -- pilier stonebrick (dans l'intérieur 7x7)
                            local sdx, sdz = 0, 0
                            if c.p2 == 2 then
                                sdx = 1
                            elseif c.p2 == 3 then
                                sdx = -1
                            elseif c.p2 == 4 then
                                sdz = 1
                            elseif c.p2 == 5 then
                                sdz = -1
                            end
                            if sdx ~= 0 or sdz ~= 0 then
                                local missing = 0
                                for y = y_floor + 1, c.hi do
                                    local s = minetest.get_node_or_nil(
                                        {x = c.x + sdx, y = y,
                                            z = c.z + sdz})
                                    if not s
                                        or not ht.is_walkable_name(s.name) then
                                        missing = missing + 1
                                    end
                                end
                                if missing > 0 then
                                    if fix then
                                        for y = y_floor + 1, c.hi do
                                            local s = minetest.get_node_or_nil(
                                                {x = c.x + sdx, y = y,
                                                    z = c.z + sdz})
                                            if not s or not ht
                                                .is_walkable_name(s.name) then
                                                minetest.set_node(
                                                    {x = c.x + sdx, y = y,
                                                        z = c.z + sdz},
                                                    {name =
                                                        "default:stonebrick"})
                                            end
                                        end
                                    end
                                    N("pilier d'appui reconstruit derrière "
                                        .. "l'échelle (" .. c.x .. "," .. c.z
                                        .. ", " .. missing .. " node(s))")
                                end
                            end
                            -- R1 : rungs manquants jusqu'à y_floor+1
                            if c.lo > y_floor + 1 then
                                if fix then
                                    for y = y_floor + 1, c.lo - 1 do
                                        minetest.set_node(
                                            {x = c.x, y = y, z = c.z},
                                            {name = "default:ladder_wood",
                                                param2 = c.p2})
                                    end
                                end
                                N("échelle (" .. c.x .. "," .. c.z
                                    .. ") complétée vers le bas")
                            end
                            -- au-dessus du rung le plus haut : dalle
                            -- (mode cellier, R3) ou puits à compléter
                            local top = minetest.get_node_or_nil(
                                {x = c.x, y = c.hi + 1, z = c.z})
                            if top and ht.is_walkable_name(top.name) then
                                if fix then
                                    minetest.set_node(
                                        {x = c.x, y = c.hi + 1, z = c.z},
                                        {name = "air"})
                                    local up = minetest.get_node_or_nil(
                                        {x = c.x, y = c.hi + 2, z = c.z})
                                    if up
                                        and ht.is_walkable_name(up.name) then
                                        minetest.set_node(
                                            {x = c.x, y = c.hi + 2,
                                                z = c.z},
                                            {name = "air"})
                                    end
                                    minetest.set_node(
                                        {x = c.x, y = c.hi, z = c.z - 1},
                                        {name = "default:stonebrick"})
                                end
                                N("passage cellier percé au-dessus de "
                                    .. "l'échelle (" .. c.x .. "," .. c.z
                                    .. ")")
                            else
                                -- R2 : puits jusqu'au premier plancher
                                local F
                                for y = c.hi + 1, c.hi + 12 do
                                    local nd = minetest.get_node_or_nil(
                                        {x = c.x, y = y, z = c.z})
                                    if nd and ht.is_walkable_name(nd.name)
                                        and nd.name:find("ladder", 1, true) == nil then
                                        F = y
                                        break
                                    end
                                end
                                if F then
                                    if fix then
                                        for y = c.hi + 1, F - 1 do
                                            minetest.set_node(
                                                {x = c.x, y = y, z = c.z},
                                                {name = "default:ladder_wood",
                                                    param2 = 5})
                                        end
                                    end
                                    N("puits complété (" .. c.x .. ","
                                        .. c.z .. ") jusqu'à F=" .. F)
                                    local fnode = minetest.get_node_or_nil(
                                        {x = c.x, y = F, z = c.z})
                                    if fnode
                                        and ht.is_walkable_name(fnode.name)
                                        and fnode.name:find("door", 1, true) == nil then
                                        if fix
                                            and minetest.registered_nodes[
                                                "doors:trapdoor_wood"] then
                                            minetest.set_node(
                                                {x = c.x, y = F, z = c.z},
                                                {name = "doors:trapdoor_wood",
                                                    param2 = 0})
                                        end
                                        N("trappe posée à F=" .. F)
                                    end
                                else
                                    N("échelle (" .. c.x .. "," .. c.z
                                        .. ") sans plancher au-dessus "
                                        .. "(puits ouvert)")
                                end
                            end
                        end
                    end
                end
                lines[#lines + 1] = "  pad (" .. bx .. "," .. by .. ","
                    .. bz .. ") [" .. state .. "] : "
                    .. (#notes > 0 and table.concat(notes, " ; ")
                        or "OK rien à signaler")
            end
        end
        if pads == 0 then
            lines[#lines + 1] = "  aucun pad maison (meta du mod) trouvé"
        end
        return true, table.concat(lines, "\n")
    end,
})

-- /htscanarea [<rayon>] : RÉTROFIT des maisons déjà posées autour du
-- joueur (le pipeline naturel n'équipe que les NOUVELLES générations).
-- Détection : mobilier nativevillages:* (liste reconstruite dynamique
-- depuis registered_nodes : résistante aux mises à jour du mod), posés
-- en INTERIEUR par les schematics ; clusterisation par proximité XZ,
-- chaque cluster de >= 2 meubles vaut une maison, box = empreinte des
-- meubles + marge 6, puis process_house complet (plancher -> sous-sol
-- -> file -> liaison). Anti-doublon : une box contenant déjà un node
-- du groupe telemosaic est sautée. Limites : rayon 16..128 nodes,
-- fenêtre verticale ±32, 30 maisons max par passage (relancer pour
-- la suite). Une maison sans AUCUN meuble natif n'est pas détectée.
minetest.register_chatcommand("htscanarea", {
    description = "housetelemosaic : équipe les maisons déjà posées "
        .. "autour du joueur (rayon en nodes, déf. 64)",
    privs = { server = true },
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[housetelemosaic] joueur introuvable"
        end
        local radius = math.max(16, math.min(
            math.floor(tonumber(param) or 64), 128))
        local pp = player:get_pos()
        local cx, cy, cz = math.floor(pp.x), math.floor(pp.y),
            math.floor(pp.z)
        local minp = {x = cx - radius, y = cy - 32, z = cz - radius}
        local maxp = {x = cx + radius, y = cy + 32, z = cz + radius}
        minetest.chat_send_player(name, "[housetelemosaic] scan de "
            .. (radius * 2) .. "x64x" .. (radius * 2)
            .. " autour de vous, émergence en cours...")
        ht.emerge_and_run(minp, maxp, function()
            -- mobilier natif : liste dynamique complète
            local names = {}
            for reg in pairs(minetest.registered_nodes) do
                if reg:sub(1, 15) == "nativevillages:" then
                    names[#names + 1] = reg
                end
            end
            if #names == 0 then
                minetest.chat_send_player(name,
                    "[housetelemosaic] aucun node nativevillages:* "
                    .. "enregistré : rien à détecter")
                return
            end
            local grouped = minetest.find_nodes_in_area(minp, maxp,
                names, true)
            local points = {}
            for _, positions in pairs(grouped) do
                for _, pos in ipairs(positions) do
                    points[#points + 1] = pos
                end
            end
            if #points == 0 then
                minetest.chat_send_player(name,
                    "[housetelemosaic] aucun meuble nativevillages "
                    .. "dans le rayon : aucune maison détectée")
                return
            end
            -- clusterisation gloutonne par distance XZ (< 24 nodes)
            local clusters = {}
            for _, pos in ipairs(points) do
                local target
                for _, cl in ipairs(clusters) do
                    local dx = pos.x - cl.cx
                    local dz = pos.z - cl.cz
                    if dx * dx + dz * dz < 24 * 24 then
                        target = cl
                        break
                    end
                end
                if not target then
                    target = {n = 0, cx = 0, cz = 0,
                        x1 = pos.x, x2 = pos.x,
                        z1 = pos.z, z2 = pos.z, ylow = pos.y}
                    clusters[#clusters + 1] = target
                end
                target.n = target.n + 1
                target.cx = target.cx + (pos.x - target.cx) / target.n
                target.cz = target.cz + (pos.z - target.cz) / target.n
                if pos.x < target.x1 then target.x1 = pos.x end
                if pos.x > target.x2 then target.x2 = pos.x end
                if pos.z < target.z1 then target.z1 = pos.z end
                if pos.z > target.z2 then target.z2 = pos.z end
                if pos.y < target.ylow then target.ylow = pos.y end
            end
            -- traitement des maisons : >= 2 meubles, pas déjà équipée
            local equipped, skipped, processed = 0, 0, 0
            for _, cl in ipairs(clusters) do
                if cl.n < 2 then
                    skipped = skipped + 1 -- meuble isolé (autel, tonneau perdu)
                elseif processed >= 30 then
                    skipped = skipped + 1 -- quota du passage
                else
                    processed = processed + 1
                    local box = {
                        x1 = cl.x1 - 6, y1 = cl.ylow - 4, z1 = cl.z1 - 6,
                        x2 = cl.x2 + 6, y2 = cl.ylow + 8, z2 = cl.z2 + 6,
                    }
                    -- anti-doublon : déjà un pad telemosaic dans la box ?
                    local pads = minetest.find_nodes_in_area(
                        {x = box.x1, y = box.y1 - 20, z = box.z1},
                        {x = box.x2, y = box.y2, z = box.z2},
                        {"group:telemosaic"})
                    local already = pads and #pads > 0
                    if already then
                        skipped = skipped + 1
                    else
                        local job = {
                            name = "retrofit",
                            pos = {x = box.x1, y = box.y1, z = box.z1},
                            box = box,
                            biome_name = "unknown",
                        }
                        -- last_pad_planned garde la valeur du traitement
                        -- précédent en cas d'échec : on compare avant/après
                        local before = ht.last_pad_planned
                        local ok = pcall(ht.process_house, job)
                        if ok and ht.last_pad_planned ~= before then
                            equipped = equipped + 1
                        end
                    end
                end
            end
            minetest.chat_send_player(name,
                "[housetelemosaic] rétrofit : " .. equipped
                .. " maison(s) équipée(s), " .. skipped
                .. " sautée(s) (isolée/déjà équipée/quota)."
                .. (processed >= 30 and " Relancez pour la suite."
                    or ""))
        end, function()
            minetest.chat_send_player(name,
                "[housetelemosaic] émergence impossible autour de "
                .. name .. " : réessayez")
        end)
        return true, "[housetelemosaic] scan lancé (résultat dans "
            .. "quelques secondes)"
    end,
})
