# hra journal (Godot game, tools/build.ps1 export part)

Source of truth for my running decisions. Newest entries at the bottom of "Log".

## Layout (game/)
```
project.godot            autoload Game = res://core/game.gd, main scene res://main/main.tscn
core/                    log, args, paths, settings, hzd_detect, sheets (resolved -> fallback -> default),
                         combat (CS damage/armor/range rules), converter_client (hzsconv serve over stdio),
                         mock_converter (--mock-data: synthetic cache written by an in-process worker), mock_data
main/                    boot flow (args -> log -> HZD detection -> loading -> world) + autotest runner hook
world/                   streaming, cell builder (terrain/instances/vegetation/campfires/spawns), cache manager
player/                  CS movement, weapons (hitscan, grenades, molotov), viewmodel
machines/                machine AI + procedural animation, spawner
ui/                      HUD, buy wheel, loading/error/missing-HZD screens, settings menu
audio/                   music/ambience director, sound helpers
dev/                     dev-only scripts (smoke.gd), excluded from export
generated/               tools/gen_sheets.py output (never hand-edited)
```
Rules I follow: no class_name lookups across files (everything via preload, so a fresh checkout without
`.godot/` runs `--script` directly); no game assets in game/ (all placeholder art is generated in code).

## Verified engine facts (Godot 4.7.2, probed in a scratch project)
- `--doctool` dump in `C:\meshy\_tools\godot-docs` (signatures only, descriptions empty).
- Args before `--` arrive in `OS.get_cmdline_args()` (incl. `--script <path>`, not `--headless/--path`), after `--`
  in `OS.get_cmdline_user_args()`.
- Autoloads are instanced in `--script` mode (root has the autoload node).
- `OS.execute_with_pipe(path, args, blocking=true)` -> `{stdio, stderr, pid}`; a reader thread doing blocking
  `get_line()` receives every line and gets an error/empty line at EOF; writing from the main thread meanwhile works.
  `blocking=false` returns EOF immediately (useless for a reader thread).
- Exists: TwoBoneIK3D, ChainIK3D, CCDIK3D, FABRIK3D, LookAtModifier3D, SkeletonModifier3D
  (`_process_modification_with_delta`), GLTFDocument.append_from_file/append_from_buffer/generate_scene,
  HeightMapShape3D (map_width/map_depth/map_data), AudioStreamMP3/WAV.load_from_file, Image.load_svg_from_buffer.

## Log
- 2026-10-09 start. Dev cache `C:\meshy\_tools\cache-dev` does not exist yet -> H1 on mock data.
- H1 done on mock data. `--mock-data` runs an in-process mock converter (core/mock_converter.gd) that writes a
  synthetic cache (formula stats, noise terrain, primitive glTF meshes) with the converter's layout, so the real
  loading/streaming code runs. Acceptance `godot --headless --path game --script res://dev/smoke.gd -- --mock-data`
  -> `SMOKE OK`, exit 0 (3 runs on an existing mock cache + 2 on fresh caches).
- Engine finding: creating RenderingServer resources (ArrayMesh, glTF scene generation, primitive meshes) on
  WorkerThreadPool threads corrupts RIDs with the headless (dummy) renderer. Cell building is now staged: worker
  thread = pure data (heights, terrain arrays, images, transforms, scatter), main thread = meshes/glTF (8 ms budget
  per frame) and nodes. Running worker tasks at quit segfaulted the engine -> World._exit_tree waits for them.
- Decision: `streaming.request_ring` (2) is only used while the player moves (> 1 m/s); a standing player needs
  `load_ring` around itself and the lead point. First launch therefore converts exactly the 3x3 bootstrap ring
  (verified: fresh mock cache, standing 6 s -> 9 cells). Needed for t09 ("<= 9 of 340").
- Decision: machines spawned through `Game.spawn_machine` face the player (front weak spots like the Watcher eye
  would otherwise be hidden behind the head hitbox when spawned facing away). Site spawns keep random headings.
- Decision: `Game.fire()` fires immediately (ignores fire-rate/deploy gates; the autotest drives timing), everything
  else is the normal path (ammo, inaccuracy, recoil, range falloff, armor, noise).
- For test (relay via main): damage returned by fire() includes the CS range falloff
  `damage * range_modifier^(dist_u/500)`; t04 expectations must include it (at 10 m the Glock eye shot is not
  exactly damage x headshot_mult). Knife reach is combat.knife_reach_m from the camera: spawn within ~1.5 m.
  Machine projectiles are in group `machine_projectiles`; player hits are logged `player hit by <attack>`.
- Logging: latest.log is shared by concurrent instances (append, pid on every line); a non-autotest launch truncates
  it unless it was written in the last 120 s.
- H2: `--hzd C:\nonexistent` -> latest.log `MissingHzdScreen shown (folder does not exist: C:/nonexistent)`. Real run:
  HZD auto-detected via Steam, `hzsconv serve` child process over stdio, progress drives the loading screen, the
  (not yet merged) HZD stage error shows the error screen, quit stops the converter.
- H3: real CS2 content works (seeded from cache-dev): view.glb in its own SubViewport world, clips + anim_events
  sounds, icons, resolved stats (reserve_as_clips true -> reserve = clips x clip_size). Smoke on real data OK.
- H5: real model.glb per machine (packed once per type), per-bone hitbox boxes from skinned vertices, weak spots
  on layer 16 winning within 15 cm behind a body box, knee = largest bend between 25-75 % of the chain, helper
  bones never animated, eye/head from meta. Bone poses read outside a SkeletonModifier3D are the unmodified
  ones (Godot 4.3+ restores them) -> use BoneAttachment3D positions for anything that must follow the animation.
- Decisions (MODLOG candidates): sight cone = 2 x meta perception.sight_half_angle_deg (the resolved
  `sight_fov_deg` holds HZD's half angle); immediate suspicion/alert distances apply only inside the cone and are
  scaled by stance x stealth grass; peripheral vision (outside the cone, up to peripheral_range_m 96) builds
  suspicion at 0.3x; grazing herds bolt from a gunshot/blast they hear (loud noise raising them to suspicious ->
  alert -> flee); ring cells are requested only after world_ready; automated runs never capture the mouse.
- Dev scenarios (dev/scenarios.gd, my versions through the Game API): t05 PASS (patrol,suspicious,alert,attack +
  eye bolt in ~6 s), t06 PASS (herd flees in 0.1 s, 33 -> 93 m), t07 PASS (respawn at B, knife+glock, armor 0,
  money kept), t10 PASS on 30 MiB mock cells (4 evictions farthest-first, max below cap, start cell back).
- H8: export preset + Build-Game verified from bash (PowerShell is blocked for this agent, so build.ps1 itself was
  not executed by me): 109 MB exe, boots on mock data, `preflight package dist` CLEAN.

- Content contract (D32) applied: core/content.gd resolves models (content_model -> meta.json model -> documented
  cache layout), bones only via bone_roles (head, neck, spine, tail, eye, leg chains as role names or "a>b>c"),
  positions only via points (weak_spot, attack_<id>, muzzle, eject). No game bone/file names left in code (only the
  documented cache layout as last fallback and generic gameplay words matched against sheet sound events).
- Real world pipeline: own glb reader (worker), textures decoded + S3TC once per hash, meshoptimizer LODs via
  ImporterMesh on the worker, chunked MultiMeshes with size-based fade, shadows only >= 12 m, collision in static
  bodies of 256 shapes. Real cell 5_-2 (37k instances): 174 M -> 6-8 M primitives; real start area 64.6 fps.
- Real mode end-to-end (svet merged): first launch on an empty cache: converter bootstrap 79 s, world_ready 87.7 s
  with only the start cell on disk, 3x3 after 19 s more, 785 MB, 14 weapons, 3 machines (dev/first_launch.gd).
  Dev scenarios in real mode: t05 PASS (5.5 s, eye bolt; log `music: combat`), t06 PASS (33.7 -> 85.6 m), t07 PASS.
- D36 implemented: machine health = hzd_health x combat.machine_health_scale (new hra-owned systems row, 1.0).
- Obstacle avoidance (feelers) added after herds piled up on real rocks/fences.

- Fix round (test findings): F6 cache size = measured cell folder + immediate full folder rescan (done.bytes only
  logged); F7 flee until flee_distance_m, then home moves there; F5 verified: every 3x3 cell's instances in static
  bodies of <= 256 shapes (e.g. 5_-3: 58,907 shapes in 231 bodies), 0 engine errors - engine errors/warnings are now
  mirrored into latest.log (core/engine_logger.gd, verified with a push_error probe); fire() returns point/distance;
  pink splotch = the Watcher eye OmniLight tinting snow in its shadow -> removed (emissive eye only); striped
  "slabs" = combined distant forest billboards (alpha MASK, 140-490 m wide) -> alpha meshes wider than 64 m are
  impostors drawn only beyond >= 220 m and get no collision; alpha only from the glTF alphaMode (no texture guess).
- Runner from test, editor build, real data (run1: C:\meshy\_tools\autotest-hra\run1, run2: ...\run2): t10, s01,
  t05, s02, s03, t06 all PASS (exit 0); t10 Game.cache_bytes max 806 MB vs disk 810 MB, 6 evictions; t06 29.4 ->
  84.9 m.
- Vegetation format 3: per species effect_range against veg_effect.png (L8 snow map; centre and every cluster
  member checked), max_instances, cluster {count, radius_m}, wander_m, footprint_m spacing, max_slope_deg. Budget:
  trees get streaming.vegetation_tree_cap (new row, 1800), the rest shares vegetation_cell_cap - tree budget.
  Start fps 38 -> 71.9 via: small plants fade at 45 m, plants <12 m fade at 0.45x, shadow distance 100 m, LOD
  threshold 6 px, no alpha-to-coverage. 4_-3: 6551 vegetation, 1377 draw calls, GPU 13.35 ms.
  Runner run4 (realfresh3): t05, t06, s01, s02, s03 PASS. Export pack: autotest/ included, dev/ excluded.
- Mesh GC vs converter: hzsconv remembers every mesh/texture it exported (or found) for its process lifetime and never
  rewrites it, so GC deleting a mesh of an evicted cell made its re-conversion reference a missing file. GC now keeps
  the refs of evicted cells whose cell.json is newer than the converter start (pinned) and runs only when the
  converter is idle and nothing is requested (retried every 5 s). Cost: meshes of cells converted in this session
  are freed only in a later session. Proper fix belongs in the converter (re-export when the glb is gone).
- Spawner: a site activates only when its whole herd fits spawning.max_active_machines (nearest sites first; idle
  sites farther away are deactivated to make room; corpses do not count).
- Segfault hunt (mock smoke crashed 1 of 4 during the first 3x3 load, never reproduced afterwards: 0/20 + 0/36
  stressed (3 parallel) + 0/5 real before the fix). Found data races: cell workers read MeshLibrary._entries/_textures
  (mutex-guarded on their side only) while the main thread inserted into them -> workers now read mutex-guarded
  _built/_tex_built sets; the build job dictionary got keys inserted after add_task while the worker wrote into it
  -> worker writes a pre-sized array slot only; converter/mock event queues were size-checked without the mutex.
  After: 0/20 + 0/36 stressed + 0/5 real. Converter now re-exports missing meshes (svet); GC pinning kept as a net.
- HOTFIX 0.1.1 buy wheel: the wheel's full-screen root Control has mouse_filter STOP, so the GUI consumed every
  mouse motion/click and _unhandled_input (where hover + click lived) never saw them -> nothing could be bought with
  the mouse in 0.1.0 (t03 used Game.buy). Mouse now goes through _root.gui_input; hold B + release over an item buys;
  a tap / release with nothing selected keeps the wheel open; warp via Viewport.warp_mouse; the automated-run guard
  that ignored B is gone (tests drive real input); log lines `buywheel: open/hover/select/denied/bought`.
  Verified with dev/buy_input_driver.gd (real InputEvents) in the editor and in an exported release exe (release
  templates ignore --script: the driver is added as an autoload through override.cfg next to the exe) at 1600x900,
  1280x720, 1920x1080.
- F8: gameplay input (move/crouch/jump, fire/reload/slots) is gated by Game.gameplay_input_allowed() = no buy
  wheel, tree not paused (Esc menu), window focused (automated runs skip focus) - not by mouse capture; mouse-look
  still needs capture; wheel/menu close re-captures in normal play. dev/buy_input_driver.gd checks W moves, key 1
  selects, LMB fires right after the wheel.
- F9: every quit path stops the converter first (world._exit_tree on a bare SceneTree.quit, Game.quit for the Quit
  buttons / error screen, main.quit_game for WM close); converter_client.stop() is bounded (quit 3 s, kill, readers
  joined at most 1 s each) and suppresses the expected "exit" event. Hang not reproduced (dev/quit_probe.gd, bare
  quit after a t10-like walk: exit 1 s, converter gone); a hard-killed game's converter exits within ~1 s (EOF).
- Weak spots (0.1.1): a bone whose only children are weak-spot bones is the weak part's own geometry (Grazer canister
  mesh) -> its box is a weak hitbox, not body; a weak hit wins when it lies within WEAK_SLACK_M behind the body
  surface or inside any body box of the same machine; Game.aim_at picks among the part's hitboxes (and points
  towards their surfaces) the nearest one the weapon's own trace reaches. dev/weak_spots.gd (8 directions, 12 m):
  before watcher eye 7/8, strider 0/8, grazer 0/8; after 7/8, 5/8, 8/8 (the rest: world or body really in front).

## 0.2 (night run 2026-10-09/10)
- H1 --profile-cells / --quit-after-cells, <logs>/cell_phases.csv, `cell phases: top=...`, vram at start, frame stats.
  Before: worst load frame 1676 ms (add_child 1126 ms, collision, multimesh, first draw).
- H2 world/cell_inserter.gd: one cell at a time in budgeted steps (streaming.main_thread_budget_ms); worker plans
  MultiMesh buffers, collision buckets, terrain collision (2 m = visual grid); object collision only within
  streaming.collision_radius_m, one 16-shape body per step from an 800-tri LOD; unloads freed lazily leaves-first;
  big data dropped on workers; herd members one per frame; machine types warmed up while loading.
- H3 DDS (verified in the 4.7.2 release template), normal/ORM/AO maps, MikkTSpace tangents on the worker.
- H8 world/precompile.gd: every StandardMaterial3D variant on quads with the real vertex layout, real materials,
  terrain, water, HLOD, one machine per type and all weapon view models drawn under the loading screen; variants kept
  alive (a shared shader dies with its last material -> 20 ms surface_set_material later).
- H4 layered terrain (4 layer sets, masks renormalised, rock triplanar, cell albedo tints near / far).
- H5 sky/sun/fog from render.* (HZD 9:00; height fog falloff x0.02 - 1:1 was a white sheet).
- H6 water material (translucent, world-space ripples); H7 occluders (2 ArrayOccluder3D per cell), occlusion culling,
  far cells (ring >= render.hlod_from_ring) = coarse terrain + hlod.glb, request_ring converted also standing;
  LOD threshold 12 px (render.lod_threshold_px), FXAA, 2048 shadow atlas.
- Release, converted format-8 route, 1920x1080, no vsync: route avg 98.4 fps, 1% low 46.0, worst 48.7 ms, 0 frames
  > 50 ms; vram at start 1425 MB.
- Quit crash (0xC0000005 after "quitting", test F9 and the "rare segfault"): World._exit_tree gave up on a running
  cell prepare after 10 s and the engine freed scripts/resources under it. Now MeshLib.cancelled stops prepare /
  prepare_far / wait_parsed early, short tasks (free, size, far) are high priority (low-priority slots are few),
  every task records its progress (`_task_info`) and quit waits up to 60 s; a still-stuck task is logged and the
  process ends itself (OS.kill own pid = exit 0) instead of a teardown under it. The script logger is removed in
  Main._exit_tree. Real-start quit loops: before 1/30 and 1/30 crashed; after 40/40, 15/15 (quit at 12 s), 20/20
  (quit at 8 s) and 30/30 mock smoke without a crash. No backtrace: the crash printed no handler output.
- Converter throttle (proto.throttle): loading screen keeps --workers, world_ready sends workers/threads from
  streaming.converter_workers_play / _threads_play (1 / 2); --no-converter-throttle for comparison. Active
  converter route (fresh c48 copy, converter built from the branch): without throttle 1% low 62.6 fps, worst
  145.1 ms, 14 frames > 50 ms, route 82 s; with throttle 1% low 76.0 fps, worst 112.1 ms (right after a profiler
  teleport, 4 new surface pipelines), 3 frames > 50 ms, route 96 s (conversion slower).

## Notes for teammates (relay via main)
- test (t10): real cells outside the start area are ~11 MB (meshes/textures shared), 5 steps east add ~164 MB, so
  cap = bytes + reserve(600) + 300 MiB never evicts (target = cap - reserve). Use e.g. cap = bytes + reserve + 50 MiB
  or more steps; eviction itself is verified with 30 MiB mock cells (dev/scenarios.gd t10: 4 farthest-first).
- test (s02): the real Watcher is 1.45 m tall; at the vertical FOV 73.74 deg it covers >= 15 % of the frame only
  within ~7.5 m.
- test: new signal `Game.player_damaged(amount, cause)` (also while invulnerable) for t05 "attack hits the player".
- test: `Game.fire()` ignores the fire-rate/deploy gate; returned damage includes CS range falloff (t04 expected
  values must include `range_modifier^(dist_u/500)`); knife reach = combat.knife_reach_m from the camera;
  `Game.spawn_machine` faces the player; `player.set_crouch(bool)` exists for t06; projectiles are in group
  `machine_projectiles`; the MissingHzdScreen Control is `Main/MissingHzdScreenLayer/MissingHzdScreen` with the
  message in a descendant Label named `Label` (use find_child). Automated runs (`--autotest`, `--script`) never
  capture the mouse and ignore B/Esc.
- svet: cell 4_-3 albedo.png is ~90 % white (mean RGB 179/177/170) - is that the real flattened albedo (snow)?
  Watcher meta height_m 1.449 (S3 asked 1.5-4 m). Game reads cell.json `vegetation: null`, empty instances and
  campfires fine; the start campfire comes from index.json start_campfire(_pos) until cells list campfires.
