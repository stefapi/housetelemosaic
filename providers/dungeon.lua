-- providers/dungeon.lua: "dungeon" destination.
-- Target: a NATIVE mapgen dungeon (mg_flags dungeons), the very one
-- dungeonsplus decorates with its features (forge, library,
-- prison, alchemy lab...) and whose loot it replaces when active
-- -- pointing "towards dungeonsplus" means pointing to a native
-- dungeon room. randungeon is a second opinion: if no native
-- dungeon is found at the scan, a full randungeon dungeon is
-- generated via randungeon.make_dungeon (public API,
-- build_dungeon_from_blocks.lua:1000); as a last resort a
-- mossycobble vaulted room is built.
-- Signature of a native dungeon at the scan: floor in cobble /
-- mossycobble / stonebrick (natural cave corridors, on the other
-- hand, are raw rock) topped by at least 3 air nodes -- exactly
-- the signature used by dungeonsplus to find its rooms (gennotify
-- dungeon + floors, init.lua:151).
-- General pattern: clone of providers/cave.lua (serializable light
-- plan, emerge_and_run, read-only VoxelManip, beacon anchoring,
-- cascading fallbacks).

local ht = housetelemosaic

--
-- Nodes resolved once at load time (basement.lua pattern)
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

local N_BEACON = pick({"telemosaic:beacon_off"}, "dungeon beacon")
local N_MOSSY = pick({"default:mossycobble", "default:cobble"},
    "fallback dungeon ground")
local N_COBBLE = pick({"default:cobble", "default:stone"},
    "fallback dungeon ground (edge)")
local N_WALL = pick({"default:stonebrick", "default:stone"},
    "fallback dungeon walls")
local N_TORCH_WALL = pick({"default:torch_wall"}, "dungeon wall torch")
local N_TORCH = pick({"default:torch"}, "dungeon floor torch")

-- Is randungeon present? (optional dependency)
local RANDUNGEON = minetest.get_modpath("randungeon") ~= nil
    and type(randungeon) == "table"
    and type(randungeon.make_dungeon) == "function"

-- Native dungeons enabled in mg_flags?
local function native_dungeons_on()
    local flags = minetest.get_mapgen_setting("mg_flags") or ""
    return flags:find("dungeons", 1, true) ~= nil
end

-- Characteristic floors of native dungeons: content_ids resolved
-- on demand (lazy: after on_mods_loaded). A node replacement mod
-- (loottest0 etc.) may rename these nodes: we therefore accept ANY
-- registered node whose name contains "mossycobble" or that is
-- exactly default:cobble / default:stonebrick, plus the "desert_"
-- and "sandstone" variants of native dungeons.
local floor_cids = nil

local function ensure_floor_cids()
    if floor_cids then
        return floor_cids
    end
    floor_cids = {}
    local function add(name)
        local id = minetest.get_content_id(name)
        if id then
            floor_cids[id] = true
        end
    end
    add("default:cobble")
    add("default:mossycobble")
    add("default:stonebrick")
    add("default:desert_cobble")
    add("default:sandstonebrick")
    add("default:desert_sandstone_brick")
    add("default:silver_sandstone_brick")
    -- any replacement variant named *mossycobble*
    for name in pairs(minetest.registered_nodes) do
        if name:find("mossycobble", 1, true) then
            add(name)
        end
    end
    return floor_cids
end

-- Tables content_id -> {walkable, liquid} (cave.lua pattern)
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

-- Horizontal directions {dx, dz, param2}: wallmounted convention,
-- param2 = direction of the supporting WALL FROM the torch
-- (2 = x+, 3 = x-, 4 = z+, 5 = z-)
local WALL_DIRS = {
    {1, 0, 2},   -- wall east   (+X) -> param2 2
    {-1, 0, 3},  -- wall west   (-X) -> param2 3
    {0, 1, 4},   -- wall south  (+Z) -> param2 4
    {0, -1, 5},  -- wall north  (-Z) -> param2 5
}

-- Wall torch on the first solid wall found around pos, otherwise
-- floor torch if the node below is walkable (cave.lua clone)
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
-- Read-only VoxelManip scan: native dungeon rooms.
-- Same skeleton as cave.lua scan_pockets, with the specific
-- ground predicate: the node ending a series of at least 3 airs
-- (going down) must be a DUNGEON FLOOR (floor_cids) and the node
-- under the ground non-liquid; the ceiling (node above the
-- series) walkable and non-liquid; 3x3 square open at levels
-- ground+1 and ground+2 (beacon placement + telemosaic
-- requirement).
--
local function scan_dungeon_floors(plan)
    local info = ensure_cid_info()
    local floors = ensure_floor_cids()
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(plan.minp, plan.maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()

    local cx, cz = plan.center.x, plan.center.z
    local y_top = plan.scan_max_y
    local y_bot = plan.scan_min_y

    -- sampling identical to cave.lua: the dungeon window is
    -- bounded to 48 radius in the plan, the step stays light
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
            local idx = area:index(x, y_top, z)
            local air_run = 0
            for y = y_top, y_bot, -1 do
                local inf = info[data[idx]]
                if inf and not inf.walkable and not inf.liquid then
                    air_run = air_run + 1
                else
                    if air_run >= 3 and inf and inf.walkable
                        and not inf.liquid
                        and floors[data[idx]] then
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

-- Anchoring of a candidate: beacon + 2 guaranteed airs (the 3x3
-- was already validated at the scan, we force them in case the
-- terrain changed between the scan and the placement -- zero gap
-- in practice, defense in depth)
local function anchor_candidate(c)
    if not N_BEACON then
        return nil
    end
    local dest = {x = c.x, y = c.y, z = c.z}
    minetest.set_node(dest, {name = N_BEACON})
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
    place_torch({x = c.x + 1, y = c.y, z = c.z}, c.y - 1, 1, 0)
    place_torch({x = c.x - 1, y = c.y, z = c.z}, c.y - 1, -1, 0)
    return dest
end

--
-- Fallback randungeon dungeon: call of the public API make_dungeon
-- (synchronous if the zone is loaded -- our preliminary
-- emerge_and_run has emerged it -- otherwise it resumes via its
-- internal emerge and the queue's callback will count the
-- attempt). Modest parameters to stay fast: width 4 (40x40),
-- 3 levels, random materials.
-- The dungeon entrance (pos + a few levels) receives the beacon;
-- the player's exact arrival position is handled by telemosaic
-- (dest.y+0.5) on the entrance landing floor.
--
local function build_randungeon(plan)
    if not RANDUNGEON then
        return nil
    end
    -- dungeon anchor point: center of the window, below the
    -- scan level (the dungeon digs downward from pos.y)
    local pos = {
        x = plan.center.x,
        y = plan.scan_min_y + 10,
        z = plan.center.z,
    }
    -- zone emerged by the materialize (window + make_dungeon
    -- margin of 60: already emerges wide, we keep the plan window)
    local ok, err = pcall(randungeon.make_dungeon, pos,
        4,                    -- width (4 blocks = 40 nodes)
        nil, nil, nil, nil, nil, nil, -- materials: random
        12,                   -- dungeon_deph
        true,                 -- rim_sealed
        3,                    -- dungeon_levels
        40, 60,               -- bottom_deph, top_deph
        true,                 -- random_materials
        30,                   -- cave_percentage
        true,                 -- light_up_corridors
        true,                 -- gold_pools
        "randungeon:dungeon_treasure", -- treasure_block
        nil)                  -- dungeon_id
    if not ok then
        minetest.log("warning", "[housetelemosaic] dungeon: "
            .. "randungeon.make_dungeon failed: " .. tostring(err))
        return nil
    end
    -- arrival landing: a few nodes below the anchor point, at the
    -- dungeon center; make_dungeon digs its entrance at pos.y -
    -- top_deph; we place the beacon on the first solid ground
    -- found going down from pos.y - 2 (the dungeon roof is at
    -- ~top_deph)
    for dy = 2, 80 do
        local y = pos.y - dy
        local n = minetest.get_node_or_nil(
            {x = pos.x, y = y, z = pos.z})
        if n and ht.is_walkable_name(n.name) then
            -- ground found: beacon placed on it (the randungeon
            -- dungeon is decorated with torches by itself, we add
            -- none)
            if N_BEACON then
                local dest = {x = pos.x, y = y + 1, z = pos.z}
                minetest.set_node(dest, {name = N_BEACON})
                return dest
            end
            return nil
        end
    end
    return nil
end

--
-- Last-resort vaulted room: 7x7 interior (9x9 footprint),
-- mossycobble ground, stonebrick walls/ceiling -- the native
-- dungeon look. A single VoxelManip pass (cave.lua
-- build_artificial pattern).
--
local function build_fallback_room(plan)
    if not (N_BEACON and N_MOSSY and N_WALL) then
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
    local c_wall = minetest.get_content_id(N_WALL)
    local c_floor = minetest.get_content_id(N_MOSSY)
    local c_air = minetest.get_content_id("air")

    for y = fy, fy + 4 do
        for x = cx - 4, cx + 4 do
            for z = cz - 4, cz + 4 do
                local i = area:index(x, y, z)
                local border = x == cx - 4 or x == cx + 4
                    or z == cz - 4 or z == cz + 4
                if y == fy then
                    data[i] = c_floor
                elseif y == fy + 4 then
                    data[i] = c_wall
                elseif border then
                    data[i] = c_wall
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
-- Complete work once emerged: native dungeon scan, then
-- randungeon, then vaulted room. Deterministic selection
-- (cave.lua clone: sort by distance, tie-break
-- PcgRandom(plan.rng_seed)).
--
local function work_emerged(plan)
    local candidates = scan_dungeon_floors(plan)
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
            ht.dlog("dungeon: native dungeon anchored at "
                .. minetest.pos_to_string(dest) .. " (" .. #candidates
                .. " room(s) found)")
            return dest
        end
    end
    local dest = build_randungeon(plan)
    if dest then
        ht.dlog("dungeon: randungeon dungeon generated, entrance "
            .. minetest.pos_to_string(dest))
        return dest
    end
    dest = build_fallback_room(plan)
    if dest then
        ht.dlog("dungeon: fallback vaulted room at "
            .. minetest.pos_to_string(dest))
    end
    return dest
end

ht.providers.dungeon = {
    -- available if native dungeons exist (mg_flags dungeons,
    -- decorated by dungeonsplus if active) OR if randungeon can
    -- generate one
    is_available = function(job)
        return native_dungeons_on() or RANDUNGEON
    end,

    -- JSON-serializable light plan (cave.lua clone). Scan window
    -- bounded to 48 radius (native dungeons are common, no need
    -- to scan far: one room is enough), depth [y1-200; y1-25]
    -- clamped >= -280 / <= -10 (native dungeons live between
    -- ~-2550 and the surface, the window stays reasonable).
    get_destination = function(job, rng)
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local r = math.min(math.floor(ht.settings.cave_radius), 48)

        local y_high = math.min(box.y1 - 25, -10)
        local y_low = math.max(box.y1 - 200, -280)

        -- fallback room/randungeon level: below the scan window,
        -- at least 40 under the base (anti-collision with the
        -- artificial cave at y1-30: we go down lower)
        local fy = math.max(y_low - 40, -300)
        if fy > box.y1 - 40 then
            fy = box.y1 - 40
        end
        if fy < -300 then
            fy = -300
        end

        return {
            kind = "dungeon",
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
            scan_min_y = y_low,
            scan_max_y = y_high,
            center = {x = cx, y = box.y1, z = cz},
            floor_y_fallback = fy,
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
                    minetest.log("warning", "[housetelemosaic] dungeon: "
                        .. "materialization failed: " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
