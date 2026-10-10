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
- 2026-10-09 LIVE: mod_status "live; live version 0.1.0", release 0.1.0 live, one click yes. Public page
  https://melty.gg/m/horizon-strike returns 200 without login; 3 screenshots in order buy_wheel (cover, media
  55e12aea), watcher_alert, herd_landscape; full description text present; "Made by EM", MIT; mashup_info: open for
  remixes. History scan before push: 135 commits / 557 blobs, no game-derived files. melty.json holds no listing or
  GitHub reference (link to horizon-strike-2 is server-side; user deletes that draft).

## 0.1.1 / 0.2 (2026-10-09)
- Preconditions checked: 0.1.0 live (1 player), history clean, origin/main = 45638b3, horizon-strike-2 deleted by the
  user; melty.json carries no listing reference (format has none).
- Hotfix 0.1.1 started: buy wheel cannot buy anything for players; t03 passed via Game.buy() (bypassed input).
  hra reproduces/fixes through real input; test rewrites t03 (and audits others) to use Input.parse_input_event.
- Hotfix root causes: (1) full-screen wheel Control MOUSE_FILTER_STOP swallowed mouse before _unhandled_input ->
  selection via gui_input; hold B + release over item buys; (2) gameplay input gated on mouse capture -> now gated on
  UI state + window focus, mouse re-captured when wheel/menu closes; (3) Grazer/Strider canisters unhittable (weak
  sphere inside a body box) -> weak geometry from skeleton structure, weak wins inside an enclosing body box;
  (4) quit paths stop the converter with time limits. t03/s01/t02/t04/t06 now drive real input via
  Input.parse_input_event.
- D47 Gameplay input = UI state + focus, never mouse capture; full-screen UI handles mouse in its root gui_input.
- 0.1.1 release: build CLEAN, autotest on release 14/14, 0 engine errors (t03 buys p250/ak47/hegrenade/kevlar/deagle
  via input, AWP refused). Melty: upload 73d9058a-0214-46ff-86e7-39c79d92f5e7, release 0.1.1 =
  544104e6-b3f9-404e-ade4-4aadf27346e8 (draft, publishable, one click yes). Waiting for the user's yes.
- 0.1.1: user approved; Controls line updated in the listing; publish -> in_review.
- Phase 2 (0.2) started: docs/BRIEF-0.2.md; rule "tests drive the player's input" added to CLAUDE.md (D48).
- 0.1.1 live (mod_status live version 0.1.1); public page shows the updated Controls line.
- 0.2 plan merged (sheets machines 6 rows, machine_attacks 16, systems +render/perf, autotest t12-t16/r01-r04;
  site_map for new machines held back until models + AI exist). Converter already converts all 6 machines
  (broadhead 159 joints, 2.17 m). docs/PLAN-0.2.md.
- D49 New archetypes predator (Sawtooth) / scavenger (Scrapper); Broadhead = herd with defend_charge; kill_reward_mult
  4.5 / 2.5 / 2.0 = round_to_0.5(1 + log2(hzd_health/90)) (Strider 2.0 kept for armour).
- D50 Sheet columns behaviour + anim (owner stroje); systems groups render + perf; autotest kind record.
- D51 Fixed time of day 9.0 h (HZD bakes lighting at 9.0); atmosphere from nora_mothers_heart_cycle (hypothesis, svet).
- D52 Texture formats by role: world albedo BC1, alpha albedo BC7, hero BC7, normal BC5, ORM BC1, terrain masks BC7.
- D53 Perf measured at 1920x1080 without vsync on perf.route_cells; stress = 20 child runs over 30 cells.
- D54 Before/after shot poses defined anew; "before" shots taken with the 0.1.1 build.
- D55 Ownership split hra/stroje per docs/PLAN-0.2.md.
- svet V0–V2 done (branch worktree-agent-a8855f4cacc830f33, 00c8126/72e079a), held until hra H3 (DDS loader):
  textures: 462, VRAM est 690 MiB uncompressed -> 109 MiB BC (start set); own BC1/BC3/BC5/BC7 encoders (BCnEncoder.Net
  BC7 6-14 s/MPix too slow; own mode-6 BC7 116 ms/MPix, PSNR 32.7 dB); DDS DX10 headers; normal BC5 + ORM BC1 from HZD
  texture sets; instances[].kind; start 3x3 textures ~232 MiB incl. normals/ORM; whole world 159 s / 5.15 GB.
- D56 terrain.albedo_px (converter) is the single source of terrain texture size; cache.terrain_texture_px deprecated.
- svet V3 done (8525693, not merged yet): Sawtooth 1100 / Scrapper 220 / Broadhead 175 HP (HZD, non-corrupted);
  weak spots canister / power cell + radar / 2 canisters (HZD x1.5); Sawtooth mesh skinned to the Ravager rig ->
  builder reads helpers from own then shared rig; Broadhead uses Strider AI perception (45 m / 12 deg); site_map
  prepared: direwolf->sawtooth (1 site, 1), hyena->scrapper (2 sites, 7), longhorn->broadhead (23 sites, 86);
  PAS_Direwolf (5,-3) has no objects in the archives.
- Merged svet V0–V2 (72e079a) + hra H1–H3 (70b8582). H1 cell-load profile (route 32 cells, 1920x1080, editor, old
  PNG cache): add_child median 187 / max 1126 ms (biggest), first_draw 57/418, mesh_upload 28/303, collision 45/295,
  multimesh 54/241, terrain_collision 47/73, terrain 6/29; worst frame median 443 / max 1676 ms; worker prepare
  1389/5976 ms; VRAM at start 780 MB. H2 (one cell at a time, 6 ms main-thread budget, object collision only within
  150 m in 32 m bins, terrain collision 257^2 heightmap per cell = 2 m grid, herd spawns 1 machine/frame, machine
  types warmed on the loading screen): worst frame on route 77.3 ms (median 44.9), add_child max 11 ms; 2 frames >
  50 ms are first-draw shader compiles (H8). H3: DDS loads in the RELEASE template (BC1->DXT1, BC5->RGTC_RG,
  BC7->BPTC); release VRAM at start 1022 MB (texture 585, buffer 414) on the DDS cache.
- Merged svet V3–V7 (596463f) with the site_map change for the new machines HELD BACK (stored in
  _tools/site_map_v02.json; re-applied after stroje M2): V4 terrain layers (4 shared HZD layer sets snow/grass/dirt/rock
  from 21-southernrockies + per-cell masks.dds from snow map, slope, undergrowth density, roads), V5 water (HZD tile
  water layers -> cell.json water.instances; 31 in 4,-3), V6 occluders (boxes >= 8 m, max 256/cell + 33^2 terrain grid)
  + hlod.glb (HZD coarse LODs, <= 20k tris), V7 ATRAC9 via vendored LibAtrac9 (Alex Barney, MIT; THIRD_PARTY_NOTICES)
  -> wind_0/1, rain_0/1 stereo; render.* sky/fog/sun from the Mother's Heart cycle at 9:00 (sun elev 17.5 deg, az 90,
  fog 50-950 m). cell.json format 8. Bootstrap 101.6 s with other agents loading the CPU.
- Merged stroje M0–M3 (68ef7a4): own analytic leg IK in one SkeletonModifier3D (4–7 joint legs + step planner),
  gaits from the sheet `anim` column, body tilt, turn in place, graze, attacks, hit react, death fall (corpses freed
  after 45 s when > 80 m away, max 240 s), animation LOD by distance (35/70/120 m -> every 2/3/6 frames). Bench real
  models: foot slide / penetration (cm) watcher 0.0/0.3, strider 0.0/1.0, grazer 0.0/1.0, sawtooth 1.4/0.9, scrapper
  1.2/1.0, broadhead 0.0/1.0 (M0 baseline watcher 14.3/1.4, strider 30.6/26.1, grazer 26.2/7.3). AI bench: Sawtooth
  suspicious->alert->stalk->attack (charge, bite); Scrapper radar pings call the pack, laser burst; Broadhead charges,
  never flees. Weak spots 8 dirs: watcher 8, strider 7, grazer 8, sawtooth 8, scrapper power cell 6 / radar 8,
  broadhead 7. Broadhead neck rest pitch 40 deg (anim.neck_rest_pitch_deg).
- site_map for the new machines re-applied (direwolf->sawtooth, hyena->scrapper, longhorn->broadhead).
- Merged hra H4–H8 (ad29048): shader precompile on the loading screen (variants kept alive all session; spread
  unloading), layered terrain (renormalised masks, triplanar rock), HZD sky/sun/fog (AgX; height-fog falloff at 2 %),
  water material (no collision), occlusion culling (start draw calls 1404 -> 831), far cells = coarse terrain + HLOD,
  render.lod_threshold_px 12 (GPU 15.0 -> 11.9 ms at start), FXAA instead of MSAA 2x, shadow atlas 2048, stalk counts
  as combat. Release route (format-8 cache, converter idle): 98.4 fps avg, 1 % low 46.0, worst load frame 48.7 ms,
  VRAM at start 1425 MB. Open: background conversion during play drops 1 % low to 5.5 fps; rare segfault at first
  cell build (1/13 mock smokes); t05 Watcher skipped `suspicious`; some 1x1 DDS mips warn.
- D57 LOD threshold 12 px from the sheet; FXAA; precompile on loading screen; far cells via HLOD proxy; ring 2 converted
  even while standing.
- Merged svet 1e11f80: converter BelowNormal + throttle op; throttled (1 worker, 2 threads) CPU share mean 9.6 % /
  max 17.2 % of 12 cores vs unthrottled 27.9 % / 45.6 % (6 cells 43.3 s vs 16.7 s); tiny DDS padded to 4x4
  (WorldMeshes.Format 5); cell.json `sheets` hash -> site_map/hzd_content/machines(id, herd)/render/streaming changes
  reconvert stale cells.
- Merged stroje 2545ce1: calm machines always go through `suspicious` first (0.8 s guard/predator/pack, 0.4 s herd),
  also for calls from other machines and shots; immediate alert only when hit by the player or the player is within
  max(3 m, immediate_alert_m/4). t05 PASS 2x on real data, t06 PASS; AI bench PASS for all 6 in 4 scenarios.
- Merged test 8e29972: t12 PASS (3 new machines' cycles), t13 PASS via real input (weak spot hittable from: watcher 7,
  strider 7, grazer 8, sawtooth 5, scrapper 7, broadhead 7 of 8; sawtooth canister 0.7-2.1 m behind the body surface in
  3 directions), t14 FAIL (buildings with normal maps 72.8 %; terrain 14/14, rocks 99.9 %), t15 measured on a build
  BEFORE hra H4-H8 (route 66.7 avg / 25.3 1% low / 541 ms load frame) - to re-run, t16 2/20 runs ok but a crash
  (0xC0000005) after "quitting (0)" when quitting ~1 s after a teleport (world stops waiting for a cell task after 10 s).
  0.1.1 baseline (noisy: other agents' Godot/converter runs): route avg 42-48 fps, VRAM 1230 MiB, 1.5-2 s hitch per
  cell load. Records: before/after PNGs, 18 machine clips + 25 s cell-crossing video, frame-time SVG.
- Merged svet b4e707d (t14 fix): building normal maps 72.6 % -> 99.3 % (100 % excluding materials with no HZD normal,
  flagged extras.hzd_normal="none"); Cauldron composite `_cmp`/`_nmt` plain textures accepted as normals after a pixel
  check; invisible occluder/collision helper geometry no longer exported (~36k building instances fewer);
  vegetation normals 77.5 % -> 100 %. WorldMeshes.Format 6.
- Merged hra 8762fe3: crash at quit/teardown (and very likely the rare start segfault) = World._exit_tree stopped
  waiting for a running cell-prepare task after 10 s and the engine freed resources the task still used -> tasks are
  cancellable (MeshLib.cancelled), short tasks high priority, quit waits up to 60 s, last resort self-kill with exit 0.
  Runs: before 1/30 + 1/30 crashes; after 0/40 starts, 0/15 quit@12 s, 0/20 quit@8 s, 0/30 mock smokes. Throttle wired
  (world_ready -> workers 1 / threads 2, rows streaming.converter_workers_play/_threads_play): active-conversion route
  1 % low 62.6 -> 76.0 fps, frames > 50 ms 14 -> 3, worst 145 -> 112 ms (4 surface pipelines still compile after the
  precompile; one 101 ms log write under disk contention).
- Merged hra 0fae764: non-blocking log (background writer, 25 ms), uniform vertex layout (all surfaces get normals +
  UV so they hit precompiled pipelines; pipeline_watch logs in-world compiles: none on the route). Release route with
  active throttled conversion: 0 frames > 50 ms, worst 45.3 ms, route 1 % low 83.2; start phase 1 % low 43.2 (risk).
- Sheet preflight CLEAN (render.* verified from hra H3/H5 evidence, perf.shot_poses from test T1). Version 0.2.0.
- T6 on release 0.2.0 (quiet machine; test 99e2a9a): 17/19 PASS. t15 FAIL only on one 51.7 ms load frame (cell 1,-2;
  next worst 45.2); start 80.8 avg / 74.4 1 % low, route 92.5 / 52.5, VRAM 1532 MiB. t16 20/20 runs exit 0, 30 cells
  each, RSS +0.6 %, but run 1 logged 5 errors (F10: with the cache nearly full, eviction deletes a cell the route needs
  -> "cell.json missing or invalid", reconverted 2 s later; many "eviction failed"). t13 weak spot first-hit: watcher
  7, strider 8, grazer 8, sawtooth 4, scrapper 7, broadhead 7 of 8. t14 PASS (buildings 100 % excl. 19 hzd_normal
  none). Clean 0.1.1 baseline: start 78.4/70.3, route 78.7/46.3, worst load frame 1435 ms, VRAM 1230 MiB.
  Records final in _tools/records-0.2/final.
- Merged hra 4035952: eviction never removes protected cells (request ring around/ahead of the player, requested,
  building, loaded, being read, written < 10 s ago, converter .tmp present); a cell leaves by ONE rename into
  <cache>/trash (Windows refuses while a file is open -> never half-deleted), trash emptied on a worker, max 4
  evictions/s; mesh GC on a worker (was 2.8 s main-thread frames with 60 cells); --cache-cap-mib for one run.
  t16 on release: 4/4 runs exit 0, 0 errors, 100-147 evictions each. Visual: neutral cool ambient in shadow
  (render.ambient_color, ambient_sky_contribution 0.35), horizon ground colour = horizon/haze colour, terrain layer ORM
  G treated as gloss (render.terrain_layer_gloss, min roughness 0.6). t15 1/3 PASS (53.4 / 49.6 / 50.5 ms worst):
  Jolt builds 16 trimesh shapes when a body enters -> each new shape now built in its own step (unverified at commit).
- Disk C: filled (0.95 GB free) by ~186 GB of agents' test caches -> 120 folders moved (not deleted) to
  E:\meshy_offload\_tools (OTAZKY.md). New test caches go to E:\meshy_work\.
- 0.3 started (docs/BRIEF-0.3.md). Branch `release-0.2` marks the 0.2.0 release state (779dbe1).
- Merged cs2 a83b4a2: 22/22 CS2 knives convert (Knife, Knife T, Bayonet, Classic, Flip, Gut, Karambit, M9 Bayonet,
  Huntsman, Falchion, Bowie, Butterfly, Shadow Daggers, Paracord, Survival, Ursus, Navaja, Nomad, Stiletto, Talon,
  Skeleton, Kukri), 132.2 MiB, 45 s, on demand via the knives op. weapon_knifegg (Arms Race golden knife) is excluded
  by the selection rule (no used_by_classes). Knife finishes cannot be converted: CS2 composite materials (vcompmat)
  are built by shaders and VRF 20 does not evaluate them – default finish only (3 attempts).
- 0.3 plan merged (docs/PLAN-0.3.md; sheets machines.xp_reward, systems xp/upgrades/fx/persist/knives/bhop/silent
  strike, hooks feedback sounds + persistence, autotest t17–t24, r05–r08).
- D58 xp_reward = 100 x kill_reward_mult; arithmetic level curve 300/150 to level 15; bonuses weak-spot kill +20 %,
  silent strike +30 %.
- D59 BHOP: 100 ms window; jumps 1..N keep speed; jump N+1 = friction + clamp to 1.0 x run speed; level 0 = 0.2 movement.
- D60 Silent strike = knife stab into an unaware machine outside its vision cone, damage x5 (design).
- D61 Hit sounds = CS2 *.AttackerFeedback / *.Victim events + SolidMetal.BulletImpact.
- D62 Player profile in loadout.json + progression.json (%LOCALAPPDATA% or --user-dir), never in the cache.
- Merged svet d39d662: converter idle release (after 5 s idle: archives closed, mesh exporter dropped, heap compacted
  incl. LOH, working set trimmed): idle 4278/4250 MB -> 7/118 MB (working set/private); first request after release
  +0.45 s; optional --idle-exit-s (restart costs ~1.3 s, off by default). Peaks still 4.0-6.4 GB during bootstrap and
  4.5 GB while converting cells -> to reduce.
- Merged hra H1–H5 (28da446): knife menu (Esc > Knife, rotating 3D preview, loadout.json, on-demand knife conversion,
  F inspect), XP/levels/points/upgrades (progression.json, K menu + Esc, HUD bar + level-up), silent strike (one stab
  kills; +130 XP on a watcher), damage upgrade x1.10 per level in Combat, bhop levels per sheet (level 0 clips every jump
  10.16 -> 6.35 m/s; level N keeps N jumps), player-side effects (hitmarker normal/weak/kill, damage numbers + Esc
  toggle, direction indicator, vignette, aimpunch, CS2 hit/hurt sounds), test API (--user-dir, knife_id,
  horizontal_speed, aimpunch_deg, viewmodel clips, Game.progression/set_progression, fx_stats(), signals
  machine_killed/player_hit_machine/player_hurt/level_up, HUD node names). Esc works in automated runs; settings.json
  moves with --user-dir.
- 0.2 release process: tag v0.2.0-rc = 140134b (commit the 0.2.0-final candidate was built from at 07:45), branch
  release/0.2 from the tag; the 6.8 s t15 frame is fixed on release/0.2, then merged into main. (The earlier branch
  release-0.2 at 779dbe1 has identical code; release/0.2 is the one used.) Stress run t16: 5x, only when loading/quit
  code changes (CLAUDE.md).
- t15 6.8 s frame analysis (hra): the final t15 run had 18 frames > 1 s (up to 14.4 s), also in other processes in the
  same window, with almost no streaming work in them. The orchestrator's disk offload (robocopy of ~150 GB C: -> E:)
  ran 07:44–08:27:44, overlapping t15 (08:20:08–08:28:57) -> system-wide I/O stalls are the most likely cause. Plan:
  re-run t15 on the unchanged 0.2.0-final build on a quiet machine after t16; fix on release/0.2 only if it reproduces.
- Merged hra 0.3 RAM (142b839, 7ee19bc) + slow-frame diagnostics (4760186): meshes/materials/textures held per cell
  and released with the last holder (RAM + VRAM), re-prepared on a worker if needed again; dup_mesh/dup_tex counters
  stay 0; dropped build data freed on a worker; `mem:` report every 15 s. Headless 20-cell route: 1845 meshes released,
  0 duplicates; static memory 1.2–1.56 GB headless (measurable cell arrays ~165 MB; rest nodes/physics/renderer).
- Merged hra 2475370: settings/loadout/progression writes on a background thread; eviction checks + rename on a
  worker; converted-cell size via async scan; knife index re-read on a worker; music/ambience loaded on a worker;
  hit/weapon sounds preloaded on the loading screen; fixed a quit crash from un-awaited knife-index tasks.
- 0.2 final T6 suite (release 0.2.0-final): 18/19 PASS – all 14 old + t12, t13, t14 + t16 (20/20 runs, 30 cells each,
  exit 0, 0 errors, RSS 2.73–2.93 GB, VRAM ~2.11 GB); t15 FAIL on one 6.8 s frame during the disk offload -> re-run 3x.
- Merged svet 69d5b1c: converter peak RAM 4.1–5.8 GB -> 1.22 GB in play (1 worker/2 threads) and 4.0–4.6 -> 2.08 GB
  in bootstrap: one shared byte-bounded LRU core-file resolver (perf.converter_resolver_mb 256), byte-LRU image cache
  (64 MB), pooled archive block buffers (no LOH garbage), memory governor compacting above perf.converter_soft_cap_mb
  1200 (bootstrap 2048). Same CPU time, byte-identical output. Remaining bootstrap peak is the CS2 weapons phase
  (1.8–2.0 GB).
- 0.2.0 uploaded to Melty as DRAFT: release 024c27ab-d661-45b7-9226-0ec9dbcb68e8, upload e6a95a38 (zip sha256 abfec3ed…,
  built from v0.2.0-rc, verified free of 0.3 features). t15 re-runs on the quiet machine: 2/3 PASS (route 1 % low 49.0 /
  44.4 / 47.1; load frames <= 37.9 ms). Listing text + new screenshots applied only at publish (they go live at once).
- 0.2.0 first launch re-measured on a quiet machine, clean default cache (%LOCALAPPDATA%): world ready 81.9 s
  (bootstrap 68.8 s: CS2 weapons 57.6 s, machines 1.9 s, audio 1.6 s, index 0.1 s, start cell 7.6 s; BC encode 9.1 s
  CPU of ~13 s in the start cell); converter throttle only after world ready. The 554 s t09 run overlapped the
  150 GB robocopy onto E: (HZD + test cache on E:). No release/0.2 change needed.
