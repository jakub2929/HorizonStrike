extends "res://autotest/lib/scenario.gd"
## t25run (child part of t25, one process per preset given by --gfx-preset): after world_ready, the start 3x3 and
## perf.settle_s, walk perf.route_cells by input as t15 (held W, mouse steering, jumps, leg teleport fallback) while
## lib/perfrec.gd records frame / GPU / CPU times and samples game + converter RAM and VRAM. After the route the player
## stands still until the converter is idle (no cell request open for perf.converter_idle_settle_s) and the
## converter's RAM is sampled. Checks the preset's limits (sheet t25). Setup only: vsync off, invulnerable.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Route := preload("res://autotest/lib/route.gd")
const PerfRec := preload("res://autotest/lib/perfrec.gd")
const T15 := preload("res://autotest/scenarios/t15_perf.gd")
const LEG_WALK_S := 45.0


func _init() -> void:
	timeout_s = 2700.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	var o = ctx.oracle
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	if not api_check(ctx.missing_api(g, ["player", "converter_pid", "world"], ["teleport"]) + ctx.missing_api(p, ["invulnerable"]) + ([] if gs != null else ["GraphicsSettings autoload"])):
		return false
	var preset := str(gs.get("preset"))
	data.preset = preset
	data.graphics = gs.call("describe")
	# setup: vsync off (the fps limit 0 came from --fps-limit), invulnerable
	gs.call("set_value", "vsync", false)
	p.set("invulnerable", true)
	data.max_fps = Engine.max_fps
	data.render_scale = ctx.tree.root.scaling_3d_scale
	var res: Array = o.system("perf.resolution")
	var win := DisplayServer.window_get_size()
	data.window = [win.x, win.y]
	data.gpu_name = RenderingServer.get_video_adapter_name()
	check("window %dx%d (perf.resolution)" % [int(res[0]), int(res[1])], win.x == int(res[0]) and win.y == int(res[1]), "%dx%d" % [win.x, win.y])
	check("preset %s active, fps unlimited, vsync off" % preset, preset in ["low", "medium", "high"] and Engine.max_fps == 0 and DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED,
		"preset %s, max_fps %d, vsync mode %d" % [preset, Engine.max_fps, DisplayServer.window_get_vsync_mode()])

	var start_c: Variant = ctx.cell_of(ctx.player_pos())
	check("start 3x3 loaded", await T15._wait_ring(ctx, start_c, 900.0), str(start_c))
	await ctx.wait(float(o.f(o.system("perf.settle_s"))))
	data.other_load_start = await T15._others(ctx)

	var rec := PerfRec.new()
	rec.name = "AutotestPerfRec"
	ctx.runner.add_child(rec)
	rec.start(g)
	rec.phase = "route"
	rec.start_mem_sampler(ctx, float(o.f(o.system("perf.mem_sample_s"))))
	var inp = InputSim.new(ctx)
	inp.capture_for_look()
	await inp.equip("knife")
	var cs := float(o.f(o.system("streaming.cell_size_m")))
	var cells: Array = o.system("perf.route_cells")
	var wps := []
	for i in cells.size():
		var c: Vector2i = ctx.v2i(cells[i])
		if i == 0 and start_c == c:
			continue
		wps.append(Route.cell_center(c, cs))
	var walker = Route.new(ctx, inp)
	walker.on_phase = func(ph): rec.phase = ph if ph != "" else "route"
	await walker.walk(wps, LEG_WALK_S, func(k): rec.cell = k)
	rec.phase = "idle"
	data.other_load_end = await T15._others(ctx)

	# converter idle: no open cell request for perf.converter_idle_settle_s, then 3 samples 2 s apart (median)
	var w: Object = g.get("world")
	var settle := float(o.f(o.system("perf.converter_idle_settle_s")))
	var wait_max := float(o.f(o.system("perf.converter_idle_wait_max_s")))
	var t_idle0 := Time.get_ticks_msec()
	var quiet_since := -1
	while (Time.get_ticks_msec() - t_idle0) / 1000.0 < wait_max:
		var req: Variant = w.get("requested") if w != null else null
		var busy: bool = req is Dictionary and not (req as Dictionary).is_empty()
		if busy:
			quiet_since = -1
		elif quiet_since < 0:
			quiet_since = Time.get_ticks_msec()
		if quiet_since >= 0 and (Time.get_ticks_msec() - quiet_since) / 1000.0 >= settle:
			break
		await ctx.wait(0.5)
	var idle_ok := quiet_since >= 0 and (Time.get_ticks_msec() - quiet_since) / 1000.0 >= settle
	data.converter_idle_wait_s = snappedf((Time.get_ticks_msec() - t_idle0) / 1000.0, 0.1)
	var conv := int(g.get("converter_pid"))
	var samples := []
	for i in 3:
		var ws: Dictionary = await PerfRec.working_sets(ctx, [conv])
		samples.append(float(ws.get(conv, -1.0)))
		await ctx.wait(2.0)
	samples.sort()
	data.converter_idle_samples_mb = samples
	data.converter_idle_mb = samples[1]
	data.converter_idle_private_mb = await PerfRec.private_mb(ctx, conv)
	data.game_private_mb_end = await PerfRec.private_mb(ctx, OS.get_process_id())
	data.converter_flag_idle = w.get("_converter_idle") if w != null else null
	rec.sampling = false
	await ctx.frames(2)

	var csv: String = ctx.out_dir.path_join("frametimes.csv")
	rec.write_csv(csv)
	rec.write_mem_csv(ctx.out_dir.path_join("mem.csv"))
	var st: Dictionary = rec.stats("route")
	var gst: Dictionary = rec.gpu_stats("route")
	var mst: Dictionary = rec.mem_stats(["route", "plan"])
	var mall: Dictionary = rec.mem_stats()
	data.csv = csv
	data.route = st
	data.gpu = gst
	data.mem = mst
	data.mem_all = mall
	data.cells_visited = walker.cells_visited.keys()
	data.leg_teleports = walker.leg_teleports
	data.teleports = walker.teleports
	data.walked_m = snappedf(walker.walked_m, 1.0)
	data.cell_loads = rec.loads.size()
	# reload churn (task C: unload ring): a cell inserted more than once during the run
	var seen := {}
	for l in rec.loads:
		seen[l[1]] = int(seen.get(l[1], 0)) + 1
	data.cell_reloads = seen.values().reduce(func(a, n): return a + n - 1, 0)
	data.unload_ring = o.i(o.system("streaming.unload_ring"))
	data.far_albedo_max_px = o.i(o.system("graphics.far_albedo_max_px"))
	if not (data.other_load_start as Array).is_empty() or not (data.other_load_end as Array).is_empty():
		note("other game/converter processes ran during the measurement (dev, shared machine): %s / %s" % [str(data.other_load_start), str(data.other_load_end)])

	check("route visited >= 10 distinct cells", walker.cells_visited.size() >= 10, str(walker.cells_visited.size()))
	check("RAM sampled (game and converter)", mst.has("game_mb_peak") and mst.has("converter_mb_peak"), str(mst))
	var game_peak := float(mst.get("game_mb_peak", INF))
	var vram_peak := float(mst.get("vram_mb_peak", INF))
	if preset == "low":
		var gmax := float(o.f(o.system("perf.low_gpu_ms_max")))
		check("low: GPU avg %s ms <= %s ms/frame" % [str(gst.get("gpu_ms_avg")), str(gmax)], float(gst.get("gpu_ms_avg", INF)) <= gmax, "p99 %s ms" % str(gst.get("gpu_ms_p99")))
		var rmax := float(o.f(o.system("perf.low_game_ram_max_mb")))
		check("low: game RAM peak %s MiB <= %s" % [str(game_peak), str(rmax)], game_peak <= rmax, "end %s MiB" % str(mst.get("game_mb_end")))
		var vmax := float(o.f(o.system("perf.low_vram_max_mb")))
		check("low: VRAM peak %s MiB <= %s" % [str(vram_peak), str(vmax)], vram_peak <= vmax, "end %s MiB" % str(mst.get("vram_mb_end")))
	else:
		var favg := float(o.f(o.system("perf.target_fps_avg")))
		var flow := float(o.f(o.system("perf.target_fps_1pct_low")))
		var wmax := float(o.f(o.system("perf.max_load_frame_ms")))
		check("%s: fps avg >= %s" % [preset, str(favg)], float(st.get("fps_avg", 0.0)) >= favg, str(st.get("fps_avg")))
		check("%s: 1 %% low >= %s" % [preset, str(flow)], float(st.get("fps_1pct_low", 0.0)) >= flow, str(st.get("fps_1pct_low")))
		check("%s: no frame > %s ms while a cell loads" % [preset, str(wmax)], float(st.get("worst_load_ms", INF)) <= wmax, "%s ms (%d loads); worst frame overall %s ms" % [str(st.get("worst_load_ms")), rec.loads.size(), str(st.get("worst_ms"))])
		var hmax := float(o.f(o.system("perf.high_game_ram_max_mb")))
		check("%s: game RAM peak %s MiB <= %s" % [preset, str(game_peak), str(hmax)], game_peak <= hmax, "end %s MiB" % str(mst.get("game_mb_end")))
	var cmax := float(o.f(o.system("perf.converter_idle_max_mb")))
	check("converter idle (no request for %s s) within %s s" % [str(settle), str(wait_max)], idle_ok, "waited %s s" % str(data.converter_idle_wait_s))
	check("converter RAM idle %s MiB <= %s" % [str(data.converter_idle_mb), str(cmax)], float(data.converter_idle_mb) >= 0.0 and float(data.converter_idle_mb) <= cmax, "samples %s, private bytes %s MiB, peak on the route %s MiB" % [str(samples), str(data.converter_idle_private_mb), str(mst.get("converter_mb_peak"))])
	note("%s: fps %s / 1%% low %s, GPU %s ms (p99 %s), CPU %s ms (p99 %s), GPU busy %s ms/s, game RAM peak %s MiB, VRAM peak %s MiB, converter peak %s / idle %s MiB" % [
		preset, str(st.get("fps_avg")), str(st.get("fps_1pct_low")), str(gst.get("gpu_ms_avg")), str(gst.get("gpu_ms_p99")),
		str(gst.get("cpu_ms_avg")), str(gst.get("cpu_ms_p99")), str(gst.get("gpu_busy_ms_per_s")), str(game_peak), str(vram_peak),
		str(mst.get("converter_mb_peak")), str(data.converter_idle_mb)])
	rec.queue_free()
	return true
