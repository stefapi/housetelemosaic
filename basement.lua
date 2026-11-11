-- basement.lua: construction of the telemosaic basement (room + access
-- shaft + house beacon + trapdoor). Exact dimensions (effective
-- basement_depth = 5 by default, structural minimum):
--   F            house floor (intact except the shaft trapdoor)
--   F-1          9x9 crowning ring (edge only), center = ladder
--   F-2          y_ceiling: 9x9 stonebrick ceiling slab (pierced at
--                the center by the shaft); y_ceiling = y_floor + 4
--   F-5..F-3     room interior: 3 air (y_floor+1 .. y_floor+3)
--   F-5          y_floor+1: walkable ground; beacon at room center,
--                non-walkable ladder above then air: valid
--                destination for the return link
--   F-6          y_floor: 9x9 cobble ground slab
--   y_floor      = F - basement_depth - 1 (depth 5 -> F-6)
-- Total XZ footprint: 9x9 (stonebrick walls at +/-4 from the
-- center, 7x7 interior). The 1x1 shaft pierces F-1 and F-2 at
-- (sx, sz); the ladder (default:ladder_wood, wallmounted: param2 =
-- direction of the support, table 2=x+ 3=x- 4=z+ 5=z-; shaft
-- placed against z-, param2 = 5) goes down from F-1 to
-- y_floor+2; a stonebrick pillar at (sx, sz-1) carries the ladder
-- inside the room.
-- Invariant I5: anti-collision offset if a native basement
-- (basements.lua) or a randungeon entrance already occupies the
-- column.

local ht = housetelemosaic

local HALF = 4          -- walls at +/-4: 7x7 interior, 9x9 footprint
local MIN_DEPTH = 5     -- ceiling at F-2 minimum, ground at F-6 minimum

--
-- Nodes resolved once at load time, with fallback chains
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

local N_WALL = pick({"default:stonebrick", "default:stone"}, "walls")
local N_FLOOR = pick({"default:cobble", "default:stone"}, "room ground")
local N_LADDER = pick({"default:ladder_wood", "default:ladder"},
    "shaft ladder")
local N_TRAPDOOR = pick({"doors:trapdoor_wood", "doors:trapdoor",
    "doors:trapdoor_steel"}, "shaft trapdoor")
local N_BEACON = pick({"telemosaic:beacon_off"}, "telemosaic beacon")
local N_TORCH_WALL = pick({"default:torch_wall"}, "wall torch")
local N_TORCH = pick({"default:torch"}, "floor torch")

local function is_door_name(name)
    return name:find("door", 1, true) ~= nil
end

local function node_name(x, y, z)
    local n = minetest.get_node_or_nil({x = x, y = y, z = z})
    return n and n.name or nil
end

local function is_open(name)
    if name == nil or name == "ignore" then
        return false
    end
    local def = minetest.registered_nodes[name]
    return def ~= nil and not def.walkable
end

-- Invariant I5: does a native basement (air/furnishing) or a
-- randungeon entrance (trapdoors/pre-digging) already occupy the
-- zone? Probe the central column + the 4 corners + the 4 edge
-- midpoints of the 9x9 footprint (9 columns: the native 1x2 shaft
-- and its landings rarely take out all nine at once), from F-3
-- (under our F-2 ceiling) down to min(F-14, y_floor-1); plus a
-- door/trapdoor test on the shaft column at levels F..F+2.
local function native_collision(cx, cz, F, y_floor)
    local bottom = math.min(F - 14, y_floor - 1)
    local cols = {
        {cx, cz},
        {cx - HALF, cz - HALF}, {cx + HALF, cz - HALF},
        {cx - HALF, cz + HALF}, {cx + HALF, cz + HALF},
        {cx - HALF, cz}, {cx + HALF, cz},
        {cx, cz - HALF}, {cx, cz + HALF},
    }
    for _, col in ipairs(cols) do
        for y = F - 3, bottom, -1 do
            local name = node_name(col[1], y, col[2])
            if name == "air" or name == "default:ladder_wood"
                or name == "default:ladder" then
                return true
            end
        end
    end
    for _, y in ipairs({F, F + 1, F + 2}) do
        local name = node_name(cx, y, cz)
        if name and is_door_name(name) then
            return true
        end
    end
    return false
end

-- FREE room zone (deep last resort): unlike native_collision, only
-- probes the footprint of the future room
-- (y_floor-1 .. y_floor+5: slab, interior, ceiling, crowning)
-- on the 9 columns -- the terrain ABOVE is not tested, it is the
-- shaft's job to cross it cleanly (shaft_column_full below).
-- Used for the last resort: native_collision probes the whole
-- column above the room and would see the cellar air or the
-- randungeon shaft, condemning every depth.
local function chamber_zone_free(cx, cz, y_floor)
    local cols = {
        {cx, cz},
        {cx - 3, cz - 3}, {cx + 3, cz - 3},
        {cx - 3, cz + 3}, {cx + 3, cz + 3},
        {cx - 3, cz}, {cx + 3, cz},
        {cx, cz - 3}, {cx, cz + 3},
    }
    for _, col in ipairs(cols) do
        for y = y_floor - 1, y_floor + 5 do
            local name = node_name(col[1], y, col[2])
            if name == "air" or name == "default:ladder_wood"
                or name == "default:ladder" then
                return false
            end
        end
    end
    return true
end

-- DEEP shaft column: same election as shaft_column (F walkable,
-- 2 air, no door) BUT the column F-1..y_bottom must be SOLID
-- terrain (no air/ladder: we must only drill through rock, never
-- cross the native cellar or the randungeon shaft destroying their
-- ladder). Returns sx, sz or nil.
local function shaft_column_full(cx, cz, F, y_bottom)
    local offsets = {-1, 1, -2, 2, -3, 3}
    for _, dx in ipairs(offsets) do
        for _, dz in ipairs(offsets) do
            local sx, sz = cx + dx, cz + dz
            local f0 = node_name(sx, F, sz)
            local f1 = node_name(sx, F + 1, sz)
            local f2 = node_name(sx, F + 2, sz)
            if f0 and f1 and f2 and ht.is_walkable_name(f0)
                and not is_door_name(f0)
                and is_open(f1) and is_open(f2)
                and not is_door_name(f1) and not is_door_name(f2) then
                local clear = true
                for y = y_bottom + 1, F - 1 do
                    local name = node_name(sx, y, sz)
                    if name == "air" or name == "default:ladder_wood"
                        or name == "default:ladder"
                        or name == "ignore" then
                        clear = false
                        break
                    end
                end
                if clear then
                    return sx, sz
                end
            end
        end
    end
    return nil
end

-- Low slab of a possible NATIVE cellar (the cellar fills the whole
-- interior, margin 2, slabs at F-k*5 for k = 1..3, low slab
-- therefore between F-5 and F-15): the deepest
-- y of [F-22 .. F-4] such that node(y) is a walkable slab
-- (window starting at F-4, NEVER F-2/F-3: that is the house floor
-- itself -- a match on the floor placed the pad on the ground
-- floor instead of the cellar; the highest native slab
-- is at F-5)
-- and node(y+1)/node(y+2) are air (level interior), probe over
-- SEVERAL columns of the interior (center + ring): a single
-- column would often land on the native ladder shaft, a landing
-- or a piece of furniture and miss the whole cellar. In solid
-- terrain without a cellar, no y matches (compact foundation
-- guaranteed by foundation_solid on the native side); a residual
-- cave would match — connecting from below a cave remains a valid
-- landing.
ht.find_native_cellar_floor = function(cx, cz, F, box)
    local probes = {
        {cx, cz},
        {cx - 2, cz}, {cx + 2, cz}, {cx, cz - 2}, {cx, cz + 2},
        {cx - 4, cz - 4}, {cx + 4, cz - 4},
        {cx - 4, cz + 4}, {cx + 4, cz + 4},
    }
    local found = nil
    for _, col in ipairs(probes) do
        local px, pz = col[1], col[2]
        -- stay inside the house interior (margin 2, MARGIN
        -- convention of basements.lua) so as not to probe the walls
        if box and (px < box.x1 + 2 or px > box.x2 - 2
            or pz < box.z1 + 2 or pz > box.z2 - 2) then
            -- outside the interior: column ignored
        else
            for y = F - 4, F - 22, -1 do
                local n0 = node_name(px, y, pz)
                local n1 = node_name(px, y + 1, pz)
                local n2 = node_name(px, y + 2, pz)
                if ht.is_walkable_name(n0 or "")
                    and is_open(n1) and is_open(n2) then
                    if not found or y < found then
                        found = y -- the DEEPEST of the matches
                    end
                    break -- first slab of this column is enough
                end
            end
        end
    end
    return found
end

-- Ladder column of the native cellar (to keep the future pad at a
-- distance): first ladder column found inside the cellar interior
-- at the low level (air cellar_floor+1..+4). Returns {x, z} or nil.
local function find_cellar_ladder(box, cellar_floor)
    local ix1, ix2 = box.x1 + 2, box.x2 - 2
    local iz1, iz2 = box.z1 + 2, box.z2 - 2
    if ix2 < ix1 or iz2 < iz1 then
        return nil
    end
    for x = ix1, ix2 do
        for z = iz1, iz2 do
            for y = cellar_floor + 1, cellar_floor + 4 do
                local n = node_name(x, y, z)
                if n == "default:ladder_wood" or n == "default:ladder" then
                    return {x = x, z = z}
                end
            end
        end
    end
    return nil
end

-- DIRECT PATCH of the native cellar: places the beacon EMBEDDED in
-- the slab of the lowest level, in a free cell (2 air, walkable
-- ground, at >= 3 nodes from the native ladder). 3x3 cobble
-- stabilization slab (makes the slab replaceable by the extenders,
-- see EMBED_FLOOR_OK in api.lua), 2 torches. No excavation, no
-- shaft: the native trapdoor and ladder already serve the house.
-- Returns pad_pos or nil (cellar too cluttered). Synchronous: the
-- cellar zone is within the house footprint, already emerged by
-- biomevillages.
ht.patch_cellar = function(job, box, cellar_floor, cx, cz)
    if not N_BEACON then
        return nil
    end
    local lad = find_cellar_ladder(box, cellar_floor)
    local ix1, ix2 = box.x1 + 2, box.x2 - 2
    local iz1, iz2 = box.z1 + 2, box.z2 - 2
    -- candidates: cells of the low level with 2 air above the
    -- slab and far enough from the native ladder; a walkable piece
    -- of furniture (chest, barrel, carpet) on the cell breaks the
    -- air test
    local best, best_key = nil, -1
    for x = ix1, ix2 do
        for z = iz1, iz2 do
            local a1 = node_name(x, cellar_floor + 1, z)
            local a2 = node_name(x, cellar_floor + 2, z)
            local fl = node_name(x, cellar_floor, z)
            if fl and a1 and a2 and ht.is_walkable_name(fl)
                and is_open(a1) and is_open(a2) then
                local dl = 99
                if lad then
                    dl = math.abs(x - lad.x) + math.abs(z - lad.z)
                end
                if dl >= 3 then
                    -- preference: far from the ladder, near the center
                    local dcx = x - cx
                    local dcz = z - cz
                    local key = dl * 1000 - (dcx * dcx + dcz * dcz)
                    if key > best_key then
                        best_key = key
                        best = {x = x, z = z}
                    end
                end
            end
        end
    end
    if not best then
        ht.dlog("cellar patch impossible: no free cell at the low "
            .. "level of " .. job.name)
        return nil
    end
    -- 3x3 cobble stabilization slab (replaces the native
    -- cobble/desert_sand ground: homogeneous zone, replaceable by
    -- the extenders)
    if N_FLOOR then
        for dx = -1, 1 do
            for dz = -1, 1 do
                minetest.set_node({x = best.x + dx, y = cellar_floor,
                    z = best.z + dz}, {name = N_FLOOR})
            end
        end
    end
    -- embedded beacon (flush with the cellar slab)
    local pad = {x = best.x, y = cellar_floor, z = best.z}
    minetest.set_node(pad, {name = N_BEACON})
    local meta = minetest.get_meta(pad)
    meta:set_string("housetelemosaic:state", "pending")
    meta:set_string("housetelemosaic:job", minetest.pos_to_string(
        {x = box.x1, y = box.y1, z = box.z1}))
    meta:set_string("housetelemosaic:mode", "patch_cellar")
    -- 2 torches placed at the corners of the slab
    if N_TORCH then
        for _, d in ipairs({{-1, -1}, {1, 1}}) do
            minetest.set_node({x = best.x + d[1], y = cellar_floor + 1,
                z = best.z + d[2]}, {name = N_TORCH, param2 = 1})
        end
    end
    minetest.log("action", "[housetelemosaic] native cellar patched for "
        .. job.name .. ": pad " .. minetest.pos_to_string(pad)
        .. (lad and (" (native ladder at " .. (math.abs(best.x - lad.x)
            + math.abs(best.z - lad.z)) .. " nodes)") or ""))
    return pad
end

-- Election of the shaft column (sx, sz): growing rings around the
-- center up to +/-4 (small footprints -- tiny houses -- often
-- offer no free column in the +/-2 ring). There must be a
-- walkable floor at F and no door/trapdoor; above it, a
-- NON-walkable replaceable node (carpet, plant, torch -- never a
-- door, trapdoor, bed or liquid) is CLEARED to place the trapdoor.
-- The CENTER is not a candidate: the room beacon is embedded there
-- (see dig), so the shaft always lands away from the pad.
local function shaft_column(cx, cz, F)
    local rings = {{0, 0},
        {0, -1}, {1, 0}, {0, 1}, {-1, 0},
        {1, -1}, {1, 1}, {-1, 1}, {-1, -1},
        {0, -2}, {2, 0}, {0, 2}, {-2, 0},
        {1, -2}, {2, -1}, {2, 1}, {1, 2}, {-1, 2}, {-2, 1},
        {-2, -1}, {-1, -2},
        {0, -3}, {3, 0}, {0, 3}, {-3, 0},
        {0, -4}, {4, 0}, {0, 4}, {-4, 0}}
    local function clearable(name)
        if name == nil or name == "ignore" then
            return false
        end
        if is_door_name(name) or name:find("bed", 1, true) then
            return false
        end
        local def = minetest.registered_nodes[name]
        return def ~= nil and not def.walkable
            and def.liquidtype == "none"
    end
    for _, off in ipairs(rings) do
        local sx, sz = cx + off[1], cz + off[2]
        local f0 = node_name(sx, F, sz)
        if f0 and ht.is_walkable_name(f0) and not is_door_name(f0) then
            local f1 = node_name(sx, F + 1, sz)
            local f2 = node_name(sx, F + 2, sz)
            if f1 and f2
                and (is_open(f1) or clearable(f1))
                and (is_open(f2) or clearable(f2)) then
                if clearable(f1) then
                    minetest.set_node({x = sx, y = F + 1, z = sz},
                        {name = "air"})
                end
                if clearable(f2) then
                    minetest.set_node({x = sx, y = F + 2, z = sz},
                        {name = "air"})
                end
                return sx, sz
            end
        end
    end
    return nil
end

-- Effective construction (emerged zone, 100% of blocks emerged).
-- bx, bz: corner of the slab where the beacon is embedded (the
-- farthest from the shaft, computed by build_basement which knows
-- sx/sz).
-- cellar_floor: y of the low slab of a NATIVE cellar (connect-from-
-- below mode) or nil (classic shaft from F).
-- Returns pad_pos or nil if an essential node is missing at dig time.
local function dig(job, cx, cz, sx, sz, y_floor, F, bx, bz, cellar_floor)
    if not (N_WALL and N_FLOOR and N_LADDER and N_BEACON) then
        return nil
    end
    local y_ceiling = y_floor + 4

    -- 1) 9x9 cobble ground slab
    for x = cx - HALF, cx + HALF do
        for z = cz - HALF, cz + HALF do
            minetest.set_node({x = x, y = y_floor, z = z},
                {name = N_FLOOR})
        end
    end

    -- 2) interior levels y_floor+1 .. y_floor+3 (3 air): stonebrick
    --    wall ring, air interior (pillar/beacon/ladder placed
    --    afterwards, so they are not crushed by this filling)
    for y = y_floor + 1, y_ceiling - 1 do
        for x = cx - HALF, cx + HALF do
            for z = cz - HALF, cz + HALF do
                if x == cx - HALF or x == cx + HALF
                    or z == cz - HALF or z == cz + HALF then
                    minetest.set_node({x = x, y = y, z = z},
                        {name = N_WALL})
                else
                    minetest.set_node({x = x, y = y, z = z},
                        {name = "air"})
                end
            end
        end
    end

    -- 3bis) pillar carrying the ladder inside the room, at (sx, sz-1)
    --    (north wall of the shaft); if it would land on the beacon
    --    cell (corner bx,bz of the slab), take it south (sz+1)
    local px, pz = sx, sz - 1
    if px == bx and pz == bz then
        pz = sz + 1
    end
    -- the pillar must NEVER cover the embedded beacon cell (case
    -- sx==bx && sz-1==bz impossible above, but the south move can
    -- land back on it: last fallback to the north)
    if px == bx and pz == bz then
        pz = sz - 1
    end
    for y = y_floor + 1, y_ceiling - 1 do
        minetest.set_node({x = px, y = y, z = pz}, {name = N_WALL})
    end

    -- 4) 9x9 ceiling slab at y_ceiling (= F-2 in the default
    --    geometry), pierced afterwards by the shaft, then crowning
    --    ring at level F-1 (edge only: the terrain under the floor
    --    stays intact elsewhere, only the shaft crosses it)
    for x = cx - HALF, cx + HALF do
        for z = cz - HALF, cz + HALF do
            minetest.set_node({x = x, y = y_ceiling, z = z},
                {name = N_WALL})
        end
    end
    for x = cx - HALF, cx + HALF do
        for z = cz - HALF, cz + HALF do
            if x == cx - HALF or x == cx + HALF
                or z == cz - HALF or z == cz + HALF then
                minetest.set_node({x = x, y = y_ceiling + 1, z = z},
                    {name = N_WALL})
            end
        end
    end

    -- 5) vertical access. Connect-from-below mode (native cellar,
    --    cellar_floor ~= nil): the classic shaft is removed -- the
    --    native cellar trapdoor already serves the house; we pierce
    --    the cellar low slab at (cx, cellar_floor) and the ladder
    --    goes down there to the room. The "carrying pillar" of the
    --    cellar (solid terrain under its slab, except our room) is
    --    the support: ladder placed against the north (z-, param2 =
    --    5) from y_floor+2 to cellar_floor-1, the cellar_floor slab
    --    and the node above become air (standing passage), a
    --    bearing wall is placed under the slab north of the hole.
    --    Classic mode: ladder from F-1 to y_floor+2 in two segments
    --    (wallmounted convention = direction of the supporting wall
    --    from the ladder: 2=x+, 3=x-, 4=z+, 5=z-):
    --    - shaft segment (y_ceiling..F-1): placed against the north
    --      (z-, param2 = 5), against the native terrain left in
    --      place at (sx, sz-1) -- including the crowning wall placed
    --      at 5bis at F-1; set_node replaces the terrain of the
    --      shaft column with the ladder: digging and equipping are
    --      done in a single pass
    --    - room segment (y_floor+2..y_ceiling-1): placed against the
    --      side of the actual carrying pillar (north by default,
    --      south in the degenerate case where the north pillar would
    --      land on the beacon cell at corner bx,bz)
    if cellar_floor then
        -- ladder bearing pillar INSIDE the room: the ladder is
        -- placed against the north (param2 = 5) at (cx, cz), yet the
        -- north node (cx, y, cz-1) is the air of the 7x7 interior --
        -- without a pillar, the ladder would float over the whole
        -- room height (the 3bis pillar is at the fictional shaft
        -- sx/sz, not here). Solid walls from y_floor+1 to
        -- y_ceiling-1; above the ceiling (cellar_floor-2..
        -- cellar_floor-1) the native terrain provides the bearing,
        -- completed by the block of 5bis below.
        for y = y_floor + 1, y_ceiling - 1 do
            minetest.set_node({x = cx, y = y, z = cz - 1},
                {name = N_WALL})
        end
        -- ladder: from the room ground (y_floor+1: the last ladder
        -- node LANDS the feet on the slab, no final fall) up to
        -- UNDER the native slab (cellar_floor-1); the slab and the
        -- node above become air (standing passage on the cellar
        -- side). It also pierces our ceiling (y_ceiling =
        -- cellar_floor-2): dig and equip in a single pass.
        for y = y_floor + 1, cellar_floor - 1 do
            minetest.set_node({x = cx, y = y, z = cz},
                {name = N_LADDER, param2 = 5})
        end
        minetest.set_node({x = cx, y = cellar_floor, z = cz},
            {name = "air"})
        minetest.set_node({x = cx, y = cellar_floor + 1, z = cz},
            {name = "air"})
        -- bearing for the top of the ladder (solid terrain north of
        -- the hole, under the slab): the z- mounted ladder finds its
        -- wall
        minetest.set_node({x = cx, y = cellar_floor - 1, z = cz - 1},
            {name = N_WALL})
    else
        local p2_chamber = (pz == sz - 1) and 5 or 4
        -- room ladder: down to y_floor+1 (feet landed on the
        -- slab, no fall from the last node)
        for y = y_floor + 1, y_ceiling - 1 do
            minetest.set_node({x = sx, y = y, z = sz},
                {name = N_LADDER, param2 = p2_chamber})
        end
        for y = y_ceiling, F - 1 do
            minetest.set_node({x = sx, y = y, z = sz},
                {name = N_LADDER, param2 = 5})
        end
    end

    -- 5bis) ladder support at F-1, classic mode only
    --    (cellar mode: the bearing is the 5) above)
    if not cellar_floor then
        minetest.set_node({x = sx, y = F - 1, z = sz - 1}, {name = N_WALL})
    end

    -- 6) trapdoor in the house floor, at (sx, F, sz): the walkable
    --    floor node is replaced; without a registered trapdoor,
    --    the hole is left open (the ladder stays visible, shaft
    --    guarantees intact)
    if not cellar_floor and N_TRAPDOOR
        and ht.is_walkable_name(node_name(sx, F, sz) or "") then
        minetest.set_node({x = sx, y = F, z = sz},
            {name = N_TRAPDOOR, param2 = 0})
    end

    -- 7) house beacon EMBEDDED in the slab (flush) at corner
    --    bx,bz passed by build_basement (the farthest from the
    --    shaft: never at the foot of the ladder). telemosaic
    --    teleports to dest.y+0.5, i.e. just level with the slab on
    --    return arrival.
    local pad = {x = bx, y = y_floor, z = bz}
    minetest.set_node(pad, {name = N_BEACON})
    local meta = minetest.get_meta(pad)
    meta:set_string("housetelemosaic:state", "pending")
    meta:set_string("housetelemosaic:job", minetest.pos_to_string(
        {x = job.box.x1, y = job.box.y1, z = job.box.z1}))

    -- 8) wall torches at the 4 cardinal points (wallmounted param2 =
    --    direction of the supporting WALL from the torch: 2 = x+,
    --    3 = x-, 4 = z+, 5 = z-; the room walls are at +/-4,
    --    the torches at +/-3); floor torch fallback at the 4
    --    corners (param2 = 1: y-, standing)
    if N_TORCH_WALL then
        local y = y_floor + 2
        minetest.set_node({x = cx - 3, y = y, z = cz},
            {name = N_TORCH_WALL, param2 = 3})
        minetest.set_node({x = cx + 3, y = y, z = cz},
            {name = N_TORCH_WALL, param2 = 2})
        minetest.set_node({x = cx, y = y, z = cz - 3},
            {name = N_TORCH_WALL, param2 = 5})
        minetest.set_node({x = cx, y = y, z = cz + 3},
            {name = N_TORCH_WALL, param2 = 4})
    elseif N_TORCH then
        for _, dx in ipairs({-3, 3}) do
            for _, dz in ipairs({-3, 3}) do
                minetest.set_node({x = cx + dx, y = y_floor + 1,
                    z = cz + dz}, {name = N_TORCH, param2 = 1})
            end
        end
    end

    ht.last_basement = {pad = pad, F = F}
    return pad
end

--
-- Entry point (called by ht.process_house). Returns pad_pos as
-- soon as the geometry is settled (the dig itself waits for the
-- emerge: the basement zone extends below the schematic footprint
-- that biomevillages has already emerged).
--
function ht.build_basement(job, F)
    local box = job.box
    local cx = math.floor((box.x1 + box.x2) / 2)
    local cz = math.floor((box.z1 + box.z2) / 2)

    -- effective depth: 5 = minimal geometry of the spec
    -- (ceiling F-2, ground F-6); beyond that the room sinks that
    -- much deeper
    local depth = math.max(ht.settings.basement_depth, MIN_DEPTH)
    local y_floor = F - depth - 1

    -- I5: offset attempts (0,0) then (+4,+4) then (+8,+8), bounded
    -- to keep the 9x9 room under the footprint (margin 2 towards
    -- each wall, MARGIN convention of basements.lua, capped at 8);
    -- as a last resort, dig 4 deeper
    local room_x = math.min(box.x2 - cx, cx - box.x1) - 2
    local room_z = math.min(box.z2 - cz, cz - box.z1) - 2
    local max_dx = math.max(0, math.min(room_x, 8))
    local max_dz = math.max(0, math.min(room_z, 8))
    local offsets = {{0, 0}, {4, 4}, {8, 8}}
    local ox, oz = 0, 0
    local placed = false
    local tried = {}
    for _, off in ipairs(offsets) do
        local dx = math.min(off[1], max_dx)
        local dz = math.min(off[2], max_dz)
        local key = dx .. "," .. dz
        if not tried[key] then
            tried[key] = true
            if not native_collision(cx + dx, cz + dz, F, y_floor) then
                ox, oz = dx, dz
                placed = true
                break
            end
        end
    end
    if not placed then
        -- deepening: the whole room lowered by 4 (the ceiling
        -- moves from F-2 to F-6), last attempt at the center
        y_floor = y_floor - 4
        if not native_collision(cx, cz, F, y_floor) then
            ox, oz = 0, 0
            placed = true
            ht.dlog("native basement collision: room deepened by "
                .. "4 for " .. job.name)
        end
    end
    local cellar_floor = nil
    if not placed then
        -- Native cellar detected (the cellar fills the whole
        -- interior, no 9x9 room fits
        -- underneath). TWO strategies, in order of preference:
        -- 1) DIRECT PATCH (priority, zero excavation): the beacon
        --    is embedded in the slab of the LOWEST level of the
        --    cellar, in a free cell far from the native ladder --
        --    the cellar becomes the teleporter room.
        -- 2) otherwise (cellar cluttered with furniture): connect
        --    from below -- 9x9 room UNDER the low slab, ladder
        --    hole pierced through the slab:
        --    house -> native trapdoor -> cellar -> ladder -> room.
        cellar_floor = ht.find_native_cellar_floor(cx, cz, F, box)
        if cellar_floor then
            local pad = ht.patch_cellar(job, box, cellar_floor, cx, cz)
            if pad then
                ht.stats.pads_dug = ht.stats.pads_dug + 1
                ht.stats.decisions.patch_cellar
                    = ht.stats.decisions.patch_cellar + 1
                ht.last_basement = {pad = pad, F = F}
                return pad
            end
            y_floor = cellar_floor - 6
            ox, oz = 0, 0
            placed = true
            ht.dlog("native cellar detected (low slab y=" .. cellar_floor
                .. "): room connected from below for " .. job.name)
        end
    end
    local deep_mode = false
    if not placed then
        -- LAST RESORT: descent in 5-node steps down to F-50.
        -- Houses without a native cellar often carry a hidden
        -- randungeon entrance: their near underground is occupied
        -- by the randungeon shaft. The room only tests its OWN
        -- footprint (chamber_zone_free); the shaft goes down only
        -- through a column of SOLID terrain (shaft_column_full:
        -- never cross the native cellar or the randungeon stair).
        local depth = 20
        while depth <= 50 do
            local test_y = F - depth - 1
            if chamber_zone_free(cx, cz, test_y)
                and shaft_column_full(cx, cz, F, test_y + 5) then
                y_floor = test_y
                ox, oz = 0, 0
                placed = true
                deep_mode = true
                ht.stats.decisions.deep_fallback
                    = ht.stats.decisions.deep_fallback + 1
                minetest.log("action", "[housetelemosaic] last "
                    .. "resort: room at F-" .. depth .. " for "
                    .. job.name .. " at " .. minetest.pos_to_string(job.pos))
                break
            end
            depth = depth + 5
        end
    end
    if not placed then
        ht.stats.decisions.giveup_native
            = ht.stats.decisions.giveup_native + 1
        minetest.log("action", "[housetelemosaic] giveup: cluttered "
            .. "native underground under " .. job.name .. " at "
            .. minetest.pos_to_string(job.pos) .. " (probed down to F-50)")
        return nil
    end
    if not deep_mode and cellar_floor then
        ht.stats.decisions.under_cellar
            = ht.stats.decisions.under_cellar + 1
    elseif not deep_mode then
        ht.stats.decisions.classic
            = ht.stats.decisions.classic + 1
    end
    cx, cz = cx + ox, cz + oz

    -- shaft column. Deep mode: shaft_column_full (column of solid
    -- terrain down to the room -- the geometry was already elected
    -- by the last-resort loop, we find it again here).
    -- Cellar mode: NO shaft (access goes through the native
    -- trapdoor and the ladder hole pierced in the low slab, see
    -- dig); sx/sz are still used for the beacon corner. Classic
    -- mode: shaft_column (F walkable, 2 air, no door).
    local sx, sz
    if deep_mode then
        sx, sz = shaft_column_full(cx, cz, F, y_floor + 5)
    else
        sx, sz = shaft_column(cx, cz, F)
    end
    if not sx then
        if cellar_floor then
            sx, sz = cx - 1, cz - 1 -- fictional corner: opposite beacon (cx+2,cz+2)
        else
            ht.stats.decisions.giveup_shaft
                = ht.stats.decisions.giveup_shaft + 1
            minetest.log("action", "[housetelemosaic] giveup: no free "
                .. "shaft column in " .. job.name .. " at "
                .. minetest.pos_to_string(job.pos))
            return nil
        end
    end

    -- beacon corner: diagonally opposite the shaft in the 7x7
    -- interior (maximal distance from the ladder), embedded in the
    -- slab
    local bx, bz = cx + 2, cz + 2
    if sx <= cx then bx = cx - 2 end
    if sz <= cz then bz = cz - 2 end

    local pad = {x = bx, y = y_floor, z = bz}
    local minp = {x = cx - HALF, y = y_floor - 1, z = cz - HALF}
    local maxp = {x = cx + HALF, y = F, z = cz + HALF}
    ht.emerge_and_run(minp, maxp, function()
        local ok, result = pcall(dig, job, cx, cz, sx, sz, y_floor, F,
            bx, bz, cellar_floor)
        if ok and result then
            ht.stats.pads_dug = ht.stats.pads_dug + 1
            minetest.log("action", "[housetelemosaic] basement built "
                .. "under " .. job.name .. ", pad "
                .. minetest.pos_to_string(result))
        else
            ht.stats.decisions.dig_fail
                = ht.stats.decisions.dig_fail + 1
            minetest.log("warning", "[housetelemosaic] dig failed for "
                .. job.name .. ": " .. tostring(result))
        end
    end, function()
        minetest.log("warning", "[housetelemosaic] emerge impossible "
            .. "for the basement of " .. job.name .. " at "
            .. minetest.pos_to_string(job.pos))
    end)
    return pad
end
