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
- 2026-10-09 IK classes in the installed 4.7.2 (ClassDB): TwoBoneIK3D, ChainIK3D, CCDIK3D, FABRIK3D, JacobianIK3D,
  SplineIK3D, LookAtModifier3D, IKModifier3D, SkeletonIK3D exist. Probe: inside a SkeletonModifier3D,
  get_bone_global_pose reflects poses set earlier in the same pass; after the frame Godot restores the unmodified
  poses. Decision: own analytic IK in ONE modifier (machine_animator.gd) instead of TwoBoneIK3D nodes: legs are
  4-7 joint chains (scapula, hoof, digitigrade ankles), the pass order body -> legs -> neck must be explicit, and
  the foot planner needs reach feedback (slack) from the solver every frame.
- 2026-10-09 M1 new animation system: anim/gaits.gd (walk lateral sequence, trot, lope, transverse gallop, half
  bound, biped walk/run; duty factors), anim/poses.gd (attack poses with wind-up/strike/recovery, hit reactions,
  idle actions as channel tables), machine_animator.gd rewritten. Key decisions:
  - Stance feet are locked in world space; swings are phase-locked (land exactly at the leg's touchdown phase even
    while the cadence changes) and aim at the leg's neutral spot at mid-stance (velocity + yaw-rate prediction).
  - Cadence: T from walk_cycle_s/run_cycle_s by speed, shortened when the stance travel would exceed the legs'
    reach (travel_max from bind-pose geometry, with the stance centred halfway under the hip while moving).
  - Reach correction: the fore/hind body lowers at once until each planted foot is reachable (toe roll included),
    released slowly; a foot about to run out of reach within one physics tick steps early (emergency step).
  - Ankle pivots so the contact joint lands exactly on target -> 0 penetration in stance.
  - Hit reaction and attack poses are body/neck channels applied BEFORE the leg IK (feet stay planted); kicks,
    rearing, pawing and pounces free the legs explicitly.
  - Death: buckle, topple to the side away from the shooter, trunk hitboxes rest on the fitted terrain plane, legs,
    head (incl. horns/antennas) and tail are lifted until every bone clears the terrain, pose frozen after 2.4 s.
    Corpses persist (freed after 45 s once the player is > 80 m away, always after 240 s).
  - machine.gd: yaw_rate/accel_fwd for the animator, turning in place limited by anim.turn_in_place_dps,
    rig.play_attack(row) passes the row timing, TrunkBody off on death.
  Bench M1 (same bench as M0):

  | machine | data | foot_slide_cm | penetration_cm | float_cm | poses |
  |---|---|---|---|---|---|
  | watcher | mock | 0.1 | 0.0 | 0.0 | all ok |
  | strider | mock | 0.0 | 0.0 | 0.0 | all ok |
  | grazer | mock | 0.0 | 0.0 | 0.0 | all ok |
  | watcher | real | 0.0 | 0.0 | 0.0 | all ok |
  | strider | real | 0.0 | 0.0 | 0.0 | all ok |
  | grazer | real | 0.0 | 0.0 | 0.0 | all ok |

  Screenshots (windowed bench --shots): C:\meshy\_tools\stroje\shots1\*.png. Smoke (mock) SMOKE OK.
  Note: dev/check_scripts.gd reports 8 bad scripts, all under game/autotest/** (`AutotestSheet` not declared) -
  not touched by stroje.
