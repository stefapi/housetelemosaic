-- providers/sky.lua: "cloudlands island" destination (optional
-- mod).
-- cloudlands API used (verified in cloudlands.lua:1574-1611):
--   cloudlands.find_nearest_island(x, z, search_radius) -> table
--     {x, z, radius, ...} or nil
--   cloudlands.get_height_at(x, z, [coreList]) -> y, isWater or nil
--     (y = altitude of the island GROUND; deterministic noise
--     computation)
-- cloudlands_altitude setting: REAL default 180 (settingtypes.txt
-- of the cloudlands mod, NOT 200 as the draft spec claimed).
--
-- EMERGE/GENERATION REASONING (documented here):
-- cloudlands writes its islands in ITS register_on_generated. An
-- island chunk not yet generated at house-link time might seem
-- destined to overwrite a platform placed too early.
-- BUT emerge_area GENERATES ungenerated mapblocks (and therefore
-- triggers the on_generated calls, including cloudlands') before
-- returning: after ht.emerge_and_run, the island terrain is
-- ALWAYS present if the noise computation places it there. The
-- only real uncertainty is "does the island pass exactly through
-- this (x,z) and at what y" -> we decide NOTHING in advance:
-- after the emerge, we re-read the node at island_ground_y:
--   walkable      -> the island is indeed there: stabilizing
--                    platform 3x3 + beacon + 4 torches;
--   air/non-walk. -> no island at this spot (real case: island
--                    removed by removeUnwantedIslands, or
--                    computation rounding at the edge) ->
--                    ARTIFICIAL platform 7x7 placed NOW: the
--                    chunk is generated, no future mapgen write
--                    will overwrite it (the mapgen only writes
--                    ungenerated chunks, and the only window
--                    "between emerge and set_node" cannot see a
--                    mapgen pass: emerge only returns once all
--                    the blocks are generated).
-- No risk window: documented and settled.
--
-- is_available: cloudlands present, house without "_cloudlands",
-- search radius > 0, house below the island altitude minus a
-- tolerance of 80 (island houses are already excluded by the
-- prefix in hook.lua, the guard remains a safety net).

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

local N_BEACON = pick({"telemosaic:beacon_off"}, "cloudlands beacon")
local N_PLAT = pick({"default:stone_block", "default:stone"},
    "cloudlands platform")
local N_SNOW = pick({"default:snowblock", "default:snow"},
    "platform guardrail")
local N_TORCH_WALL = pick({"default:torch_wall"}, "sky wall torch")
local N_TORCH = pick({"default:torch"}, "sky floor torch")

-- Average island altitude: real setting of the mod, default 180
local function island_altitude()
    return tonumber(minetest.settings:get("cloudlands_altitude"))
        or 180
end

--
-- Search for a DRY arrival point on the island: center then
-- ±radius/3 offsets in the 4 directions (get_height_at signals
-- water via isWater; the sampling avoids ponds; a single call per
-- offset, deterministic noise is cheap).
-- Returns {x, y, z} (y = island GROUND) or nil.
--
local function find_land(island)
    local offsets = {
        {0, 0},
        {island.radius / 3, 0},
        {0, island.radius / 3},
        {-island.radius / 3, 0},
        {0, -(island.radius / 3)},
    }
    for _, off in ipairs(offsets) do
        local x = math.floor(island.x + off[1] + 0.5)
        local z = math.floor(island.z + off[2] + 0.5)
        local y, isWater = cloudlands.get_height_at(x, z)
        if y and not isWater then
            return {x = x, y = y, z = z}
        end
    end
    return nil
end

--
-- Torch placed at p if p is air and the node below walkable:
-- torch_wall mount on the searched edge, otherwise a simple
-- floor torch. Returns true if placed.
--
local function torch_here(p)
    local n = minetest.get_node_or_nil(p)
    local below = minetest.get_node_or_nil(
        {x = p.x, y = p.y - 1, z = p.z})
    if n and below and n.name == "air"
        and ht.is_walkable_name(below.name) then
        if N_TORCH then
            minetest.set_node(p, {name = N_TORCH, param2 = 1})
            return true
        end
    end
    return false
end

--
-- Common equipment (emerged zone): beacon + 2 guaranteed airs +
-- 4 corner torches (artificial platform: corners at +/-3 of the
-- 7x7 slab; natural ground: torches around the beacon at +/-2,
-- placed only if the node below is solid -- at the edge of a
-- sloping island a torch may be skipped, no harm done).
--
local function equip_platform(platform)
    if not N_BEACON then
        return nil
    end
    minetest.set_node(platform, {name = N_BEACON})
    for dy = 1, 2 do
        local p = {x = platform.x, y = platform.y + dy, z = platform.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name ~= "air" then
            local def = minetest.registered_nodes[n.name]
            if def == nil or def.walkable then
                minetest.set_node(p, {name = "air"})
            end
        end
    end
    local corners = {{2, 2}, {-2, 2}, {2, -2}, {-2, -2}}
    for _, c in ipairs(corners) do
        torch_here({x = platform.x + c[1], y = platform.y,
            z = platform.z + c[2]})
    end
    return platform
end

--
-- 7x7 artificial platform: ONE VoxelManip pass -- stone_block
-- slab at ground_y, 2 levels of air above (the beacon and the
-- torches follow via set_node) -- then snowy guardrails at the 4
-- corners. The player arrives above any void but on solid
-- ground, at the computed level of the missing island.
--
local function build_artificial_platform(platform, ground_y)
    if not (N_BEACON and N_PLAT) then
        return nil
    end
    local minp = {x = platform.x - 3, y = ground_y, z = platform.z - 3}
    local maxp = {x = platform.x + 3, y = ground_y + 2,
        z = platform.z + 3}
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local c_plat = minetest.get_content_id(N_PLAT)
    local c_air = minetest.get_content_id("air")

    for x = minp.x, maxp.x do
        for z = minp.z, maxp.z do
            data[area:index(x, ground_y, z)] = c_plat
            data[area:index(x, ground_y + 1, z)] = c_air
            data[area:index(x, ground_y + 2, z)] = c_air
        end
    end
    vm:set_data(data)
    vm:write_to_map(true)

    -- snowy guardrails at the 4 corners (at +/-3: on the slab)
    if N_SNOW then
        local corners = {{3, 3}, {-3, 3}, {3, -3}, {-3, -3}}
        for _, c in ipairs(corners) do
            minetest.set_node({x = platform.x + c[1], y = platform.y,
                z = platform.z + c[2]}, {name = N_SNOW})
        end
    end
    return equip_platform(platform)
end

--
-- Work once emerged: re-read the ground (reasoning at the top of
-- the file). platform.y = island_ground_y + 1 -> the expected
-- ground is at platform.y - 1.
--
local function work_emerged(plan)
    local platform = plan.platform
    local ground_y = platform.y - 1
    local n = minetest.get_node_or_nil(
        {x = platform.x, y = ground_y, z = platform.z})
    if n and ht.is_walkable_name(n.name) then
        -- island present: stabilizing 3x3 stone_block platform
        -- placed via set_node at ground_y (local ground replaced
        -- for a clean arrival, the island stays intact
        -- elsewhere)
        if N_PLAT then
            for lx = platform.x - 1, platform.x + 1 do
                for lz = platform.z - 1, platform.z + 1 do
                    minetest.set_node({x = lx, y = ground_y, z = lz},
                        {name = N_PLAT})
                end
            end
        end
        ht.dlog("sky: arrival stabilized on the island at "
            .. minetest.pos_to_string(platform))
        return equip_platform(platform)
    end
    ht.dlog("sky: ground absent after emerge, artificial platform "
        .. "at " .. minetest.pos_to_string(platform))
    return build_artificial_platform(platform, ground_y)
end

ht.providers.sky = {
    is_available = function(job)
        if not minetest.global_exists("cloudlands") then
            return false
        end
        if ht.settings.sky_search_radius <= 0 then
            return false
        end
        if job and job.name and job.name:find("_cloudlands", 1, true) then
            return false
        end
        -- the house must be clearly BELOW the island altitude
        if job and job.box and job.box.y1 > island_altitude() - 80 then
            return false
        end
        return true
    end,

    -- Serializable plan: position computed ONCE (deterministic
    -- noise: a recomputation would yield the same y). link_direct
    -- = island already LOADED at plan time; get_node_or_nil does
    -- not distinguish "generated-unloaded" from "never
    -- generated" -> purely informative flag, the truth is read
    -- after the emerge in materialize (reasoning at the top of
    -- the file).
    get_destination = function(job, rng)
        if not N_BEACON then
            return nil
        end
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)
        local island = cloudlands.find_nearest_island(cx, cz,
            math.floor(ht.settings.sky_search_radius))
        if not island then
            ht.dlog("sky: no island within a radius of "
                .. ht.settings.sky_search_radius)
            return nil
        end
        local land = find_land(island)
        if not land then
            ht.dlog("sky: nearest island without a dry point "
                .. "(radius " .. ht.settings.sky_search_radius .. ")")
            return nil
        end
        local n = minetest.get_node_or_nil(land)
        local link_direct = (n ~= nil and n.name ~= "air"
            and n.name ~= "ignore")
        return {
            kind = "sky",
            platform = {x = land.x, y = land.y + 1, z = land.z},
            island = {x = island.x, z = island.z,
                radius = island.radius},
            link_direct = link_direct,
        }
    end,

    materialize = function(job, plan, callback)
        local p = plan.platform
        -- ±6 in xz / ±3 in y around the platform: covers the 7x7
        -- slab, the guardrails and the ground reads
        local minp = {x = p.x - 6, y = p.y - 3, z = p.z - 6}
        local maxp = {x = p.x + 6, y = p.y + 3, z = p.z + 6}
        ht.emerge_and_run(minp, maxp, function()
            local ok, dest = pcall(work_emerged, plan)
            if ok and dest then
                callback(true, dest)
            else
                if not ok then
                    minetest.log("warning", "[housetelemosaic] sky: "
                        .. "materialization failed: " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
