# Task plan 0.2 (from "plan", 2026-10-09) – measure first

Goal and rules: docs/BRIEF-0.2.md, CLAUDE.md (incl. "Tests drive the player's input", unattended-run forbidden
commands, content contract). Sheets: machines (6 rows: + sawtooth=direwolf, scrapper=hyena, broadhead=longhorn),
machine_attacks (16), systems (+ groups render, perf), autotest (t12–t16, r01–r04). `site_map` changes for the new
machines are merged LAST (after svet V3 models + stroje M2 AI), otherwise the game spawns machines without code.

```powershell
$G="C:\Users\bezdo\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
$CS2="C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"; $HZD="E:\SteamLibrary\steamapps\common\Horizon Zero Dawn"
$DEV="C:\meshy\_tools\cache-dev"; $CONV="dotnet run --project converter/src/Hzs.Cli -c Release --"
```

## Ownership (4 executors must not collide)
| executor | owns | does not touch |
|---|---|---|
| svet | converter/src/Hzs.Decima/**, sheets hzd_content/site_map/hooks(hzd rows), machines.json content columns (entity..sound_banks, hzd_*, perception bindings, weak_spot_bones, leg_chains, content_model, bone_roles, points), tools/cell_info.py | game/** |
| hra | game/core/**, game/world/**, game/main/**, game/ui/**, game/player/**, game/audio/**, game/machines/spawner.gd, project.godot, tools/build.ps1, systems render/streaming/cache rows | game/machines/* except spawner |
| stroje | game/machines/** except spawner.gd (machine.gd AI/perception/attacks, machine_animator.gd, machine_rig.gd, projectile.gd, machine_audio.gd, new species/*.gd, anim/*.gd), game/dev/machine_bench.*, machines.json columns archetype/behaviour/anim/speeds/perception thresholds/attacks/herd/flee, machine_attacks.json | game/core/combat.gd, game/world/** |
| test | game/autotest/**, autotest.json, systems perf.* rows, tools/frametime_graph.py, records in C:\meshy\_tools\records-0.2\ | game code |

Frozen hra↔stroje interface (changes only via the orchestrator): spawner calls `machine.setup(type, meta)` and adds
it to the tree; machine exposes `machine_type, state, health, suspicion, ai_enabled, current_attack, weak_spots(),
weak_points(), aim_point(), take_hit()`; `take_hit` computes damage via `Combat` (hra); world access via `Game`.
Sheet edits: one row = one line; each edits only its columns/rows; machines.json merge order svet then stroje.

## Phase A – measure (parallel, no behaviour change)
- hra H1 profile cell loading FIRST: phases prepare(worker), mesh_upload, tex_decode, terrain, multimesh, collision,
  add_child, first draw (shader compile); VRAM at start. Output `<logs>/cell_phases.csv` + table for MODLOG.
  Accept: `& $G --path game -- --game $CS2 --cache-dir $DEV --profile-cells --quit-after-cells 10` -> CSV >= 10 cells,
  phase ms columns, worst_frame_ms; latest.log `cell phases: top=<phase> <ms>`.
- test T1 baseline 0.1.1: `git archive <0.1.1 commit> game` into C:\meshy\_tools\baseline-0.1.1\ (copy, no worktree),
  add r01 + t15-route scenarios against the 0.1.1 API, export, run. Accept: records-0.2\before\{mothers_heart,valley,
  rocks_close}.png (non-blank) + baseline\frametimes.csv >= 10 cells; perf.shot_poses filled.
- svet V0 texture audit: counts/sizes per role, VRAM estimate, BC encoder choice + benchmark (new dependency, e.g.
  BCnEncoder.Net MIT, or own). Accept: MODLOG line `textures: N, VRAM est X MiB uncompressed -> Y MiB BC`, BC7 ms/MPix.
- stroje M0 bench for the 3 existing machines: game/dev/machine_bench.gd measures foot slide in stance and terrain
  penetration. Accept: `& $G --headless --path game --script res://dev/machine_bench.gd -- --mock-data --machines
  watcher,strider,grazer` -> per machine foot_slide_cm, penetration_cm, poses ok/fail.

## Phase B – fix the biggest item, base look
- hra H2 time-budgeted insertion (terrain -> MultiMesh batches -> collision incrementally within
  streaming.collision_radius_m), within streaming.main_thread_budget_ms. Accept: H1 rerun worst_frame_ms <= 50 on a
  10-cell route.
- svet V1 BC1/BC3/BC5/BC7 precompression per render.texture_format_* (DDS + mips). Accept: `$CONV cell --hzd $HZD
  --cache C:\meshy\_tools\cache-02 --cell 4,-3` + `python tools/cell_info.py ...\4_-3 --textures` -> 0 png/jpg,
  formats {BC1,BC5,BC7}, mips ok; whole-world time in MODLOG.
- hra H3 DDS loading (verify in the 4.7.2 RELEASE template first) + VRAM. Accept: release latest.log perf line
  vram_mb <= 2560 at start.
- svet V2 normal + roughness/ORM for rocks, buildings, vegetation from HZD texture sets; terrain normal derived from
  heights; cell.json instances[].kind. Accept: glb_info on 4_-3 meshes -> normalTexture on >= 95 % rocks/buildings.
- stroje M1 new animation system on the 3 existing machines: gaits from `anim` + bone_roles (biped/walk/trot/
  gallop/bound), foot IK (TwoBoneIK3D/ChainIK3D – check they exist in 4.7.2), body tilt by ground + acceleration,
  turn in place by stepping, graze/scavenge, attack poses, hit react (additive), death fall settling on the ground.
  Accept: bench foot_slide_cm < 5, penetration_cm < 5, all poses ok.

## Phase C – new machines, world look
- svet V3 the 3 new models (`machines --only sawtooth,scrapper,broadhead`), fill all svet TODOs in machines.json,
  site table to MODLOG. Accept: glb_info skins 1, joints = meta.bones; preflight no svet findings in machines;
  `hzsconv hzd-sites` -> direwolf->sawtooth, hyena->scrapper, longhorn->broadhead.
- stroje M2 AI predator/scavenger/herd-defend; M3 animation of all 6 on real models. Accept: t12, t13 PASS (N/8 per
  machine in details), bench for 6 ok.
- svet V4 terrain material masks + layer textures (snow, grass, dirt, rock) -> cell.json terrain.layers (fallback:
  masks from snow/ecotope maps + slope with HZD detail textures). Accept: 4 layers with files, masks sum ~1 (+-0.05).
- svet V5 water (cell.json water), V6 occluders + HLOD (cell.json occluders, hlod.glb <= 20k tris; HZD LodMeshResource
  LODs). Accept: cell_info occluders > 0, HLOD in budget; water records or one MODLOG sentence.
- svet V7 ATRAC9, max 3 attempts (LibAtrac9 C# MIT; ffmpeg on the player side; own decode via LibAtrac9). Accept:
  hzd/audio/ambience/wind_*.wav (6->2 downmix) or one MODLOG sentence.
- hra H4–H8: layered terrain shader + triplanar on slopes; sky/sun/fog/atmosphere from render.* at 9:00; water;
  MultiMesh everywhere repeated, visibility ranges, HLOD switch, OccluderInstance3D from cell occluders (enable
  rendering/occlusion_culling/use_occlusion_culling); shader precompile on the loading screen; Game API for tests.
  Accept: t14, t15 PASS on the dev cache.

## Phase D – tests and records
- test T2 inputsim extensions (aim at a world point by relative mouse motion; route walker); T3 t12–t14; T4 t15, t16
  + tools/frametime_graph.py (dev only, no deps, SVG); T5 r01–r04; T6 full regression on the release build.
  Accept: release exe `--autotest` ExitCode 0, 14 old + 5 new PASS, 0 engine errors; records-0.2 has 3+3 PNG,
  19 MP4, 1 SVG.

## Risks
Merge order (site_map last); difficulty (Sawtooth 1100 HP real HZD value; Broadhead 23 sites/88 machines);
BC7 encode time; DDS loading in the release template unverified; terrain masks may be unreadable (D42, fallback V4);
route walking may get stuck (teleport with count + limit); --write-movie in the export template unknown (records via
editor binary with --path game); t16 ~1 h. Not doing: Ravager, Thunderjaw, other types, day/night, weather, part
detachment, DLC1.
