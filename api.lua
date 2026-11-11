-- api.lua: shared utilities (deterministic PRNGs, scans, extenders,
-- linking of the two pads). ht.link_pads is consumed by link_queue.lua.

local ht = housetelemosaic

--
-- Seeds for deterministic draws (basements.lua convention: one
-- PcgRandom stream per use, mixed with the world seed)
--
ht.BASE_SEED = 0xBA5E4E7   -- generic stream of the mod
ht.HOUSE_SEED = 0x4A0E5EED -- chance draw per house
ht.MAZE_SEED = 0xAB1E      -- maze generator stream

-- World seed, read on demand (may change between worlds)
function ht.world_seed()
    return tonumber(minetest.get_mapgen_setting("seed")) or 0
end

-- Deterministic per-site PRNG: same world + same footprint = same
-- draws, a regenerated chunk rebuilds the same basement
function ht.house_rng(x1, y1, z1, salt)
    return PcgRandom(ht.world_seed() + salt, x1, y1, z1)
end

-- Session counters (snapshot of the current run, NOT persisted;
-- durable counters live in mod storage, see /htstats).
-- /htcheck displays them to locate where the pipeline stops:
-- each step (wrapper call -> eligible -> draw -> floor -> pad ->
-- dug -> queue -> link) has its own counter.
ht.stats = {
    calls = 0,            -- wrapper calls (every placed building)
    ineligible = 0,       -- non-house buildings (barns, wells...)
    eligible = 0,         -- eligible houses seen
    chance_skip = 0,      -- eligible rejected by the chance draw
    floors = 0,           -- detected floors
    no_floor = 0,         -- "no floor" giveups
    pads = 0,             -- scheduled pads (process_house)
    pads_dug = 0,         -- basements ACTUALLY dug (after emerge)
    queued = 0,           -- entries enqueued
    linked = 0,           -- links established
    mat_fail = 0,         -- materialize/link failures (attempts)
    provider_switch = 0,  -- fallback provider switches
    unlinked = 0,         -- definitive giveups (session)
    -- breakdown of build_basement decisions (diagnosing
    -- "chance 1.0 but rare pads": who makes the decision, and where
    -- it fails) -- /htcheck
    decisions = {
        patch_cellar = 0,   -- pad placed INSIDE the native cellar
        under_cellar = 0,   -- room under the cellar (from below)
        classic = 0,        -- classic room under a house without cellar
        deep_fallback = 0,  -- last resort F-20..F-45
        giveup_native = 0,  -- giveup: cluttered native basement
        giveup_shaft = 0,   -- giveup: no shaft column
        dig_fail = 0,       -- dig failed after emerge
    },
}

-- Deep copy (the native job must never be mutated by mistake)
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

-- Debug log (only if housetelemosaic_debug)
function ht.dlog(msg)
    if ht.settings.debug then
        minetest.log("action", "[housetelemosaic] " .. tostring(msg))
    end
end

--
-- Guarded emerge_area: on_ok only if 100% of the blocks emerged
-- successfully. Success = action >= EMERGE_FROM_MEMORY (block loaded
-- from memory, from disk or generated -- the EMERGE_OK constant
-- does not exist in the Luanti API, do not use it); failure =
-- EMERGE_CANCELLED / EMERGE_ERRORED. Callback signature:
-- callback(blockpos, action, calls_remaining).
--
local EMERGE_FROM_MEMORY = core.EMERGE_FROM_MEMORY or 2

local function emerge_action_ok(action)
    return action ~= nil and action ~= core.EMERGE_CANCELLED
        and action ~= core.EMERGE_ERRORED
        and action >= EMERGE_FROM_MEMORY
end

-- An error in an emerge callback is FATAL for the server
-- (AsyncErr on_emerge_area_completion): on_ok and on_fail are
-- always executed under pcall. If on_ok fails: error log +
-- traceback then on_fail attempted ONCE (protected); if on_fail
-- fails: log only. Never reloop.
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
                    minetest.log("error", "[housetelemosaic] on_ok "
                        .. "failed after emerge: " .. tostring(err)
                        .. "\n" .. debug.traceback())
                    if on_fail then
                        local ok2, err2 = pcall(on_fail)
                        if not ok2 then
                            minetest.log("error", "[housetelemosaic] "
                                .. "on_fail also failed: "
                                .. tostring(err2))
                        end
                    end
                end
            elseif on_fail then
                local ok, err = pcall(on_fail)
                if not ok then
                    minetest.log("error", "[housetelemosaic] on_fail "
                        .. "failed (partial emerge " .. ok_count .. "/"
                        .. total .. " blocks): " .. tostring(err)
                        .. "\n" .. debug.traceback())
                end
            else
                minetest.log("warning", "[housetelemosaic] partial emerge ("
                    .. ok_count .. "/" .. total .. " blocks) around "
                    .. minetest.pos_to_string(minp))
            end
        end
    end)
end

--
-- Node predicates (systematic nil guards)
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

-- Furniture / stairs: a "floor" candidate bearing one of these
-- prefixes is an object PLACED on the floor, not the floor (the
-- documented pitfall of scan_floor_y in biomevillages/basements.lua:
-- carpets, beds, chests, stairs elected one node too high)
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
-- GROUND FLOOR level of the house. Probes: center, rings
-- ±1/±2/±3 in cross shape and ±1 diagonals (some 5x5 carpets cover
-- the center). Valid candidate (native scan filters): walkable,
-- not furniture, node below not furniture either, 2 air above,
-- 1 walkable below, and compact foundation (anti-cave guard).
-- Returns the floor node y, or nil + the reason (logs /htcheck).
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
    -- Native window y0-5 .. y0+3 (y0 = y1-4, anchor -4), swept in
    -- ASCENDING order: the first candidate met is the lowest
    -- floor (an upper-storey floor is above the high bound and can
    -- never be elected). Do not widen downward: the slabs of native
    -- cellars (F-5k) live there -- a deeper scan would elect them
    -- as "floor"; houses without any valid probe (furnished cellar)
    -- go through the floorless mode of process_house (direct cellar
    -- patch).
    -- Anti-cave guard (simplified native foundation_solid): >= 3
    -- solid nodes out of the 4 below the candidate, otherwise move
    -- up to the next candidate of the column.
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
                    -- compact foundation? (4 solid nodes below)
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
                    -- cave floor: next candidate (move up)
                end
            end
        end
    end
    if saw_ignore then
        return nil, "ignore nodes in the window (chunk not emerged)"
    end
    return nil, "no valid floor in the y0-5..y0+3 window"
end

--
-- Telemosaic extenders
--

-- Available extender tier: three (range 80) else two (20) else
-- one (5); the need formula keeps the matching range
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

-- Number of extenders needed to cover dist from the beacon base
-- range; clamped by max_extenders (0 = unlimited). The clamp can
-- make the link impossible (insufficient range): warning.
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
            .. " extenders needed for a link at "
            .. string.format("%.0f", dist) .. " nodes, clamped to "
            .. max_n .. " (link may be impossible)")
        needed = max_n
    end
    return needed
end

-- Spiral order (center outward) of the 48 cells of the 7x7 area
-- around the beacon, center excluded -- telemosaic's check_beacon
-- only counts extenders at +/-3 XZ and y-1..y of the beacon
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

-- Slab materials placed by THIS mod (basement: cobble; maze/sky:
-- stone_block). Embedded pads require flush extenders too: a cell
-- of our own slab is therefore replaceable.
-- STRICTLY limited to these two names: never natural rock nor
-- walls (an extender in a wall would make a visual wound and a
-- possible hole if the node is not walkable).
local EMBED_FLOOR_OK = {
    ["default:cobble"] = true,
    ["default:stone_block"] = true,
}

-- Place count extenders in a square spiral around pos, at the same y,
-- in buildable nodes (air / buildable_to) or in a slab cell placed
-- by the mod (embedded pad, see EMBED_FLOOR_OK).
-- Returns the number actually placed.
function ht.place_extenders_around(pos, count)
    if count <= 0 then
        return 0
    end
    local name = resolve_extender()
    if not name then
        minetest.log("warning", "[housetelemosaic] no telemosaic "
            .. "extender registered, short link only")
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
-- Linking of the two pads: extenders placed on both sides according
-- to the distance, destinations programmed in both directions (if
-- return_enabled), get_destination check after each write.
-- Returns true if both requested links are in place.
--
function ht.link_pads(pad, dest)
    local dist = vector.distance(pad, dest)
    local needed = ht.compute_extenders_needed(dist)
    if needed > 0 then
        local n1 = ht.place_extenders_around(pad, needed)
        local n2 = ht.place_extenders_around(dest, needed)
        ht.dlog("extenders placed: " .. n1 .. " (house) + " .. n2
            .. " (destination) for " .. string.format("%.0f", dist)
            .. " nodes")
    end
    local ok = true
    pcall(telemosaic.set_destination, pad, dest)
    if not telemosaic.get_destination(pad) then
        minetest.log("warning", "[housetelemosaic] destination not "
            .. "registered on the house pad "
            .. minetest.pos_to_string(pad))
        ok = false
    end
    if ht.settings.return_enabled then
        pcall(telemosaic.set_destination, dest, pad)
        if not telemosaic.get_destination(dest) then
            minetest.log("warning", "[housetelemosaic] return link not "
                .. "registered on the destination pad "
                .. minetest.pos_to_string(dest))
            ok = false
        end
    end
    return ok
end
