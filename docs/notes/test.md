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
- F2 (hra): parent and child game share `%LOCALAPPDATA%\HorizonStrike\logs\latest.log` – hra's log.gd already
  opens it shared, appends within 120 s and tags lines with the pid; t08 filters by pid. Closed unless it regresses.

## Log
- 2026-10-09 runner, libs and all 13 scenario scripts written against the documented API; stub verification above.
