-- hook.lua: hooks into the biomevillages placement flow.
-- SINGLE monkey-patch of biomevillages.basements.maybe_dig_basement:
-- placement.lua run_job re-reads biomevillages.basements on EVERY call
-- (placement.lua:773) and calls it under pcall for each placed house,
-- AFTER place_schematic -- the house is therefore already built when
-- the wrapper runs. Verified fallback: biomevillages.dungeon.
-- maybe_place_hidden_entrance (same convention, placement.lua:792).
-- Without either: inert mod with an explicit error log.

local ht = housetelemosaic

-- Prefixes of eligible houses (basements.lua:144 convention; jungle
-- houses register as junglehouse1-3 despite their cannibalhouse*
-- files, hence the two entries). Civic buildings (barns, wells,
-- towers...) carry none of these prefixes.
local PREFIXES = {
    -- tribal families (basements.lua convention)
    "grasslandhouse", "deserthouse", "savannahouse",
    "icehouse", "junglehouse", "cannibalhouse",
    -- extended families: names do not share the grasslandhouse
    -- prefix (town_house_large_1/2, medium, small, tiny_1/2/3,
    -- small_house_1_0, witchhouse); the "_cloudlands" exclusion
    -- below filters their floating-island variants
    "grasslandtown_house", "grasslandsmall_house",
    "savannawitchhouse",
    -- NOT "lakehouse": stilt houses anchored in water (the
    -- native mod excludes them too) -- no walkable floor below
}

function ht.is_eligible(job)
    local name = job and job.name
    if type(name) ~= "string" then
        return false
    end
    if name:find("_cloudlands", 1, true) then
        return false -- floating islands, nothing solid to dig into
    end
    for _, prefix in ipairs(PREFIXES) do
        if name:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

-- Deterministic chance draw per house (re-executed identically on a
-- regenerated chunk). Session counters -> /htcheck; action log ONLY
-- for retained houses (civic buildings and rejected draws would be
-- too verbose, they are counted).
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
        ht.dlog(job.name .. ": draw " .. draw .. " >= "
            .. ht.settings.chance .. ", rejected")
        return
    end
    minetest.log("action", "[housetelemosaic] " .. job.name .. " ("
        .. minetest.pos_to_string(job.pos) .. "): eligible, draw "
        .. string.format("%.3f", draw) .. " retained (< "
        .. ht.settings.chance .. ")")
    local copy = ht.deep_copy(job)
    -- protected: an error in a minetest.after callback is fatal
    -- for the server
    minetest.after(0.1, function()
        local ok, err = pcall(ht.process_house, copy)
        if not ok then
            minetest.log("error", "[housetelemosaic] process_house "
                .. "failed (deferred task): " .. tostring(err)
                .. "\n" .. debug.traceback())
        end
    end)
end

-- Serializable "slim" job: the native job may carry functions or
-- non-serializable references; the queue (mod storage) only needs
-- name, box, pos and biome_name (the providers' contract, they
-- only read these fields)
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

-- Chain of candidates: providers available for the house, in the
-- order of the destinations setting ("ordered" mode) or with
-- deterministic random rotation ("random" mode: same list, starting
-- point drawn by the rng). exclude: provider to leave out (queue
-- fallback chain after failure). Used by process_house AND by the
-- queue (link_queue) to recompute the next provider.
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

-- Plan selection: first candidate whose get_destination answers.
-- The rng is re-seeded per house with an offset (0 at creation,
-- incremented on each queue fallback): deterministic per house,
-- while varying the fallback variant compared to the failed
-- attempt. Sets plan.provider (JSON traceability).
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
                .. "failed for " .. dest .. ": " .. tostring(plan))
        end
    end
    return nil, nil
end

-- Basement construction + destination selection (is_available ->
-- get_destination chain with fallbacks) + enqueueing; the queue
-- (link_queue) runs materialize + ht.link_pads.
function ht.process_house(job)
    local tag = job.name .. " (" .. minetest.pos_to_string(job.pos) .. ")"
    local F, why = ht.scan_floor_y(job.box)
    if not F then
        -- FLOORLESS MODE: all probes failed (furnished native
        -- cellar covering every probe) -- instead of giving up, we
        -- attempt the
        -- DIRECT PATCH of the native cellar with an estimated F
        -- (y1+3: anchor -4 + one floor node; find_native_cellar_floor
        -- revalidates every slab anyway, an error of one or two
        -- nodes in the estimate has no effect on it)
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
                .. ": floor not found, native cellar patched "
                .. "directly, pad " .. minetest.pos_to_string(pad))
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
        minetest.log("action", "[housetelemosaic] giveup for " .. tag
            .. ": " .. tostring(why))
        return
    end
    ht.stats.floors = ht.stats.floors + 1
    minetest.log("action", "[housetelemosaic] " .. job.name
        .. ": floor detected F=" .. F)
    local pad = ht.build_basement(job, F)
    if not pad then
        return -- build_basement logs its own giveup reason
    end
    ht.stats.pads = ht.stats.pads + 1
    -- planned pad position (the actual dig is asynchronous: emerge;
    -- /htforce and /htcheck display this position in the meantime)
    ht.last_pad_planned = pad
    -- Selection: full chain with fallbacks
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
            .. minetest.pos_to_string(pad) .. " placed for " .. tag
            .. ", link " .. provider_name .. " enqueued")
    else
        minetest.get_meta(pad):set_string("housetelemosaic:state",
            "unlinked")
        minetest.log("action", "[housetelemosaic] pad "
            .. minetest.pos_to_string(pad) .. " placed but no "
            .. "destination available for " .. tag)
    end
end

--
-- The patch itself
--

local function patch_applied()
    return ht._patched ~= nil
end

function ht.install_hook()
    if patch_applied() then
        return true
    end
    if not minetest.global_exists("biomevillages") then
        minetest.log("error", "[housetelemosaic] biomevillages absent: "
            .. "inert mod")
        return false
    end
    local nv = biomevillages

    -- Source marker for /htcheck: real path of the wrapped native
    -- mod. Only one version of biomevillages exists at a time (the
    -- hypothetical "biomevillages_origin" duplicate would be visible
    -- here: different path), the two copies present on this machine
    -- are byte-for-byte identical (empty diff -rq).
    ht._source = tostring(minetest.get_modpath("biomevillages"))

    -- Main hook point, VERIFIED in placement.lua:773-780:
    -- re-reads biomevillages.basements on every run_job
    local Bs = nv.basements
    if type(Bs) == "table" and type(Bs.maybe_dig_basement) == "function" then
        local original = Bs.maybe_dig_basement
        Bs.maybe_dig_basement = function(job)
            local ok, err = pcall(original, job)
            if not ok then
                minetest.log("warning", "[housetelemosaic] native hook "
                    .. "maybe_dig_basement failed: " .. tostring(err))
            end
            local ok2, err2 = pcall(ht.handle_house, job)
            if not ok2 then
                minetest.log("warning", "[housetelemosaic] handle_house "
                    .. "failed: " .. tostring(err2))
            end
        end
        ht._patched = "basements.maybe_dig_basement"
        minetest.log("action", "[housetelemosaic] hook installed on "
            .. "biomevillages.basements.maybe_dig_basement")
        return true
    end

    -- Verified fallback: dungeon_entrances.lua:712, called under
    -- pcall by run_job (placement.lua:792-795), same guarantees
    -- (per house, after placement, job as argument)
    local D = nv.dungeon
    if type(D) == "table"
        and type(D.maybe_place_hidden_entrance) == "function" then
        local original = D.maybe_place_hidden_entrance
        D.maybe_place_hidden_entrance = function(job)
            local ok, err = pcall(original, job)
            if not ok then
                minetest.log("warning", "[housetelemosaic] native hook "
                    .. "maybe_place_hidden_entrance failed: "
                    .. tostring(err))
            end
            local ok2, err2 = pcall(ht.handle_house, job)
            if not ok2 then
                minetest.log("warning", "[housetelemosaic] handle_house "
                    .. "failed: " .. tostring(err2))
            end
        end
        ht._patched = "dungeon.maybe_place_hidden_entrance"
        minetest.log("action", "[housetelemosaic] hook installed on "
            .. "biomevillages.dungeon.maybe_place_hidden_entrance "
            .. "(fallback, basements absent)")
        return true
    end

    -- No real hook point: impossible to detect schematics placed
    -- otherwise, the mod stays inert
    minetest.log("error", "[housetelemosaic] no hook point "
        .. "found in biomevillages (basements.maybe_dig_basement "
        .. "and dungeon.maybe_place_hidden_entrance absent): inert mod")
    return false
end

-- telemosaic (hard dependency) and biomevillages (hard dependency of
-- mod.conf) are loaded before housetelemosaic; the order depends on
-- the name, so the patch is applied once all mods are initialized
minetest.register_on_mods_loaded(function()
    ht.install_hook()
end)
