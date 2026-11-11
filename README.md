# House Telemosaic (`housetelemosaic`)

Every eligible nativevillages house receives, according to an adjustable chance (default: all of them), a
basement accessible by trapdoor and ladder, containing a bidirectional telemosaic pad pointing to:

- a **cave**: natural air pocket scanned at depth, with an artificial fallback
  room if none is found;
- a **dungeon**: a room of a native mapgen dungeon (the very ones `dungeonsplus`
  decorates with its features and loot when active), a `randungeon` dungeon
  generated as a fallback, or a mossycobble vaulted room as a last resort;
- a generated **maze**: deterministic recursive backtracker, with a "carrot"
  removing about 8% of the walls to create loops;
- the nearest **cloudlands island**: stabilized arrival platform (`sky`
  destination, `cloudlands` mod required).

Eligible houses: prefixes `grasslandhouse`, `deserthouse`, `savannahouse`, `icehouse`,
`junglehouse`, `cannibalhouse`, `grasslandtown_house`, `grasslandsmall_house`,
`savannawitchhouse`; `*_cloudlands` buildings and stilt houses (`lakehouse`) excluded.
Only **newly generated** houses are equipped — for existing villages,
use `/htscanarea`.

## Dependencies

| Mod | Status | Role |
|-----|--------|------|
| `telemosaic` | required | beacons, extenders and linking API |
| `nativevillages` | required | house placement (intercepted hook) |
| `cloudlands` | optional | enables the `sky` destination (floating islands) |
| `randungeon` | optional | full generated dungeon as a fallback for the `dungeon` destination |
| `dungeonsplus` | optional | decorates the native dungeons targeted by the `dungeon` destination |
| minetest_game | expected | `default` and `doors` nodes (shaft trapdoor) |

The construction nodes are resolved at load time with fallback chains
(`default:stonebrick` to `default:stone`, `doors:trapdoor_wood` to the other trapdoors):
if absent, the mod degrades gracefully (hole left open, warnings in the log).

## How it works

### Intercepting nativevillages placement

At `on_mods_loaded`, the mod wraps `nativevillages.basements.maybe_dig_basement`
(monkey-patch): every placed house goes through the wrapper after the schematic
is placed. Without a known hook point (otherwise
`nativevillages.dungeon.maybe_place_hidden_entrance`), the mod stays inert with
an explicit error log.

The equipment chance is drawn deterministically per house (`PcgRandom`
stream: world seed + coordinates), re-executed identically on a regenerated
chunk.

### Basement: five construction paths

In order of preference, the house receives its pad through one of these paths:

1. **Direct patch of the native cellar**: when the house has a native cellar,
   the beacon is embedded in the slab of its lowest level, in a free cell at
   ≥ 3 nodes from the native ladder, on a 3×3 stabilization slab — zero
   excavation, the cellar becomes the teleporter room.
2. **Classic 9x9 room** (house without cellar): stonebrick walls, cobble
   ground, torches; ceiling pierced by a 1x1 shaft fitted with a ladder and
   closed by a trapdoor in the floor; beacon EMBEDDED in the slab (flush), at
   the corner diagonally opposite the shaft — never at the foot of the ladder.
   Anti-collision with native basements and randungeon entrances (9-column
   probing, +4/+8 offsets, deepening).
3. **Connect from below** (cellar present but impossible to patch or avoid):
   the room installs itself under the cellar's low slab, without its own shaft
   or trapdoor — a ladder hole pierced through the low slab goes down to the
   pad (house → native trapdoor → cellar → ladder → pad room).
4. **Deep room**: in 5-node steps down to F-50 when the near underground is
   entirely occupied (randungeon shaft) — the room only probes its own
   footprint, the shaft goes down through a column of solid terrain.
5. **Floorless mode**: no probe of the floor scan passes (furnished cellar) —
   direct patch of the cellar with an estimated level.

Long-distance extenders are embedded in the slab like the beacon (only
`default:cobble`/`default:stone_block` placed by the mod are replaceable).

### Destination choice

Deterministic selection per house (world seed + coordinates) among the
available providers, in the order of the `housetelemosaic_destinations` setting
(`ordered` mode) or by deterministic random rotation (`random` mode), with a
fallback chain between providers:

- **cave**: read-only VoxelManip scan of livable air pockets, within a
  `cave_radius` radius and a deep window (y1-60 to y1-20, clamped); 9x9
  artificial room as a fallback if no pocket is found (can be disabled);
- **dungeon**: scan of the characteristic floors of native dungeons (cobble,
  mossycobble, stonebrick — the very rooms `dungeonsplus` decorates) within a
  48 radius and a deep window y1-200..y1-25; if no room is found: `randungeon`
  dungeon generated via `randungeon.make_dungeon` (40x40, 3 levels, random
  materials), otherwise mossycobble/stonebrick 9x9 vaulted room;
- **maze**: square grid of W cells (footprint (2W+1)² nodes), deterministic
  recursive backtracker, carrot removing `floor(W*W*0.08)` separator walls
  (loops), beacon placed at the entry, enclosure open to the north;
- **sky**: nearest island via `cloudlands.find_nearest_island` (radius
  `sky_search_radius`); stabilized arrival platform: 3x3 on the real island
  ground, or 7x7 artificial platform if the terrain is not there.

### Telemosaic linking

Destinations are programmed in both directions via `telemosaic.set_destination`
(return link can be disabled with `housetelemosaic_return_enabled`), and
extenders are placed automatically in a spiral around each pad according to
the distance (tier three, two then one; capped by
`housetelemosaic_max_extenders`).

### Persistent link queue

Pending links are persisted in mod storage (`{pad, job, plan, provider, tries}`)
and resumed automatically:

- LBM on beacons still `pending` when their chunk loads;
- re-processing on `on_generated` (at most every 10 s) and at server startup;
- 3 attempts per provider, then deterministic switch to the next provider
  before the definitive giveup (`unlinked` state).

## Settings

All settings are clamped to their documented bounds; an invalid value falls
back to the default.

| Setting | Default | Description |
|---------|---------|-------------|
| `housetelemosaic_chance` | `1.0` | Chance that an eligible house receives the basement (0.0 to 1.0) |
| `housetelemosaic_destinations` | `cave,dungeon,maze,sky` | Ordered list of destinations (`cave`, `dungeon`, `maze`, `sky`) |
| `housetelemosaic_dest_mode` | `ordered` | `ordered`: first of the list; `random`: draw among the available ones |
| `housetelemosaic_return_enabled` | `true` | Also place a return link on the destination pad towards the house |
| `housetelemosaic_cave_artificial_fallback` | `true` | Artificial fallback cave when no natural cave is found |
| `housetelemosaic_cave_depth` | `30` | Target depth of the cave pad below the surface (nodes) |
| `housetelemosaic_cave_radius` | `48` | Horizontal search radius for a natural cave (nodes) |
| `housetelemosaic_maze_depth` | `25` | Depth of the maze pad below the surface (nodes) |
| `housetelemosaic_maze_width` | `21` | Width of the maze in cells (footprint 2W+1 nodes, square) |
| `housetelemosaic_maze_height` | `5` | Height of the maze corridors (nodes) |
| `housetelemosaic_basement_depth` | `5` | Depth of the basement below the house floor (nodes) |
| `housetelemosaic_sky_search_radius` | `512` | Search radius for a cloudlands island (nodes, 0 = disabled) |
| `housetelemosaic_max_extenders` | `12` | Maximum extenders per pad (0 = unlimited) |
| `housetelemosaic_debug` | `false` | Detailed debug logging in the server log |

## Commands

| Command | Privilege | Description |
|----------|-----------|-------------|
| `/htstats` | — | Queue status: entries per provider, cumulative giveups, last pad, hook |
| `/htcheck` | — | Installation diagnostics (hook, step-by-step counters); the report is also written to `htcheck_report.txt` at the world root |
| `/htrelink` | `server` | Restarts the processing of all queue entries |
| `/htforce` | `server` | Full pipeline test: basement + pad forced under the player's position |
| `/htdebug` | `server` | Toggles debug logging at runtime |
| `/htscanarea [<radius>]` | `server` | Retroactively equips houses already placed around the player (def. 64 nodes, 30 houses/pass) |
| `/htaudit [<radius>] [fix\|report]` | `server` | Audits and repairs already built basements (ladders, shaft, trapdoor, cellar passage, embedded beacon) |
| `/htmaze <x> <y> <z> [<w> [<h>]]` | `server` | Test maze of `w`x`h` cells (def. 15x15) at (x, y, z) |

## Technical notes

- **Determinism**: every draw is a `PcgRandom` stream mixed with the world seed
  and the house coordinates; a regenerated chunk rebuilds the same basement, the
  same plan re-materializes exactly the same maze.
- **No writing in an ungenerated chunk**: all constructions outside the already
  emerged house footprint (basement, cave, maze, platform) first go through
  `emerge_area`; the callback only runs if 100% of the blocks emerge
  successfully (actions `EMERGE_FROM_MEMORY`, `EMERGE_FROM_DISK` or
  `EMERGE_GENERATED`).
- **Vertical separation** of the structures (F = house floor): basement room at
  F - basement_depth - 1 (ground at F-6 by default), maze at F - maze_depth,
  artificial cave at y1 - cave_depth (at least 26 nodes under the house base) —
  distinct depths by default, never superimposed.
- **Robustness**: the whole asynchronous chain (emerge callbacks,
  minetest.after) is under `pcall` — a mod error can never interrupt the
  server; the mod storage is captured at load time only
  (`get_mod_storage()` returns nil at runtime).

## License

MIT (see `mod.conf`).
