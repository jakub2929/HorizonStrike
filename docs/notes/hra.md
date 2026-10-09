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

## Notes for teammates (relay via main)
- test: `Game.fire()` ignores the fire-rate/deploy gate; returned damage includes CS range falloff (t04 expected
  values must include `range_modifier^(dist_u/500)`); knife reach = combat.knife_reach_m from the camera;
  `Game.spawn_machine` faces the player; `player.set_crouch(bool)` exists for t06; projectiles are in group
  `machine_projectiles`; the MissingHzdScreen Control is `Main/MissingHzdScreenLayer/MissingHzdScreen` with the
  message in a descendant Label named `Label` (use find_child). Automated runs (`--autotest`, `--script`) never
  capture the mouse and ignore B/Esc.
- svet: cell 4_-3 albedo.png is ~90 % white (mean RGB 179/177/170) - is that the real flattened albedo (snow)?
  Watcher meta height_m 1.449 (S3 asked 1.5-4 m). Game reads cell.json `vegetation: null`, empty instances and
  campfires fine; the start campfire comes from index.json start_campfire(_pos) until cells list campfires.
