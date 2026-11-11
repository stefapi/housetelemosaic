-- providers/cave.lua: "cave" destination.
-- Phase 1 (get_destination): serializable light plan = scan window
-- (radius ht.settings.cave_radius around the house XZ center, from
-- box.y1-60 to box.y1-20, clamped y >= -200 and y <= -1) +
-- fallback level floor_y_fallback (box.y1 - cave_depth, clamped
-- > -300 and at least 26 under the house base: the mod's basement
-- goes down at worst to y1-16, the randungeon entrance to y1-18) +
-- rng_seed bounded to 2^31-1 to break distance ties
-- deterministically AND stay exact after JSON serialization (a
-- 64-bit integer would lose precision).
-- Phase 2 (materialize): emerge_and_run of the union window +
-- fallback room, THEN a single READ-ONLY VoxelManip pass that
-- spots livable "air pockets"; if no pocket (or fallback alone
-- possible): 9x9 room dug/built in a single write VoxelManip
-- pass. The natural/artificial decision is thus made on the REAL
-- terrain state after emergence, not on a forecast.

local ht = housetelemosaic

--
-- Nodes resolved once at load time (basement.lua pattern: fallback
-- chain + warning if absent)
--
local function pick(names, what)
    for _, n in ipairs(names) do
        if minetest.registered_nodes[n] then
            return n
        end
    end
    minetest.log("warning", "[housetelemosaic] node unavailable for "
        .. what .. " (tried: " .. table.concat(names, ", ") .. ")")
    return nil
end

local N_BEACON = pick({"telemosaic:beacon_off"}, "cave beacon")
local N_STONE = pick({"default:stone"}, "artificial cave walls")
local N_COBBLE = pick({"default:cobble", "default:stone"},
    "artificial cave ground")
local N_TORCH_WALL = pick({"default:torch_wall"}, "cave wall torch")
local N_TORCH = pick({"default:torch"}, "cave floor torch")

-- Tables content_id -> {walkable, liquid}, built ON DEMAND
-- (lazy: at the first materialize, hence after on_mods_loaded, all
-- the nodes of the other mods are registered). A cid missing from
-- the table (uninstalled mod) is treated as non-walkable/non-liquid.
local cid_info = nil

local function ensure_cid_info()
    if cid_info then
        return cid_info
    end
    cid_info = {}
    for name, def in pairs(minetest.registered_nodes) do
        cid_info[minetest.get_content_id(name)] = {
            walkable = def.walkable == true,
            liquid = def.liquidtype ~= nil and def.liquidtype ~= "none",
        }
    end
    return cid_info
end

-- Horizontal directions {dx, dz, param2}: the torch is placed at
-- (pos + d) and the expected wall at (pos + 2*d). Official
-- wallmounted convention (cf. nativevillages basements.lua
-- ring_wallmounted, and default dir_to_wallmounted): param2 =
-- direction of the supporting WALL FROM the torch -- 2 = x+,
-- 3 = x-, 4 = z+, 5 = z-; a wall east (+X) of the torch ->
-- param2 = 2.
local WALL_DIRS = {
    {1, 0, 2},   -- wall east   (+X) -> param2 2
    {-1, 0, 3},  -- wall west   (-X) -> param2 3
    {0, 1, 4},   -- wall south  (+Z) -> param2 4
    {0, -1, 5},  -- wall north  (-Z) -> param2 5
}

-- Wall torch on the first solid wall found around pos, otherwise
-- floor torch placed at (pos + ox/oz) if the node below is
-- walkable. Returns true if a torch was placed.
local function place_torch(pos, floor_y, ox, oz)
    for _, d in ipairs(WALL_DIRS) do
        local t = {x = pos.x + d[1], y = pos.y, z = pos.z + d[2]}
        local m = {x = pos.x + 2 * d[1], y = pos.y, z = pos.z + 2 * d[2]}
        local tn = minetest.get_node_or_nil(t)
        local mn = minetest.get_node_or_nil(m)
        if tn and mn and tn.name == "air"
            and ht.is_walkable_name(mn.name) then
            if N_TORCH_WALL then
                minetest.set_node(t, {name = N_TORCH_WALL, param2 = d[3]})
                return true
            elseif N_TORCH then
                minetest.set_node(t, {name = N_TORCH, param2 = 1})
                return true
            end
        end
    end
    if N_TORCH then
        local p = {x = pos.x + ox, y = floor_y + 1, z = pos.z + oz}
        local below = minetest.get_node_or_nil(
            {x = p.x, y = floor_y, z = p.z})
        if below and ht.is_walkable_name(below.name) then
            minetest.set_node(p, {name = N_TORCH, param2 = 1})
            return true
        end
    end
    return false
end

--
-- Read-only VoxelManip scan: livable air pockets.
-- Each sampled column (x,z) is walked top-down over
-- precomputed indices (idx -= ystride): no find_nodes_in_area,
-- no per-node calls. A SERIES of at least 3 consecutive open
-- nodes (non-walkable and non-liquid) becomes a candidate if:
--   - the node ending the series going down (the ground) is
--     walkable and non-liquid,
--   - the node UNDER the ground (idx + ystride, under the
--     blocking node) is non-liquid (dry ground, flooded
--     pockets rejected),
--   - the CEILING (node above the series, idx +
--     (air_run+1)*ystride) is walkable and non-liquid,
--   - a 3x3 square at levels ground+1/ground+2 is entirely open
--     (beacon placement surface; also guarantees the 2
--     non-walkable nodes above required by
--     telemosaic.is_valid_destination).
-- "Open" rather than strictly "air": cave grass and plants remain
-- valid arrival surfaces, only the walkable/liquid predicate
-- matters. An index that would leave the VoxelArea (series
-- touching the emerged edge) gives data[out of bounds] = nil ->
-- nil predicate -> candidate ignored, without a Lua error.
--
local function scan_pockets(plan)
    local info = ensure_cid_info()
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(plan.minp, plan.maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()

    local cx, cz = plan.center.x, plan.center.z
    local y_top = plan.scan_max_y
    local y_bot = plan.scan_min_y

    -- sampling: step 2 if the side exceeds ~48, step 4 beyond ~96
    -- (at the extreme setting 512x512x40: ~1.6M column-nodes
    -- tested instead of 10M; the step only depends on the plan
    -- bounds, it stays deterministic). The 3x3 square, however,
    -- ALWAYS reads the real neighboring columns (x-1..x+1),
    -- sampled or not.
    local side = plan.maxp.x - plan.minp.x + 1
    local step = 1
    if side > 48 then
        step = 2
    end
    if side > 96 then
        step = 4
    end

    local ystride = area.ystride
    local candidates = {}

    for x = plan.minp.x, plan.maxp.x, step do
        for z = plan.minp.z, plan.maxp.z, step do
            -- empty window (very high house): inner loop zero
            -- iterations, no candidate
            local idx = area:index(x, y_top, z)
            local air_run = 0
            for y = y_top, y_bot, -1 do
                local inf = info[data[idx]]
                if inf and not inf.walkable and not inf.liquid then
                    air_run = air_run + 1
                else
                    -- blocking node at y: potential ground of the
                    -- finished pocket (airs occupy y+1 .. y+air_run)
                    if air_run >= 3 and inf and inf.walkable
                        and not inf.liquid then
                        -- ceiling: node ABOVE the air series (the
                        -- indices GROW with y); underground: node
                        -- under the candidate ground (idx + ystride)
                        local ceil = info[
                            data[idx + (air_run + 1) * ystride]]
                        local under = info[data[idx + ystride]]
                        if ceil and under and ceil.walkable
                            and not ceil.liquid
                            and not under.liquid then
                            local ok = true
                            for ly = y + 1, y + 2 do
                                for lx = x - 1, x + 1 do
                                    for lz = z - 1, z + 1 do
                                        local o = info[
                                            data[area:index(lx, ly, lz)]]
                                        if not o or o.walkable
                                            or o.liquid then
                                            ok = false
                                            break
                                        end
                                    end
                                    if not ok then
                                        break
                                    end
                                end
                                if not ok then
                                    break
                                end
                            end
                            if ok then
                                local dx = x - cx
                                local dz = z - cz
                                candidates[#candidates + 1] = {
                                    x = x, y = y + 1, z = z,
                                    d2 = dx * dx + dz * dz,
                                }
                                if #candidates >= 128 then
                                    return candidates
                                end
                            end
                        end
                    end
                    air_run = 0
                end
                idx = idx - ystride
            end
        end
    end
    return candidates
end

--
-- Anchoring of a natural candidate (already emerged zone,
-- set_node): beacon, 2 forced airs, 3x3 ground completed in cobble
-- if a neighbor of the ground is non-walkable (uneven ground),
-- 2 torches (wall-mounted with floor torch fallback).
--
local function anchor_candidate(c)
    if not N_BEACON then
        return nil
    end
    local floor_y = c.y - 1
    if N_COBBLE then
        for lx = c.x - 1, c.x + 1 do
            for lz = c.z - 1, c.z + 1 do
                local n = minetest.get_node_or_nil(
                    {x = lx, y = floor_y, z = lz})
                if not n or not ht.is_walkable_name(n.name) then
                    minetest.set_node({x = lx, y = floor_y, z = lz},
                        {name = N_COBBLE})
                end
            end
        end
    end
    minetest.set_node({x = c.x, y = c.y, z = c.z}, {name = N_BEACON})
    -- 2 airs guaranteed above the beacon (telemosaic requirement)
    for ly = c.y + 1, c.y + 2 do
        local p = {x = c.x, y = ly, z = c.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name ~= "air" then
            local def = minetest.registered_nodes[n.name]
            if def == nil or def.walkable then
                minetest.set_node(p, {name = "air"})
            end
        end
    end
    place_torch({x = c.x + 1, y = c.y, z = c.z}, floor_y, 1, 0)
    place_torch({x = c.x - 1, y = c.y, z = c.z}, floor_y, 0, 1)
    return {x = c.x, y = c.y, z = c.z}
end

--
-- Artificial fallback room: 7x7 interior, 9x9 footprint, dug
-- and dressed in a SINGLE VoxelManip pass (set_data +
-- write_to_map(true)) at plan.floor_y_fallback:
--   floor_y        9x9 cobble ground slab
--   floor_y+1..+3  stone wall ring, air interior
--   floor_y+4      stone ceiling
-- The volume is already emerged (the plan's minp/maxp cover the
-- union scan window + room): read_from_map there is synchronous
-- and the mapgen will not rewrite these blocks (already
-- generated). Beacon and torches via set_node after write_to_map.
--
local function build_artificial(plan)
    if not ht.settings.cave_artificial_fallback then
        ht.dlog("cave: no pocket found and artificial fallback "
            .. "disabled")
        return nil
    end
    if not (N_BEACON and N_STONE and N_COBBLE) then
        return nil
    end
    local cx, cz = plan.center.x, plan.center.z
    local fy = plan.floor_y_fallback
    local minp = {x = cx - 4, y = fy, z = cz - 4}
    local maxp = {x = cx + 4, y = fy + 4, z = cz + 4}
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local c_stone = minetest.get_content_id(N_STONE)
    local c_cobble = minetest.get_content_id(N_COBBLE)
    local c_air = minetest.get_content_id("air")

    for y = fy, fy + 4 do
        for x = cx - 4, cx + 4 do
            for z = cz - 4, cz + 4 do
                local i = area:index(x, y, z)
                local border = x == cx - 4 or x == cx + 4
                    or z == cz - 4 or z == cz + 4
                if y == fy then
                    data[i] = c_cobble
                elseif y == fy + 4 then
                    data[i] = c_stone
                elseif border then
                    data[i] = c_stone
                else
                    data[i] = c_air
                end
            end
        end
    end
    vm:set_data(data)
    vm:write_to_map(true)

    local dest = {x = cx, y = fy + 1, z = cz}
    minetest.set_node(dest, {name = N_BEACON})
    -- torches mounted on the certain walls (edge at +/-4 in
    -- stone): west torch (cx-3) -> support wall at x- -> param2 3;
    -- east torch (cx+3) -> wall at x+ -> param2 2 (convention:
    -- param2 = direction of the wall from the torch)
    if N_TORCH_WALL then
        minetest.set_node({x = cx - 3, y = fy + 2, z = cz},
            {name = N_TORCH_WALL, param2 = 3})
        minetest.set_node({x = cx + 3, y = fy + 2, z = cz},
            {name = N_TORCH_WALL, param2 = 2})
    elseif N_TORCH then
        minetest.set_node({x = cx - 3, y = fy + 1, z = cz},
            {name = N_TORCH, param2 = 1})
        minetest.set_node({x = cx + 3, y = fy + 1, z = cz},
            {name = N_TORCH, param2 = 1})
    end
    return dest
end

--
-- Complete work once the zone has emerged: scan, deterministic
-- selection (sort by distance to the house center, tie-break
-- among the best 3 via PcgRandom(plan.rng_seed): the same plan
-- always chooses the same candidate), natural anchoring or
-- artificial room.
--
local function work_emerged(plan)
    local candidates = scan_pockets(plan)
    if #candidates > 0 then
        table.sort(candidates, function(a, b)
            return a.d2 < b.d2
        end)
        local rng = PcgRandom(plan.rng_seed)
        local n = math.min(3, #candidates)
        local chosen = candidates[1]
        if n > 1 then
            chosen = candidates[rng:next(1, n)]
        end
        local dest = anchor_candidate(chosen)
        if dest then
            ht.dlog("cave: natural cave anchored at "
                .. minetest.pos_to_string(dest) .. " (" .. #candidates
                .. " pocket(s) found)")
            return dest
        end
    end
    local dest = build_artificial(plan)
    if dest then
        ht.dlog("cave: artificial room dug at "
            .. minetest.pos_to_string(dest))
    end
    return dest
end

ht.providers.cave = {
    -- always available: the artificial fallback is internal to the
    -- provider (and remains conditioned on the
    -- housetelemosaic_cave_artificial_fallback setting at build
    -- time)
    is_available = function(job)
        return true
    end,

    -- JSON-serializable light plan (flat positions + numbers).
    -- A house placed very high (y1 > 59) yields an empty scan
    -- window -> only the artificial room (y1 - cave_depth, dug
    -- into the mountain) is possible; this is represented by
    -- scan_max_y < scan_min_y (the scan loop does not run).
    get_destination = function(job, rng)
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local r = math.floor(ht.settings.cave_radius)

        -- scan window: [y1-60; y1-20], clamped >= -200 (implicit
        -- lower bound) and <= -1 (always below the surface)
        local y_high = math.min(box.y1 - 20, -1)
        local y_low = math.max(box.y1 - 60, -200)

        -- fallback level: cave_depth below box.y1, clamped > -300
        -- and at least 26 under the house base (anti-collision
        -- mod basement / randungeon)
        local fy = box.y1 - ht.settings.cave_depth
        if fy > box.y1 - 26 then
            fy = box.y1 - 26
        end
        if fy < -296 then
            fy = -296
        end

        return {
            kind = "cave",
            minp = {
                x = cx - r,
                y = math.min(y_low, fy - 1),
                z = cz - r,
            },
            maxp = {
                x = cx + r,
                y = math.max(y_high, fy + 5),
                z = cz + r,
            },
            -- real scan window (minp/maxp may have been extended
            -- in y to cover the fallback room)
            scan_min_y = y_low,
            scan_max_y = y_high,
            center = {x = cx, y = box.y1, z = cz},
            floor_y_fallback = fy,
            -- bounded to 2^31-1: stable after a JSON round trip
            rng_seed = rng:next(0, 2147483647),
        }
    end,

    materialize = function(job, plan, callback)
        ht.emerge_and_run(plan.minp, plan.maxp, function()
            local ok, dest = pcall(work_emerged, plan)
            if ok and dest then
                callback(true, dest)
            else
                if not ok then
                    minetest.log("warning", "[housetelemosaic] cave: "
                        .. "materialization failed: " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
