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
- Task C unload ring, headless Low (t25run run directly: `--headless -- --autotest t25run --gfx-preset low
  --fps-limit 0`, same route, dev shared machine; GPU / VRAM / window checks meaningless headless):
  | run | unload_ring | game WS peak | reloads | worst load frame | converter |
  | vykon03-c-ring3-1 | 3 | 2221.8 MiB | 0 | 318 ms | converted new cells, peak 1056 MiB (not comparable) |
  | vykon03-c-ring2-1 | 2 | 1932.3 MiB | 2 of 25 loads | 36.7 ms | idle (warm) |
  | vykon03-c-ring3-2 | 3 | 2110.7 MiB | 0 of 23 loads | 34.9 ms | idle (warm) |
  Warm comparison: ring 2 saves 178 MiB (-8.5 %) and adds 2 reloads per 10-cell route. But streaming.unload_ring
  is also the outer far-cell ring (world._update_far: far cells from render.hlod_from_ring to unload_ring), so 2 also
  cuts the HLOD horizon from 1.5 km to 1 km. Headless Low peak 2.11 GB is under 2.5 GB with ring 3. Decision: leave
  3 (sheet unchanged); if the windowed Low run exceeds perf.low_game_ram_max_mb, split a full-cell unload ring from
  the far ring in world.gd (owner hra) and set the full-cell one to 2.
- Converter idle (headless runs): working set 5.6-10.0 MiB, private bytes 20.9-21.4 MiB after 15 s idle; peak while
  converting new cells on the route 1056 MiB. Target 300 MB met by a wide margin.
- t01 PASS headless (vykon03-t0103-1); t03 FAIL headless: buy wheel opens, prices shown, but the synthetic clicks do
  not reach the GUI without a window (no "bought" line in the game log). My branch changes no game code outside
  game/autotest (git diff main -- game ':!game/autotest' ':!game/generated' is empty); t03 must be run windowed.
- r08clip headless check (no movie): level 5 take-off 10.16 then 10.19 m/s kept for 5 jumps, then clipped to 6.35;
  level 0 clips at the first landing and decays 6.35 -> 1.55 m/s. My air-strafe input alone did not raise the speed
  (6.40 m/s on every landing), hence the setup boost to 1.6 x run speed after the first take-off (sheet r08 setup).
  Clip length counted in physics steps (drawn frames do not advance headless).
- r07clip headless check: 18 s, 23 hitmarkers / numbers / sparks, 12 player hits, 5 waves (weak-spot AK shots kill a
  scrapper or watcher in one shot, so a new wave is spawned when one is down). Aim by Game.aim_at as lib/combat.gd;
  the closed-loop mouse aim missed every shot while aimpunch kicked the view.
- Paused by the coordinator (windowed): t25 (Low + High), r05, r06, r09 and the movie runs of r07, r08.

## fix-03-low-preset (from release/0.3 6322918; dev editor, release converter 0.3.0-rc2, cache E:\meshy_work\test03-cache-1)
- Where Low's GPU time goes (dev/gpu_ablation.gd, Low, 7 poses, E:\meshy_work\vykon03-ablation-1..4): Godot 4.7
  exposes no per-pass timestamps to scripts (RenderingDevice captured timestamps = viewport begin/end only), so
  items are switched off one at a time. Root viewport 6.9 ms, viewmodel viewport 0.2 ms. Full-cell instances
  4.4-7.9 ms of 7.5-11.3 ms; trees 0.5-3.8; sun shadows 1.1-2.4; terrain 0.2-0.6; far cells, sky, fog, FXAA, lights,
  machines ~0; render scale 0.67 -> 0.5 only -0.2..-0.3 ms (not pixel bound); FSR -> bilinear -0.1..-0.2.
  Inside instances: the player's cell 6.5-7.4 ms at the start whatever the view direction -> cell_builder's 512 m
  (>= 12 m meshes) / 256 m chunks: a MultiMesh is culled and LOD-selected as one, so every big instance of the cell was
  vertex-processed at LOD0 in every pass. Candidate preset values (lod bias 0.25/0.125, instance range x0.7/x0.5,
  no sun shadows, scale 0.5) together saved at most 1.6-4.1 ms -> not enough.
- Fix (coordinator approved): render.instance_chunk_max_m 128 caps the chunk edge in cell_builder._lod_class (all
  presets). Same Low preset, GPU per pose 10.1/10.0/9.7/9.1 (start) -> 6.0/5.7/5.4/5.4, mothers_heart 7.5 -> 3.2,
  valley 8.8 -> 2.5, rocks_close 11.3 -> 2.8 ms.
- RAM: graphics.presets full_ring (Low 2, Medium/High 3) via GraphicsSettings.full_cell_ring() in world.gd; far/HLOD
  ring stays streaming.unload_ring 3 (horizon kept). Windowed effect small: Low peak 2778 -> 2753-2770 MiB.
  staging buffer 128 -> 32 MB (project setting, tried once, reverted): 2734 MiB (-30). Memory map of the Low game
  mid-route (psutil): working set 2688 MiB = mapped images 599 (Godot editor exe 174, NVIDIA driver DLLs ~330) +
  private; Godot static ~1.0 GB (15 cells loaded, 31k nodes); the rest is driver / Vulkan allocations. Low and High
  peak the same before the fix (2778 / 2775 MiB): the preset levers do not reach it. Not met: best 2734-2770 MiB dev
  (release template ~90 MiB less: rc2 2684 vs dev 2778 before).
- t25 dev before (release/0.3 source exported to E:\meshy_work\vykon03-before-src, same converter/cache) vs after:
  Low GPU 7.45 -> 3.28 / 3.27 ms (p99 15.25 -> 9.75 / 8.28), fps 119.4 -> 206.4 / 190.4, VRAM 1517 -> 1473 / 1478,
  RAM 2778 -> 2770 / 2753; High fps 83.1 -> 154.7 / 157.6, 1 % low 47.5 -> 57.8 / 60.5, GPU 11.39 -> 5.13 / 4.96 ms,
  RAM 2775 -> 2847 / 2860, VRAM 1753 -> 1753; worst load frame High 32.1 -> 57.9 (run 1 FAIL) / 48.4 (run 2 PASS),
  both at the same spot (t ~227 s, cell 0,-2: 13-machine site activation + a 11.7 ms collision op; before 42.2 ms
  there, outside the load window). Draw calls avg Low 904 -> 987, High 1022 -> 1293-1319.
- Cell insert (main thread per cell, "cell phases"): multimesh median 33 -> 41 ms (+24 %, in 6 ms budget steps),
  add_child 1.1 -> 1.1, insert wall median 1.7 -> 1.8-1.9 s.
- t15 PASS (start 127.0 / 109.5, route 160.6 / 66.0, worst load 37.1 ms), t26 PASS, t16 (HZS_T16_RUNS=2) PASS
  (30 cells, RSS 2902 / 2921 MB, VRAM 1227, 0 errors).
- Visual: Low screenshots before/after E:\meshy_work\vykon03-low-shots\{before,after}: identical apart from more
  trees in the valley view after (128 m vegetation chunks are faded by their own distance instead of a 512 m
  chunk's centre).
