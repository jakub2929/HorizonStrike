# MODLOG – Horizon Strike (CS2 × Horizon Zero Dawn Complete Edition)

Journal and decision log (orchestrator-owned). Newest entries at the bottom of each section.

## Setup (2026-10-09)
- CS2: Steam app 730, `C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive`, buildid 25738536
  (StateFlags 6 = update pending; files readable). 506 VPK chunks; `scripts/items/items_game.txt` present.
- HZD Complete Edition: Steam app 1151640, `E:\SteamLibrary\steamapps\common\Horizon Zero Dawn`, buildid 8040161,
  original 2020 PC port (Packed_DX12/*.bin, oo2core_3_win64.dll).
- Melty: CS2 has no loader Melty installs; it is "standalone"-capable (program in `{managed}`, `{game}` = CS2 dir).
  HZD is not in Melty's catalog (`custom-horizon-zero-dawn-complete-edition`, role "secondary").
  Working examples: `spike-rush` (CS2 standalone, one click yes), `kh1-x-cs2` (CS2 primary + custom game secondary).
- Installed tools: Godot 4.7.2 export templates (Windows x64) into `%APPDATA%\Godot\export_templates\4.7.2.stable`;
  ValveResourceFormat CLI 20.0 into `C:\meshy\_tools\vrf`; universal-modder clone (commit 8370faa) into `C:\meshy\_tools`.

## Research findings (HZD, 2026-10-09)
- Archives: all 39 `.bin` magic 0x20304050 (unencrypted). Header 40 B; file entry 32 B (index, key, u64 path hash,
  u64 offset in decompressed space, u32 size, key2); chunk entry 32 B; chunks Oodle-compressed (oo2core_3, max chunk
  0x40000). Path hash = first u64 of MurmurHash3_x64_128(seed 42) over UTF-8 path + ".core" + NUL. Patch.bin overrides.
  Path list obtainable at runtime from `prefetch/fullgame.prefetch.core`.
- Machines: meshes `models/characters/robots/<int>/animation/parts/*.core(.stream)`, skeleton
  `.../animation/skeletons/skeleton_rootbone.core`, textures `.../textures/<int>_set.core`. Internal names: scout =
  Watcher (verified); horse = Strider, antelope = Grazer (to verify).
- Machine animations: Morpheme / EdgeAnim compressed, no public decoder -> procedural animation on the real skeleton.
- World: StreamingTile / PrefabInstance / StaticMeshInstance placements are decodable (Workshop exports them).
  Terrain heightmap: data exists (`tiles/*/worlddata/worlddata_height_terrain.core`, `layers/terrain/terraintiledata.core`,
  `lods/combined_flattened_height`), no public decoder -> research risk. Procedural vegetation `worlddata/placement_*`
  is GPU-generated -> place from density maps.
- Audio: no Wwise; `WaveResource` (PCM/MP3/ADPCM/...) and `MusicResource` (MP3 tracks).
- Licences: Decima Workshop GPL-3.0, HZDCoreEditor/HZDMeshTool unlicensed -> format reference only; own MIT code.

## Decisions
- D1 Host/route: standalone program, CS2 primary (`{managed}/HorizonStrike.exe --game {game}`), HZD secondary,
  auto-detected via Steam libraryfolders. Neither game is launched or written to.
- D2 Engine: Godot 4.7.2 GDScript game + .NET converter `hzsconv` (ValveResourceFormat for CS2, own Decima reader).
- D3 Kill reward = CS2 kill award of the weapon class × machine multiplier (machines sheet); cap $16,000.
- D4 Weak-spot hit = weapon damage × that weapon's CS2 headshot multiplier.
- D5 Shots raise suspicion of machines within a radius; suppressed weapons use a smaller radius.
- D6 Buy wheel: max 12 items, prices from CS2 data: pistols, SMG, rifles, AWP, shotgun, HE, molotov, armor.
- D7 Other machines' sites are populated with v1 machines by site type (variant B); mapping logged below.
- D8 Cells are converted on demand ahead of the player; first launch converts only weapons, machines and the start
  area; cache cap with eviction of distant cells; cache size shown in game.
- D9 In-game UI language: English (Melty audience is international). Listing in English.
- D10 Credits "EM", licence MIT, remix allowed.
- D11 Converter targets .NET 10 instead of .NET 8 (ValveResourceFormat 20.0.6980 NuGet only ships net10.0); confirmed by
  the user. Published self-contained win-x64 so players need no .NET runtime installed.
- D12 Converter runs as a JSON-lines server child process of the game (`hzsconv serve`) over **stdio only** (no TCP,
  no named pipe needed, so no firewall prompt); bootstrap first, then cells by priority; the game owns eviction.
  If a socket is ever added it binds 127.0.0.1 only. Autotest checks the converter process listens on no
  non-loopback address.
- D13 "Horizon Strike" is a working title; final title, tagline and description are written from the finished build.
- D14 Buy wheel (12): p250, deagle, mp9, ump45, galilar, ak47, m4a1_silencer, awp, nova, hegrenade, molotov, kevlar.
  Start loadout knife + glock.
- D15 M4A1-S is always silenced (CS2 mode 1); no Glock burst mode in v1.
- D16 Kevlar only (no helmet); machines never deal headshots.
- D17 CS armor rule applies to machines' body hits; weak spots ignore machine armor.
- D18 Machine design values (health 140/400/300 Watcher/Strider/Grazer, kill multipliers 1/2/1.5, speeds, suspicion)
  are design estimates on the CS2 damage scale; HZD bindings replace them where svet can read real values.
- D19 Buying works anywhere except in combat.
- D20 `systems` is one row per parameter; extra sheets `site_map` and `machine_attacks`; `{"cs2":"*"}` bind templates
  (generator patch accepted).
- D21 Cell = main-world HZD tile; start (4,-3) Mother's Heart; bootstrap converts the start cell first (playable),
  ring cells next; DLC1 (Frozen Wilds) world out of v1.
- D22 Cache cap default 4 GiB (min 1, max 64), 600 MiB disk reserve, farthest-first eviction.
- D23 Vegetation is scattered by the game from HZD density maps.
- D24 Machine sites refill after 300 s when the player is more than 200 m away.
- D25 CS2 updated to 25815307 during planning; only the AUG reload changed; all sheet evidence re-checked.
- D26 Policy: sheets may hold asset paths, binding key paths and single numbers as `_evidence` (identifiers and
  facts needed to bind and verify); no bulk extracts, text dumps or files from the games in the repo.
- D27 Assumptions: armor is lost on death; before any campfire is activated the respawn point is the start campfire
  near Mother's Heart; the kill reward uses the weapon that dealt the killing damage; molotov (not incendiary).
- D28 (cs2) view.glb = CS2 arms (`weapon_arms.vmdl`) + weapon world model (`body_hd`) on bone `wpn`; origin = eye,
  forward -Z, parent under Camera3D with identity; always play a clip. Clips from the weapon's anim graph resources:
  draw, idle, fire (`shoot1_*`; knife `light_miss1`; grenades `throw_overhand`), reload, inspect (`lookat01`), extra
  `fire2` (knife heavy), `pullpin`; additive clips composed over idle. Forearm twist constraint not evaluated (minor
  wrist deformation in extreme poses).
- D29 (cs2) Textures max 1024 px (opaque JPEG q90 4:4:4, alpha PNG); GLBs compacted (VRF otherwise keeps 4096 px data).
  Sounds `snd/<lower(after first dot)>_<n>.(wav|mp3)`; `anim_events.json` = {clip:[{t,event}]}. Missing vdata keys ->
  null + log warning. A key is a pair if any weapon stores it as a 2-element array; scalars become [v, v].
- D30 (cs2) Serve mode keeps stdout protocol-only (VRF stdout redirected to the log). Manifest gains `cs2_format`;
  a full run clears the cs2 stamp first so an interrupted conversion repeats. Shared helper Hzs.Common/ManifestFile.cs.
- D31 Teammate agents cannot message each other (executor/tester tool sets lack SendMessage); the orchestrator relays.
- D32 Content contract: code is content-agnostic; machines/weapons carry content_model, bone_roles, points in sheets
  and meta.json; world via cell.json; content swappable by files + sheets (rule in CLAUDE.md).
- D33 (svet) Axes: HZD X=east, Y=north, Z=up, right-handed; `godot=(x, z, -y)`, north = Godot -Z (landmarks Meridian
  (-1,-3) west of Nora (4,-3), Sunfall (-3,0) NW of Meridian). Cell = 512 m tile, origin = NW corner, heights raw/32 m,
  1024^2 samples at 512/1023 m, shared edge samples (seam delta 0.0 m).
- D34 (svet) Start = 3 m from campfire `Campfire_x04_y-03_01` towards the village centre, Godot (2489.1, 216.1, 1347.8);
  start campfire = that campfire.
- D35 (svet) Internal names: Watcher=scout, Strider=horse, Grazer=harvester (planning guess antelope was wrong:
  antelope=Lancehorn); longhorn=Broadhead, bison=Trampler, raptor=Thunderjaw, direwolf=Sawtooth, greywolf=Ravager,
  mole=Rockbreaker.
- D36 Machine health = real HZD InitialHealth (Watcher 90, Strider 105, Grazer 150) x `combat.machine_health_scale`
  (default 1.0, tuned by test); machine armor stays a design value via the CS armor rule. HZD sight angles are half
  cone angles (game doubles them for FOV). Watcher real perception: sight 45 m, peripheral 96 m, hearing 100 m,
  suspicious 30 m, alert 15 m.
- D37 (svet) Whole world converts: 340/340 cells with real terrain, 52 s for the whole world with 2 workers (median
  0.1 s/cell, max 5.7 s); 131 cells with placed objects (1.63 M instances), 167 campfires, 80 machine sites; whole world
  4.2 GB. Bootstrap (incl. CS2) 69.6 s on an empty cache; cache after bootstrap ~762 MB (hzd 646 + cs2 116).
- D38 (svet) Not in v1: machine animations from HZD (no decoder; procedural), normal maps, GPU-procedural wilderness
  rocks, random world encounters (fixed sites only), outdoor wind/rain ambience (6-ch ATRAC9; ambience = birds + fire).
  New dependency TinyBCSharp 0.1.2 (MIT, already pulled in by ValveResourceFormat).

## Site mapping (variant B)
Full per-site table: `docs/notes/svet.md`. No placement references `ai/groups`, so the "type" rows apply.
| original | sites | machines orig | populated with | machines now |
|---|---|---|---|---|
| horse | 20 | 74 | strider | 76 |
| longhorn (Broadhead) | 23 | 88 | grazer | 89 |
| goat | 12 | 60 | strider | 53 |
| antelope (Lancehorn) | 5 | 44 | grazer | 28 |
| harvester (Grazer) | 4 | 16 | grazer | 17 |
| spraybot | 3 | 5 | strider | 7 |
| crab | 2 | 7 | strider | 7 |
| hyena (Scrapper) | 2 | 7 | watcher | 6 |
| scout (Watcher) | 2 | 5 | watcher | 5 |
| bison (Trampler) | 1 | 5 | strider | 5 |
| beachlizard | 1 | 3 | watcher | 3 |
| glider (Glinthawk) | 1 | 4 | watcher | 3 |
| cargorhino | 1 | 2 | strider | 2 |
| direwolf (Sawtooth) | 1 | 1 | watcher | 2 |
| longleg | 1 | 2 | watcher | 2 |
| mole (Rockbreaker) | 1 | 2 | watcher | 2 |

## Log
- 2026-10-09 Melty draft created: modId `6e2ecdda-6217-40c2-b016-e6940db6aee4`, slug `horizon-strike`,
  Studio https://melty.gg/studio/6e2ecdda-6217-40c2-b016-e6940db6aee4 (title, games, MIT, madeBy EM; text later).
- 2026-10-09 CS2 updated by the user: buildid 25738536 -> 25815307 (StateFlags 4, fully installed). All CS2 evidence
  and conversions from now on refer to build 25815307.
- 2026-10-09 cs2 merged (C1-C5 accepted): 14 items, 27 glb, cache/cs2 115 MiB, ~60 s full conversion; second run
  `cs2 up to date (25815307)`; Build-Converter publish verified by the orchestrator (96.3 MB, hzsconv --help ok).
- 2026-10-09 svet merged (S1-S8 accepted; Watcher bind-pose height 1.45 m is real data, below the planned 1.5-4 m guess).
- 2026-10-09 cs2 content contract merged (b9b827c): weapons content_model/bone_roles/points, meta.json for 14 items, 0 mismatches; attach bone read from viewmodel skeleton (no hard-coded wpn).
- 2026-10-09 svet D32 follow-up merged (f90c947): new sheet hzd_content.json (52 rows) holds all HZD paths/names; output byte-identical; PROTO OK (bootstrap 70.6 s). Orchestrator fix: converter log falls back to converter-<pid>.log when another converter holds converter.log (autotest children).
- 2026-10-09 hra merged (c0ec0cd): game runs end-to-end on real content (CS2 weapons with real viewmodel clips, 3 HZD
  machines on real skeletons with procedural IK animation, real terrain + 37k instances/cell, vegetation, campfires,
  music). Dev checks: t05/t06/t07 pass in real mode, t10 pass on mock only (cap formula), first start world_ready
  ~88 s, 64.6 fps at start. Orchestrator ran tools/build.ps1 into dist/ (converter 96.6 MB + game 104.4 MB) and
  `preflight package dist` -> CLEAN.
- D39 (hra) Wider request ring only while moving; ring cells requested after world_ready; vision cone = 2x HZD half
  angle, instant detection only inside it, peripheral builds suspicion at 0.3x; herds flee on shots/explosions;
  weak spot wins within 15 cm behind the body hitbox; per-bone vertex-fitted box hitboxes; static mesh LODs via
  Godot's built-in mesh LOD generation; shadows only from objects >= 12 m; a failed bootstrap with a playable cache
  continues; automated runs never capture the mouse. Movement constants + kevlar armor points remain unverified
  (CS2 defaults live only in server.dll binaries) -> design values with evidence "CS2 cvar defaults".
- 2026-10-09 test merged (5d1bc3d). Exported build (as Melty launches + --autotest): 13/14 PASS, FAIL t10 (F6:
  converter per-cell done.bytes cumulative -> game cache size inflated). t09: bootstrap 74.4 s, 341.5 MiB at
  world_ready (start cell only), 749.0 MiB after 3x3. Screenshots in _tools/autotest-dist. Fix round started:
  svet (F6, vegetation alpha, terrain albedo, rock tint), hra (F5 Jolt compound depth -> missing collisions, F7 herd
  flee distance, fire() point/distance, magenta splotch, cache size from disk).
- D40 (test) Scenario order t03 before t02, s03 before t06; t04 accounts for CS range falloff; t09 allows cells within
  2 of start after bootstrap; t10 cap reserve 50 MiB; s02 re-shoots from 6 m when the Watcher is too small.
- 2026-10-09 hra fix round merged (f14594f): instance collisions split into bodies of <=256 shapes (no Jolt errors over
  3x3; engine errors mirrored into latest.log), cache size measured from disk (t10 PASS: max 806 MB vs cap 1368 MiB,
  6 evictions), herd flees to flee_distance_m then re-homes (t06 PASS 29.4 -> 84.9 m), fire() returns point/distance,
  pink splotch was an eye light (now emissive only). Runner on real data: t05,t06,t10,s01-s03 PASS.
- D41 (hra) Transparent meshes wider than 64 m (HZD far-forest impostors) render only beyond 220 m and have no
  collision; transparency follows glTF alphaMode/alphaCutoff/doubleSided only.
- 2026-10-09 svet fix round merged (376a15c): F6 fixed (per-job bytes, exact sum check), BC4/BC5 decode fix (vegetation
  alpha + rock AO were corrupted), alpha only from alpha-type channels, standalone colour textures (carex), terrain
  albedo 2048 px (0.25 m/px; ~19 MB/cell, whole world ~+1.5 GB), optional instances[].tint (rock ground tint 0.5).
- D42 Terrain colour: HZD computes it in per-tile compiled shaders; the engine-baked `flattened_albedo` is the
  faithful source. Mother's Heart (4,-3) is 67 % snow in HZD's own snow map, so a white valley is correct. No HZD
  close-up detail layers -> game adds own procedural detail noise. Terrain normal map not exported (no tangents).
- D43 Vegetation species read via PlacementTargets (fix in progress) with per-species density + global density scale.
- 2026-10-09 hra follow-up merged (7b8a8f2): rock tint via MultiMesh instance colours, terrain albedo mipmapped +
  S3TC + anisotropic + own procedural close-up noise, vegetation species params with per-cell budget
  (`streaming.vegetation_cell_cap` 14000, `streaming.vegetation_density_scale` 1.0). Fresh conversion: world_ready
  68.3 s (start cell only), 3x3 +17.3 s, 826 MB; 62.6 fps at start (worst frame 17.2 ms); runner t05,t06,s01-s03 PASS.
- 2026-10-09 svet vegetation merged (e8fa530): species via PlacementTargets (4_-3: 118 species in 241 layers, 6 picked
  per channel incl. snow/no-snow variants by HZD's ecotope_effect snow map), cell.json format 3 (veg_effect.png,
  per-species per_m2/max_instances/cluster/effect_range), sheet rows vegetation.density_scale 0.25 and
  max_instances_per_species 3000 (performance). Bootstrap 59.8 s in proto_smoke.
- 2026-10-09 hra vegetation merged (f3b8cd7): effect_range on the snow map, clusters, max_instances, tree budget
  `streaming.vegetation_tree_cap` 1800 + rest of 14000; small plants fade at 45 m, shadows 100 m, LOD threshold 6 px,
  alpha-to-coverage off. 71.9 fps at start (worst 31.1 ms); runner t05,t06,s01-s03 PASS; export includes autotest/
  (runs only with --autotest), excludes dev/.
- D44 CS2 movement/combat engine constants (not in CS2 data files) verified against the public CS2 command reference; sv_accelerate 5.5 kept (reference table value). Sheet preflight: 2871/2871 cells verified, CLEAN.
- 2026-10-09 Release prep: runtime BC compression only in editor builds (release templates lack it; release uses
  uncompressed textures: ~58-65 fps at start, 1.1-1.5 GB VRAM); 30 s perf line in latest.log; cache size scans
  (game + autotest) never call FileAccess.get_size on paths that may vanish; s03 picks a camera position that sees the
  whole herd (test d9b1a3d).
- 2026-10-09 Final-release autotest round 3 (0.1.0-final): 11/14, 0 engine errors; found mesh GC deleting meshes the
  converter session still considered written (cell re-conversion referenced missing files) and partial herd
  activation under the machine cap; test scenarios left spawned machines behind. Fixed: test per-scenario cleanup +
  t04 line of sight (128fa4d); hra GC pins meshes known to the running converter and runs only when idle, whole-herd
  activation nearest-first (ba7bc33). Open: converter re-export of missing meshes (svet), a 1-in-4 segfault during
  mock world load (hra investigating).
- D45 A site activates only when its whole herd fits under spawning.max_active_machines; nearest sites first, far
  idle sites yield.
- 2026-10-09 svet 6074fe1 merged: WorldMeshes.Ensure re-exports missing glb/.tex/textures; CellUpToDate requires all referenced files (GC regen verified in one serve session).
- 2026-10-09 hra 634a156 merged: three data races fixed (mesh_library dicts read by workers, job dict written during task, converter queues unguarded). Segfault not reproduced in 122 runs before/after (original 1/4). D46 worker code never reads dictionaries the main thread writes; shared state only via mutex-guarded sets or pre-allocated slots.
- 2026-10-09 Release candidate rc5 (main): `tools/build.ps1` -> converter 96.6 MB + game 104.5 MB; package preflight
  CLEAN; full autotest on the release exe launched as Melty does (+ --autotest): 14/14 PASS, 0 engine errors, no
  `mesh missing`; t09 bootstrap 71.8 s, world_ready 73.4 s after start with only cell 4_-3 (345.8 MiB), 3x3 ring
  12.4 s later (793.3 MiB); t10 max 904 MB under a 1.51 GB cap with 24 evictions.
- 2026-10-09 Melty: inspect_package / validate_recipe valid / one_click_check "yes"; listing text updated (title Horizon
  Strike, MIT, madeBy EM, remix allowed); upload 70a3517b-a6fe-4520-b4ee-99764e8d8bfc (HorizonStrike-0.1.0.zip,
  82,462,465 B, sha256 c9919d5b...ce06); release 0.1.0 = a59fbb25-0e99-4374-a5bf-1251e18ff67a (draft, publishable,
  findings: review-level only); screenshots buy_wheel (cover), watcher_alert, herd_landscape from the rc5 autotest.
  Not published – waiting for the user's yes.
- 2026-10-09 GitHub: origin = https://github.com/jakub2929/HorizonStrike (empty, not pushed). melty.json committed
  (d9ad69b, fileName HorizonStrike-*.zip, validated). create_mod with githubRepo created a SEPARATE empty draft
  6dff49e8-b36e-4d0d-b9df-7960ebc8ccbc (slug horizon-strike-2) instead of linking the existing listing; the tools
  cannot delete drafts or attach a repo to an existing listing (user can delete the empty one in Studio).
- 2026-10-09 User approved publishing; publish(6e2ecdda...) -> in_review.
