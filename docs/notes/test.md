# test – journal (autotest + screenshots)

Owner: test. Scope: `game/autotest/**`, test-owned cells of `sheets/autotest.json`.

## Layout
```
game/autotest/runner.gd              entry (boot instances it on --autotest); order/child args from AutotestSheet
game/autotest/lib/args.gd            command line (before and after "--")
game/autotest/lib/oracle.gd          expected values: resolved cache -> sheet fallback -> column default -> literal
game/autotest/lib/ctx.gd             Game API access, waits, signal recorder, screenshots, engine-error logger
game/autotest/lib/scenario.gd        base: named checks -> {pass, details}
game/autotest/lib/{combat,sites,frame,proc}.gd   shooting, real sites, image/frustum checks, processes/netstat
game/autotest/scenarios/<id>_*.gd    one per sheet row (s02 is produced inside t05)
```
Output: `<out>/results.json` = `[{id, name, pass, details}]`, `details = {summary, checks[{check, ok, info}], data,
notes, seconds, engine_errors?, child?}`; `<out>/autotest.log`; screenshots `buy_wheel.png`, `watcher_alert.png`,
`herd_landscape.png`; children write `<out>/t08/`, `<out>/t09/` (t09 + t10).

## Decisions
- Expected numbers come only from the oracle (resolved cache values, else sheet fallback/default); an expected value
  that resolves to nothing fails the scenario ("expected values resolved") instead of guessing.
- A scenario passes only if `_run` returns normally (bool) and every check passed. A GDScript runtime error aborts
  `_run` (returns null) and is reported as "scenario ran to the end: false" plus the captured engine error
  (OS.add_logger). Verified with an injected error: t01 FAIL, exit 1.
- Runner watchdog per scenario (`timeout_s`); children have their own timeout and are killed by exact PID.
- Children (t08; t09+t10) get the sheet's extra_args, the parent's known game args (`--game --hzd --cache-dir
  --mock-data`) minus the overridden ones, `--path <project> --` when run from the editor binary, `--headless` when
  the parent is headless. Child mode is signalled with env `HZS_AUTOTEST_CHILD` so the command line stays as in the
  sheet. A child result counts only if `<child out>/results.json` is newer than the launch.
- Fresh cache for t09: `<out>/cache_fresh`. The runner writes a marker `.hzs_autotest_fresh` into folders it creates;
  on the next run such a folder goes to the recycle bin (reversible), any other existing folder is never touched (a
  suffixed new folder is used).
- Screenshots: `Game.screenshot(path)` after `RenderingServer.frame_post_draw`; the PNG is read back and must be newer
  than the run start (no stale files from earlier runs), luma stddev > 10 on a 320 px downscale.
- t11: netstat parsing is locale independent (TCP listener = foreign port 0; every UDP row is an endpoint) because
  the state column is translated on non-English Windows. The PID is checked with tasklist (hzsconv.exe / dotnet.exe).
  Verified both ways on the stub: real `hzsconv serve` -> PASS; a fake converter listening on 0.0.0.0 -> FAIL.
- Sheet change (test-owned `order`): t03 (6) now runs before t02 (7) – t03 needs the fresh start inventory, t02 buys
  or reuses the ak47.
- t04 includes the systems range falloff (`damage *= range_modifier^(dist_u / combat.range_step_u)`): the sheet's
  "= 120 / = 14.1" hold only at 0 m; at 10 m the Glock gives ~105.6 / ~12.4. Exact distance from `fire().point` or
  `.distance` when present, else camera->machine with a +-1.5 m tolerance band.
- t09 "after bootstrap": all cells on disk within max(bootstrap_ring, request_ring) of the start (<= 25 of 340); the
  sheet's 3x3 conflicts with `streaming.request_ring = 2` (normal streaming requests 5x5 ahead). At world_ready only
  the start cell must be on disk (strict).
- t10 samples the cache both through `Game.cache_bytes()` and independently from the folder on disk (thread).
- s02: captured at the first alert in t05; if the Watcher is < 15 % of the frame there (35 m start distance ->
  ~5 % with a 74 deg vertical FOV), a retake with a fresh Watcher 9 m ahead (AI on) until alert.
- Multi-spawn scenarios use one base direction so a later spawn never lands on an earlier (dead) machine after
  `aim_at` turned the view.

## Verification without the game (scratch stub)
hra's game was not on main yet, so the runner was exercised against a fake `Game` autoload in a scratch project
(outside the repo; never committed). Results (stub, Godot 4.7.2):
- t01, t03 headless: exit 0, both PASS. Injected bugs (start money 700, ak47 charged 2600): exit 1, t01/t03 FAIL with
  the exact values. Injected script error in t01: FAIL "scenario ran to the end", engine error captured.
- t08 (child, `--hzd <out>/no_hzd_here`), t11 (real hzsconv serve), s01 (window, 1600x900 PNG, stddev 21): PASS.
- t09 + t10 (child, fresh cache, 20 MB fake cells): PASS; injected "evict protected cells": t10 FAIL with the
  offending evictions listed. Second run moved the previous marked cache_fresh to the recycle bin.
- t02, t04 with the real resolved CS2 values (copy of cache-dev/cs2 JSON in C:\meshy\_tools\cache-test-oracle):
  PASS (1100 / 3050 / 16000; weak 104.82 vs body 12.56 at ~10 m).

## What the runner relies on beyond the documented Game API
Aligned with hra's in-progress code (read-only look at the hra worktree, not merged; re-check after the merge):
- world ready: signal + polling `Game.is_world_ready` (or `world_is_ready`) – the runner is added deferred.
- cache: `Game.cache_root` (or `cache_dir`), else `--cache-dir`, else `%LOCALAPPDATA%\HorizonStrike\cache`.
- buy wheel content: `Game.buy_wheel_items()` if it exists, else the visible wheel nodes `BuyItem_<id>` with their
  `Price` label (what the player sees), else `Game.buy_wheel_item_ids()` (ids only -> price check fails).
- cells: `Game.cell_of(pos)` or `Game.world.cell_of(pos)`; cache cap: `Game.set_cache_cap(bytes, false)` (no
  persisting), else `Game.cache_cap_bytes`.
- hits on the invulnerable player: signal `player_damaged` if it exists, else the `hud_message` "Hit: ..." the game
  emits; projectiles: group `machine_projectiles`.
- crouch: `player.set_crouch(true)`, else `player.crouching`, else the `crouch` input action (ignored by the game
  while the mouse is not captured, i.e. in automated runs).
- t04 distance: `fire().distance` / `fire().point` if present, else `machine.aim_point(part)` (+-0.75 m band).
- t08 log: `Game.log_path` if present, else `%LOCALAPPDATA%\HorizonStrike\logs\latest.log`, filtered to this
  process's `[pid]` lines.

## Open requests for hra
1. `fire()` result: add `point: Vector3` (or `distance: float`) so t04 checks the falloff exactly.
2. With `--mock-data` the converter is the in-process mock (`converter_pid` = 0): t11 can only pass on real data.
3. t02 case 3 (cap): `kill_reward.amount` must equal the money actually added (100) – hra's `award_kill` already
   emits the delta.

## Findings for owners
- F1 (cs2 / Hzs.Common, hra): two converters with the same log dir – the second one crashes at start:
  `System.IO.IOException: The process cannot access the file '...\converter.log' because it is being used by another
  process` (`Log` opens it with FileMode.Create + FileShare.Read; still so on main 73099fb). Hits the t08 child
  (same cache dir as the parent -> same `<cache>/../logs`) and any second game instance. Fix: FileShare.ReadWrite or a
  per-process `--log-dir` from the game. Reproduced with two `hzsconv serve` processes (scratch build of the skeleton).
  Lower priority now: hra's game does not start the converter when HZD is missing (t08 log: "converter not started"),
  so the autotest no longer hits it. Fixed on main 216d757 (per-process log fallback) – closed.
- F3 (hra) t04, real data: spawned Watchers have health 140 (sheet design value); expected = resolved hzd_health 90 x
  `combat.machine_health_scale` (1.0) per the svet merge decision. `setup: watchers at full health 90.0: A 140.0
  B 140.0`. Damage numbers themselves match (weak 107.76 vs expected 107.58 +-1.09 at 8.5 m; body 12.66 vs 12.50).
- F4 (hra, spawner) t05, real data: cell 5_-2 lists two spawns with the same site name `FE_Harvester_Scout`
  (4 grazer orig harvester + 2 watcher orig scout); the game log shows only `site FE_Harvester_Scout active: 4 grazer
  (orig harvester)` – the watcher entry never spawns (sites keyed by name?), so there is no Watcher at a real Watcher
  site in [5,-2]/[3,-2] and t05/s02 cannot run (`0 found` within 240 s). Key sites by name + index or by entry.
- F5 (hra / svet) engine error while cells load, real data: `jolt_shaped_object_3d.cpp:138 Failed to create compound
  shape for body 'InstanceBodies:<StaticBody3D>' ... 'Compound hierarchy is too deep and exceeds the amount of
  available sub shape ID bits'` – that cell's static instances probably have no collision. Split InstanceBodies into
  several bodies (Jolt sub-shape ID bits limit).
- F6 (svet, then hra) t10, real data: `Game.cache_bytes()` peaked at 4 741 MiB while the cache folder never exceeded
  841 MiB (cap 3 619 MiB) -> t10 FAIL "max Game.cache_bytes() sample <= cap: 4971678609 <= 3795370491". Cause: the
  converter's `done.bytes` for a cell is `Sizes.DirBytes(target) + Meshes(ctx, res).BytesWritten`
  (converter/src/Hzs.Decima/World/CellConverter.cs:168), and `BytesWritten` is a process-wide cumulative counter, so
  every cell reports all mesh bytes written so far (game log: `cell (6, -3) converted (504613266 bytes ...)` while
  evicted cells are 7-13 MB). hra's world.gd adds done.bytes to its running total -> HUD size and eviction work on an
  inflated number (it evicted ring-5 cells early). Fix: report the bytes written by that job only; hra could also
  re-anchor on its background folder scan instead of keeping the delta.

- F6 still open on main e8f117d (CellConverter.cs:168 unchanged): full dev run 2 `Game.cache_bytes()` max 6 352 MiB vs
  folder max 761 MiB, cap 3 261 MiB.
- F7 (hra) t06, real data, full dev run 2: the herd flees at once (0.05 s) but two of three Grazers are back to
  `graze` before 10 s; mean distance 31.9 -> 60.3 m (+28.4 m < 30 m). Earlier runs: +36 m and +50 m. machines sheet
  grazer flee_distance_m = 80, run_speed 9 m/s -> fleeing should last until ~80 m away. Flaky until the flee keeps
  going to flee_distance_m.
- F3 resolved on main (D36): Watchers spawn with 90 HP.
- Observation (svet/hra, not a test criterion): herd_landscape.png – terrain albedo mostly white (snow) and vegetation
  renders as vertical textured slabs; Grazers cover only 1-5 % of the frame at 40-60 m (sheet distance).

## Runs on main with hra merged (dev editor build, real data, cache copy C:\meshy\_tools\cache-test-real)
- T1 acceptance (`--mock-data --autotest t01,t03 --out C:\meshy\_tools\autotest-dev`): ExitCode 0, t01 + t03 PASS.
- Full run 2 (`C:\meshy\_tools\autotest-dev\full2`): 12/14 PASS; FAIL t10 (F6), t06 (F7).
  t09: bootstrap_seconds 75.1, 333.5 MiB at world_ready (start cell only), 749.0 MiB after the 3x3 (9.4 s later).

## T6: exported build, launched as Melty does plus --autotest
`C:\meshy\dist` (built from main) has no game/autotest (main does not contain this branch yet), so its exe cannot run
the autotest. I exported my merged branch (main e8f117d + game/autotest) with the same preset to
`C:\meshy\_tools\dist-test` and copied converter/, licenses/ and the txt files from `C:\meshy\dist`;
`tools/preflight.py package` -> CLEAN (222 files). Launch: `HorizonStrike.exe --game <CS2> --autotest --out
C:\meshy\_tools\autotest-dist` (no --cache-dir: real first launch into %LOCALAPPDATA%\HorizonStrike\cache).
Result: ExitCode 1, 13/14 PASS, FAIL t10 (F6: Game.cache_bytes() 6 356 MiB vs folder 765 MiB, cap 2 746 MiB; HUD
showed "Cache 3.3 GB / 4.0 GB"). t09: bootstrap_seconds 74.4, 341.5 MiB at world_ready, 749.0 MiB after the 3x3.
Screenshots: `C:\meshy\_tools\autotest-dist\{buy_wheel,watcher_alert,herd_landscape}.png`.

## s03 made robust (after the final-release rerun failed "3 in frustum, 2 unoccluded")
Candidate views: rings 40/50/60 m x 16 directions on loaded ground, sorted by herd members a ray from eye height
reaches (then nearer ring, higher ground). Up to 10 candidates are tried: teleport, aim at the herd, wait 1 s, then the
same frustum + ray check as the pass criterion runs from the real camera; the screenshot is saved at the first view
with >= 3 unoccluded Grazers, and the criterion is evaluated again for the saved frame (herd AI off, so nothing moves).
If no candidate verifies, the best estimate is captured and the check fails (verified on the stub with a 5-grazer
requirement: 10 of 10 views tried, FAIL). Real data, editor, main f82b0ef + this change, s03 alone three times
(`C:\meshy\_tools\autotest-dev\s03run{1,2,3}`): PASS, PASS, PASS – each "3 in frustum, 3 unoccluded", view 1 of 10
(40 m from FE_Antelope_Scout); the retry path was not needed in these three runs.

## 0.1.1 hotfix: player input instead of API shortcuts
The released 0.1.0 could not buy anything with the wheel, yet t03 passed: it called `Game.buy()`. Now the behaviour
under test goes through simulated player input in the game process (`lib/inputsim.gd`, `Input.parse_input_event`,
keys/buttons taken from the game's InputMap; the OS cursor and the user's devices are never touched). API calls stay
only for setup (money, spawn, teleport, aim_at = camera direction, invulnerable, kill_player) and for reading state.
- t03 (rewritten): buy key -> mouse moves to the item's slot as drawn on screen (found by its displayed name and
  "$price" label, centre of that slot) -> left click; HE Grenade by holding the buy key, hovering and releasing it.
  Cases: P250, AK-47, HE Grenade, Kevlar (price subtracted, item/armor given, shown price == resolved price), then AWP
  with $price-1 refused (money unchanged, not given). `Game.buy()` is never called.
- s01: the wheel is opened/closed with the buy key; "12 items" is read from the slots on screen.
- t02, t04: weapons taken with their slot keys (CS slots 1-4 from weapons.slot), shots with the fire button, reload key
  on an empty clip; damage read from the target's health. t04: the Watcher has 90 HP, so its weak shot is capped (check:
  one weak shot kills and the formula deals >= 90); the exact weak-spot number is measured on a Grazer's weak spot
  (150 HP).
- t06: crouch key held down, Glock from slot 2, the shot into the air with the fire button (one round must be used).
- Not changed (setup, not the behaviour under test): t07 buys its loadout with Game.buy (the death rule is under test),
  kill_player (documented lethal-damage path), teleports (positioning), campfire activation (the game activates by
  proximity; the test stands next to it).
- Verified on the scratch stub: a correct input-driven wheel -> t03 23/23 + s01 PASS; wheel that ignores input in
  automated runs -> FAIL "wheel open and the slot visible on screen" x5; wheel GUI that swallows clicks/motion -> FAIL
  "money unchanged / item not given" x4.

### Before hra's fix (main 143bc4a, real data, editor) – `C:\meshy\_tools\autotest-dev\hotfix-before`
ExitCode 1. t03 FAIL (wheel never opens: "wheel open and the slot visible on screen" x5), s01 FAIL (shown []),
t02 FAIL (fire button: "presses_without_shot": 5, ammo (30, 90) unchanged; knife slot key: current stays ak47),
t04 FAIL (slot key: current stays ak47), t06 FAIL (crouch key: crouched = false; fire button: ammo unchanged).
- F8 (hra): in automated runs the game ignores all player input: `ui/buy_wheel.gd _unhandled_input` returns when
  `Game.args.automated()`; `player/weapons.gd` returns unless `Input.mouse_mode == MOUSE_MODE_CAPTURED`;
  `player/player.gd` movement/crouch need the captured mouse too. Automated runs must accept (simulated) input without
  capturing the OS mouse, otherwise no test can exercise the real input path.

### After hra's buy wheel fix (main d0a0de1, real data, editor)
- t03 now also has a case that starts with `Input.mouse_mode = MOUSE_MODE_CAPTURED` (as during play): the buy key must
  make the mouse visible and the buy still works by motion + click. Side effect: for that moment the OS cursor is
  captured and the game warps it to the window centre once when the wheel opens; `ctx.cleanup` always frees it.
- t03 three times (`C:\meshy\_tools\autotest-dev\t03after{1,2,3}`): PASS 28/28 each (P250, AK-47, HE by release, Kevlar,
  Desert Eagle with captured mouse 2 -> 0, AWP refused with $4749). Game log shows `buywheel: open/hover/select/bought/close`.
- Full suite (`C:\meshy\_tools\autotest-dev\full-0.1.1b`): 11/14 PASS (t08 t11 t09 t10 t01 t03 s01 t05 s02 s03 t07);
  FAIL t02, t04, t06 = F8 below (weapons and crouch still ignore input while the mouse is not captured).
- F8 (hra) still open for weapons/player: `player/weapons.gd:163` returns unless `Input.mouse_mode ==
  MOUSE_MODE_CAPTURED` (slot keys, fire, reload) and `player/player.gd:298` (`input_enabled`, crouch/move) the same.
  Evidence: "ak47 taken with its slot key | current ak47" (slot 3 had no effect), "fire button fired the Glock ... ammo
  (20, 60) -> (20, 60)", "player.crouched = false" with the crouch key held. On the stub with an input path that does
  not require the captured mouse, t02 16/16, t04 14/14, t06 12/12 PASS; with weapons ignoring input t04 FAIL.
- F9 (hra): the t09/t10 child hung for 20 min after its runner called `get_tree().quit(0)` (results written, converter
  still running, no exit) and was killed by PID. The runner now quits through `Game.main.quit_game(code)` (stops the
  converter first): verified `quitting (0)` and ExitCode 0. A bare SceneTree.quit with a busy converter should still
  not hang.
- Runner fixes on the way: simulated events are no longer force-flushed (the engine delivers them at frame start, so
  every `_process` sees `is_action_just_pressed`); taps hold for 4 process frames; a slot key is exercised even when the
  weapon is already in hand (switch away first - a dead key cannot pass); the cleanup gives the start loadout back via
  `kill_player` + respawn when a scenario lost it (buying a pistol replaces the Glock).

### t04 weak spot as the first hit (after hra 430c92f) and the full suite 14/14
- Line of sight per shot: the ray from the camera (machines' non-hitbox bodies ignored, like the bullet trace) must hit
  the wanted hitbox FIRST. Exception that mirrors the game rule since 430c92f ("weak wins inside an enclosing body
  box"): the first collider may be a body hitbox of the same machine if the weak hitbox lies INSIDE that box where the
  ray meets it; a weak hitbox BEHIND a body box fails and the player is moved around the target (8 x 45 deg). The first
  hit is reported (`first_hit`, earlier blockers). Stub checks: weak inside -> clear "next: eye ... inside it"; weak
  behind -> "next: eye at 2.57 m further, behind it" -> moved until clear; a game that never counts the weak spot inside
  the body still FAILS (weak 12.6 vs 105.6).
- Real data, before hra's fix (t04run1-3 of the first round): "line of sight B eye ... first hit: Hit_body ... after
  9 moves" 3/3 FAIL (the eye inside the Watcher's body box) and one Grazer canister shot without damage.
- Spread: a weak-spot shot that misses or lands on the body (damage < half of damage x headshot_mult) is retried, 3 shots
  max; earlier shots are recorded (`earlier_shots_damage`), the measured damage is the last shot's. If the game never
  counted the weak spot all 3 would be body damage and the formula check fails.
- After hra 430c92f, t04 three times (`C:\meshy\_tools\autotest-dev\t04run{1,2,3}`): PASS 17/17 each. Body 12.66
  (expected 12.34 +-0.39); Watcher eye kills (90 HP, formula 107.2); Grazer canister 104.55 / 104.59 / 104.51 (expected
  103.59 +-4.06); first hits: Watcher eye inside Hit_body (0.00 m), canister inside Hit_body (0.76 m); run 3 needed one
  extra shot (first landed on the body: 12.31).
- Full suite (`C:\meshy\_tools\autotest-dev\full-0.1.1c`): ExitCode 0, 14/14 PASS. t09 bootstrap_seconds 119.9,
  337.8 MiB at world_ready, 793.3 MiB after the 3x3; t10 Game.cache_bytes max 975.6 MiB, folder max 842.8 MiB, cap
  1 219.9 MiB, 24 evictions (F6 fixed); t02 1100/3050/16000; t06 30.8 -> 81.6 m.

## Scenario isolation + t04 line of sight (after final3: t04 miss, s03/t06 herd of 1 at the machine cap)
- The runner calls `ctx.begin_scenario()` before and `ctx.cleanup()` after every in-process scenario (also after a
  timeout): machines the scenario spawned through `Game.spawn_machine` are freed (`queue_free`; the game unregisters
  them in `_exit_tree`, so they stop holding `spawning.max_active_machines` slots), world machines whose AI a scenario
  switched (`ctx.set_ai`) get their original flag back (an alerted/attacking one stays frozen and is listed), the
  player's invulnerable/crouch flags are restored and the buy wheel is closed. `details.cleanup` records it.
- t04: before each shot a ray from the camera (hitbox areas included) must reach the target point first; otherwise
  the player moves around the machine at the same distance (8 x 45 deg) and the blockers are recorded
  (`blocked_by_before_moving`); a miss records what the shot line meets (`miss_blocked_by`). Stub check with a Grazer
  placed in A's line: `blocked_by_before_moving: ['body (hitbox of @Node3D@74)']`, then hit on body, PASS.
- Real data, editor, main bb534ed + this change, `t02,t04,s03,t06` (`C:\meshy\_tools\autotest-dev\iso1`): ExitCode 0,
  4/4 PASS. t02 cleanup removed 3, t04 removed 4; s03/t06 restored AI of 3 herd members; herd of 3 at
  FE_Antelope_Scout both times; t04 exact distances from `fire().distance` (body 12.47 = 12.47, weak 107.79 vs
  107.78, tolerance 0.05); t06 30.3 -> 80.7 m.

## Pre-merge integration runs (hra 4ea177b snapshot, dev editor build)
| id | name | mock | real data | key details (real) |
|---|---|---|---|---|
| t01 | start loadout | PASS | PASS | knife+glock, $800, glock clip 20 |
| t02 | kill reward | PASS | PASS | 1100 / 3050 / 16000, signal == delta |
| t03 | buy | PASS | PASS | 3000 -> 300 -> 0, awp refused, wheel 12 items at resolved prices |
| t04 | weak spot | PASS | FAIL (F3) | weak 107.76 vs body 12.66 at ~9 m; full health 140 vs expected 90 |
| t05 | watcher alert | PASS | FAIL (F4) | no Watcher spawned at FE_Harvester_Scout |
| s02 | watcher alert shot | PASS | not produced (F4) | mock: 28 % of frame at 9 m (retake) |
| t06 | herd flees | PASS | PASS | 3/3 flee in 0.01 s, 31.5 -> 67.5 m |
| s03 | herd landscape | FAIL (mock terrain) | PASS | 3 grazers unoccluded, terrain.real, 115 973 veg instances |
| t07 | death/respawn | PASS | PASS | respawn at Campfire_x05_y-03_3, 1.6 m, $5000 kept |
| t08 | missing HZD | PASS | PASS | screen + message + log line, converter not started |
| t09 | first launch | FAIL (mock has no model.glb) | PASS | bootstrap_seconds 88.1; 346 MiB at world_ready, 749 MiB after the 3x3 |
| t10 | cache cap | PASS (60 MiB padded cells) | FAIL (F6) | disk max 841 MiB <= cap 3 619 MiB, 24 evictions, none protected |
| t11 | no listener | FAIL (in-process mock) | PASS | hzsconv.exe, 0 listeners |
- F2 (hra): parent and child game share `%LOCALAPPDATA%\HorizonStrike\logs\latest.log` – hra's log.gd already
  opens it shared, appends within 120 s and tags lines with the pid; t08 filters by pid. Closed unless it regresses.

## 0.2 night run (T1-T6)

### T1 baseline 0.1.1 (status for the coordinator)
- Build: game source 042d111 (`git archive` into `C:\meshy\_tools\baseline-0.1.1\src`, no worktree), current
  game/autotest overlaid (+ `autotest/data/systems_rows.json` with the 59 systems rows 0.1.1 lacks), exported with
  Godot 4.7.2 into `baseline-0.1.1\build-b` (converter copied from `build`). Cache copy
  `C:\meshy\_tools\cache-baseline-011-a`. t15 child at 1920x1080, vsync off, max_fps 0, RTX 3060 Ti.
- Shot poses (systems `perf.shot_poses`): mothers_heart (2587.5, 243.2, 1386.2) yaw 45 pitch -9.8; valley
  (2229.1, 381.5, 1027.8) yaw -90 pitch -6; rocks_close (2568.6, 177.5, 786.4) yaw -113.4 pitch 8.
  "Before" screenshots: `C:\meshy\_tools\records-0.2\before\{mothers_heart,valley,rocks_close}.png` (checked, not
  blank).
- Measurement problem found and fixed on my side: the runner's parent is a full game instance and kept rendering and
  streaming next to the measuring child (parent log: 38 fps at 43 ms process while the child measured). Fixed in
  `lib/proc.gd quiet_parent()` (parent: 3D off, 5 fps cap, low-processor mode, tree paused while a child runs; also
  t16 and the movie children). Runs a-d were made with the old runner and are not valid baselines.
- Second problem, not fixable from the test: other agents' Godot / hzsconv processes share the GPU. t15 records them
  at start and end of the measurement (`data.other_load_start/_end`, note), and the baseline runs wait for a machine
  without such processes (scratch `wait_quiet.py`, 20 s quiet, max 30 min) - they start again within seconds.
- Numbers so far (route = the 10 cells of perf.route_cells, start = 30 s 360 deg turn):

| run | runner | start avg / 1 % low | route avg / 1 % low | worst | worst during load | VRAM start | cells | others |
|---|---|---|---|---|---|---|---|---|
| c | old (parent rendered) | 75.4 / 68.9 | 47.7 / 14.2 | 3262 ms | 2052 ms | 1229.7 MiB | 7 | yes |
| e | parent quiet | 8.5 / 1.9 | 42.1 / 2.6 | 1500 ms | 1500 ms | 1229.7 MiB | 10 | yes (2 Godot + hzsconv started right after the quiet window) |
| f | parent quiet | 20.8 / 2.8 | 47.5 / 4.5 | 1979 ms | 1683 ms | 1229.7 MiB | 10 | yes at start (2 Godot + hzsconv), none at the end |

  Run e's start phase is ~500 ms per frame for 25 s - another process saturated the GPU; route 42 fps is closer to
  run c. Start phase in 3 s buckets (ms per frame): c 13-14 throughout, e 130-515, f 240/305 then 28-88 - the
  start phase depends on whoever else renders at that moment. Robust across c/e/f: route avg 42-48 fps, VRAM 1230 MiB
  at start, and 1.5-2.1 s frames while cells load (0.1.1 inserts cells on the main thread). 1 % low is not
  comparable between runs on this shared machine.
- Baseline kept: run f -> `C:\meshy\_tools\records-0.2\baseline\frametimes.csv` (+ `results-t15.json`,
  `frametime_0.1.1.svg`). For r04 I will rerun 0.1.1 and 0.2 t15 back to back late in the night so both see similar
  conditions, and report the competing processes of both.

### T2-T5 scenarios (committed; runs on the 0.2 game follow)
- t12 new machines (main process): open snow field (2582, 178, 780); Broadhead spawned as a pair (the second must
  leave graze). Input only: W until suspicious, view kept by mouse motion, one glock shot into the air if no alert
  10 s after suspicious, W again if alert but no attack 8 s later (defend_charge only charges inside 25 m). Stalk =
  sub-state of alert, scavenge = calm (stroje's states). Laser burst: a node in group machine_projectiles whose
  `attack` is scrapper_laser_burst.
- t13 weak spots for every machines row: 8 ring positions at 10 m, mouse aim at each weak point, first hit along the
  shot must be that weak spot (lib/hitcheck.gd), deagle shot by the fire button, retried up to 3x on spread, body
  shot for comparison; reports N/8 per machine.
- t14 normal maps: classification by cell.json `instances[].kind` (or node meta `kind` / mesh id in the node name).
  Validated on the 0.1.1 cache (no kind field): terrain 9/9 with a normal map, 2 of 220 197 instances with a normal
  map -> FAIL, as it should before svet's V-tasks.
- t16 stress (main process): perf.stress_runs children `--autotest t16run --out <out>/t16/run<n>`; the child sets
  `player.speed_mult = perf.stress_speed_mult` (setup; missing on main -> note, normal speed), walks
  perf.stress_route_cells by input (25 s legs, then a teleport to the waypoint), writes RSS (tasklist), VRAM and the
  `[error]` lines of its pid in latest.log. Sheet t16: process main (was child).
- r02 / r03 (sheet: process main): lib/movie.gd starts a movie-maker child (`--write-movie <avi> --fixed-fps 30
  --resolution 1280x720`); the child films through its own side-on camera (HUD and the first-person weapon layer
  hidden; the player's camera still drives aim and shots) and writes the frame range of each clip; the parent cuts
  MP4s with ffmpeg (dev tool, PATH or HZS_FFMPEG) and checks 3 frames of each for blankness. One child per machine
  (walk, attack, death in a row) instead of one per clip: 6 boots instead of 18. Raw AVIs stay in `<out>/r02raw`,
  `<out>/r03raw` (not in the records folder).
  Validation on main 36e1bea + the 0.1.1 cache (dev editor): r03 PASS (25.3 s, cells (4,-3) -> (4,-4) -> (5,-4),
  luma stddev 41-46); r02 PASS 18/18 clips of 7.2-8 s, not blank (new machines were placeholder boxes there).
- Needs: hra `player.speed_mult` (t16); svet `kind` per cell.json instance (t14).


### Runs on main 0110c88 (svet V0-V7, hra H1-H3, stroje M0-M3), dev editor, cache copy `cache-test-02a` (c48)
- t12 PASS (`C:\meshy\_tools\autotest-dev\v02-e`): sawtooth patrol 0 -> suspicious 1.7 -> alert 3.8 -> stalk 4.4 ->
  attack 9.9 s (charge 9.9, pounce 12.4); scrapper scavenge -> suspicious 2.0 -> alert 3.2 -> attack 3.8, laser_burst
  projectile at 4.7 s; broadhead graze -> suspicious 2.7 -> alert 4.7 -> attack 5.3 (charge 5.3), the second
  Broadhead graze -> suspicious 3.8 -> alert 4.7 -> attack 5.3. None fled. No shot into the air needed.
  Earlier attempts failed on test bugs (machine spawned at the player's feet, previous machines left at the spot);
  one attempt (v02-d) had sawtooth patrol -> alert in 0.3 s at 45 m without suspicious - not reproduced in v02-e,
  watch item for stroje.
- t13 PASS (`v02-f`), real input shots, first hit along the shot = the weak spot (game WEAK_SLACK_M 0.15 m agrees:
  a weak box 0.7 m behind the body surface does not count):

| machine | weak spot first hit + hit by the shot | weak > body (body-only lines) | stroje bench |
|---|---|---|---|
| watcher | 7/8 (180 deg: eye 2.0 m behind the body) | 7/7 | 8 |
| strider | 7/8 (0 deg: canister 1.9 m behind) | 6/6 | 7 |
| grazer | 8/8 | 8/8 | 8 |
| sawtooth | 5/8 (0/90/270 deg: canister 0.7-2.1 m behind the body) | 5/5 | 8 |
| scrapper | 7/8 power_cell | 7/7 | 6/8 power cell |
| broadhead | 7/8 | 7/7 | 7 |

  Weak damage = deagle.damage x headshot_mult x falloff (oracle) within +-0.02 when the falloff is taken at the weak
  hitbox surface (e.g. watcher 185.42 vs 185.43); at the aim point it was off by up to 2.1 on the Grazer.
  Observation for stroje: on the Sawtooth a shot at the default body point (and at body box centres) registers as a
  weak hit (182 instead of ~44) - the canister box sits inside the body box, so the game's "weak inside an enclosing
  body box wins" rule applies; t13 compares against body-only lines only.
- t14 FAIL (`v02-e`): terrain 14/14, rock 22 705/22 738 (99.9 %) with a normal map, building 51 052/70 139
  (72.8 %) - finding for svet below. Vegetation 15 233/19 738, props 120/321 (not criteria).
- Finding F8 (svet) t14: building instances without a normal map in the loaded cells around (4,-3), top meshes
  `825f6b53d3cf44b0_0` x4070, `0ff5e965b6e24263_58` x515, `2548028a75587510_49` x451, `651eef0e181d2161_58` x327,
  `57b5d8d0323b8a62_13` x326, `fe54649fd6408bd7_66` x291 (material without normal_enabled + normal_texture, or a
  ShaderMaterial without a bound *normal* texture).
- t16 validation with 2 runs (`HZS_T16_RUNS=2`, `v02-h`, no speed_mult on main -> 8 s legs + teleports, 30/30
  cells each): run 1 exit 0 (261 s, RSS 2139 MB, VRAM 1527 MB), run 2 wrote its PASS result and logged
  `quitting (0)` at 01:01:43, then `[warn] world exit: worker task 424751 still running after 10 s, not waiting for
  it` at 01:01:53 and the process ended at ~01:02:36 with exit code -1073741819 (0xC0000005 access violation).
  RSS run 2 2355 MB (+10 % of run 1), VRAM equal, 0 `[error]` lines.
- Finding F9 (hra): crash on quit while a world worker task (cell load) is still running - the main thread stops
  waiting after 10 s and the engine tears down under the running task. Reproduce: teleport across cells and quit
  within ~1 s (t16run does this after its last waypoint). Fix: cancel/finish the task (or keep waiting) before the
  world is freed.

### T5 records + t15 on 0.2 (test build `C:\meshy\_tools\test-02-build-a` = export of 0110c88 + converter publish)
- `--autotest r01,r02,r03` (`C:\meshy\_tools\autotest-02\rec-a`): r01 PASS (3 PNG, same poses as before/, not
  blank), r02 PASS (18 MP4, 7.2-8 s, 3 frames each checked: not blank; real models + animation), r03 PASS (25.3 s,
  2 borders). Copied to `C:\meshy\_tools\records-0.2\after\` and `...\video\` (19 MP4).
- t15 on 0.2 (`records-0.2\t15-02-g`, others at start: only its own parent; at the end 2 Godot + hzsconv of other
  agents): start 63.5 / 55.6 fps, route 66.7 avg / 25.3 1 % low, worst 589 ms, worst during a load 541 ms, VRAM
  1021.6 MiB, 10 cells, 0 engine errors. FAIL: route 1 % low >= 45, no frame > 50 ms while a cell loads (hra H4+).
- r04: `records-0.2\frametime_0.1_vs_0.2.svg` (0.1.1 run f vs 0.2 run g, route phase). Scenario r04 runs the tool
  from the game (env HZS_BASELINE_CSV, HZS_T15_CSV / <out>/t15, HZS_TOOLS, HZS_PYTHON).
- t14 after svet's fix (main 4a7cf9b, cache copy of svet's c54 -> `cache-test-02b`, `autotest-dev\v02-i`): PASS.
  Building 41 096/41 318 instances with a normal map (99.5 % raw), 222 excluded as `hzd_normal: none` -> 100 %; rock
  14 009/14 019 (10 excluded); terrain 9/9; 0 engine errors. hra's glb reader does not pass the glTF material extras
  on (no material meta), so t14 reads the flag from the cache glb (`hzd/meshes/<id>.glb`, JSON chunk): an instance
  is excluded when its surfaces without a normal map are no more than its glb primitives with a flagged material.
  F8 closed. (Request to hra, optional: keep `extras.hzd_normal` as material meta so the test reads the game's own.)

## Log
- 2026-10-09 runner, libs and all 13 scenario scripts written against the documented API; stub verification above.
- 2026-10-09 pre-merge integration: hra's committed game (branch head 4ea177b, exported with `git archive` into a
  scratch folder, my game/autotest overlaid; nothing merged) on mock data and on real data (copy of cache-dev in
  `C:\meshy\_tools\cache-test-real`, converter built from my merged main). Fixes on my side from these runs: t03 start
  money from prices, LOS-checked spawns, tapping, kill_award_class fallback, t10 "already loaded", user args to
  children, s03 view point, sites prefer the own HZD type, no fall damage from site teleports.
