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

## Log
- 2026-10-09 runner, libs and all 13 scenario scripts written against the documented API; stub verification above.
- 2026-10-09 pre-merge integration: hra's committed game (branch head 4ea177b, exported with `git archive` into a
  scratch folder, my game/autotest overlaid; nothing merged) on mock data and on real data (copy of cache-dev in
  `C:\meshy\_tools\cache-test-real`, converter built from my merged main). Fixes on my side from these runs: t03 start
  money from prices, LOS-checked spawns, tapping, kill_award_class fallback, t10 "already loaded", user args to
  children, s03 view point, sites prefer the own HZD type, no fall damage from site teleports.
