-- hook.lua : accroche sur le flux de placement de biomevillages.
-- Monkey-patch UNIQUE de biomevillages.basements.maybe_dig_basement :
-- placement.lua run_job relit biomevillages.basements à CHAQUE appel
-- (placement.lua:773) et l'appelle sous pcall pour chaque maison posée,
-- APRÈS place_schematic -- la maison est donc déjà construite quand le
-- wrapper tourne. Fallback vérifié : biomevillages.dungeon.
-- maybe_place_hidden_entrance (même convention, placement.lua:792).
-- Sans les deux : mod inerte avec un log d'erreur explicite.

local ht = housetelemosaic

-- Préfixes des maisons éligibles (convention basements.lua:144 ; les
-- maisons jungle s'enregistrent junglehouse1-3 malgré leurs fichiers
-- cannibalhouse*, d'où les deux entrées). Les bâtiments civiques
-- (étables, puits, tours...) ne portent aucun de ces préfixes.
local PREFIXES = {
    -- familles tribales (convention basements.lua)
    "grasslandhouse", "deserthouse", "savannahouse",
    "icehouse", "junglehouse", "cannibalhouse",
    -- familles élargies : les noms ne partagent pas le préfixe
    -- grasslandhouse (town_house_large_1/2, medium, small, tiny_1/2/3,
    -- small_house_1_0, witchhouse) ; l'exclusion "_cloudlands"
    -- ci-dessous filtre leurs variantes d'îles flottantes
    "grasslandtown_house", "grasslandsmall_house",
    "savannawitchhouse",
    -- PAS "lakehouse" : maisons sur pilotis ancrées dans l'eau (le
    -- natif les exclut aussi) -- aucun plancher marchable dessous
}

function ht.is_eligible(job)
    local name = job and job.name
    if type(name) ~= "string" then
        return false
    end
    if name:find("_cloudlands", 1, true) then
        return false -- îles flottantes, rien de solide à creuser
    end
    for _, prefix in ipairs(PREFIXES) do
        if name:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

-- Tirage chance déterministe par maison (ré-exécutable à l'identique
-- sur un chunk régénéré). Compteurs de session -> /htcheck ; log
-- action UNIQUEMENT pour les maisons retenues (les bâtiments civiques
-- et les tirages écartés seraient trop verbeux, ils sont comptés).
function ht.handle_house(job)
    ht.stats.calls = ht.stats.calls + 1
    if not job or not job.box or not job.pos then
        return
    end
    if not ht.is_eligible(job) then
        ht.stats.ineligible = ht.stats.ineligible + 1
        return
    end
    ht.stats.eligible = ht.stats.eligible + 1
    local rng = ht.house_rng(job.box.x1, job.box.y1, job.box.z1,
        ht.HOUSE_SEED)
    local draw = rng:next(0, 999999) / 999999
    if draw >= ht.settings.chance then
        ht.stats.chance_skip = ht.stats.chance_skip + 1
        ht.dlog(job.name .. " : tirage " .. draw .. " >= "
            .. ht.settings.chance .. ", écarté")
        return
    end
    minetest.log("action", "[housetelemosaic] " .. job.name .. " ("
        .. minetest.pos_to_string(job.pos) .. ") : éligible, tirage "
        .. string.format("%.3f", draw) .. " retenu (< "
        .. ht.settings.chance .. ")")
    local copy = ht.deep_copy(job)
    -- protégé : une erreur dans un callback minetest.after est
    -- fatale pour le serveur
    minetest.after(0.1, function()
        local ok, err = pcall(ht.process_house, copy)
        if not ok then
            minetest.log("error", "[housetelemosaic] process_house a "
                .. "échoué (tâche différée) : " .. tostring(err)
                .. "\n" .. debug.traceback())
        end
    end)
end

-- Job "mince" sérialisable : le job natif peut porter des fonctions
-- ou des références non sérialisables ; la file (mod storage) n'a
-- besoin que de name, box, pos et biome_name (contrat des providers,
-- qui ne lisent que ces champs)
local function slim_job(job)
    return {
        name = job.name,
        pos = {x = job.pos.x, y = job.pos.y, z = job.pos.z},
        box = {
            x1 = job.box.x1, y1 = job.box.y1, z1 = job.box.z1,
            x2 = job.box.x2, y2 = job.box.y2, z2 = job.box.z2,
        },
        biome_name = job.biome_name,
    }
end

-- Chaîne de candidats : providers disponibles pour la maison, dans
-- l'ordre du setting destinations (mode "ordered") ou avec rotation
-- aléatoire déterministe (mode "random" : même liste, point de
-- départ tiré par le rng). exclude : provider à écarter (chaîne de
-- fallback de la file après échec). Utilisé par process_house ET par
-- la file (link_queue) pour recalculer le provider suivant.
function ht.candidate_providers(job, rng, exclude)
    local avail = {}
    for _, dest in ipairs(ht.settings.destinations) do
        local provider = ht.providers[dest]
        if dest ~= exclude and provider
            and provider.is_available(job) then
            avail[#avail + 1] = dest
        end
    end
    if ht.settings.dest_mode == "random" and rng and #avail > 1 then
        local start = rng:next(1, #avail)
        local rotated = {}
        for i = 1, #avail do
            rotated[i] = avail[((start + i - 2) % #avail) + 1]
        end
        return rotated
    end
    return avail
end

-- Sélection du plan : premier candidat dont get_destination répond.
-- Le rng est re-seedé par maison avec un offset (0 à la création,
-- incrémenté à chaque fallback dans la file) : déterministe par
-- maison, tout en variant la variante de secours par rapport à la
-- tentative échouée. Positionne plan.provider (traçabilité JSON).
function ht.select_plan(job, offset, exclude)
    local rng = ht.house_rng(job.box.x1, job.box.y1, job.box.z1,
        ht.BASE_SEED + (offset or 0))
    for _, dest in ipairs(ht.candidate_providers(job, rng, exclude)) do
        local ok, plan = pcall(ht.providers[dest].get_destination,
            job, rng)
        if ok and plan then
            plan.provider = dest
            return plan, dest
        end
        if not ok then
            minetest.log("warning", "[housetelemosaic] get_destination "
                .. "a échoué pour " .. dest .. " : " .. tostring(plan))
        end
    end
    return nil, nil
end

-- Construction du sous-sol + sélection de destination (chaîne
-- is_available -> get_destination avec fallbacks) + mise en file ;
-- la file (link_queue) déroule materialize + ht.link_pads.
function ht.process_house(job)
    local tag = job.name .. " (" .. minetest.pos_to_string(job.pos) .. ")"
    local F, why = ht.scan_floor_y(job.box)
    if not F then
        -- MODE SANS PLANCHER : toutes les sondes ont échoué (cellier
        -- natif meublé couvrant chaque sonde) -- au lieu d'abandonner,
        -- on tente le
        -- PATCH DIRECT du cellier natif avec un F estimé (y1+3 :
        -- ancrage -4 + un node de plancher ; find_native_cellar_floor
        -- revalide chaque dalle de toute façon, une erreur d'une ou
        -- deux nodes sur l'estimation est sans effet sur lui)
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local pad
        if ht.find_native_cellar_floor and ht.patch_cellar then
            local est_F = box.y1 + 3
            local cellar = ht.find_native_cellar_floor(cx, cz, est_F, box)
            if cellar then
                pad = ht.patch_cellar(job, box, cellar, cx, cz)
            end
        end
        if pad then
            ht.stats.decisions.patch_cellar
                = ht.stats.decisions.patch_cellar + 1
            ht.stats.pads = ht.stats.pads + 1
            ht.stats.pads_dug = ht.stats.pads_dug + 1
            ht.last_pad_planned = pad
            minetest.log("action", "[housetelemosaic] " .. job.name
                .. " : plancher introuvable, cellier natif patché "
                .. "directement, pad " .. minetest.pos_to_string(pad))
            local plan, provider_name = ht.select_plan(job, 0)
            if plan and provider_name then
                ht.stats.queued = ht.stats.queued + 1
                ht.queue.add({
                    pad = pad,
                    job = slim_job(job),
                    plan = plan,
                    provider = provider_name,
                    tries = 0,
                })
            end
            return
        end
        ht.stats.no_floor = ht.stats.no_floor + 1
        minetest.log("action", "[housetelemosaic] abandon pour " .. tag
            .. " : " .. tostring(why))
        return
    end
    ht.stats.floors = ht.stats.floors + 1
    minetest.log("action", "[housetelemosaic] " .. job.name
        .. " : plancher détecté F=" .. F)
    local pad = ht.build_basement(job, F)
    if not pad then
        return -- build_basement logge sa raison d'abandon propre
    end
    ht.stats.pads = ht.stats.pads + 1
    -- position prévue du pad (le dig réel est asynchrone : emerge ;
    -- /htforce et /htcheck affichent cette position en attendant)
    ht.last_pad_planned = pad
    -- Sélection : chaîne complète avec fallbacks
    local plan, provider_name = ht.select_plan(job, 0)
    if plan and provider_name then
        ht.stats.queued = ht.stats.queued + 1
        ht.queue.add({
            pad = pad,
            job = slim_job(job),
            plan = plan,
            provider = provider_name,
            tries = 0,
        })
        minetest.log("action", "[housetelemosaic] pad "
            .. minetest.pos_to_string(pad) .. " posé pour " .. tag
            .. ", liaison " .. provider_name .. " mise en file")
    else
        minetest.get_meta(pad):set_string("housetelemosaic:state",
            "unlinked")
        minetest.log("action", "[housetelemosaic] pad "
            .. minetest.pos_to_string(pad) .. " posé mais aucune "
            .. "destination disponible pour " .. tag)
    end
end

--
-- Le patch proprement dit
--

local function patch_applied()
    return ht._patched ~= nil
end

function ht.install_hook()
    if patch_applied() then
        return true
    end
    if not minetest.global_exists("biomevillages") then
        minetest.log("error", "[housetelemosaic] biomevillages absent : "
            .. "mod inerte")
        return false
    end
    local nv = biomevillages

    -- Marqueur de source pour /htcheck : chemin réel du mod natif
    -- wrappé. Une seule version de biomevillages existe à la fois
    -- (l'hypothétique doublon "biomevillages_origin" serait visible
    -- ici : chemin différent), les deux copies présentes sur cette
    -- machine sont identiques au byte près (diff -rq vide).
    ht._source = tostring(minetest.get_modpath("biomevillages"))

    -- Point d'accroche principal, VÉRIFIÉ dans placement.lua:773-780 :
    -- relit biomevillages.basements à chaque run_job
    local Bs = nv.basements
    if type(Bs) == "table" and type(Bs.maybe_dig_basement) == "function" then
        local original = Bs.maybe_dig_basement
        Bs.maybe_dig_basement = function(job)
            local ok, err = pcall(original, job)
            if not ok then
                minetest.log("warning", "[housetelemosaic] hook natif "
                    .. "maybe_dig_basement a échoué : " .. tostring(err))
            end
            local ok2, err2 = pcall(ht.handle_house, job)
            if not ok2 then
                minetest.log("warning", "[housetelemosaic] handle_house a "
                    .. "échoué : " .. tostring(err2))
            end
        end
        ht._patched = "basements.maybe_dig_basement"
        minetest.log("action", "[housetelemosaic] hook installé sur "
            .. "biomevillages.basements.maybe_dig_basement")
        return true
    end

    -- Fallback vérifié : dungeon_entrances.lua:712, appelé sous pcall
    -- par run_job (placement.lua:792-795), mêmes garanties (par maison,
    -- après placement, job en argument)
    local D = nv.dungeon
    if type(D) == "table"
        and type(D.maybe_place_hidden_entrance) == "function" then
        local original = D.maybe_place_hidden_entrance
        D.maybe_place_hidden_entrance = function(job)
            local ok, err = pcall(original, job)
            if not ok then
                minetest.log("warning", "[housetelemosaic] hook natif "
                    .. "maybe_place_hidden_entrance a échoué : "
                    .. tostring(err))
            end
            local ok2, err2 = pcall(ht.handle_house, job)
            if not ok2 then
                minetest.log("warning", "[housetelemosaic] handle_house a "
                    .. "échoué : " .. tostring(err2))
            end
        end
        ht._patched = "dungeon.maybe_place_hidden_entrance"
        minetest.log("action", "[housetelemosaic] hook installé sur "
            .. "biomevillages.dungeon.maybe_place_hidden_entrance "
            .. "(fallback, basements absent)")
        return true
    end

    -- Aucun point d'accroche réel : impossible de détecter les
    -- schematics posés autrement, le mod reste inerte
    minetest.log("error", "[housetelemosaic] aucun point d'accroche "
        .. "trouvé dans biomevillages (basements.maybe_dig_basement "
        .. "et dungeon.maybe_place_hidden_entrance absents) : mod inerte")
    return false
end

-- telemosaic (dépendance dure) et biomevillages (dépendance dure du
-- mod.conf) sont chargés avant housetelemosaic ; l'ordre dépend du nom,
-- le patch est donc posé une fois tous les mods initialisés
minetest.register_on_mods_loaded(function()
    ht.install_hook()
end)
