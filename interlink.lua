-- interlink.lua: interlinks BETWEEN structures -- CHAINS and
-- TREES of destinations.
-- A chain starts when a house link lands on a cave or a dungeon:
-- beacons are placed a few nodes away from the arrival beacon,
-- pointing to target structures searched AROUND through a
-- synthetic job (the pattern proven by /htforce and
-- /htscanarea). Each anchor reached (house destination or chain
-- node) draws its number of branches k with DEGRESSIVE
-- probabilities: P(k) proportional to 4^-k -- P(0) = A,
-- P(1) = A/4, P(2) = A/16... up to
-- housetelemosaic_interlink_branches (A = normalization constant,
-- the law is scale-free so there is no separate "chance" setting).
-- k = 0 stops the chain; k >= 1 continues it with k beacons, each
-- branch growing independently up to
-- housetelemosaic_interlink_max_chain links per branch. The first
-- housetelemosaic_interlink_min_chain links of every branch are
-- forced (a k = 0 draw is overridden to 1 below that depth).
-- Type diversity: each entry carries the list of zone types
-- already visited by its branch; target selection prefers types
-- NOT yet visited, so a chain tends to cover cave/dungeon/sky.
-- sky is a TERMINAL node (from a cloudland, a cave/dungeon window
-- would hang in the air and sky.is_available itself refuses: a
-- sky platform is a leaf of the tree).
--
-- Trigger point: the ok_cb success branch of handle_entry
-- (link_queue.lua) calls ht.note_anchor (registry) then
-- ht.on_link_established (this file) -- same optional-hook pattern
-- as ht.note_unlinked in debug.lua. Chain continuation happens in
-- the success branch of ht.run_interlink_entry (this file).
--
-- Storage namespaces (mod storage, JSON-safe values only; excluded
-- from the queue by Q.is_queue_key):
--   anchor:<pos>  one entry per successfully materialized
--                 destination: {"kind","pos","born"}
--   ilink:<pos>   interlink record of one SOURCE anchor:
--                 {"links":[{"pad","target","born"},...]} -- the
--                 anti-duplicate guard counts #links against the
--                 branches setting
--   stats:interlink_attempted / _created / _failed  counters
--
-- Determinism: every draw uses PcgRandom streams seeded by
-- (world_seed + salt, anchor x, y, z[, branch slot]) -- a
-- regenerated chunk rebuilds the same chain; the ilink: guard
-- makes the whole flow idempotent. No math.random, no os.time in
-- geometry.

local ht = housetelemosaic

-- Self-contained seeds/counters (api.lua deliberately untouched)
local LINK_SEED = 0x11ACCE1        -- stream base
local LINK_SEED_BRANCH = 0x817C4 -- branch count draw per anchor
local LINK_SEED_DIR = 0x0130     -- push direction per slot
local LINK_SALT_PLAN = ht.BASE_SEED + 5000 -- plan selection stream

-- Sources allowed (a chain link can start FROM these): enclosed
-- rooms where a second beacon finds a spot. sky is target-only
-- (terminal leaf, see header).
local INTERLINK_SOURCES = { cave = true, dungeon = true }

-- Session counters (snapshot; durable twins live in mod storage)
ht.stats.interlink_attempted = 0 -- enqueues attempted
ht.stats.interlink_created = 0   -- interlinks established (session)
ht.stats.interlink_failed = 0    -- soft failures + definitive giveups
ht.stats.interlink_seen = 0      -- anchors offered to the trigger

local MAX_TRIES = 3
local N_BEACON = "telemosaic:beacon_off"

-- Hard validation band of a materialized target distance from its
-- source anchor. Lower bound: anti-identity only (a target closer
-- than 12 nodes is the source structure itself); the SEARCH WINDOW
-- push (interlink_min_dist) already keeps the scan away. Upper
-- bound: the REAL link range (beacon + extenders), capped by the
-- user setting -- sky targets legitimately live 400-600 nodes
-- away, the old 320 cap rejected them all
local INTERLINK_MIN_VALID = 12

local function link_range()
    local base = telemosaic.beacon_range or 20
    local tier = (telemosaic.extender_ranges
        and telemosaic.extender_ranges[3]) or 80
    local maxn = ht.settings.max_extenders
    if maxn == 0 then
        return 4096 -- unlimited setting: generous cap
    end
    return base + maxn * tier
end

-- Horizontal push directions (deterministic draw): the synthetic
-- job is pushed interlink_min_dist away from the anchor so the
-- target search window does not overlap the source structure
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- Second-beacon offsets around the arrival beacon: every (dx, dz)
-- with 3 <= sqrt(dx^2+dz^2) <= 5 (>= 3 nodes away per spec, within
-- the 3x3-open guarantee of the dungeon scan), sorted by distance
-- then by |dx|+|dz| (SPIRAL sort of api.lua, spirit)
local OFFSETS = {}
do
    for dx = -5, 5 do
        for dz = -5, 5 do
            local d2 = dx * dx + dz * dz
            if d2 >= 9 and d2 <= 25 then
                OFFSETS[#OFFSETS + 1] = {dx, dz, d2}
            end
        end
    end
    table.sort(OFFSETS, function(a, b)
        if a[3] ~= b[3] then
            return a[3] < b[3]
        end
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
end

-- Vertical order: same surface as the arrival beacon first, one
-- node up next, one node down as a last resort
local DY_ORDER = {0, 1, -1}

-- entries whose interlink materialize is IN FLIGHT (own guard: the
-- queue's inflight table is not set for routed interlink entries)
local inflight = {}

--
-- Small helpers
--

local function flat(pos)
    return {x = math.floor(pos.x), y = math.floor(pos.y),
        z = math.floor(pos.z)}
end

local function anchor_key(pos)
    return "anchor:" .. core.pos_to_string(pos)
end

local function ilink_key(pos)
    return "ilink:" .. core.pos_to_string(pos)
end

-- Persistent counter (stats:* fields, bump_unlinked pattern of
-- debug.lua; ht.mod_storage is the ONLY valid storage reference at
-- runtime -- never core.get_mod_storage() here)
local function bump_stat(suffix)
    local storage = ht.mod_storage
    if not storage then
        return
    end
    storage:set_int("stats:" .. suffix,
        storage:get_int("stats:" .. suffix) + 1)
end

-- hook called by link_queue (interlink entry purged after 12 pad
-- waits): keeps the persistent counter consistent without the
-- queue knowing the storage layout of the interlink feature
function ht.note_interlink_failed()
    bump_stat("interlink_failed")
end

-- Soft failure: nothing was enqueued, nothing was written on the
-- map -- one action log + counters. The queue's own stats
-- (unlinked, mat_fail) stay untouched
local function soft_fail(anchor, why)
    ht.stats.interlink_failed = ht.stats.interlink_failed + 1
    bump_stat("interlink_failed")
    minetest.log("action", "[housetelemosaic] interlink not created "
        .. "for anchor " .. core.pos_to_string(anchor) .. ": " .. why)
end

local function interlink_active()
    local S = ht.settings
    return S.interlink_enabled == true
        and #S.interlink_targets > 0
        and S.interlink_max_chain >= 1
end

--
-- DEGRESSIVE branch count draw: k branches with weight 4^-k,
-- k = 0..K (K = housetelemosaic_interlink_branches). Normalized:
-- P(0) = A = 1/sum(4^-k) > P(1) = A/4 > P(2) = A/16 > ...
-- Deterministic per anchor (same world + same anchor = same k).
--
-- branch slot cap (must be defined before draw_branch_count)
local function branch_slots()
    return math.max(1, math.floor(ht.settings.interlink_branches or 1))
end

local function draw_branch_count(a)
    local K = branch_slots()
    local rng = ht.house_rng(a.x, a.y, a.z,
        LINK_SEED + LINK_SEED_BRANCH)
    local r = rng:next(0, 999999) / 999999
    local total = 0
    for k = 0, K do
        total = total + 4 ^ (-k)
    end
    local acc = 0
    for k = 0, K do
        acc = acc + 4 ^ (-k)
        if r < acc / total then
            return k
        end
    end
    return K
end


--
-- Anchor registry: one storage entry per successfully materialized
-- destination (all kinds). Diagnostic only -- no routing decision,
-- but retro-usable if the feature is re-enabled later.
--

function ht.note_anchor(provider, dest_pos)
    local storage = ht.mod_storage
    if not storage or not dest_pos then
        return
    end
    local pos = flat(dest_pos)
    local key = anchor_key(pos)
    if storage:get_string(key) ~= "" then
        return -- idempotent (regenerated chunk, second house)
    end
    local ok, json = pcall(core.write_json, {
        kind = tostring(provider or "unknown"),
        pos = pos,
        born = os.time(),
    })
    if ok and type(json) == "string" then
        storage:set_string(key, json)
    end
end

--
-- Interlink records (anti-duplicate guard): {"links":[...]} per
-- source anchor, links appended on each success. The guard counts
-- #links against the branches setting (a branch slot already
-- recorded is never re-created, even after a setting change).
--

local function read_ilink(storage, a)
    local raw = storage:get_string(ilink_key(a))
    if raw == "" then
        return {links = {}}
    end
    local ok, t = pcall(core.parse_json, raw)
    if not ok or type(t) ~= "table" or type(t.links) ~= "table" then
        return {links = {}}
    end
    return t
end

local function count_anchor_links(storage, a)
    return #read_ilink(storage, a).links
end

-- pending interlink entries of this anchor occupy their slots too
-- (the ilink: record is only written on SUCCESS: two houses
-- reaching the same anchor concurrently must not create the same
-- branch slot twice). One storage iteration per spawn -- spawn is
-- rare, acceptable.
local function count_pending_anchor_slots(storage, a)
    local key = core.pos_to_string(a)
    local n = 0
    for id, raw in pairs(storage:to_table().fields) do
        if raw ~= "" and ht.queue.is_queue_key(id) then
            local ok, e = pcall(core.parse_json, raw)
            if ok and type(e) == "table"
                and e.kind == "interlink"
                and e.anchor
                and core.pos_to_string(e.anchor) == key then
                n = n + 1
            end
        end
    end
    return n
end

-- appends one link record; returns true on success
local function record_anchor_link(storage, a, link)
    local t = read_ilink(storage, a)
    t.links[#t.links + 1] = link
    local ok, json = pcall(core.write_json, t)
    if ok and type(json) == "string" then
        storage:set_string(ilink_key(a), json)
        return true
    end
    return false
end

--
-- Target selection: clone of ht.select_plan (hook.lua) restricted
-- to ht.settings.interlink_targets, with TYPE DIVERSITY: the types
-- already visited by the branch (chain) are tried LAST, so a chain
-- tends to cover cave/dungeon/sky before repeating a type.
--

local function candidate_targets(job, exclude, chain)
    local seen = {}
    if type(chain) == "table" then
        for _, k in ipairs(chain) do
            seen[k] = true
        end
    end
    local avail, fresh = {}, {}
    for _, dest in ipairs(ht.settings.interlink_targets) do
        local provider = ht.providers[dest]
        if dest ~= exclude and provider
            and provider.is_available(job) then
            avail[#avail + 1] = dest
            if not seen[dest] then
                fresh[#fresh + 1] = dest
            end
        end
    end
    -- fresh types FIRST (settings order), then the already-visited
    -- ones appended as fallbacks: a fresh sky with no island in
    -- range falls back to a visited cave instead of DEAD-ENDING
    -- the chain (the old exclusive return starved the chains of
    -- cave/sky as soon as dungeon answered first)
    for _, v in ipairs(avail) do
        if seen[v] then
            fresh[#fresh + 1] = v
        end
    end
    return fresh
end

-- anchor: the source arrival beacon (seeds the rng)
-- Returns plan, target_name (plan.provider set for traceability)
function ht.interlink_select_plan(anchor, job, offset, exclude, chain)
    local rng = ht.house_rng(anchor.x, anchor.y, anchor.z,
        LINK_SALT_PLAN + (offset or 0))
    for _, dest in ipairs(candidate_targets(job, exclude, chain)) do
        local ok, plan = pcall(ht.providers[dest].get_destination,
            job, rng)
        if ok and plan then
            plan.provider = dest
            return plan, dest
        end
        if not ok then
            minetest.log("warning", "[housetelemosaic] interlink: "
                .. "get_destination failed for " .. dest .. ": "
                .. tostring(plan))
        end
    end
    return nil, nil
end

--
-- Second beacon placement (the arrival beacon already carries the
-- destination towards its house: reusing it would destroy that
-- link -- telemosaic allows ONE destination per beacon). The
-- structure is EMERGED at call time (we run from the ok_cb of its
-- materialize), plain set_node is therefore legal.
-- Valid spot: buildable node, walkable below, 2 non-walkable
-- above (telemosaic requirement).
--

local function spot_ok(p)
    local n = minetest.get_node_or_nil(p)
    if not n then
        return false -- not loaded: cannot happen here, defensive
    end
    local def = minetest.registered_nodes[n.name]
    if not (n.name == "air" or (def and def.buildable_to)) then
        return false
    end
    local below = minetest.get_node_or_nil(
        {x = p.x, y = p.y - 1, z = p.z})
    if not below or not ht.is_walkable_name(below.name) then
        return false
    end
    for dy = 1, 2 do
        local a = minetest.get_node_or_nil(
            {x = p.x, y = p.y + dy, z = p.z})
        if not a then
            return false
        end
        local adef = minetest.registered_nodes[a.name]
        if adef and adef.walkable then
            return false
        end
    end
    return true
end

local function place_interlink_beacon(dest_pos)
    if not minetest.registered_nodes[N_BEACON] then
        return nil
    end
    for _, dy in ipairs(DY_ORDER) do
        for _, off in ipairs(OFFSETS) do
            local p = {x = dest_pos.x + off[1],
                y = dest_pos.y + dy, z = dest_pos.z + off[2]}
            if spot_ok(p) then
                minetest.set_node(p, {name = N_BEACON})
                minetest.get_meta(p):set_string(
                    "housetelemosaic:interlink", "pending")
                return p
            end
        end
    end
    return nil
end

--
-- Core of one link creation (after all guards): synthetic job +
-- target selection + second beacon + enqueueing. Returns
-- pad, target_name or nil, reason.
--   a      source anchor (flat pos)
--   depth  1-based depth of the link being created in its branch
--   chain  types visited by the branch so far (list of strings)
--   slot   branch number on this anchor (1..branches): seeds the
--          push direction so two branches diverge
--
local function start_interlink(a, depth, chain, slot)
    -- synthetic job pushed interlink_min_dist away from the
    -- anchor in a deterministic per-slot direction: the providers'
    -- scan windows open AROUND the pushed center, vertically below
    -- box.y1 = anchor.y for cave/dungeon (their own band rules
    -- keep the target clear of the source structure)
    local rng_dir = ht.house_rng(a.x, a.y, a.z,
        LINK_SEED + LINK_SEED_DIR + slot)
    local dir = DIRS[rng_dir:next(1, 4)]
    local d = math.floor(ht.settings.interlink_min_dist)
    local cx, cz = a.x + dir[1] * d, a.z + dir[2] * d
    local job = {
        -- no "_cloudlands" in the name: passes sky.is_available
        name = "interlink_dungeon",
        pos = {x = cx - 4, y = a.y, z = cz - 4},
        box = {
            x1 = cx - 4, y1 = a.y, z1 = cz - 4,
            x2 = cx + 4, y2 = a.y + 5, z2 = cz + 4,
        },
        biome_name = "unknown",
    }
    local plan, target = ht.interlink_select_plan(a, job, 0, nil,
        chain)
    if not plan then
        soft_fail(a, "no target plan available (depth " .. depth
            .. ", visited " .. table.concat(chain or {}, ">") .. ")")
        return nil, "no plan"
    end
    local pad = place_interlink_beacon(a)
    if not pad then
        soft_fail(a, "no room for a second beacon near "
            .. core.pos_to_string(a))
        return nil, "no beacon spot"
    end
    ht.stats.interlink_attempted = ht.stats.interlink_attempted + 1
    bump_stat("interlink_attempted")
    minetest.log("action", "[housetelemosaic] interlink beacon "
        .. core.pos_to_string(pad) .. " placed at anchor "
        .. core.pos_to_string(a) .. " (depth " .. depth .. "/"
        .. ht.settings.interlink_max_chain .. ", slot " .. slot
        .. "), target " .. target .. " enqueued")
    ht.queue.add({
        kind = "interlink",
        pad = pad,
        anchor = a,
        job = job,
        plan = plan,
        provider = target,
        tries = 0,
        depth = depth,
        slot = slot,
        chain = chain,
    })
    return pad, target
end

--
-- Branch spawning on an anchor. The number of branches k is drawn
-- ONCE per anchor with the degressive law P(k) ~ 4^-k (k = 0
-- stops the chain here); a k = 0 draw is overridden to 1 while the
-- depth stays <= min_chain (guaranteed diversity prefix). Existing
-- and pending links of this anchor are honored (a k never exceeds
-- what the anchor already has: a re-trigger after an abandon can
-- only complete, never duplicate). Called for house links (depth
-- 0) and after each interlink success (chain continuation).
--
local function spawn_branches(kind, dest_pos, depth, chain)
    if not interlink_active() then
        return
    end
    if not INTERLINK_SOURCES[kind] then
        ht.dlog("interlink: " .. tostring(kind)
            .. " is a terminal node (no continuation)")
        return
    end
    local new_depth = depth + 1
    if new_depth > ht.settings.interlink_max_chain then
        ht.dlog("interlink: chain at max depth ("
            .. ht.settings.interlink_max_chain .. "), stop")
        return
    end
    local storage = ht.mod_storage
    if not storage then
        return
    end
    local a = flat(dest_pos)
    ht.stats.interlink_seen = ht.stats.interlink_seen + 1
    local existing = count_anchor_links(storage, a)
        + count_pending_anchor_slots(storage, a)
    if existing >= branch_slots() then
        return -- every slot of this anchor is used
    end
    -- degressive draw: k branches with P(k) ~ 4^-k (0..K)
    local k = draw_branch_count(a)
    if k == 0 and new_depth <= ht.settings.interlink_min_chain then
        -- forced prefix: the first min_chain links of a branch
        -- always exist (k = 0 overridden to 1)
        k = 1
    end
    if k <= existing then
        ht.dlog("interlink: anchor " .. core.pos_to_string(a)
            .. " drew k=" .. k .. " (existing " .. existing
            .. "), no new branch")
        return
    end
    ht.dlog("interlink: anchor " .. core.pos_to_string(a)
        .. " drew k=" .. k .. " branch(es) (existing " .. existing
        .. "), depth " .. new_depth)
    for slot = existing + 1, k do
        start_interlink(a, new_depth, chain, slot)
    end
end

--
-- Trigger for house links: called from the ok_cb success branch
-- of handle_entry (link_queue.lua), under pcall. Starts the chain
-- from the house destination (depth 0 -> links at depth 1).
--

function ht.on_link_established(entry, dest_pos)
    if not entry or not dest_pos then
        return
    end
    if entry.kind == "interlink" then
        return -- routed entries cascade in run_interlink_entry
    end
    if not INTERLINK_SOURCES[entry.provider] then
        ht.dlog("interlink: trigger skipped (provider "
            .. tostring(entry.provider) .. ", cave/dungeon required)")
        return
    end
    spawn_branches(entry.provider, dest_pos, 0, {entry.provider})
end

--
-- /htinterlink entry point: replays the FULL interlink flow on an
-- existing cave/dungeon arrival beacon, bypassing the chance draw
-- and the branch-slot guard (test command -- the production
-- trigger keeps both). The anchor must be a telemosaic beacon.
--
function ht.force_interlink(anchor)
    local a = flat(anchor)
    local node = minetest.get_node_or_nil(a)
    if not node
        or core.get_item_group(node.name, "telemosaic") == 0 then
        return false, "no telemosaic beacon at "
            .. core.pos_to_string(a)
    end
    if not interlink_active() then
        return false, "interlink disabled or no target configured"
    end
    -- empty chain: maximum type diversity for the forced link
    local pad, target = start_interlink(a, 1, {}, 1)
    if pad then
        return true, "interlink towards " .. tostring(target)
            .. " enqueued (beacon " .. core.pos_to_string(pad)
            .. "), follow-up in the log"
    end
    return false, "interlink could not start (reason in the log)"
end

--
-- Interlink entry processing (routed from handle_entry after the
-- generic pad-presence checks; retries, persistence and resume
-- paths are shared with the queue).
--

-- Definitive giveup: silent purge (the queue's purge() is NOT
-- used -- it would bump the unlinked/mat_fail stats of the house
-- pipeline), dedicated counter, meta trace on the beacon
local function abandon(id, entry, why)
    local storage = ht.mod_storage
    if storage then
        storage:set_string(id, "")
    end
    local meta = core.get_meta(entry.pad)
    if meta then
        meta:set_string("housetelemosaic:interlink", "failed")
    end
    ht.stats.interlink_failed = ht.stats.interlink_failed + 1
    bump_stat("interlink_failed")
    minetest.log("action", "[housetelemosaic] interlink abandoned "
        .. "for " .. id .. ": " .. why)
end

-- Next target on failure (try_next_provider clone): at most as
-- many switches as configured targets, rng offset = tries for a
-- deterministic variation of the fallback plan. The chain is
-- passed along: the replacement target keeps the diversity rule.
local function try_next_target(id, entry)
    if not entry.job or not entry.job.box or not entry.anchor then
        return false
    end
    entry.fallbacks = (entry.fallbacks or 0) + 1
    if entry.fallbacks > #ht.settings.interlink_targets then
        return false
    end
    local plan, name = ht.interlink_select_plan(entry.anchor,
        entry.job, entry.tries, entry.provider, entry.chain)
    if plan and name then
        entry.plan = plan
        entry.provider = name
        entry.tries = 0
        ht.queue.save_entry(id, entry)
        minetest.log("action", "[housetelemosaic] interlink "
            .. "fallback to target " .. name .. " for " .. id)
        return true
    end
    return false
end

function ht.run_interlink_entry(id, entry)
    if inflight[id] then
        return -- already in flight for this entry
    end
    local provider = ht.providers[entry.provider]
    if not provider or type(provider.materialize) ~= "function" then
        abandon(id, entry, "provider " .. tostring(entry.provider)
            .. " without materialize")
        return
    end
    -- Protected callback (async emerge context: an uncaught error
    -- is FATAL for the server) -- handle_entry ok_cb skeleton
    local ok_cb
    ok_cb = function(ok, dest_pos)
        local ran, err = pcall(function()
            inflight[id] = nil
            if ok and dest_pos then
                -- post-materialize distance validation: the REAL
                -- link range (beacon + max extenders) is the only
                -- sound upper bound -- sky islands live 400-600
                -- nodes away and were ALL rejected by the old 320
                -- cap, caves often closer than min_dist; the lower
                -- bound only guards against identity (target =
                -- source structure)
                local dist = vector.distance(entry.anchor, dest_pos)
                if dist < INTERLINK_MIN_VALID
                    or dist > link_range() then
                    ok = false
                    minetest.log("action", "[housetelemosaic] "
                        .. "interlink target "
                        .. core.pos_to_string(dest_pos) .. " at "
                        .. string.format("%.0f", dist)
                        .. " nodes rejected (valid band ["
                        .. INTERLINK_MIN_VALID .. ","
                        .. string.format("%.0f", link_range())
                        .. "])")
                end
            end
            local storage = ht.mod_storage
            if ok and dest_pos and ht.link_pads(entry.pad, dest_pos)
                and storage then
                -- success: the target beacon is FRESH (its only
                -- destination is the interlink one; the previous
                -- links of the chain are untouched)
                ht.stats.interlink_created =
                    ht.stats.interlink_created + 1
                bump_stat("interlink_created")
                storage:set_string(id, "")
                local recorded = record_anchor_link(storage,
                    entry.anchor, {
                        pad = flat(entry.pad),
                        target = tostring(entry.provider),
                        born = os.time(),
                    })
                if not recorded then
                    minetest.log("warning", "[housetelemosaic] "
                        .. "interlink record could not be saved "
                        .. "for anchor "
                        .. core.pos_to_string(entry.anchor))
                end
                local meta = core.get_meta(entry.pad)
                if meta then
                    meta:set_string("housetelemosaic:interlink",
                        "done")
                end
                -- the new destination becomes an anchor too
                -- (diagnostic registry)
                ht.note_anchor(entry.provider, dest_pos)
                minetest.log("action", "[housetelemosaic] interlink "
                    .. "established for " .. id .. " (depth "
                    .. tostring(entry.depth) .. ", target "
                    .. entry.provider .. ", destination "
                    .. minetest.pos_to_string(dest_pos) .. ")")
                -- CHAIN CONTINUATION: the branch goes on from the
                -- new anchor (unless terminal/max depth -- decided
                -- inside spawn_branches)
                local chain = {}
                for _, k in ipairs(entry.chain or {}) do
                    chain[#chain + 1] = k
                end
                chain[#chain + 1] = tostring(entry.provider)
                spawn_branches(entry.provider, dest_pos,
                    entry.depth or 1, chain)
            elseif ok and dest_pos and not storage then
                abandon(id, entry, "mod storage unavailable")
            else
                entry.tries = entry.tries + 1
                minetest.log("action", "[housetelemosaic] "
                    .. "interlink failure for " .. id
                    .. " (attempt " .. entry.tries .. "/"
                    .. MAX_TRIES .. ", target " .. entry.provider
                    .. ")")
                if entry.tries >= MAX_TRIES then
                    if try_next_target(id, entry) then
                        ht.queue.defer(1, ht.queue.process)
                        return
                    end
                    abandon(id, entry, "no target succeeded after "
                        .. entry.tries .. " attempts")
                else
                    ht.queue.save_entry(id, entry)
                    ht.queue.defer(5, ht.queue.process)
                end
            end
        end)
        if not ran then
            inflight[id] = nil -- do not leave the entry blocked
            minetest.log("error", "[housetelemosaic] interlink "
                .. "callback failed for " .. id .. ": "
                .. tostring(err) .. "\n" .. debug.traceback())
        end
    end
    inflight[id] = true
    local ok, err = pcall(provider.materialize, entry.job, entry.plan,
        ok_cb)
    if not ok then
        minetest.log("warning", "[housetelemosaic] interlink "
            .. "materialize failed for " .. id .. ": "
            .. tostring(err))
        ok_cb(false, nil)
    end
end

--
-- Persistent snapshot for /htstats (debug.lua)
--

function ht.interlink_stats()
    local out = {
        attempted = 0,
        created = 0,
        failed = 0,
        anchors = 0,
    }
    local storage = ht.mod_storage
    if not storage then
        return out
    end
    out.attempted = storage:get_int("stats:interlink_attempted")
    out.created = storage:get_int("stats:interlink_created")
    out.failed = storage:get_int("stats:interlink_failed")
    for k, raw in pairs(storage:to_table().fields) do
        if raw ~= "" and k:sub(1, 7) == "anchor:" then
            out.anchors = out.anchors + 1
        end
    end
    return out
end
