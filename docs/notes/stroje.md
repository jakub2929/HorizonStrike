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
- 2026-10-09 M2 AI (machine.gd; behaviour column knobs, no sheet value changes):
  - calm state per archetype: guard/predator `patrol`, scavenger `scavenge` (wander + head-down drill bouts),
    herd `graze`. New states `stalk`, `scavenge`; `current_attack` = machine_attacks id while an attack runs.
  - Sawtooth (predator): investigates suspicion, on alert stalks low and slow (stalk_speed_mps 2.2, crouched pose)
    to stalk_until_m 18, then attacks (charge 9-30 m, pounce 5-9 m = leap covering the distance in active_s, bite
    0-3 m); shot while stalking -> attacks at once; calls nobody (call_on_alert false).
  - Scrapper (scavenger): radar ping every radar_ping_interval_s (+-15 %), visible ring; a ping that finds the
    player within radar_ping_radius_m (no line of sight needed) adds 0.5 x alert threshold of suspicion (2 pings ->
    alert); on alert calls the pack within pack_call_radius_m; laser burst = 1 bolt per 0.15 s of active_s (4);
    circles the player at 10-20 m while attacks cool down; bite/lunge up close.
  - Broadhead (herd + defend_charge): does not flee; alert -> attacks when the player is within
    fight_back_radius_m 25 (50 for 10 s after being shot), else stands facing the threat pawing the ground and calms
    after search_time; goes back to alert when the threat backs off beyond 1.5x the radius.
  - Herds bolt from loud noises regardless of flee_on_alert (defenders then alert instead of fleeing).
  AI check (`machine_bench.gd --ai`, stand-in player walks up from 70 m; dev only, not the autotest), cache with
  svet's 6 models (copy of c40 = C:\meshy\_tools\cache-stroje2):
  | machine | cycle | attacks used | hits on player |
  |---|---|---|---|
  | sawtooth | suspicious > patrol > suspicious > alert > stalk > attack | charge 1, bite 6-7 | 7-8 (250-285 HP) |
  | scrapper x2 | (radar 6 of 10 pings found the player) > alert > attack, pack alerted | laser burst 2 (4 bolts), lunge 1, bite 5-6 | 26-27 |
  | broadhead x2 | suspicious > graze > suspicious > alert > attack, never flees | charge 1, headbutt 4, stomp 2 | 11-12 |
  | watcher | suspicious > alert > attack | eye bolt, tail sweep, bite | 11 |
  | strider/grazer x2 | suspicious > alert > flee > suspicious > graze | - | 0 |
  hra dev scenarios on real machines (mock world, seed C:\meshy\_tools\stroje\seed1): t05, t06, t07 PASS.
- 2026-10-09 M3 all 6 machines on their real models (bench, cache-stroje2):
  | machine | foot_slide_cm | penetration_cm | float_cm | poses |
  |---|---|---|---|---|
  | watcher | 0.0 | 0.3 | 0.0 | all ok |
  | strider | 0.0 | 1.0 | 0.0 | all ok |
  | grazer | 0.0 | 1.0 | 0.0 | all ok |
  | sawtooth | 1.4 | 0.9 | 0.0 | all ok |
  | scrapper | 1.2 | 1.0 | 0.0 | all ok |
  | broadhead | 0.0 | 1.0 | 0.0 | all ok |
  (penetration ~1 cm = the 5 cm terrain-height cache). Fixes for the new rigs: turning cadence from the farthest
  foot (Sawtooth's origin sits near its front legs), free legs never below the ground, mandible pairs (jaw_l/jaw_r),
  anim.neck_rest_pitch_deg 40 for Broadhead (its mesh carries the head raised over the Strider skeleton's rest),
  death settling probes for plates on leg roots and horn tips. Screenshots C:\meshy\_tools\stroje\shots2,3.
  Weak spots (hra's dev/weak_spots.gd, 8 directions, 12 m, real machines): watcher eye 8/8, strider canister 7/8,
  grazer canister 8/8, sawtooth canister 8/8, scrapper power_cell 6/8 + radar 8/8, broadhead canister 7/8 ->
  WEAKSPOTS OK (0.1.1: 7/8, 5/8, 8/8).
- Performance (`--perf 24`, all types, AI on): ~140 us per machine update, 24 machines ~3.3 ms/frame without LOD
  (GDScript overhead; ~0.5 raycasts per update thanks to a 5 cm terrain-height cache). Distance LOD: beyond
  35/70/120 m from the camera the pose is recomputed every 2nd/3rd/6th frame (cached local poses in between).
- Interface notes for hra (not changed by me): new states `stalk` and `scavenge` exist. `Game.in_combat()`
  (core/game.gd:107) checks alert/attack -> should include `stalk`; audio_director counts only `attack` as combat
  and suspicious/alert as wary -> `stalk` belongs to wary/combat; spawner._engaged -> add `stalk`. For test: t06's
  calm list ["idle","patrol","graze"] -> add "scavenge" for Scrappers.
- 2026-10-10 Follow-up (hra's autotest t05: Watcher patrol -> alert, skipping suspicious). Causes in machine.gd:
  (1) the immediate-alert distance (in the sight cone within immediate_alert_m 15 m) jumped a calm machine straight
  to alert, e.g. a patrolling Watcher that turns to face the player inside 15 m; (2) receive_alert (a second Watcher
  on the site calling within alert_call_radius_m 60, herd calls) and loud-noise herd alerts set alert directly.
  Fix (HZD flow): a calm machine (idle/patrol/graze/scavenge) always turns `suspicious` first and looks at the
  stimulus for SUSPICIOUS_LOOK_S 0.8 s (herds 0.4 s), then goes alert - also when called or startled by a shot.
  Immediate alert only when hit by the player or with the player very close (25 % of immediate_alert_m, >= 3 m).
  Sheet thresholds unchanged (Watcher suspicious 30 m / alert 15 m / sight 45 m / half angle 25 deg).
  Verification: test's autotest t05 on the real world (copy of c48, editor binary, project imported once so the
  runner's global classes resolve): PASS, suspicious at 1.9 s (32 m) -> alert 4.4 s -> attack 5.0 s.
  hra's dev scenarios t05 x3 PASS, t06 PASS (graze -> flee in 0.4 s). Bench --ai now requires the first non-calm
  state of EVERY group member to be entered from suspicious: PASS for all 6 (approach from 70 m), standing at 35 m
  (Broadhead holds its ground in alert, player outside fight_back_radius), standing at 12 m (Sawtooth inside
  stalk_until_m attacks without stalking), gunshot near crouched herds (grazer/strider: graze -> suspicious ->
  alert -> flee 0.41-0.42 s after the shot; Broadhead: suspicious -> alert, holds).
