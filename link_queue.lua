-- link_queue.lua: pad -> destination link queue, persisted in mod
-- storage. materialize at the provider's then
-- ht.link_pads; after 3 failures, tries the NEXT PROVIDER of the
-- chain (recomputed from the job, failing provider excluded, rng
-- re-seeded with offset = tries: deterministic per house) before
-- declaring "unlinked"; LBM on pending beacons to resume orphaned
-- entries when chunks load; light resume on on_generated
-- (10 s throttle).
--
-- Serialization contract: entry = {pad (flat pos), job (slim:
-- name/pos/box/biome_name), plan (JSON-safe, providers' contract),
-- provider (string), tries (number)}. The slim job is built by
-- hook.lua slim_job(); old entries (deep-copied job) stay
-- readable: only the consumed fields are accessed.

local ht = housetelemosaic

-- UNIQUE mod storage reference, captured HERE at load time:
-- get_mod_storage() returns a valid StorageRef only during mod
-- loading; called at runtime (emerge callback, after...), it
-- returns nil and any indexing crashes. NEVER call
-- get_mod_storage() outside of load time: use this shared
-- reference (ht.mod_storage, consumed by debug.lua).
local storage = core.get_mod_storage()
ht.mod_storage = storage
local Q = {}
ht.queue = Q

-- re-entrancy protection: process can be triggered by add(), by a
-- deferred callback, by the LBM or by /htrelink while it is
-- already running
local processing = false
local rerun = false

-- entries whose materialize is IN FLIGHT (asynchronous callback
-- not yet returned): a double trigger of the SAME entry (LBM at
-- chunk load during a deferred retry, /htrelink during a process)
-- does not start a second work site in parallel -- the build would
-- be identical (deterministic plans) but doubled in cost and in
-- link_pads calls
local inflight = {}

-- throttle of the on_generated resume (at most every 10 s)
local last_gen_check = 0

local MAX_TRIES = 3

local function entry_key(pad)
    return core.pos_to_string(pad)
end

-- Storage key namespaces: queue entries are keyed by plain position
-- strings; "stats:" (counters), "anchor:" and "ilink:" (interlink
-- registries, interlink.lua) are reserved and never processed as
-- entries
function Q.is_queue_key(id)
    return id:sub(1, 6) ~= "stats:"
        and id:sub(1, 7) ~= "anchor:"
        and id:sub(1, 6) ~= "ilink:"
end

-- Serialization: job, pad, plan and tries must only contain
-- positions, numbers, strings and flat lists (contract honored:
-- slim_job on the hook side, JSON-safe plans on the provider side)
local function save_entry(id, entry)
    local ok, json = pcall(core.write_json, entry)
    if ok and type(json) == "string" then
        storage:set_string(id, json)
    else
        minetest.log("error", "[housetelemosaic] cannot serialize "
            .. id .. ": " .. tostring(json))
    end
end

-- Protected deferred task: a Lua error surfacing in a
-- minetest.after callback is fatal for the server; we log with
-- traceback and return.
local function safe_after(delay, fn)
    minetest.after(delay, function()
        local ok, err = pcall(fn)
        if not ok then
            minetest.log("error", "[housetelemosaic] deferred task "
                .. "failed: " .. tostring(err) .. "\n"
                .. debug.traceback())
        end
    end)
end

-- exposed for interlink.lua: protected deferral (identical to the
-- queue's own retries) and entry persistence
Q.defer = safe_after
Q.save_entry = save_entry

function Q.add(entry)
    if not entry or not entry.pad or not entry.provider then
        minetest.log("warning", "[housetelemosaic] invalid queue "
            .. "entry, ignored")
        return
    end
    entry.tries = entry.tries or 0
    -- creation timestamp: distinguishes entries from the current
    -- flow (pad possibly still being dug asynchronously) from
    -- entries inherited from earlier sessions (born absent)
    entry.born = os.time()
    local id = entry_key(entry.pad)
    save_entry(id, entry)
    ht.dlog("entry added: " .. id .. " (provider " .. entry.provider
        .. ")")
    Q.process()
end

local function purge(id, entry, state)
    storage:set_string(id, "")
    local meta = core.get_meta(entry.pad)
    if meta then
        meta:set_string("housetelemosaic:state", state)
    end
    -- persistent counter for /htstats (wired by debug.lua; the
    -- queue does not know about debug, just the optional hook)
    if state == "unlinked" then
        ht.stats.unlinked = ht.stats.unlinked + 1
        if type(ht.note_unlinked) == "function" then
            ht.note_unlinked()
        end
    end
end

--
-- next provider on failure: recomputes the candidate chain from
-- the job excluding the failing provider, rng re-seeded with
-- offset = tries (same house salt + deterministic variation: the
-- Nth attempt of a house always yields the same fallback plan).
-- Replaces the entry's plan; returns true if a replacement was
-- found.
--
local function try_next_provider(id, entry)
    if not entry.job or not entry.job.box then
        return false
    end
    -- anti ping-pong safeguard: at most as many switches as there
    -- are configured destinations (a house cannot keep cycling
    -- forever on providers that all fail)
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
        minetest.log("action", "[housetelemosaic] fallback switch "
            .. "to provider " .. name .. " for " .. id)
        return true
    end
    return false
end

local function handle_entry(id, entry)
    if inflight[id] then
        return -- already in flight for this entry
    end
    -- Pad not placed yet? Three cases: dig still in flight (fresh
    -- entries: the asynchronous basement digging can outrun the
    -- queue), chunk not loaded (get_node -> "ignore", typically at
    -- startup for persisted entries), or ghost pad (dig that never
    -- completed, e.g. server stopped during the emerge). We
    -- re-check in 5 s WITHOUT consuming an attempt or
    -- re-materializing; after a dozen postponements (~1 min), the
    -- entry is purged -- a real dig never takes that long
    local pad_node = core.get_node(entry.pad)
    if core.get_item_group(pad_node.name, "telemosaic") == 0 then
        entry.waits = (entry.waits or 0) + 1
        if entry.waits >= 12 then
            minetest.log("action", "[housetelemosaic] entry " .. id
                .. " purged: no pad beacon at this position ("
                .. pad_node.name .. " after " .. entry.waits
                .. " checks)")
            if entry.kind == "interlink" then
                -- silent purge: purge() would bump the house
                -- pipeline's unlinked counter and write the wrong
                -- meta on an interlink beacon (interlink.lua owns
                -- its own stats and metas)
                storage:set_string(id, "")
                local m = core.get_meta(entry.pad)
                if m then
                    m:set_string("housetelemosaic:interlink", "failed")
                end
                if ht.stats.interlink_failed then
                    ht.stats.interlink_failed =
                        ht.stats.interlink_failed + 1
                end
                if type(ht.note_interlink_failed) == "function" then
                    pcall(ht.note_interlink_failed)
                end
            else
                purge(id, entry, "unlinked")
            end
        else
            save_entry(id, entry)
            safe_after(5, function()
                Q.process_entry(id)
            end)
        end
        return
    end
    -- interlink entries (interlink.lua): the generic pad-presence
    -- checks above have run, the flow is then routed to the
    -- dedicated handler -- retries, persistence, inflight guard and
    -- the resume paths stay shared with the queue
    if entry.kind == "interlink" then
        if type(ht.run_interlink_entry) == "function" then
            ht.run_interlink_entry(id, entry)
        else
            minetest.log("warning", "[housetelemosaic] interlink "
                .. "entry without handler, purged: " .. id)
            storage:set_string(id, "")
        end
        return
    end
    local provider = ht.providers[entry.provider]
    if not provider or type(provider.materialize) ~= "function" then
        minetest.log("warning", "[housetelemosaic] provider "
            .. tostring(entry.provider) .. " without materialize, entry "
            .. id .. " purged")
        purge(id, entry, "unlinked")
        return
    end
    -- Protected materialize callback: it is invoked at the deepest
    -- level of an asynchronous emerge callback, where any
    -- uncaught Lua error is FATAL for the server (AsyncErr); we
    -- log with traceback and return.
    local ok_cb
    ok_cb = function(ok, dest_pos)
        local ran, err = pcall(function()
            inflight[id] = nil
            if ok and dest_pos and ht.link_pads(entry.pad, dest_pos) then
                ht.stats.linked = ht.stats.linked + 1
                purge(id, entry, "linked")
                minetest.log("action", "[housetelemosaic] link established "
                    .. "for " .. id .. " (provider " .. entry.provider
                    .. ", destination "
                    .. minetest.pos_to_string(dest_pos) .. ")")
                -- optional hooks (interlink.lua): anchor registry +
                -- interlink trigger -- same pattern as
                -- ht.note_unlinked (function field, pcall). A hook
                -- error NEVER breaks the link itself; it is logged
                -- (not swallowed) so the interlink pipeline stays
                -- diagnosable
                if type(ht.note_anchor) == "function" then
                    local okh, errh = pcall(ht.note_anchor,
                        entry.provider, dest_pos)
                    if not okh then
                        minetest.log("warning", "[housetelemosaic] "
                            .. "note_anchor hook failed: "
                            .. tostring(errh))
                    end
                end
                if entry.kind ~= "interlink"
                    and type(ht.on_link_established) == "function" then
                    local okh, errh = pcall(ht.on_link_established,
                        entry, dest_pos)
                    if not okh then
                        minetest.log("warning", "[housetelemosaic] "
                            .. "on_link_established hook failed: "
                            .. tostring(errh))
                    end
                end
            else
                entry.tries = entry.tries + 1
                ht.stats.mat_fail = ht.stats.mat_fail + 1
                minetest.log("action", "[housetelemosaic] "
                    .. "materialize/link failure for " .. id .. " (attempt "
                    .. entry.tries .. "/" .. MAX_TRIES .. ", provider "
                    .. entry.provider .. ")")
                if entry.tries >= MAX_TRIES then
                    -- last resort: the next provider in the chain,
                    -- before the definitive giveup
                    if try_next_provider(id, entry) then
                        safe_after(1, Q.process)
                        return
                    end
                    minetest.log("warning", "[housetelemosaic] link "
                        .. "abandoned for " .. id .. " after "
                        .. entry.tries .. " attempts (provider "
                        .. entry.provider .. ")")
                    purge(id, entry, "unlinked")
                else
                    save_entry(id, entry)
                    safe_after(5, Q.process)
                end
            end
        end)
        if not ran then
            inflight[id] = nil -- do not leave the entry blocked
            minetest.log("error", "[housetelemosaic] link callback "
                .. "failed for " .. id .. ": " .. tostring(err)
                .. "\n" .. debug.traceback())
        end
    end
    inflight[id] = true
    local ok, err = pcall(provider.materialize, entry.job, entry.plan,
        ok_cb)
    if not ok then
        minetest.log("warning", "[housetelemosaic] materialize failed "
            .. "for " .. id .. ": " .. tostring(err))
        ok_cb(false, nil)
    end
end

-- Processing of ONE entry (public: the LBM re-triggers a specific
-- entry when its beacon loads; /htrelink uses it too)
function Q.process_entry(id)
    -- reserved prefixes (stats:, anchor:, ilink:) are not entries
    if not Q.is_queue_key(id) then
        return false
    end
    local raw = storage:get_string(id)
    if raw == "" then
        return false
    end
    local ok, entry = pcall(core.parse_json, raw)
    if not ok or type(entry) ~= "table" or not entry.pad then
        minetest.log("warning", "[housetelemosaic] corrupted entry "
            .. "purged: " .. id)
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
    -- reserved prefixes excluded: stats:* are counters and
    -- anchor:*/ilink:* are interlink registries, not entries
    -- (otherwise Q.process would purge them as "corrupted")
    for id, raw in pairs(storage:to_table().fields) do
        if raw ~= "" and Q.is_queue_key(id) then
            local ok, entry = pcall(core.parse_json, raw)
            if ok and type(entry) == "table" and entry.pad then
                handle_entry(id, entry)
            else
                minetest.log("warning", "[housetelemosaic] corrupted "
                    .. "entry purged: " .. id)
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
        if raw ~= "" and Q.is_queue_key(k) then
            n = n + 1
        end
    end
    return n
end

--
-- Resume LBM: a pending beacon whose entry STILL exists in
-- storage (the pad has not been linked yet) re-triggers its entry
-- when its chunk loads -- typically the server stopped during an
-- in-flight materialize. The "unlinked"/"linked" metas do
-- nothing. nodenames = telemosaic group (beacon_off and
-- beacon, the two states of the pad).
--
minetest.register_lbm({
    name = "housetelemosaic:beacon",
    label = "Resume housetelemosaic links",
    nodenames = {"group:telemosaic"},
    run_at_every_load = true,
    action = function(pos)
        local meta = core.get_meta(pos)
        if meta:get_string("housetelemosaic:state") ~= "pending" then
            return
        end
        local id = entry_key(pos)
        if storage:get_string(id) ~= "" then
            ht.dlog("LBM: resuming entry " .. id)
            Q.process_entry(id)
        end
    end,
})

-- Resume on chunk generation: if entries are still pending
-- (destination in an area not generated at the first attempt),
-- every generated chunk is a chance that the destination has
-- become buildable. Light check (a count + timestamp, at most
-- every 10 s).
minetest.register_on_generated(function()
    local now = os.time()
    if now - last_gen_check < 10 then
        return
    end
    last_gen_check = now
    if Q.count() > 0 then
        ht.dlog("on_generated: queue not empty, re-processing")
        Q.process()
    end
end)

-- resume at startup: entries queued at the time the server
-- stopped are reprocessed once everything is loaded
minetest.register_on_mods_loaded(function()
    safe_after(10, Q.process)
end)
