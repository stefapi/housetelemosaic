-- link_queue.lua : file de liaison pad -> destination, persistée en
-- mod storage. VAGUE 2 : materialize chez le provider puis
-- ht.link_pads ; après 3 échecs, tente le PROVIDER SUIVANT de la
-- chaîne (recalculée depuis le job, provider défaillant exclu, rng
-- re-seedé avec offset = tries : déterministe par maison) avant de
-- déclarer "unlinked" ; LBM sur les beacons pending pour reprendre
-- les entrées orphelines au chargement des chunks ; reprise légère
-- sur on_generated (throttle 10 s).
--
-- Contrat de sérialisation : entry = {pad (pos plate), job (mince :
-- name/pos/box/biome_name), plan (JSON-safe, contrat providers),
-- provider (string), tries (nombre)}. Le job mince est fabriqué par
-- hook.lua slim_job() ; les entries anciennes (vague 1, job copie
-- profonde éventuellement enrichie) restent lisibles : seuls les
-- champs consommés sont accédés.

local ht = housetelemosaic

-- Référence UNIQUE du mod storage, capturée ICI, au chargement :
-- get_mod_storage() ne renvoie un StorageRef valide que pendant le
-- chargement du mod ; appelé au runtime (callback emerge, after...),
-- il rend nil et tout indexage crashe. Ne JAMAIS rappeler
-- get_mod_storage() hors du temps de chargement : utiliser cette
-- référence partagée (ht.mod_storage, consommée par debug.lua).
local storage = core.get_mod_storage()
ht.mod_storage = storage
local Q = {}
ht.queue = Q

-- protection de ré-entrance : process peut être déclenché par add(),
-- par un callback différé, par le LBM ou par /htrelink pendant qu'il
-- tourne déjà
local processing = false
local rerun = false

-- entrées dont un materialize est EN COURS (callback asynchrone pas
-- encore revenu) : un double déclenchement de la MÊME entrée (LBM au
-- chargement du chunk pendant un retry différé, /htrelink pendant un
-- process) ne relance pas un deuxième chantier en parallèle -- la
-- construction serait identique (plans déterministes) mais doublée
-- en coût et en appels link_pads
local inflight = {}

-- throttle de la reprise on_generated (au plus toutes les 10 s)
local last_gen_check = 0

local MAX_TRIES = 3

local function entry_key(pad)
    return core.pos_to_string(pad)
end

-- Sérialisation : job, pad, plan et tries ne doivent contenir que
-- positions, nombres, chaînes et listes plates (contrat respecté :
-- slim_job côté hook, plans JSON-safe côté providers)
local function save_entry(id, entry)
    local ok, json = pcall(core.write_json, entry)
    if ok and type(json) == "string" then
        storage:set_string(id, json)
    else
        minetest.log("error", "[housetelemosaic] sérialisation "
            .. "impossible de " .. id .. " : " .. tostring(json))
    end
end

-- Tâche différée protégée : une erreur Lua remontant dans un
-- callback minetest.after est fatale pour le serveur ; on logge
-- avec traceback et on rend la main.
local function safe_after(delay, fn)
    minetest.after(delay, function()
        local ok, err = pcall(fn)
        if not ok then
            minetest.log("error", "[housetelemosaic] tâche différée a "
                .. "échoué : " .. tostring(err) .. "\n"
                .. debug.traceback())
        end
    end)
end

function Q.add(entry)
    if not entry or not entry.pad or not entry.provider then
        minetest.log("warning", "[housetelemosaic] entrée de file "
            .. "invalide, ignorée")
        return
    end
    entry.tries = entry.tries or 0
    -- horodatage de création : distingue les entrées du flux courant
    -- (pad possiblement encore en cours de creusage asynchrone) des
    -- entrées héritées des sessions antérieures (born absent)
    entry.born = os.time()
    local id = entry_key(entry.pad)
    save_entry(id, entry)
    ht.dlog("entrée ajoutée : " .. id .. " (provider " .. entry.provider
        .. ")")
    Q.process()
end

local function purge(id, entry, state)
    storage:set_string(id, "")
    local meta = core.get_meta(entry.pad)
    if meta then
        meta:set_string("housetelemosaic:state", state)
    end
    -- compteur persistant pour /htstats (branché par debug.lua ; la
    -- file ne connaît pas debug, juste le hook optionnel)
    if state == "unlinked" then
        ht.stats.unlinked = ht.stats.unlinked + 1
        if type(ht.note_unlinked) == "function" then
            ht.note_unlinked()
        end
    end
end

--
-- provider suivant sur échec : recalcule la chaîne de candidats
-- depuis le job en excluant le provider défaillant, rng re-seedé
-- avec offset = tries (même sel maison + variation déterministe :
-- la Nième tentative d'une maison donne toujours le même plan de
-- secours). Remplace le plan de l'entrée ; retourne true si un
-- remplaçant a été trouvé.
--
local function try_next_provider(id, entry)
    if not entry.job or not entry.job.box then
        return false
    end
    -- garde-fou anti ping-pong : au maximum autant de bascules qu'il
    -- existe de destinations configurées (une maison ne peut pas
    -- re-tourner indéfiniment sur des providers qui échouent tous)
    entry.fallbacks = (entry.fallbacks or 0) + 1
    if entry.fallbacks > #ht.settings.destinations then
        return false
    end
    local plan, name = ht.select_plan(entry.job, entry.tries,
        entry.provider)
    if plan and name then
        entry.plan = plan
        entry.provider = name
        entry.tries = 0
        save_entry(id, entry)
        ht.stats.provider_switch = ht.stats.provider_switch + 1
        minetest.log("action", "[housetelemosaic] bascule de "
            .. "secours vers le provider " .. name .. " pour " .. id)
        return true
    end
    return false
end

local function handle_entry(id, entry)
    if inflight[id] then
        return -- déjà en cours pour cette entrée
    end
    -- Pad pas encore posé ? Trois cas : dig encore en vol (entrées
    -- fraîches : le creusage asynchrone du sous-sol peut devancer la
    -- file), chunk non chargé (get_node -> "ignore", typiquement au
    -- démarrage pour les entrées persistées), ou pad fantôme hérité
    -- du bug EMERGE_OK (dig qui n'a jamais abouti). On re-vérifie
    -- dans 5 s SANS consommer d'essai ni re-materializer ; après une
    -- douzaine de reports (~1 min), l'entrée est purgée -- un dig
    -- réel ne prend jamais aussi longtemps
    local pad_node = core.get_node(entry.pad)
    if core.get_item_group(pad_node.name, "telemosaic") == 0 then
        entry.waits = (entry.waits or 0) + 1
        if entry.waits >= 12 then
            minetest.log("action", "[housetelemosaic] entrée " .. id
                .. " purgée : pas de beacon pad à cette position ("
                .. pad_node.name .. " après " .. entry.waits
                .. " vérifications)")
            purge(id, entry, "unlinked")
        else
            save_entry(id, entry)
            safe_after(5, function()
                Q.process_entry(id)
            end)
        end
        return
    end
    local provider = ht.providers[entry.provider]
    if not provider or type(provider.materialize) ~= "function" then
        minetest.log("warning", "[housetelemosaic] provider "
            .. tostring(entry.provider) .. " sans materialize, entrée "
            .. id .. " purgée")
        purge(id, entry, "unlinked")
        return
    end
    -- Callback de materialize protégé : il est invoqué au plus
    -- profond d'un callback emerge asynchrone, où toute erreur Lua
    -- non capturée est FATALE pour le serveur (AsyncErr) ; on logge
    -- avec traceback et on rend la main.
    local ok_cb
    ok_cb = function(ok, dest_pos)
        local ran, err = pcall(function()
            inflight[id] = nil
            if ok and dest_pos and ht.link_pads(entry.pad, dest_pos) then
                ht.stats.linked = ht.stats.linked + 1
                purge(id, entry, "linked")
                minetest.log("action", "[housetelemosaic] liaison établie "
                    .. "pour " .. id .. " (provider " .. entry.provider
                    .. ", destination "
                    .. minetest.pos_to_string(dest_pos) .. ")")
            else
                entry.tries = entry.tries + 1
                ht.stats.mat_fail = ht.stats.mat_fail + 1
                minetest.log("action", "[housetelemosaic] échec "
                    .. "materialize/liaison pour " .. id .. " (essai "
                    .. entry.tries .. "/" .. MAX_TRIES .. ", provider "
                    .. entry.provider .. ")")
                if entry.tries >= MAX_TRIES then
                    -- dernier recours : le provider suivant dans la
                    -- chaîne, avant l'abandon définitif
                    if try_next_provider(id, entry) then
                        safe_after(1, Q.process)
                        return
                    end
                    minetest.log("warning", "[housetelemosaic] liaison "
                        .. "abandonnée pour " .. id .. " après "
                        .. entry.tries .. " essais (provider "
                        .. entry.provider .. ")")
                    purge(id, entry, "unlinked")
                else
                    save_entry(id, entry)
                    safe_after(5, Q.process)
                end
            end
        end)
        if not ran then
            inflight[id] = nil -- ne pas laisser l'entrée bloquée
            minetest.log("error", "[housetelemosaic] callback de liaison "
                .. "a échoué pour " .. id .. " : " .. tostring(err)
                .. "\n" .. debug.traceback())
        end
    end
    inflight[id] = true
    local ok, err = pcall(provider.materialize, entry.job, entry.plan,
        ok_cb)
    if not ok then
        minetest.log("warning", "[housetelemosaic] materialize a échoué "
            .. "pour " .. id .. " : " .. tostring(err))
        ok_cb(false, nil)
    end
end

-- Traitement d'UNE entrée (publique : le LBM redéclenche une entrée
-- précise au chargement de son beacon ; /htrelink s'en sert aussi)
function Q.process_entry(id)
    -- les champs stats:* (ex stats:unlinked) ne sont pas des entrées
    if id:sub(1, 6) == "stats:" then
        return false
    end
    local raw = storage:get_string(id)
    if raw == "" then
        return false
    end
    local ok, entry = pcall(core.parse_json, raw)
    if not ok or type(entry) ~= "table" or not entry.pad then
        minetest.log("warning", "[housetelemosaic] entrée corrompue "
            .. "purgée : " .. id)
        storage:set_string(id, "")
        return false
    end
    handle_entry(id, entry)
    return true
end

function Q.process()
    if processing then
        rerun = true
        return
    end
    processing = true
    -- stats:* exclu : ce sont des compteurs, pas des entrées (sinon
    -- Q.process les purgerait comme "corrompues")
    for id, raw in pairs(storage:to_table().fields) do
        if raw ~= "" and id:sub(1, 6) ~= "stats:" then
            local ok, entry = pcall(core.parse_json, raw)
            if ok and type(entry) == "table" and entry.pad then
                handle_entry(id, entry)
            else
                minetest.log("warning", "[housetelemosaic] entrée "
                    .. "corrompue purgée : " .. id)
                storage:set_string(id, "")
            end
        end
    end
    processing = false
    if rerun then
        rerun = false
        Q.process()
    end
end

function Q.count()
    local n = 0
    for k, raw in pairs(storage:to_table().fields) do
        if raw ~= "" and k:sub(1, 6) ~= "stats:" then
            n = n + 1
        end
    end
    return n
end

--
-- LBM de reprise : un beacon pending dont l'entrée existe ENCORE en
-- storage (le pad n'a pas encore été lié) re-déclenche son entrée au
-- chargement de son chunk -- typiquement le serveur s'est arrêté
-- pendant un materialize en cours. Les meta "unlinked"/"linked"
-- ne font rien. nodenames = groupe telemosaic (beacon_off et
-- beacon, les deux états du pad).
--
minetest.register_lbm({
    name = "housetelemosaic:beacon",
    label = "Reprise des liaisons housetelemosaic",
    nodenames = {"group:telemosaic"},
    run_at_every_load = true,
    action = function(pos)
        local meta = core.get_meta(pos)
        if meta:get_string("housetelemosaic:state") ~= "pending" then
            return
        end
        local id = entry_key(pos)
        if storage:get_string(id) ~= "" then
            ht.dlog("LBM : reprise de l'entrée " .. id)
            Q.process_entry(id)
        end
    end,
})

-- Reprise sur génération de chunk : si des entrées pendent encore
-- (destination dans une zone non générée au premier essai), chaque
-- chunk généré est une chance que la destination soit devenue
-- constructible. Vérification légère (un compte + horodatage, au
-- plus toutes les 10 s).
minetest.register_on_generated(function()
    local now = os.time()
    if now - last_gen_check < 10 then
        return
    end
    last_gen_check = now
    if Q.count() > 0 then
        ht.dlog("on_generated : file non vide, re-traitement")
        Q.process()
    end
end)

-- reprise au démarrage : les entrées en file au moment de l'arrêt du
-- serveur sont retraitées une fois tout chargé
minetest.register_on_mods_loaded(function()
    safe_after(10, Q.process)
end)
