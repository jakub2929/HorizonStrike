# vykon journal (graphics settings, perf tests, records)

Source of truth for my running decisions. Newest entries at the bottom of "Log".

## Owned files
- game/settings/graphics_settings.gd (autoload GraphicsSettings), game/ui/graphics_menu.gd (Esc > Graphics)
- game/dev/perf_*.gd, tools/perf_mem.py, tools/perf_report.py
- 0.3 tests (branch vykon-03): game/autotest/scenarios/t25*, t26*, t27*, r05*-r09* (+ their child parts) and
  game/autotest/lib/child.gd, perfrec.gd, gfxstate.gd, recclip.gd

## How to run (dev editor, worktree)
- Fresh worktree: `godot --headless --path game --import` once (global class cache: AutotestSheet etc.), else the
  runner does not compile ("Identifier AutotestSheet not declared").
- The main checkout's converter build can be stale: `dotnet build converter/hzsconv.sln -c Release` in the worktree
  (Paths.converter_exe prefers the worktree build).
- CS2 is NOT auto-detected: pass `--game "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"`.
- The console exe is a wrapper: the game is its child `Godot_v4.7.2-stable_win64.exe` (kill that PID on a timeout).
- Warm dev cache: E:\meshy_work\vykon03-cache-1 (robocopy of my earlier cache-m3, 127 cells; CS2 re-converted).

## Test design (sheet rows t25-t27, r05-r09)
- t25: main process, one child per preset (`t25run`, `--gfx-preset <p> --fps-limit 0`, own --user-dir,
  `--resolution 1920x1080`). Preset via the command line so Low's half textures apply from the first cell.
  Child walks perf.route_cells exactly like t15 (lib/route.gd), perfrec.gd records frame / GPU / CPU time, tasklist
  working set of the game and Game.converter_pid every perf.mem_sample_s, VRAM. Converter idle = world.requested
  empty for perf.converter_idle_settle_s, then 3 samples (median).
- GPU time = sum of viewport_get_measured_render_time_gpu over root + SubViewports (the weapon viewmodel is one).
  GPU load (t27) = GPU busy ms per wall-clock second.
- t26: main process, child A (`t26a`) clicks PresetLow/Medium/High/Low by input and reads ENGINE state
  (lib/gfxstate.gd: viewport scale/mode, LOD threshold, sun shadow/mode/distance, Environment SSAO/SSR/fog,
  vegetation chunk fade factor and visible counts) + graphics.json; child B (`t26b`) same --user-dir after restart.
- t27: sheet child row (runner child mechanism), menu clicks FpsLimit_0 then FpsLimit_60, 20 s each standing still.
- r05-r09 rows were child rows whose extra_args had no `--autotest` (the runner could not launch them): changed to
  main-process recorders that start their own children (lib/child.gd, lib/recclip.gd) with their own --user-dir.

## Log
