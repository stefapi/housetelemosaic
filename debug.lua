-- debug.lua: supervision chat commands. /htstats is free;
-- /htrelink, /htmaze and /htdebug require the "server" privilege.
-- /htmaze goes through the REAL provider path (materialize with a
-- plan of the same shape as get_destination): what is validated
-- in-game is exactly what the houses will receive.

local ht = housetelemosaic

-- Persistent counter of "unlinked" pads: purged entries are no
-- longer in the storage and metas are not enumerable without
-- walking the map -> a simple storage field, incremented by the
-- queue at unlinked purge time.
-- NB: get_mod_storage() returns a valid StorageRef ONLY during
-- mod load -- at runtime we read the shared reference
-- ht.mod_storage (captured at load time by link_queue.lua); the
-- code stays defensive: called from an asynchronous emerge
-- callback, it must never crash.
local function bump_unlinked()
    local storage = ht.mod_storage
    if not storage then
        ht.dlog("note_unlinked: mod storage unavailable, counter "
            .. "not incremented")
        return
    end
    storage:set_int("stats:unlinked",
        storage:get_int("stats:unlinked") + 1)
end

-- hook called by link_queue (unlinked purge): wired here to keep
-- the counter consistent without the queue knowing about debug
ht.note_unlinked = bump_unlinked

local function storage_stats()
    local total = 0
    local by_provider = {}
    -- ht.mod_storage (load-time reference) and NOT
    -- core.get_mod_storage(), which returns nil at runtime
    local storage = ht.mod_storage
    if not storage then
        return 0, {}, 0
    end
    -- stats:* excluded from the count: they are counters, not
    -- queue entries
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
    description = "housetelemosaic: link queue status",
    func = function(name)
        local total, by_provider, unlinked = storage_stats()
        local lines = { "[housetelemosaic] queue: " .. total
            .. " entry(ies), " .. unlinked .. " cumulative giveup(s)" }
        for p, n in pairs(by_provider) do
            lines[#lines + 1] = "  provider " .. p .. ": " .. n
        end
        if ht.last_basement and ht.last_basement.pad then
            local meta = minetest.get_meta(ht.last_basement.pad)
            lines[#lines + 1] = "  last pad "
                .. minetest.pos_to_string(ht.last_basement.pad)
                .. " (F=" .. ht.last_basement.F .. "): state "
                .. meta:get_string("housetelemosaic:state")
        else
            lines[#lines + 1] = "  no basement built in this session"
        end
        lines[#lines + 1] = "  hook: " .. tostring(ht._patched)
        return true, table.concat(lines, "\n")
    end,
})

minetest.register_chatcommand("htrelink", {
    description = "housetelemosaic: force queue processing",
    privs = { server = true },
    func = function(name)
        -- load-time reference (ht.mod_storage): never
        -- core.get_mod_storage() at runtime
        local storage = ht.mod_storage
        if not storage then
            return false, "[housetelemosaic] mod storage unavailable"
        end
        local n = 0
        for id, raw in pairs(storage:to_table().fields) do
            if raw ~= "" and id:sub(1, 6) ~= "stats:"
                and ht.queue.process_entry(id) then
                n = n + 1
            end
        end
        return true, "[housetelemosaic] re-processing of " .. n
            .. " entry(ies) triggered by " .. name
    end,
})

-- /htcheck: pipeline installation diagnostics, step by step. The
-- session counters (ht.stats, api.lua) tell WHERE the chain stops:
-- if calls = 0, the hook never fires (terrain already generated:
-- biomevillages only builds on NEW chunks, use /htforce); if
-- eligible = 0 but calls > 0, prefixes are at fault; if pads > 0
-- but pads_dug = 0, the emerge fails, etc.
minetest.register_chatcommand("htcheck", {
    description = "housetelemosaic: installation diagnostics "
        .. "(hook, source, session counters)",
    func = function(name)
        local s = ht.stats
        local lines = { "[housetelemosaic] diagnostics:" }
        lines[#lines + 1] = "  mod loaded: yes"
        lines[#lines + 1] = "  hook: "
            .. (ht._patched and ("installed on biomevillages."
                .. tostring(ht._patched)) or "NOT installed")
        lines[#lines + 1] = "  biomevillages source: "
            .. (ht._source or "unknown")
        lines[#lines + 1] = "  destinations: "
            .. table.concat(ht.settings.destinations, ",")
            .. " (mode " .. ht.settings.dest_mode .. ")"
        lines[#lines + 1] = "  chance=" .. ht.settings.chance
        lines[#lines + 1] = "  wrapper called: " .. s.calls .. " times"
        lines[#lines + 1] = "  eligible houses: " .. s.eligible
            .. " (non-eligible: " .. s.ineligible
            .. ", rejected by draw: " .. s.chance_skip .. ")"
        lines[#lines + 1] = "  floors detected: " .. s.floors
            .. " (floorless giveups: " .. s.no_floor .. ")"
        lines[#lines + 1] = "  pads scheduled: " .. s.pads
            .. ", ACTUALLY dug: " .. s.pads_dug
        local qtotal = 0
        if ht.queue and ht.queue.count then
            qtotal = ht.queue.count()
        end
        local _, _, unlinked_total = storage_stats()
        lines[#lines + 1] = "  queue entries (storage): " .. qtotal
            .. ", enqueued: " .. s.queued
        lines[#lines + 1] = "  links established: " .. s.linked
            .. ", attempt failures: " .. s.mat_fail
            .. ", switches: " .. s.provider_switch
            .. ", unlinked (storage cumulative): " .. unlinked_total
        local d = s.decisions or {}
        lines[#lines + 1] = "  basement decisions: cellar patched "
            .. (d.patch_cellar or 0) .. ", under cellar "
            .. (d.under_cellar or 0) .. ", classic "
            .. (d.classic or 0) .. ", deep "
            .. (d.deep_fallback or 0) .. " | giveups: native "
            .. (d.giveup_native or 0) .. ", shaft "
            .. (d.giveup_shaft or 0) .. ", dig " .. (d.dig_fail or 0)
        if s.calls == 0 then
            lines[#lines + 1] = "  >> wrapper never called: the "
                .. "explored terrain was already generated, or no "
                .. "village. Test /htforce under your feet then "
                .. "explore NEW terrain."
        elseif s.pads_dug == 0 and s.pads > 0 then
            lines[#lines + 1] = "  >> pads scheduled but never dug: "
                .. "check the emerge warnings in debug.txt"
        end
        -- the report is ALSO written to a world file: openable in
        -- any text editor (copying from the Luanti chat is not
        -- always possible)
        local ok, err = pcall(function()
            local worldpath = minetest.get_worldpath()
            local f = io.open(worldpath .. "/htcheck_report.txt", "w")
            if not f then
                error("cannot open htcheck_report.txt")
            end
            f:write(table.concat(lines, "\n") .. "\n")
            f:close()
        end)
        if ok then
            lines[#lines + 1] = "  report written: "
                .. minetest.get_worldpath() .. "/htcheck_report.txt"
        else
            lines[#lines + 1] = "  (report writing impossible: "
                .. tostring(err) .. ")"
        end
        return true, table.concat(lines, "\n")
    end,
})

-- /htforce: tests the WHOLE pipeline at the player's position,
-- without waiting for a new village to generate. Builds the
-- synthetic job {box 9x6x9 grounded under the player,
-- name="grasslandhouse1", biome_name="unknown"} and runs the
-- complete process_house (floor -> basement -> queue -> link).
-- The chat reports each step (the same action logs as the natural
-- pipeline, replayed to the player).
minetest.register_chatcommand("htforce", {
    description = "housetelemosaic: forces a telemosaic basement + pad "
        .. "under the player's position (full pipeline test)",
    privs = { server = true },
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[housetelemosaic] player not found"
        end
        local pp = player:get_pos()
        -- ground: first walkable node under the player's feet
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
            return false, "[housetelemosaic] no ground found under "
                .. name .. " within 40 nodes"
        end
        -- synthetic job: box 9x6x9 centered on the player, grounded
        -- (y1 = ground + 1: the interior above the ground, like a
        -- house anchored at offset -4 whose floor is ~y1+4;
        -- F will be found by scan_floor_y; scan_floor_y scans down
        -- to y1-8, the player's ground stays in the window)
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
        minetest.chat_send_player(name, "[housetelemosaic] /htforce: "
            .. "ground detected at y=" .. ground .. ", box 9x6x9 at ("
            .. (cx - 4) .. "," .. y1 .. "," .. (cz - 4) .. ")")
        -- full pipeline run by replaying the steps one by one to
        -- the chat: floor, then process_house (which logs pad +
        -- queue), then the queue unrolls asynchronously (its
        -- action logs go to the journal; /htstats gives its state)
        local F, why = ht.scan_floor_y(job.box)
        if not F then
            return false, "[housetelemosaic] no floor in the test "
                .. "box: " .. tostring(why)
        end
        minetest.chat_send_player(name, "[housetelemosaic] floor F=" .. F)
        local ok, err = pcall(ht.process_house, job)
        if not ok then
            return false, "[housetelemosaic] process_house failed: "
                .. tostring(err)
        end
        if ht.last_pad_planned then
            minetest.chat_send_player(name, "[housetelemosaic] pad planned "
                .. minetest.pos_to_string(ht.last_pad_planned)
                .. ": dug as soon as the emerge completes (~1 s), then "
                .. "linked by the queue (head provider "
                .. table.concat(ht.settings.destinations, ",")
                .. "). Dig/look under your feet; /htstats for the "
                .. "state, /htcheck for the counters")
            return true, "[housetelemosaic] full pipeline triggered "
                .. "(follow-up in debug.txt)"
        end
        return false, "[housetelemosaic] pad not scheduled (reason in "
            .. "debug.txt: native collision, no shaft column...)"
    end,
})

-- /htmaze <x> <y> <z> [<w> [<h>]]: test maze at the given
-- position (w x h CELLS, defaults 15x15; these are cell counts,
-- parity does not matter). FIXED seeds (world +
-- MAZE_SEED) for visual reproducibility. (server priv)
minetest.register_chatcommand("htmaze", {
    description = "housetelemosaic: test maze at <x> <y> "
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
            return false, "usage: /htmaze <x> <y> <z> [<w> [<h>]] "
                .. "(cells, def 15 15)"
        end
        local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
        local W = math.max(3, math.min(tonumber(ws) or 15, 51))
        local H = math.max(3, math.min(tonumber(hs) or W, 51))
        -- plan of the same shape as get_destination (fixed seeds)
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
                    "[housetelemosaic] maze " .. W .. "x" .. H
                    .. " generated, entry "
                    .. minetest.pos_to_string(dest))
            else
                minetest.chat_send_player(name,
                    "[housetelemosaic] generation failed (see log)")
            end
        end)
        return true, "[housetelemosaic] generation started at ("
            .. x .. ", " .. y .. ", " .. z .. ")"
    end,
})

minetest.register_chatcommand("htdebug", {
    description = "housetelemosaic: toggles debug mode",
    privs = { server = true },
    func = function()
        ht.settings.debug = not ht.settings.debug
        local state = ht.settings.debug and "enabled" or "disabled"
        return true, "[housetelemosaic] debug " .. state
    end,
})

-- /htaudit [<radius>] [fix|report]: audits (and by default repairs)
-- the basements already built by the mod around the player.
-- Targets the HOUSE pads (meta housetelemosaic:state) -- the
-- providers' arrival beacons do not carry this meta. Repairs:
--  R1 ladder: missing rungs completed down to y_floor+1
--  R2 shaft: ladder completed up to F-1 (first walkable floor
--     above), trapdoor placed if the F floor stayed solid
--  R3 cellar mode: air passage x2 above the ladder top when the
--     node above is a slab, bearing wall to the north
--  R4 beacon placed ON the slab and not linked -> embedded (meta
--     copied over)
-- "report": diagnostics without writing. (server priv)
local LADDER_NAMES = {
    ["default:ladder_wood"] = true,
    ["default:ladder"] = true,
}

minetest.register_chatcommand("htaudit", {
    description = "housetelemosaic: audits/repairs already built "
        .. "basements around the player (/htaudit [radius] [fix|report])",
    privs = { server = true },
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[housetelemosaic] player not found"
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
            return true, "[housetelemosaic] no telemosaic beacon "
                .. "within a radius of " .. radius
        end
        local lines = { "[housetelemosaic] audit of " .. #found
            .. " beacon(s) (mode " .. (fix and "FIX" or "REPORT") .. "):" }
        local pads = 0
        for _, pos in ipairs(found) do
            if pads >= 20 then
                lines[#lines + 1] = "  (limit of 20 pads: relaunch "
                    .. "elsewhere)"
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
                -- y_floor: embedded beacon (neighbor = slab) or
                -- standing (below = slab)
                local side = minetest.get_node_or_nil(
                    {x = bx + 1, y = by, z = bz})
                local below = minetest.get_node_or_nil(
                    {x = bx, y = by - 1, z = bz})
                local y_floor
                if side and ht.is_walkable_name(side.name) then
                    y_floor = by -- embedded in the slab
                elseif below and ht.is_walkable_name(below.name) then
                    y_floor = by - 1 -- standing on the slab
                    if fix and not linked then
                        -- R4: embed the unlinked beacon
                        local newp = {x = bx, y = y_floor, z = bz}
                        minetest.set_node(newp,
                            {name = "telemosaic:beacon_off"})
                        local m2 = minetest.get_meta(newp)
                        m2:set_string("housetelemosaic:state", state)
                        N("beacon embedded in the slab")
                    else
                        N("beacon placed ON the slab"
                            .. (linked and " (linked, not moved)" or ""))
                    end
                else
                    N("beacon without identifiable slab: skipped")
                end
                if y_floor then
                    -- room center: corner diagonally opposite the
                    -- beacon, the one whose 9x9 floor is the
                    -- fullest
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
                        N("room not identified (" .. best_n
                            .. "/81 slab cells)")
                    else
                        -- ladder columns of the 7x7 interior
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
                            N("no ladder in the room")
                        end
                        for _, c in ipairs(cols) do
                            -- R5: bearing wall missing behind the
                            -- rungs (param2 = direction of the WALL
                            -- from the ladder: 2 = x+, 3 = x-,
                            -- 4 = z+, 5 = z-); a non-walkable node
                            -- behind a rung = floating ladder, we
                            -- place a stonebrick pillar (inside the
                            -- 7x7 interior)
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
                                    N("bearing pillar rebuilt behind "
                                        .. "the ladder (" .. c.x .. "," .. c.z
                                        .. ", " .. missing .. " node(s))")
                                end
                            end
                            -- R1: missing rungs down to y_floor+1
                            if c.lo > y_floor + 1 then
                                if fix then
                                    for y = y_floor + 1, c.lo - 1 do
                                        minetest.set_node(
                                            {x = c.x, y = y, z = c.z},
                                            {name = "default:ladder_wood",
                                                param2 = c.p2})
                                    end
                                end
                                N("ladder (" .. c.x .. "," .. c.z
                                    .. ") completed downward")
                            end
                            -- above the highest rung: slab
                            -- (cellar mode, R3) or shaft to complete
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
                                N("cellar passage pierced above "
                                    .. "the ladder (" .. c.x .. "," .. c.z
                                    .. ")")
                            else
                                -- R2: shaft up to the first floor
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
                                    N("shaft completed (" .. c.x .. ","
                                        .. c.z .. ") up to F=" .. F)
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
                                        N("trapdoor placed at F=" .. F)
                                    end
                                else
                                    N("ladder (" .. c.x .. "," .. c.z
                                        .. ") without floor above "
                                        .. "(open shaft)")
                                end
                            end
                        end
                    end
                end
                lines[#lines + 1] = "  pad (" .. bx .. "," .. by .. ","
                    .. bz .. ") [" .. state .. "]: "
                    .. (#notes > 0 and table.concat(notes, " ; ")
                        or "OK nothing to report")
            end
        end
        if pads == 0 then
            lines[#lines + 1] = "  no house pad (mod meta) found"
        end
        return true, table.concat(lines, "\n")
    end,
})

-- /htscanarea [<radius>]: RETROFIT of houses already placed around
-- the player (the natural pipeline only equips NEWLY generated
-- ones). Detection: biomevillages:* furniture (dynamic list
-- rebuilt from registered_nodes: resistant to mod updates), placed
-- INSIDE by the schematics; clustering by XZ proximity, each
-- cluster of >= 2 pieces of furniture counts as a house, box =
-- furniture footprint + margin 6, then complete process_house
-- (floor -> basement -> queue -> link). Anti-duplicate: a box
-- already containing a node of the telemosaic group is skipped.
-- Limits: radius 16..128 nodes, vertical window ±32, 30 houses max
-- per pass (relaunch for the rest). A house without ANY native
-- furniture is not detected.
minetest.register_chatcommand("htscanarea", {
    description = "housetelemosaic: equips houses already placed "
        .. "around the player (radius in nodes, def. 64)",
    privs = { server = true },
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[housetelemosaic] player not found"
        end
        local radius = math.max(16, math.min(
            math.floor(tonumber(param) or 64), 128))
        local pp = player:get_pos()
        local cx, cy, cz = math.floor(pp.x), math.floor(pp.y),
            math.floor(pp.z)
        local minp = {x = cx - radius, y = cy - 32, z = cz - radius}
        local maxp = {x = cx + radius, y = cy + 32, z = cz + radius}
        minetest.chat_send_player(name, "[housetelemosaic] scanning "
            .. (radius * 2) .. "x64x" .. (radius * 2)
            .. " around you, emerging...")
        ht.emerge_and_run(minp, maxp, function()
            -- native furniture: complete dynamic list
            local names = {}
            for reg in pairs(minetest.registered_nodes) do
                if reg:sub(1, 14) == "biomevillages:" then
                    names[#names + 1] = reg
                end
            end
            if #names == 0 then
                minetest.chat_send_player(name,
                    "[housetelemosaic] no biomevillages:* node "
                    .. "registered: nothing to detect")
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
                    "[housetelemosaic] no biomevillages furniture "
                    .. "in the radius: no house detected")
                return
            end
            -- greedy clustering by XZ distance (< 24 nodes)
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
            -- house processing: >= 2 pieces of furniture, not
            -- already equipped
            local equipped, skipped, processed = 0, 0, 0
            for _, cl in ipairs(clusters) do
                if cl.n < 2 then
                    skipped = skipped + 1 -- isolated furniture (altar, lost barrel)
                elseif processed >= 30 then
                    skipped = skipped + 1 -- pass quota
                else
                    processed = processed + 1
                    local box = {
                        x1 = cl.x1 - 6, y1 = cl.ylow - 4, z1 = cl.z1 - 6,
                        x2 = cl.x2 + 6, y2 = cl.ylow + 8, z2 = cl.z2 + 6,
                    }
                    -- anti-duplicate: already a telemosaic pad in the box?
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
                        -- last_pad_planned keeps the previous
                        -- processing value on failure: compare
                        -- before/after
                        local before = ht.last_pad_planned
                        local ok = pcall(ht.process_house, job)
                        if ok and ht.last_pad_planned ~= before then
                            equipped = equipped + 1
                        end
                    end
                end
            end
            minetest.chat_send_player(name,
                "[housetelemosaic] retrofit: " .. equipped
                .. " house(s) equipped, " .. skipped
                .. " skipped (isolated/already equipped/quota)."
                .. (processed >= 30 and " Relaunch for the rest."
                    or ""))
        end, function()
            minetest.chat_send_player(name,
                "[housetelemosaic] emerging impossible around "
                .. name .. ": try again")
        end)
        return true, "[housetelemosaic] scan started (result in a "
            .. "few seconds)"
    end,
})
