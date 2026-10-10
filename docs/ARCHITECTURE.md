# Architecture and contracts

Working title: **Horizon Strike** (internal prefix `hzs`). Design source of truth: `BRIEF.md`. Data source of
truth: `sheets/*.json`. If code and a sheet disagree, fix the sheet first, then the code.

## Repository layout
```
BRIEF.md, CLAUDE.md, MODLOG.md        orchestrator-owned
docs/ARCHITECTURE.md                  this file (orchestrator-owned)
sheets/*.json                         design sheets (plan) + sheets/schema/*.schema.json
tools/gen_sheets.py                   sheets -> game/generated/*.gd and converter/src/Hzs.Generated/*.cs
tools/preflight.py                    sheet preflight + package scan (orchestrator-owned)
tools/build.ps1                       builds converter + exports Godot + assembles dist/ (hra owns, cs2 adds converter step)
converter/                            .NET solution "hzsconv" (cs2 owns Hzs.Cs2, svet owns Hzs.Decima/Hzs.World, shared Hzs.Cli)
game/                                 Godot 4.7.2 project, GDScript (hra owns; test owns game/autotest/)
```
Never in the repo: anything read or converted from CS2 or HZD (models, textures, sounds, text dumps, path lists,
RTTI dumps), downloaded tools, caches. Reference clones live in `C:\meshy\_tools\research` (gitignored).

## Installed layout (what Melty puts in `{managed}`) and launch
```
{managed}/HorizonStrike.exe            Godot export (pck embedded)
{managed}/converter/hzsconv.exe        .NET self-contained publish (+ its native dlls, e.g. SkiaSharp)
{managed}/LICENSE.txt, THIRD_PARTY_NOTICES.txt, README.txt
```
Melty launch: `{managed}/HorizonStrike.exe --game {game}` where `{game}` = the player's CS2 folder (the folder that
contains `game/csgo/pak01_dir.vpk`).

Game command line (read with `OS.get_cmdline_args()` + `OS.get_cmdline_user_args()`):
| arg | meaning |
|---|---|
| `--game <dir>` | CS2 install (from Melty). Required. |
| `--hzd <dir>` | override HZD install (dev/test). Default: auto-detect (below). `--hzd <missing dir>` simulates "HZD not installed". |
| `--cache-dir <dir>` | override cache root. Default `%LOCALAPPDATA%\HorizonStrike\cache`. |
| `--autotest [ids]` | run autotest scenarios (all if no ids), write results + screenshots, exit 0 if all pass else 1. |
| `--out <dir>` | autotest/screenshot output dir. Default `%LOCALAPPDATA%\HorizonStrike\autotest`. |

HZD auto-detect: Steam path from `HKCU\Software\Valve\Steam\SteamPath` (fallback `C:\Program Files (x86)\Steam`),
parse `steamapps/libraryfolders.vdf`, find library containing app `1151640`, read `appmanifest_1151640.acf`
`installdir`, require `<lib>/steamapps/common/<installdir>/Packed_DX12/Initial.bin` and `oo2core_3_win64.dll`.
If missing: the game still starts and shows a clear in-game screen ("Horizon Zero Dawn Complete Edition is not
installed - this mashup reads its world and machines from your copy. Install it on Steam and press Play again.").

Log: `%LOCALAPPDATA%\HorizonStrike\logs\latest.log` (game) and `...\logs\converter.log` (converter).

## Coordinate system and units
Converter outputs **Godot space**: meters, Y-up, right-handed, -Z forward. HZD (Decima) is Z-up; convert as
`godot = (hzd.x, hzd.z, -hzd.y)` (verify handedness with a known landmark and record it in MODLOG). CS2 units
(inches, Z-up) are converted by the converter: 1 CS2 unit = 0.0254 m.

## Converter `hzsconv.exe`
One-shot CLI for development and a server mode for the game.
```
hzsconv cs2      --cs2 <dir> --cache <dir>                  # weapons, viewmodels, sounds, icons, stats
hzsconv machines --hzd <dir> --cache <dir>                  # Watcher, Strider, Grazer + their sounds
hzsconv index    --hzd <dir> --cache <dir>                  # world index: cell grid, start cell, spawn sites, campfires
hzsconv cell     --hzd <dir> --cache <dir> --cell X,Y       # one world cell
hzsconv serve    --cs2 <dir> --hzd <dir> --cache <dir>      # JSON lines over stdin/stdout (below)
```
Server protocol (one JSON object per line, UTF-8). Requests from the game:
```
{"id":1,"op":"bootstrap"}                     # cs2 + machines + index + cells around the start (radius in sheets/systems.json)
{"id":2,"op":"cell","cell":[x,y],"prio":0}    # lower prio = sooner; re-requesting changes prio
{"id":3,"op":"cancel","cell":[x,y]}
{"id":4,"op":"status"}
{"id":5,"op":"quit"}
```
Events from the converter:
```
{"id":1,"event":"progress","stage":"weapons","done":3,"total":12}
{"id":2,"event":"done","ok":true,"bytes":123456}
{"id":2,"event":"error","message":"..."}
{"event":"log","level":"info","message":"..."}
```
Writes are atomic: build into `<target>.tmp`, then rename. The converter never deletes cache entries; the game owns
eviction. The converter only ever **reads** game installs (open files read-only, share read).

## Cache layout (`<cache>`)
```
manifest.json                          {"format":1,"converter":"x.y.z","cs2_build":..,"hzd_build":..}
cs2/weapons.json                       per weapon id (sheet id): stats read from the player's CS2 data
cs2/weapons/<id>/world.glb             third-person/world model
cs2/weapons/<id>/view.glb              first-person viewmodel incl. arms + clips (draw, idle, fire, reload, inspect)
cs2/weapons/<id>/icon.svg              buy wheel icon
cs2/weapons/<id>/meta.json             content contract: content_model, bone_roles, points
cs2/weapons/<id>/snd/<event>_<n>.(wav|mp3)
cs2/ui/...                             any other CS2 UI art used (money/armor icons)
hzd/index.json                         world grid: cell size, bounds, list of cells, start cell, campfires, spawn sites
hzd/machines/<id>/model.glb            skinned mesh + real skeleton + textures (bind pose)
hzd/machines/<id>/meta.json            bone names, weak-spot bones/meshes, dimensions
hzd/machines/<id>/snd/<event>_<n>.(wav|mp3)
hzd/audio/music/<name>.mp3, hzd/audio/ambience/...
hzd/meshes/<meshid>.glb                shared static meshes (rocks, ruins, buildings, trees), with LODs if available
hzd/cells/<x>_<y>/cell.json            terrain + instances + vegetation + campfires + spawn sites of this cell
hzd/cells/<x>_<y>/height.r32           float32 heights, row-major, size in cell.json
hzd/cells/<x>_<y>/albedo.png, normal.png, splat.png (as available)
```
`cell.json` (Godot space):
```json
{"cell":[x,y],"origin":[ox,0,oz],"size":512.0,
 "terrain":{"file":"height.r32","res":[w,h],"min":-12.0,"max":310.0,"real":true,"albedo":"albedo.png"},
 "instances":[{"mesh":"<meshid>","xf":[12 floats basis+origin, column-major Godot Transform3D]}],
 "vegetation":[{"mesh":"<meshid>","xfs":[[...],[...]]}],
 "campfires":[{"id":"...","pos":[x,y,z]}],
 "spawns":[{"site":"...","orig_type":"sawtooth","type":"watcher","count":2,"pos":[x,y,z],"radius":30}],
 "meshes":["<meshid>", "..."]}
```
`terrain.real` is `false` only for the fallback terrain. Exact fields may grow; additions go into the sheet
`sheets/hooks.json` row for the cell format first.

## Game (Godot 4.7.2, GDScript)
- Streaming: the game requests cells ahead of the player (radius/lead in `sheets/systems.json`), loads finished
  cells with `GLTFDocument` (runtime glTF) and builds terrain mesh + `HeightMapShape3D` collision, instances via
  `MultiMeshInstance3D`, evicts cells over the cache cap (farthest first, never the active set), then removes
  shared meshes no remaining cell references. Settings menu: cache cap; HUD/menu shows cache size.
- Player: CS2-style movement and weapons per `sheets/weapons.json` + `cache/cs2/weapons.json`.
- Machines: AI state machines per `sheets/machines.json` (Horizon logic), procedural animation on the real skeleton.
- Economy / buy wheel / death / campfire respawn per `sheets/systems.json`.
- Generated code: `game/generated/*.gd` from sheets (never hand-edit).
- Missing HZD: in-game message (above). Missing cache or converter error: in-game error screen with the log path.

## Autotest
`HorizonStrike.exe --game <cs2> --autotest` (exactly how Melty launches it, plus the flag). Scenarios live in
`game/autotest/`; each writes `{id, name, pass, details}` into `<out>/results.json`; screenshots via the game's own
viewport (`get_viewport().get_texture().get_image().save_png`) so only the game is captured. Scenario list =
`BRIEF.md` "Autotest".

## Game API used by the autotest (hra implements, test consumes)
Autoload `Game` (`res://core/game.gd`). The boot code instances `res://autotest/runner.gd` (owned by test) when
`--autotest` is on the command line; the runner drives the game only through this API and real gameplay code paths
(no shortcuts that bypass the systems under test).
- Signals: `world_ready`, `cell_loaded(cell: Vector2i)`, `machine_state_changed(machine, old: String, new: String)`,
  `money_changed(value: int)`, `player_died`, `player_respawned(campfire_id: String)`, `kill_reward(machine_type: String, weapon_id: String, amount: int)`.
- State: `money: int`, `player` (Node3D: `inventory: Array[String]` weapon ids, `current_weapon: String`,
  `health: float`, `armor: float`), `last_campfire_id: String`, `hzd_missing: bool`, `machines: Array`,
  `cache_cap_bytes: int`, `bootstrap_seconds: float`, `cells_converted: int`.
- Methods: `spawn_machine(type: String, pos: Vector3) -> Node`, `buy(item_id: String) -> bool` (same path as the
  wheel), `open_buy_wheel()`, `close_buy_wheel()`, `equip(weapon_id: String)`, `aim_at(target: Node3D, part: String)`
  (`part` = "body" or a weak-spot name; points the player camera at it), `fire() -> Dictionary` (one real shot:
  `{hit, target, part, damage}`), `kill_player()` (lethal damage through the normal damage path),
  `teleport(pos: Vector3)`, `campfires_near(pos: Vector3, radius: float) -> Array`, `cache_bytes() -> int`,
  `screenshot(path: String)`.
- Machine node: `machine_type: String`, `state: String` (idle, patrol, graze, suspicious, alert, attack, flee, dead),
  `health: float`, `suspicion: float`, `weak_spots() -> Array[String]`.

## Sheet conventions (as implemented by tools/preflight.py and tools/gen_sheets.py)
- Sheets: `weapons`, `machines`, `machine_attacks`, `systems` (one row per parameter), `site_map`, `hooks`, `autotest`.
- Column types: `string|int|number|bool|enum|ref (list:true allowed)|list (of, len)|object|value`.
- Unfilled = `null`, `"TODO..."`, `""`, `"?"`; not applicable = `-1`, `0`, `"none"` or `[]`. `_owner` names who fills a
  cell, `_verified` is `"*"` or a list of verified columns, `_evidence` gives source + value per verified fact.
- Bindings: `{"cs2": "<alias>:<key path>"}` with aliases from `hooks.json` (`vdata` = `scripts/weapons.vdata_c`,
  `items` = `scripts/items/items_game.txt`, `cfg` = `game/csgo/cfg/gamemode_competitive.cfg`);
  `{"hzd": "<core path or {a,b} brace list>[#Type.member.path]"}`. A column may define `"bind"` (a template such as
  `vdata:{cs2_item}.m_nDamage`) and rows then hold `{"cs2": "*"}`; the generator expands it.
- Optional `fallback` (cell) and `default` (column) are used by the game only when a bound value is missing.
- Resolved values: converter writes `cache/cs2/weapons.json`, `cache/cs2/systems.json`, `cache/hzd/machines.json`,
  `cache/hzd/systems.json` shaped `{"<row>": {"<col>": value|null}, "_errors": [...]}`. The game reads a value via
  `game/core/sheets.gd`: resolved value -> cell `fallback` -> column `default`.

## Contract revisions from planning (2026-10-09) – these override earlier sections
- CS2 weapon stats live in `scripts/weapons.vdata_c` (KV3), many as `[mode0, mode1]` pairs (M4A1-S mode 1 =
  silenced, AWP mode 1 = scoped); armor price in items_game; economy cvars in `game/csgo/cfg/gamemode_competitive.cfg`.
  CS2 build id comes from `steamapps/appmanifest_730.acf` (`buildid`).
- CS2 viewmodel animations are AnimGraph2 clips (`animation/anims/viewmodel/...`) with the arms model
  `weapons/models/shared/arms/weapon_arms.vmdl_c`; `view.glb` clip names: draw, idle, fire, reload, inspect, plus
  `cs2/weapons/<id>/anim_events.json` (sound events with frame times). Icons: `icon.svg` (from `.vsvg_c`).
  Textures are downscaled to max 1024 px.
- HZD archive set: `Initial, Remainder, DLC1, FGRWin32, Patch` (.bin; language bins not needed). Cell = main-world
  streaming tile `levels/worlds/world/tiles/tile_x{XX}_y{YY}` (expected 512 m; svet confirms); cache id `<x>_<y>`;
  340 terrain tiles, x -7..12, y -9..7; start tile (4,-3) Mother's Heart; DLC1 world out of v1.
- `hzd/index.json` = `{cell_size, grid_min, grid_max, cells, start_cell, start_pos, start_campfire}`; campfires and
  spawns live only in `cell.json`. `cell.json` vegetation = `{"density": "veg_density.png", "channels": [...],
  "species": [...]}`; the game scatters vegetation from it.
- Protocol: events also include `cancelled`, `status` (`bytes, pending, running, bootstrapped`), `bye`. The game
  sends `bootstrap` with radius 0, then requests ring cells with `cell` ops, so play starts after the start cell.
- Command line: `--mock-data` (dev/test only); args accepted before and after `--`; `--autotest t01,t03` ids
  comma-separated; t08 and t09/t10 run as child processes of the runner (fresh `--hzd`/`--cache-dir`).
- Game API additions: `player.ammo(id) -> Vector2i`, `player.invulnerable`, `machine.ai_enabled`,
  `cells_on_disk() -> Array[Vector2i]`, signal `cell_evicted(cell)`, `converter_pid: int`, node `MissingHzdScreen`
  (with a Label); `world_ready` means playable.
- Autotest: the exported exe is a GUI app – get its exit code with `Start-Process -Wait -PassThru`; screenshots
  need a real window (not `--headless`).
- Dev-only tools (never packaged): `tools/glb_info.py`, `tools/cell_info.py`, `tools/proto_smoke.py`.

## Content contract (2026-10-09; rule in CLAUDE.md)
Code is content-agnostic. Per asset the converter writes `meta.json` next to the model:
```json
{"model": "model.glb", "up": "y", "forward": "-z", "scale_m": 1.0,
 "bone_roles": {"root": "...", "head": "...", "spine": "...", "tail": "...",
                "leg_fl_upper": "...", "leg_fl_lower": "...", "leg_fl_foot": "..."},
 "points": {"weak_eye": {"bone": "...", "offset": [0,0,0], "radius": 0.15, "kind": "weak_spot"},
            "muzzle":   {"bone": "...", "offset": [0,0,0], "kind": "fx"}},
 "leg_chains": [["leg_fl_upper","leg_fl_lower","leg_fl_foot"]]}
```
Sheet columns (machines and weapons): `content_model` (cache-relative path), `bone_roles` (object role -> bone),
`points` (object name -> {bone, offset, radius?, kind}). Sheet values are the source of truth; `meta.json` is what the
converter found (sheet cells reference roles/points by name; the game reads names, never bone strings in code).
World cells: `cell.json` (above) is the contract; the game must work with any producer of that format (own terrain
included). Weak spots, attack origins, hit FX and muzzle flashes are always looked up by point name.

## 0.2 revisions (2026-10-09)
- New executor "stroje" owns game/machines/** except spawner.gd (hra); frozen interface in docs/PLAN-0.2.md.
- cell.json additions: instances[].kind, terrain.layers, water, occluders, hlod; textures as .dds (BC1/3/5/7).
- Game API additions: signal cell_insert_started(cell), player.speed_mult (test setup only), machine.current_attack,
  machine.weak_points(part); machine states add stalk, scavenge.
- Dev-only tools: tools/frametime_graph.py, game/dev/machine_bench.gd.
- Protocol op `{"id":N,"op":"throttle","workers":W,"threads":T}` -> `{"id":N,"event":"throttled",...}`; serve runs at
  BelowNormal priority; `status` reports workers/threads. Game: workers 1 / threads 2 in-world, workers 2 on the
  loading screen. cell.json `sheets` = hash of sheet values affecting cell output (stale cells reconvert).

## 0.3 revisions (2026-10-10)
- Knives: cache/cs2/knives/index.json ({format, cs2_build, selection, knives:[{id, classname, def_index, display_name,
  dir, state ok|failed|pending, reason, clips, bytes}]}) + cs2/knives/<id>/ with the weapon layout (meta.json,
  view.glb clips draw/idle/fire/fire2/inspect[/inspect2/3], world.glb, anim_events.json, icon.svg, snd/). Knife list
  comes from items_game via the sheet row knives.selection (no list in code). Protocol op
  `{"op":"knives","ids":[...],"prio":N}` (on demand, after bootstrap, throttled); CLI `hzsconv knives`.
