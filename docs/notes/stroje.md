# stroje journal (machines: animation, AI, bench)

Owner of game/machines/** except spawner.gd, game/dev/machine_bench.gd, machines.json columns archetype/behaviour/
anim/speeds/perception thresholds/attacks/herd/flee, machine_attacks.json. Newest entries at the bottom of "Log".

## Tools
- Bench: `godot --headless --path game --script res://dev/machine_bench.gd -- (--mock-data | --cache <dir>)
  --machines a,b,c [--out f.json]`. Synthetic terrain (bumps 0.18 m, 12 deg ramp, 4.6 deg cross slope), AI off,
  driven through `machine.drive_dir/drive_speed/drive_face` (dev hook, used only when ai_enabled is false).
  Measures on the FINAL skeleton pose inside `Skeleton3D.skeleton_updated` (verified equal to a BoneAttachment3D on
  the same bone: 0.00 cm), foot contact = leg chain end joint, expected height = terrain + its bind-pose height.
  foot_slide_cm = max horizontal drift within one planted phase; penetration_cm = max depth below the expected
  height (all phases but death). Exit 0 only if every machine passes (< 5 cm, < 5 cm, all poses ok).
- Real models: fresh cache `C:\meshy\_tools\cache-stroje1` (`hzsconv machines`, all 6, built from this branch).
- Logs: `C:\meshy\_tools\stroje\*.log` / `*.json`.

## Log
- 2026-10-09 M0. Bench written. Baseline (old animator, commit of M0):

  | machine | data | foot_slide_cm | penetration_cm | float_cm | failing poses |
  |---|---|---|---|---|---|
  | watcher | mock | 22.7 | 1.0 | 0.2 | death (bone 52 cm under ground) |
  | strider | mock | 31.7 | 33.5 | 5.0 | graze (head 0.12 m), death (25 cm under) |
  | grazer | mock | 22.1 | 3.0 | 4.6 | graze (0.11 m), death (35 cm under) |
  | watcher | real | 14.3 | 1.4 | 0.1 | death (34 cm under) |
  | strider | real | 30.6 | 26.1 | 4.8 | graze (head not lower), death (12 cm under) |
  | grazer | real | 26.2 | 7.3 | 3.9 | graze (head not lower), death (84 cm under) |

  Worst items: hit flinch rotates spine bones AFTER the leg IK (planted feet move with the body, 14-30 cm), walk/run
  stance slide 15-28 cm on quadrupeds (feet planted at a predicted point the clamped IK cannot reach), rear kick
  pushes feet 26 cm into the ground, death rotates the body bone around the skeleton origin into the terrain.
