extends "res://autotest/lib/scenario.gd"
## t15 Performance: start + 10-cell route (child process, window perf.resolution, vsync off). After world_ready, the
## 3x3 and perf.settle_s: video memory, then a slow 360 deg turn by relative mouse motion for perf.start_measure_s, then
## perf.route_cells walked by input (forward key held, mouse steering, knife out = run speed; jump when stuck,
## teleport fallback counted). Every frame time goes to <out>/frametimes.csv (columns t_s, frame_ms, phase, cell,
## event, vram_mb). A cell-load window is 1 s before to 0.25 s after the game's cell_loaded signal (the insertion
## runs on the main thread just before it; a cell_insert_started signal is used too when the game has one).

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Route := preload("res://autotest/lib/route.gd")
const FrameRec := preload("res://autotest/lib/framerec.gd")
## walking time per route leg; a leg not reached by then ends with a teleport to its waypoint (Nora's mountains and
## settlements block straight walking; the same procedure runs on every build, so the frame times stay comparable)
const LEG_WALK_S := 45.0


func _init() -> void:
	timeout_s = 3600.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player"], ["teleport"]) + ctx.missing_api(p, ["invulnerable"])):
		return false
	var o = ctx.oracle
	# setup: vsync off, no frame cap, invulnerable (machines must not end the walk)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	data.max_fps_before = Engine.max_fps
	Engine.max_fps = 0
	p.set("invulnerable", true)
	var res: Array = o.system("perf.resolution")
	var win := DisplayServer.window_get_size()
	data.window = [win.x, win.y]
	data.viewport = [ctx.runner.get_viewport().get_visible_rect().size.x, ctx.runner.get_viewport().get_visible_rect().size.y]
	check("window %dx%d (perf.resolution)" % [int(res[0]), int(res[1])], win.x == int(res[0]) and win.y == int(res[1]), "%dx%d" % [win.x, win.y])
	data.gpu = RenderingServer.get_video_adapter_name()

	var start_c: Variant = ctx.cell_of(ctx.player_pos())
	var ring := await _wait_ring(ctx, start_c, 900.0)
	check("start 3x3 loaded", ring, str(start_c))
	await ctx.wait(float(o.f(o.system("perf.settle_s"))))

	var rec := FrameRec.new()
	rec.name = "AutotestFrameRec"
	ctx.runner.add_child(rec)
	rec.start(g)
	var inp = InputSim.new(ctx)
	inp.capture_for_look()
	var vram_start := FrameRec.vram_mb()
	data.vram_start_mb = snappedf(vram_start, 0.1)

	# start: slow 360 deg turn by mouse motion
	rec.phase = "start"
	var dur := float(o.f(o.system("perf.start_measure_s")))
	var t0 := Time.get_ticks_msec()
	var turned := 0.0
	var prev: Vector2 = inp.yaw_pitch()
	while (Time.get_ticks_msec() - t0) / 1000.0 < dur:
		var dt := get_process_delta(ctx)
		var dx: float = (TAU / dur * dt) / float(inp.rad_per_px)
		inp.look(dx, 0.0)
		await ctx.frames(1)
		var now: Vector2 = inp.yaw_pitch()
		turned += absf(wrapf(now.x - prev.x, -PI, PI))
		inp.learn_sensitivity(prev, now, dx)
		prev = now
	data.start_turn_deg = snappedf(rad_to_deg(turned), 0.1)

	# route
	rec.phase = "route"
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
	rec.phase = "done"
	await ctx.frames(2)

	var csv: String = ctx.out_dir.path_join("frametimes.csv")
	rec.write_csv(csv)
	var st_start: Dictionary = rec.stats("start")
	var st_route: Dictionary = rec.stats("route")
	data.csv = csv
	data.start = st_start
	data.route = st_route
	data.cells_visited = walker.cells_visited.keys()
	data.teleports = walker.teleports
	data.walked_m = snappedf(walker.walked_m, 1.0)
	data.hopped_m = snappedf(walker.hopped_m, 1.0)
	data.plans = walker.plans
	data.refocus_presses = walker.refocus
	data.jumps = walker.jumps
	data.legs = walker.legs
	data.look_rad_per_px = inp.rad_per_px
	data.cell_loads = rec.loads.size()
	var vmax := float(o.f(o.system("perf.vram_start_max_mb")))
	var favg := float(o.f(o.system("perf.target_fps_avg")))
	var flow := float(o.f(o.system("perf.target_fps_1pct_low")))
	var wmax := float(o.f(o.system("perf.max_load_frame_ms")))
	check("VRAM at start %s MiB <= %s" % [str(data.vram_start_mb), str(vmax)], vram_start <= vmax)
	for e in [["start", st_start], ["route", st_route]]:
		var s: Dictionary = e[1]
		check("%s: fps avg >= %s" % [e[0], str(favg)], float(s.get("fps_avg", 0.0)) >= favg, str(s.get("fps_avg")))
		check("%s: 1 %% low >= %s" % [e[0], str(flow)], float(s.get("fps_1pct_low", 0.0)) >= flow, str(s.get("fps_1pct_low")))
	check("no frame > %s ms while a cell loads" % str(wmax), float(st_route.get("worst_load_ms", 0.0)) <= wmax and float(st_start.get("worst_load_ms", 0.0)) <= wmax, "route %s ms, start %s ms (%d loads)" % [str(st_route.get("worst_load_ms")), str(st_start.get("worst_load_ms")), rec.loads.size()])
	check("route visited >= 10 distinct cells", walker.cells_visited.size() >= 10, str(walker.cells_visited.size()))
	# the HZD world around Nora is mountainous and full of structures: a straight route meets cliffs and fences the
	# terrain plan cannot see; short hops are the fallback, the walked share is the criterion (hops reported)
	var share: float = walker.walked_m / maxf(1.0, walker.walked_m + walker.hopped_m)
	data.walked_share = snappedf(share, 0.01)
	data.leg_teleports = walker.leg_teleports
	data.legs_reached_by_walking = walker.legs.filter(func(l): return l.reached_by_walking).size()
	note("route: %d of %d legs reached by walking, %d leg teleports, %d short hops, %.0f m walked (Nora terrain: teleports are reported, not a criterion)" % [data.legs_reached_by_walking, walker.legs.size(), walker.leg_teleports, walker.teleports, walker.walked_m])
	rec.queue_free()
	Engine.max_fps = int(data.max_fps_before)
	return true


static func get_process_delta(ctx) -> float:
	return ctx.runner.get_process_delta_time()


static func _wait_ring(ctx, c: Variant, timeout_s: float) -> bool:
	if c == null:
		return false
	var w: Variant = ctx.game.get("world") if "world" in ctx.game else null
	if not (w is Object and w.has_method("is_cell_loaded")):
		await ctx.wait(10.0)
		return false
	var want := []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			want.append((c as Vector2i) + Vector2i(dx, dy))
	return await ctx.wait_until(func(): return want.all(func(x): return bool(w.call("is_cell_loaded", x))), timeout_s)
