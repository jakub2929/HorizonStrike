# Task plan (from "plan", 2026-10-09)

Shell variables used in acceptance commands (PowerShell):
```powershell
$G="C:\Users\bezdo\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
$CS2="C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"; $HZD="E:\SteamLibrary\steamapps\common\Horizon Zero Dawn"; $DEV="C:\meshy\_tools\cache-dev"
$CONV="dotnet run --project converter/src/Hzs.Cli -c Release --"
```
Preflight status at hand-off: `sheets: 7  cells: 2556  verified: 2496`, 60 findings, all "unfilled (owner svet)" or
"unverified" (machines/systems mostly svet; movement constants and kevlar armor points hra).

## Key facts found while planning
- CS2 stats: `scripts/weapons.vdata_c` (KV3, one block per weapon, many values `[mode0, mode1]`); armor price in
  `scripts/items/items_game.txt` (`item_kevlar` 650); economy in loose `game/csgo/cfg/gamemode_competitive.cfg`
  (`mp_startmoney`, `mp_maxmoney`, `cash_player_killed_enemy_factor`, `ammo_grenade_limit_total`).
  Reload time = `m_flDisallowAttackAfterReloadStartDuration`. `m_bReserveAmmoAsClips` semantics unconfirmed.
- CS2 first-person anims are NOT in the weapon vmdl: AnimGraph2 clips under `animation/anims/viewmodel/...`, arms
  `weapons/models/shared/arms/weapon_arms.vmdl_c`; VRF CLI decodes a clip (DMX + sound events with frame times).
  Weapon colour maps are 4096 px (downscale to <=1024). Icons: `panorama/images/icons/equipment/<name>.vsvg_c` -> SVG.
- HZD grid: 340 terrain tiles x -7..12, y -9..7; Mother's Heart = `tile_x04_y-03` (start). Whole-world low-res
  heightmap: `levels/worlds/world/lods/combined_flattened_height.core` (cheapest first real-terrain attempt).
  Per-tile `tiles/*/worlddata/worlddata_height_terrain.core`, `layers/terrain/terraintiledata.core`.
- Internal names: scout = Watcher (verified); horse = Strider (likely: tile (5,-4) `fe_mq3_striders` near `fe_horse`);
  antelope = Grazer (likely: `canisterlarge`). Confirm via `interface/menu/datasources/datasourcerobotcatalogue.core`.
- Bootstrap 3x3 around (4,-3): (3,-2) Grazers+Watchers, horse scene; (4,-2) horse encounter, harvester herd;
  (5,-2) Mother's Vigil, `fe_antelope_scout`, `fe_horse_01`; (4,-3) START `manmade_mothers_heart*.core`,
  `manmade_rost_hovel.core`; (5,-3) Mother's Rise, `fe_horse_02`; (3,-4) `fe_hyena_scene`; (4,-4) Rost's house;
  (5,-4) Embrace / Mother's Cradle, `fe_mq3_striders`. 59 tiles have campfires, 55 robot placements.
- Size estimates: ~30 MB per cell average (terrain 4-10 MB, meshes shared 10-150 MB), whole world 8-10 GB (x2 error);
  first launch needs CS2 ~100 MB + machines 60-120 MB + start cell 100-200 MB.

## cs2 (converter, CS2 side) – owner of converter/src/Hzs.Cs2
1. C1 Binding resolver: add VRF NuGet 20.0.6980 + Hzs.Generated ref; read vdata (KV3), items (KV1), cfg; write
   `cs2/weapons.json` and `cs2/systems.json` as `{row:{col:value|null}, _errors}`.
   Accept: `$CONV cs2 --cs2 $CS2 --cache $DEV --only-stats`; then
   `python -c "import json;w=json.load(open(r'C:\meshy\_tools\cache-dev\cs2\weapons.json'));print(w['ak47']['damage'],w['ak47']['price'],w['m4a1_silencer']['spread'],w['kevlar']['price'],len(w['_errors']))"`
   -> `36 2700 [0.0006, 0.0005] 650 0`.
2. C2 First slice AK-47: world.glb; view.glb (arms + weapon; clips draw/idle/fire/reload/inspect from the
   viewmodel clips); anim_events.json; icon.svg; sounds.
   Accept: `python tools/glb_info.py $DEV\cs2\weapons\ak47\view.glb` -> animations draw idle fire reload inspect,
   skins>=1, max_texture_px<=1024; `snd` holds single/clipout/clipin/boltpull/draw.
3. C3 All 14 items + UI art/sounds. Accept: 14 weapons, `_errors==[]`, glb_info on every glb, cs2/ 50-200 MB.
4. C4 `manifest.json` cs2_build from appmanifest_730.acf (25815307) + `IsUpToDate`. Accept: 2nd run prints
   `cs2 up to date (25815307)` and writes nothing.
5. C5 Publish step in `tools/build.ps1` (self-contained win-x64) + THIRD_PARTY_NOTICES (VRF, SkiaSharp, ... MIT).
   Accept: `dist\converter\hzsconv.exe --help` exits 0.

## svet (Decima reader, world, machines, HZD audio) – owner of converter/src/Hzs.Decima
1. S1 Archive reader + Oodle loaded in place + prefetch path list; dev command `hzd-ls`.
   Accept: `$CONV hzd-ls --hzd $HZD --prefix models/characters/robots/scout/` -> 25 .core paths;
   `--tiles` -> `360 tiles, 340 terrain, x -7..12, y -9..7`.
2. S2 Object reader for the needed types (hand-written layouts); dev command `hzd-dump`.
   Accept: `hzd-dump --path entities/characters/robots/scout/scout_destructibility.core --member
   DestructibilityResource.InitialHealth` prints a number (record in MODLOG report, not in repo files).
3. S3 First slice Watcher: model.glb (real skeleton + textures) + meta.json (bones, weak_spots, height_m,
   leg_chains); fill machines.json TODOs. Accept: glb_info -> skins 1, joints N; meta has N bones; weak-spot bone
   among them; height 1.5-4 m.
4. S4 First slice terrain of cell (4,-3): try `lods/combined_flattened_height` first, then per-tile
   `worlddata_height_terrain`; record axis handedness from a landmark. Accept: `python tools/cell_info.py
   $DEV\hzd\cells\4_-3` -> `real=True bytes_ok=True nan=0 range_m>20`; with (4,-2): `--seam` -> seam_max_delta_m<0.5.
5. S5 `index`: cell_size, grid, 340 cells, start cell, start position (`locationmarkers.core`), start campfire;
   fill `respawn.start_campfire`, `streaming.cell_size_m`. Accept: prints `340 512.0 [4, -3] True`.
6. S6 Full cells: instances, shared meshes, campfires, spawns via site_map (variant B), vegetation density map.
   Accept: cell_info 4_-3 -> instances>0 meshes_missing=0 campfires>=1; 5_-2 spawns include grazer (orig antelope)
   and watcher (orig scout). Report the site table for MODLOG.
7. S7 Strider, Grazer, machine sounds, music, ambience; confirm internal names. Accept: glb_info passes for both;
   every sound role has files; >=1 `hzd/audio/music/*.mp3`; preflight sheets shows no svet findings.
8. S8 Converter server cell ops (priority, cancel, 2 workers). Accept: `python tools/proto_smoke.py --cs2 $CS2
   --hzd $HZD --cache C:\meshy\_tools\cache-proto` -> `PROTO OK`.

## hra (Godot game) – owner of game/ (except game/autotest/) and tools/build.ps1
1. H1 First slice: `Game` autoload per ARCHITECTURE incl. API additions; arg parsing; `--mock-data` (synthetic
   numbers only); placeholder terrain; CS2 movement; hitscan; placeholder machine with weak spot; buy wheel from mock
   data; money HUD. Accept: `& $G --headless --path game --script res://dev/smoke.gd -- --mock-data` -> `SMOKE OK`.
2. H2 HZD detection + MissingHzdScreen; converter child process over stdio (non-blocking reader thread).
   Accept: run with `--hzd C:\nonexistent` -> latest.log contains `MissingHzdScreen shown`.
3. H3 Real weapons from cache (after C2/C3). Accept: t01, t03, s01 pass on $DEV.
4. H4 Streaming, terrain, vegetation scatter, eviction, cache HUD + settings (after S4/S6/S8). Bootstrap radius 0,
   then ring 1 via `cell` ops. Accept: t09, t10 pass.
5. H5 Machine AI (idle/patrol/graze/suspicious/alert/attack/flee/dead, herds) + procedural animation on the real
   skeleton (check which IK / SkeletonModifier3D classes exist in 4.7.2 first). Accept: t04, t05, t06, s02, s03.
6. H6 Death + campfire respawn. Accept: t07.
7. H7 Audio (Horizon music/ambience, CS2 weapon sounds). Accept: during t05 the log has `music: combat`.
8. H8 Export + `tools/build.ps1` -> `dist\HorizonStrike.exe` + `dist\converter\hzsconv.exe`;
   `python tools/preflight.py package dist --cache $DEV` -> CLEAN.

## test (autotest + screenshots) – owner of game/autotest/
1. T1 `game/autotest/runner.gd`: results.json, screenshot helper, child-process launch (adds `--path game` when run
   from the editor). Accept: `Start-Process $G -ArgumentList '--path','game','--','--mock-data','--game',$CS2,
   '--autotest','t01,t03','--out','C:\meshy\_tools\autotest-dev' -Wait -PassThru` -> ExitCode 0; results t01,t03 pass.
2. T2 t02, t04, t11 on mock, then real data. 3. T3 t05, t06, t07. 4. T4 t08 (child) and t09+t10 (child, fresh cache).
5. T5 s01-s03 with pixel/frustum checks. 6. T6 Final run on dist exactly as Melty launches it + `--autotest`:
   ExitCode 0, all pass, 3 PNGs, t09.details has bootstrap_seconds and cache size.
Expected numbers are computed from sheets (t02 1100/3050/16000, t03 300/0, t04 120 vs 14.1), never hard-coded.

## Not in v1 (deliberate)
DLC1 world, wall penetration (column read, unused), silencer toggle, Glock burst, knife backstab, flash/smoke/decoy,
people/quests, riding machines, detachable machine parts, Horizon loot.

## Risks
Terrain decoding has no public reference (fallback allowed by BRIEF after a real attempt); CS2 viewmodel clips via
the VRF library unproven (fallback: static weapon models with procedural motion); design numbers are estimates;
Godot 4.7.2 APIs (OS.execute_with_pipe, IK modifiers) to be checked against the installed engine.
