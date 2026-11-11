-- providers/maze.lua: "maze" destination.
-- DETERMINISTIC recursive backtracker generator on a grid of
-- W x H cells (settings maze_width/maze_height in CELLS):
-- footprint in nodes (2W+1) x (2H+1). BASE 1 numbering: cell
-- (cx,cy) -> node (2cx, 2cy), wall between adjacent cells ->
-- intermediate node (2cx+dx, 2cy+dy). Entry = cell (1,1) -> node
-- (2,2); the north wall is open at node (2,1) (above the
-- entry, always, per spec); the beacon is PLACED at the entry.
-- PcgRandom(seed, x1, z1) flow where seed = rng:next() captured
-- in the plan: the same plan regenerates EXACTLY the same maze on
-- every re-materialize (boolean grid rebuilt from the seeds).
-- Vertical coherence (doc): maze at F - maze_depth (def 25),
-- artificial cave at y1 - cave_depth (def 30, floor forced 26
-- under y1): different depths by default, never overlapping; if
-- the user sets maze_depth == cave_depth both dig at the same
-- level but a house has only ONE destination: no impact. Clamp
-- for safety y >= -280.
-- Dimension convention: origin.y = y of the maze GROUND;
-- corridors in air from origin.y+1 to origin.y+maze_height;
-- walls/enclosure solid over the same height; ceiling at
-- origin.y+maze_height+1; beacon at the entry (node (2,2)) at
-- y = origin.y+1, 2 guaranteed airs above (requirement of
-- telemosaic.is_valid_destination).

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

local N_BEACON = pick({"telemosaic:beacon_off"}, "maze beacon")
local N_FLOOR = pick({"default:stone_block", "default:stone"},
    "maze ground")
local N_WALL = pick({"default:stone"}, "maze walls")
local N_FENCE = pick({"default:desert_stone", "default:stone"},
    "maze enclosure")
local N_TORCH_WALL = pick({"default:torch_wall"}, "maze wall torch")
local N_TORCH = pick({"default:torch"}, "maze floor torch")

-- Directions {dx, dz, param2}: torch placed at (pos + d),
-- expected wall at (pos + 2d). Official wallmounted convention
-- (cf. nativevillages basements.lua ring_wallmounted, and
-- default dir_to_wallmounted): param2 = direction of the
-- supporting WALL FROM the torch -- 2 = x+, 3 = x-, 4 = z+,
-- 5 = z-; wall east (+X) of the torch -> 2.
local WALL_DIRS = {
    {1, 0, 2},   -- wall east   (+X)
    {-1, 0, 3},  -- wall west   (-X)
    {0, 1, 4},   -- wall south  (+Z)
    {0, -1, 5},  -- wall north  (-Z)
}

-- Wall torch on the first solid wall found around ref, otherwise
-- floor torch at ref if the node below is walkable. Returns true
-- if placed.
local function place_torch(ref)
    for _, d in ipairs(WALL_DIRS) do
        local t = {x = ref.x + d[1], y = ref.y, z = ref.z + d[2]}
        local m = {x = ref.x + 2 * d[1], y = ref.y, z = ref.z + 2 * d[2]}
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
        local below = minetest.get_node_or_nil(
            {x = ref.x, y = ref.y - 1, z = ref.z})
        local n = minetest.get_node_or_nil(ref)
        if below and ht.is_walkable_name(below.name) and n
            and n.name == "air" then
            minetest.set_node(ref, {name = N_TORCH, param2 = 1})
            return true
        end
    end
    return false
end

--
-- Generation of the wall grid (seeded backtracker + carrot).
-- walls[gz][gx]: true = solid wall, false = passage; gx/gz in
-- NODES base 1, 1..2W+1 / 1..2H+1. The border (enclosure) always
-- stays a wall.
-- Returns nil if the construction nodes are missing.
--
local function gen_walls(W, H, seed, x1, z1, carrot_seed)
    if not (N_WALL and N_FENCE and N_FLOOR) then
        return nil
    end
    local gw, gh = 2 * W + 1, 2 * H + 1
    local walls = {}
    for gz = 1, gh do
        local row = {}
        for gx = 1, gw do
            row[gx] = true
        end
        walls[gz] = row
    end

    local rng = PcgRandom(seed, x1, z1)
    -- visited: key cy * W + cx (cx in 1..W, cy in 1..H:
    -- injective), backtracker stack
    local visited = {}
    local stack = {}
    local cx, cy = 1, 1
    visited[cy * W + cx] = true
    stack[#stack + 1] = {cx, cy}
    walls[2 * cy][2 * cx] = false -- node (2,2): entry cell

    local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
    while #stack > 0 do
        local top = stack[#stack]
        cx, cy = top[1], top[2]
        local neigh = {}
        for _, d in ipairs(DIRS) do
            local nx, ny = cx + d[1], cy + d[2]
            if nx >= 1 and nx <= W and ny >= 1 and ny <= H
                and not visited[ny * W + nx] then
                neigh[#neigh + 1] = {nx, ny, d[1], d[2]}
            end
        end
        if #neigh == 0 then
            stack[#stack] = nil
        else
            local ch = neigh[rng:next(1, #neigh)]
            -- intermediate wall then target cell
            walls[2 * cy + ch[4]][2 * cx + ch[3]] = false
            cx, cy = ch[1], ch[2]
            walls[2 * cy][2 * cx] = false
            visited[cy * W + cx] = true
            stack[#stack + 1] = {cx, cy}
        end
    end

    -- carrot (loops): remove floor(W*H*0.08) random separator
    -- walls. A separator wall has exactly one even coordinate
    -- (gx even & gz odd, or gx odd & gz even): never both even
    -- (corner pillar), never both odd (cell).
    -- Rejection sampling: deterministic for a given carrot_seed.
    local carrot = math.floor(W * H * 0.08)
    local rng2 = PcgRandom(carrot_seed, x1, z1)
    for _ = 1, carrot do
        local gx = rng2:next(2, gw - 1)
        local gz = rng2:next(2, gh - 1)
        local is_sep = (gx % 2 == 0 and gz % 2 == 1)
            or (gx % 2 == 1 and gz % 2 == 0)
        if is_sep and walls[gz][gx] then
            walls[gz][gx] = false
        end
    end
    return walls
end

-- Exposed for /htmaze (debug.lua): complete grid for a test run
function ht.maze_grid(W, H, seed, x1, z1, carrot_seed)
    return gen_walls(W, H, seed, x1, z1, carrot_seed)
end

--
-- Writing in a SINGLE VoxelManip pass (volume already emerged):
--   ground : N_FLOOR at origin.y over the WHOLE footprint
--   body   : walls true -> N_WALL (interior) / N_FENCE
--            (enclosure); walls false -> air, from origin.y+1 to
--            origin.y+height
--   ceiling : N_WALL at origin.y+height+1 over the whole footprint
-- Then opening of the north enclosure at node (2,1) (above the
-- entry), over the corridor height. Beacon + torches via
-- set_node after write_to_map. Returns the beacon position.
--
local function write_maze(plan, walls)
    local W, H = plan.w, plan.h
    local gw, gh = 2 * W + 1, 2 * H + 1
    local o = plan.origin
    -- corridor height frozen in the plan (identical
    -- re-materialize even if the setting changes in between)
    local ch = plan.corridor_h or math.floor(ht.settings.maze_height)

    local minp = {x = o.x, y = o.y, z = o.z}
    local maxp = {x = o.x + gw - 1, y = o.y + ch + 1, z = o.z + gh - 1}
    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
    local data = vm:get_data()
    local c_floor = minetest.get_content_id(N_FLOOR)
    local c_wall = minetest.get_content_id(N_WALL)
    local c_fence = minetest.get_content_id(N_FENCE)
    local c_air = minetest.get_content_id("air")

    for gz = 1, gh do
        for gx = 1, gw do
            local x = o.x + gx - 1
            local z = o.z + gz - 1
            local border = gx == 1 or gx == gw or gz == 1 or gz == gh
            local is_wall = walls[gz][gx]
            data[area:index(x, o.y, z)] = c_floor
            for y = o.y + 1, o.y + ch do
                local i = area:index(x, y, z)
                if is_wall then
                    data[i] = border and c_fence or c_wall
                else
                    data[i] = c_air
                end
            end
            data[area:index(x, o.y + ch + 1, z)] = c_wall
        end
    end

    -- opening of the north enclosure at node (2,1): above the
    -- entry, over the corridor height (the ceiling stays solid)
    for y = o.y + 1, o.y + ch do
        data[area:index(o.x + 1, y, o.z)] = c_air
    end

    vm:set_data(data)
    vm:write_to_map(true)

    -- beacon at the entry (node (2,2)): the passage is already
    -- air over the whole height, but if maze_height < 3 we force
    -- the 2 airs above the beacon (telemosaic requirement)
    if not N_BEACON then
        return nil
    end
    local entry = {x = o.x + 1, y = o.y + 1, z = o.z + 1}
    minetest.set_node(entry, {name = N_BEACON})
    for dy = 1, 2 do
        local p = {x = entry.x, y = entry.y + dy, z = entry.z}
        local n = minetest.get_node_or_nil(p)
        if n and n.name ~= "air" then
            local def = minetest.registered_nodes[n.name]
            if def == nil or def.walkable then
                minetest.set_node(p, {name = "air"})
            end
        end
    end

    -- torches (wall otherwise floor): entry, center, opposite
    -- corner. place_torch looks for a solid wall in the 4
    -- directions; from a maze cell at least one wall separates
    -- from a neighbor (except extreme carrot: the placement is
    -- then simply skipped)
    place_torch(entry)
    place_torch({
        x = o.x + math.floor(gw / 2),
        y = o.y + 1,
        z = o.z + math.floor(gh / 2),
    })
    place_torch({x = o.x + gw - 2, y = o.y + 1, z = o.z + gh - 2})

    return entry
end

--
-- Work once emerged: regenerate the grid from the plan (same
-- backtracker, same seeds = same maze), write, anchor.
--
local function work_emerged(plan)
    local walls = gen_walls(plan.w, plan.h, plan.seed, plan.origin.x,
        plan.origin.z, plan.carrot_seed)
    if not walls then
        return nil
    end
    local dest = write_maze(plan, walls)
    if dest then
        ht.dlog("maze: maze " .. plan.w .. "x" .. plan.h
            .. " written, entry " .. minetest.pos_to_string(dest))
    end
    return dest
end

ht.providers.maze = {
    -- always available: terrain-independent (we dig)
    is_available = function(job)
        return true
    end,

    -- Complete serializable plan: everything needed to REGENERATE
    -- (dimensions, origin, seeds, entry). W/H captured at plan
    -- time: changing the setting afterwards does not break an
    -- already serialized queue entry.
    get_destination = function(job, rng)
        if not N_BEACON then
            return nil
        end
        local box = job.box
        local cx = math.floor((box.x1 + box.x2) / 2)
        local cz = math.floor((box.z1 + box.z2) / 2)

        -- F = floor level recomputed if possible, otherwise
        -- offset -4 + 1 convention -> y1 + 5 (spec)
        local F = ht.scan_floor_y(box) or (box.y1 + 5)

        -- deterministic offset against native shaft/basement
        -- column
        local ox = rng:next(-10, 10)
        local oz = rng:next(-10, 10)

        -- Square W x W grid: maze_width is the dimension in
        -- CELLS; maze_height is the VERTICAL height of the
        -- corridors (bounds 3..10), not a grid dimension
        local W = math.floor(ht.settings.maze_width)
        local H = W
        local gw = 2 * W + 1
        local gh = 2 * H + 1

        -- y of the maze GROUND: F - maze_depth, clamped >= -280
        local y = F - math.floor(ht.settings.maze_depth)
        if y < -280 then
            y = -280
        end
        -- origin = north-west corner (node (1,1)): the gw x gh
        -- footprint is centered on (cx+ox, cz+oz)
        local origin = {
            x = cx + ox - math.floor(gw / 2),
            y = y,
            z = cz + oz - math.floor(gh / 2),
        }

        return {
            kind = "maze",
            origin = origin,
            w = W,
            h = H,
            -- corridor height captured AS WELL: a re-materialize
            -- (LBM, queue) rebuilds exactly the same volume even
            -- if the setting has changed in between
            corridor_h = math.floor(ht.settings.maze_height),
            -- complete PcgRandom seeds (captured ONCE: every
            -- re-materialize regenerates the same maze)
            seed = rng:next(0, 2147483647),
            carrot_seed = rng:next(0, 2147483647),
            -- entry = node (2,2): cell (1,1)
            entry = {x = origin.x + 1, y = origin.y + 1,
                z = origin.z + 1},
        }
    end,

    materialize = function(job, plan, callback)
        local o = plan.origin
        local ch = plan.corridor_h or math.floor(ht.settings.maze_height)
        -- +1 margin around the footprint for the equipment
        -- set_node calls
        local minp = {x = o.x - 1, y = o.y - 1, z = o.z - 1}
        local maxp = {
            x = o.x + 2 * plan.w + 1,
            y = o.y + ch + 2,
            z = o.z + 2 * plan.h + 1,
        }
        ht.emerge_and_run(minp, maxp, function()
            local ok, dest = pcall(work_emerged, plan)
            if ok and dest then
                callback(true, dest)
            else
                if not ok then
                    minetest.log("warning", "[housetelemosaic] maze: "
                        .. "materialization failed: " .. tostring(dest))
                end
                callback(false, nil)
            end
        end, function()
            callback(false, nil)
        end)
    end,
}
