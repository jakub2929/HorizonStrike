extends "res://autotest/lib/scenario.gd"
## t27 FPS limit (BRIEF-0.3 Autotest 11), child process (window perf.resolution, own --user-dir): standing at the start
## view, Esc > Graphics > Unlimited by input, measure; Esc > Graphics > 60 by input, measure. The limited run must
## average perf.fps_limit_test +- perf.fps_limit_tolerance and its GPU load (GPU busy ms per second, systems
## perf.gpu_time_rule) must be perf.fps_limit_gpu_drop_min_pct lower than unlimited. Setup only: VSync off,
## invulnerable.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const GfxState := preload("res://autotest/lib/gfxstate.gd")
const PerfRec := preload("res://autotest/lib/perfrec.gd")
const T15 := preload("res://autotest/scenarios/t15_perf.gd")


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	var o = ctx.oracle
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	if not api_check(ctx.missing_api(p, ["invulnerable"]) + ([] if gs != null else ["GraphicsSettings autoload"])):
		return false
	gs.call("set_value", "vsync", false)
	p.set("invulnerable", true)
	data.preset = str(gs.get("preset"))
	data.gpu_name = RenderingServer.get_video_adapter_name()
	var win := DisplayServer.window_get_size()
	data.window = [win.x, win.y]
	check("VSync off (setup)", DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, str(DisplayServer.window_get_vsync_mode()))
	var start_c: Variant = ctx.cell_of(ctx.player_pos())
	check("start 3x3 loaded", await T15._wait_ring(ctx, start_c, 900.0), str(start_c))
	await ctx.wait(float(o.f(o.system("perf.settle_s"))))
	data.other_load_start = await T15._others(ctx)

	var limit: int = o.i(o.system("perf.fps_limit_test"))
	var tol := float(o.f(o.system("perf.fps_limit_tolerance")))
	var dur := float(o.f(o.system("perf.fps_limit_measure_s")))
	var drop_min := float(o.f(o.system("perf.fps_limit_gpu_drop_min_pct")))
	var rec := PerfRec.new()
	rec.name = "AutotestPerfRec"
	ctx.runner.add_child(rec)
	rec.start(g)
	var inp = InputSim.new(ctx)
	var phases := {}
	for step in [[0, "unlimited"], [limit, "limit%d" % limit]]:
		var v: int = step[0]
		rec.phase = "menu"
		var opened: bool = await GfxState.open_graphics(ctx, inp)
		var clicked: bool = opened and await GfxState.click_control(ctx, inp, "FpsLimit_%d" % v)
		var max_fps := Engine.max_fps
		var closed: bool = await GfxState.close_graphics(ctx, inp)
		check("Esc > Graphics > FpsLimit_%d by input: Engine.max_fps %d" % [v, v], opened and clicked and closed and max_fps == v,
			"opened %s, clicked %s, closed %s, max_fps %d" % [str(opened), str(clicked), str(closed), max_fps])
		rec.phase = "settle"
		await ctx.wait(2.0)
		rec.phase = step[1]
		await ctx.wait(dur)
		rec.phase = "done"
		phases[step[1]] = {"frames": rec.stats(step[1]), "gpu": rec.gpu_stats(step[1]), "max_fps": max_fps}
	data.phases = phases
	data.input = inp.sent
	data.other_load_end = await T15._others(ctx)
	rec.write_csv(ctx.out_dir.path_join("frametimes.csv"))
	var un: Dictionary = phases["unlimited"]
	var li: Dictionary = phases["limit%d" % limit]
	var fps_li := float(li.frames.get("fps_avg", 0.0))
	var fps_un := float(un.frames.get("fps_avg", 0.0))
	var load_un := float(un.gpu.get("gpu_busy_ms_per_s", 0.0))
	var load_li := float(li.gpu.get("gpu_busy_ms_per_s", INF))
	check("limit %d: fps avg %s within %d +- %s" % [limit, str(fps_li), limit, str(tol)], absf(fps_li - limit) <= tol, "1 %% low %s" % str(li.frames.get("fps_1pct_low")))
	check("unlimited runs above the limit (fps avg %s > %s)" % [str(fps_un), str(limit + tol)], fps_un > limit + tol)
	var want := load_un * (1.0 - drop_min / 100.0)
	check("GPU load with the limit %s ms/s <= %s ms/s (unlimited %s ms/s - %s %%)" % [str(load_li), str(snappedf(want, 0.1)), str(load_un), str(drop_min)],
		load_li <= want, "GPU ms/frame unlimited %s, limited %s" % [str(un.gpu.get("gpu_ms_avg")), str(li.gpu.get("gpu_ms_avg"))])
	note("unlimited: %s fps, GPU %s ms/frame, %s ms/s; limit %d: %s fps, GPU %s ms/frame, %s ms/s" % [str(fps_un), str(un.gpu.get("gpu_ms_avg")), str(load_un), limit, str(fps_li), str(li.gpu.get("gpu_ms_avg")), str(load_li)])
	rec.queue_free()
	return true
