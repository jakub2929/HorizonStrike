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
- 2026-10-10 12:55 t26 PASS (dev, shared machine; E:\meshy_work\vykon03-t2627-2): A 11/11 checks (Low, Medium,
  High, Low clicked; engine state matched within the click's frames), B 7/7 after restart (low), graphics.json only in
  --user-dir (%LOCALAPPDATA% file mtime unchanged). Vegetation density check compares per chunk
  visible == round(count x density) (small chunks round: a share check failed on 1-3-instance chunks).
- 2026-10-10 12:57 t27 PASS (same run): unlimited 72.9 fps, GPU 12.62 ms/frame = 920 ms/s; limit 60: 60.0 fps
  (1 % low 58.3), GPU 12.52 ms/frame = 751 ms/s (-18 %). Other Godot/converter processes of the test teammate ran.
- graphics.json follows --user-dir already (GraphicsSettings.settings_path reads --user-dir itself because the
  autoload starts before Game sets Paths.user_dir_override); no fix needed.
- 13:00 coordinator: no windowed runs (user works on this PC). t25 windowed run (vykon03-t25-1) was stopped from
  outside after 150 s; r05-r09 and the windowed t25 not run yet. Headless only from here.
- Task C far albedo (graphics.far_albedo_max_px), from the cache (97 cells): every albedo.dds is 2048 px BC1 sRGB
  with 12 mips = 2.67 MiB. Far cells = rings render.hlod_from_ring (2) .. streaming.unload_ring (3) = up to 40 cells:
  uncapped 106.7 MiB, cap 1024 26.7 MiB, cap 512 6.7 MiB, cap 256 1.7 MiB. 512 (merged) already takes 94 % of the
  saving; 256 would save 5 MiB more and is coarser than a screen pixel at ring 2 (~1 m/px at 1-1.5 km, 1080p).
  Decision: keep 512.
