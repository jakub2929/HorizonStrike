# Task plan 0.3 (from "plan", 2026-10-10)

Goal: docs/BRIEF-0.3.md. Sheets (merged): machines.xp_reward; systems groups xp, upgrades, fx, persist, knives.*,
movement.bhop_*, combat.silent_strike_*; hooks cs2.feedback_sounds, cache.persistence; autotest t17–t24, r05–r08.
Caches ONLY under E:\meshy_work\ (never C:). Tests that save a profile use `--user-dir <out>/userNN`.

## Key definitions
- XP: xp_reward = 100 × kill_reward_mult (watcher 100, strider 200, grazer 150, sawtooth 450, scrapper 250,
  broadhead 200); +20 % weak-spot kill, +30 % silent strike (additive). Level curve arithmetic: L→L+1 costs
  300 + 150·(L−1), max level 15 (20 250 XP); 1 point per level.
- Upgrades: damage +10 %/level (max 5, all weapons incl. knives, applied before armour/weak multiplier); max HP +20/level
  (base 100, max 5); bhop +1 jump/level (max 5).
- BHOP: a jump continues the chain if pressed within movement.bhop_window_ms (100) after landing; jumps 1..N keep the
  landing speed (no friction, no clamp; air strafe unchanged); jump N+1 (and every jump at level 0) behaves like today
  (friction) plus a clamp of take-off speed to bhop_clip_speed_mult × run speed (1.0, unverified; CS:GO used 1.1).
- Silent strike (new mechanic): knife stab (secondary attack) into a machine in idle/patrol/graze/scavenge, outside its
  vision cone, works with all knives; damage × combat.silent_strike_mult (5, unverified).
- Effects (fx.*): hitmarker normal/weak, damage numbers (0.8 s, rise 0.6 m, default on, toggle in Esc menu), impact
  sparks/debris (8+2 normal, 24+6+flash weak, max 32 emitters; owner stroje), damage direction indicator 1.5 s,
  vignette from 60 % HP (alpha max 0.55, gamma 1.5, flash per hit), aimpunch (CS2 cvar decay values; kick = design).
- Sounds (CS2 events, cs2 converts into cs2/ui/snd/): Player.DamageBodyArmor.AttackerFeedback (machine hit),
  Player.DamageHeadShot.AttackerFeedback (weak hit), Player.DeathHeadShot.AttackerFeedback.Dink (weak kill),
  Weapon_Knife.Hit (knife), SolidMetal.BulletImpact (3D impact, stroje), Player.DamageBody.Victim /
  Player.DamageBodyArmor.Victim (player hurt).
- Persistence: loadout.json {format, knife}; progression.json {format, xp, level, points, upgrades} (atomic); settings
  show_damage_numbers; in %LOCALAPPDATA%\HorizonStrike\ or --user-dir; missing knife -> knives.default.

## Ownership
| who | owns | tasks |
|---|---|---|
| cs2 | converter/src/Hzs.Cs2/** | K1 knives (done); K2 feedback sounds → cs2/ui/snd/ for the 7 events (skip null.vsnd) |
| hra | game/player/**, game/ui/**, game/core/** (combat damage multiplier, new progression.gd, persistence), game/audio/** | H1 knife menu + preview + loadout.json + F inspect (t17–t19); H2 XP/levels/points/upgrades, K menu, HUD bar + level-up, progression.json, silent strike (t20, t21); H3 bhop levels (t22); H4 player-side effects (t23); H5 test API |
| stroje | game/machines/** (+ fx/impact_fx.gd), machines.xp_reward | S1 pooled impact sparks/debris at hit point, stronger on weak spots, 3D SolidMetal.BulletImpact, hit reaction unchanged; S2 signal machine_killed(type, weapon, weak, silent) in _die |
| test | game/autotest/**, autotest.json | T1 inputsim (click Control by name, timed jump, synced air strafe); T2 t17–t21; T3 t22; T4 t23, t24; T5 r05–r08 into E:\meshy_work\records-0.3\; T6 full regression on the release build |

Frozen hra↔stroje interface: `machine.take_hit(weapon_id, base_damage, part, is_weak, hit_pos := Vector3.INF,
hit_normal := Vector3.ZERO)`; upgrade damage multiplier applied by Combat (hra) before take_hit; XP computed by hra
from machine_killed.

Test API needed (hra H5): --user-dir; read player.knife_id, player.horizontal_speed, player.aimpunch_deg;
viewmodel.clips()/current_clip; Game.progression (read; setup write only); signal machine_killed; Game.fx_stats; HUD
node names Hitmarker, DamageNumbers, DamageIndicator, Vignette.

Order: K2 + H5 + T1 now; H1 → t17–t19; H2, H3, S2 → t20–t22; H4, S1 → t23, t24; records; regression.
Risks: t22 needs synced air strafe to exceed run speed; silent strike ×5 design value; aimpunch not in CS2 data;
effects vs the 50 ms limit (t24).
