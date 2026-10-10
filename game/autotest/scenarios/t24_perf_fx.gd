extends "res://autotest/lib/scenario.gd"
## t24 Performance with effects: a 30 s fight with 3 Scrappers (child process, window perf.resolution). Setup: frame
## limit off and VSync off through the GraphicsSettings API, player invulnerable, AK-47 bought through the buy path
## (money set), the start 3x3 loaded + perf.settle_s, 3 scrappers with AI on 20 m ahead (a dead one is replaced).
## Then 30 s by input: the camera turned onto a machine (body or weak spot) by relative mouse motion, the fire button
## held for short bursts, R when the magazine is empty. Every frame time goes to <out>/frametimes.csv.
## Pass: avg fps >= perf.target_fps_avg, 1 % low >= perf.target_fps_1pct_low, no frame > perf.max_load_frame_ms;
## fx_stats sparks > 0 and numbers > 0.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const FrameRec := preload("res://autotest/lib/framerec.gd")
const Combat := preload("res://autotest/lib/combat.gd")
const FIGHT_S := 30.0
const MACHINES := 3
const DIST_M := 20.0


func _init() -> void:
	timeout_s = 1800.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "money", "machines"], ["buy", "spawn_machine", "fx_stats"]) + ctx.missing_api(p, ["invulnerable"])):
		return false
	var o = ctx.oracle
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	if gs != null:
		gs.call("set_value", "fps_limit", 0)
		gs.call("set_value", "vsync", false)
		data.graphics = {"preset": gs.get("preset"), "fps_limit": gs.get("fps_limit"), "vsync": gs.get("vsync")}
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		data.graphics = "GraphicsSettings autoload missing: vsync/max_fps set directly"
	data.engine = {"max_fps": Engine.max_fps, "vsync_mode": DisplayServer.window_get_vsync_mode()}
	check("frame limit off and VSync off (setup)", Engine.max_fps == 0 and DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, str(data.engine))
	p.set("invulnerable", true)
	var res: Array = o.system("perf.resolution")
	var win := DisplayServer.window_get_size()
	data.window = [win.x, win.y]
	check("window %dx%d (perf.resolution)" % [int(res[0]), int(res[1])], win.x == int(res[0]) and win.y == int(res[1]), "%dx%d" % [win.x, win.y])
	data.gpu = RenderingServer.get_video_adapter_name()

	# AK-47 through the buy path (converted in the background after the start: retried while "preparing")
	var bought := false
	var t_buy := Time.get_ticks_msec()
	while not bought and Time.get_ticks_msec() - t_buy < 600000:
		g.set("money", 16000)
		bought = bool(await ctx.call_api(g, "buy", ["ak47"]))
		if not bought:
			await ctx.wait(2.0)
	data.buy_wait_s = snappedf((Time.get_ticks_msec() - t_buy) / 1000.0, 0.1)
	if not check("AK-47 bought (setup)", bought, "after %.0f s" % data.buy_wait_s):
		return false
	var inp = InputSim.new(ctx)
	if InputSim.headless_look():
		note("--headless: no mouse capture, the camera is pointed as setup (look_at_point) instead of by mouse motion")
		data.headless_setup_look = true
	inp.capture_for_look()
	check("AK-47 in hand (slot key)", await inp.equip("ak47"), str(p.get("current_weapon")))

	var start_c: Variant = ctx.cell_of(ctx.player_pos())
	var ring: bool = await ctx.wait_until(func(): return _ring_loaded(ctx, start_c), 900.0)
	check("start 3x3 loaded", ring, str(start_c))
	await ctx.wait(float(o.f(o.system("perf.settle_s"))))
	# machines of the world nearby stay out of it (only the 3 scrappers fight)
	for m in g.get("machines"):
		if is_instance_valid(m) and (m as Node3D).global_position.distance_to(ctx.player_pos()) < 120.0:
			ctx.set_ai(m, false)
	var base_dir: Vector3 = ctx.forward()
	var fighters: Array = []
	for i in MACHINES:
		var m: Node = await ctx.spawn_ahead("scrapper", DIST_M, -25.0 + 25.0 * i, true, base_dir)
		if m != null:
			fighters.append(m)
	check("%d scrappers spawned 20 m ahead (AI on)" % MACHINES, fighters.size() == MACHINES, str(fighters.size()))
	await ctx.wait(1.0)

	var fx0: Dictionary = g.call("fx_stats")
	var hits = ctx.record(g, "player_hit_machine")
	var rec := FrameRec.new()
	rec.name = "AutotestFrameRec"
	ctx.runner.add_child(rec)
	rec.start(g)
	rec.phase = "fight"
	var t0 := Time.get_ticks_msec()
	var target_i := 0
	var bursts := 0
	var reloads := 0
	var replaced := 0
	var weak_aims := 0
	while (Time.get_ticks_msec() - t0) / 1000.0 < FIGHT_S:
		# keep 3 alive: a dead one is replaced (setup)
		for i in fighters.size():
			if Combat.is_dead(fighters[i]):
				ctx.despawn(fighters[i])
				var nm: Node = await ctx.spawn_ahead("scrapper", DIST_M, -25.0 + 25.0 * i, true, base_dir)
				if nm != null:
					fighters[i] = nm
					replaced += 1
		var alive := fighters.filter(func(m): return not Combat.is_dead(m))
		if alive.is_empty():
			await ctx.frames(1)
			continue
		var m: Node = alive[target_i % alive.size()]
		target_i += 1
		# every third burst at a weak spot
		var part := "body"
		if bursts % 3 == 2 and m.has_method("weak_spots") and not m.call("weak_spots").is_empty():
			part = str(m.call("weak_spots")[0])
			weak_aims += 1
		var pt: Vector3 = m.call("aim_point", part, ctx.player_camera().global_position) if m.has_method("aim_point") else (m as Node3D).global_position + Vector3(0, 1, 0)
		await inp.aim_at_point(pt, 0.004, 30)
		inp.press("fire")
		var t_b := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t_b < 350 and is_instance_valid(m):
			await ctx.frames(1)
			if is_instance_valid(m) and not Combat.is_dead(m) and m.has_method("aim_point"):
				inp.look_step(InputSim.yaw_pitch_to(ctx.player_camera().global_position, m.call("aim_point", part, ctx.player_camera().global_position)).x,
					InputSim.yaw_pitch_to(ctx.player_camera().global_position, m.call("aim_point", part, ctx.player_camera().global_position)).y, 60.0)
		inp.release("fire")
		bursts += 1
		var ammo: Variant = Combat.ammo_of(ctx, "ak47")
		if (ammo is Vector2i or ammo is Vector2) and int(ammo.x) == 0:
			if int(ammo.y) == 0:
				g.set("money", 16000)
				await ctx.call_api(g, "buy", ["ak47"])   # setup: a full AK again (same buy path)
				await inp.equip("ak47")
			else:
				await inp.tap("reload")
				reloads += 1
				await ctx.wait(float(o.num(o.weapon("ak47", "reload_time"))) + 0.1)
		await ctx.wait(0.15)
	rec.phase = "done"
	await ctx.frames(2)
	var fx1: Dictionary = g.call("fx_stats")
	var csv: String = ctx.out_dir.path_join("frametimes.csv")
	rec.write_csv(csv)
	var st: Dictionary = rec.stats("fight")
	data.csv = csv
	data.fight = st
	data.bursts = bursts
	data.weak_bursts = weak_aims
	data.reloads = reloads
	data.replaced_machines = replaced
	data.hits = hits.events.size()
	data.weak_hits = hits.events.filter(func(e): return bool(e.args[2])).size()
	data.fx_before = fx0
	data.fx_after = fx1
	data.other_processes = await _others(ctx)
	if not (data.other_processes as Array).is_empty():
		note("other game/converter processes ran during the measurement: %s" % str(data.other_processes))
	var favg := float(o.f(o.system("perf.target_fps_avg")))
	var flow := float(o.f(o.system("perf.target_fps_1pct_low")))
	var wmax := float(o.f(o.system("perf.max_load_frame_ms")))
	check("fight %.0f s: hits on the machines (%d, %d weak)" % [FIGHT_S, data.hits, data.weak_hits], data.hits > 0 and data.weak_hits > 0, str(bursts) + " bursts")
	check("avg fps >= %s" % str(favg), float(st.get("fps_avg", 0.0)) >= favg, str(st.get("fps_avg")))
	check("1 %% low >= %s" % str(flow), float(st.get("fps_1pct_low", 0.0)) >= flow, str(st.get("fps_1pct_low")))
	check("no frame > %s ms" % str(wmax), float(st.get("worst_ms", 1e9)) <= wmax, str(st.get("worst_ms")))
	var sparks := int(fx1.get("sparks", 0)) - int(fx0.get("sparks", 0))
	var numbers := int(fx1.get("numbers", 0)) - int(fx0.get("numbers", 0))
	check("fx_stats sparks > 0 and numbers > 0 during the fight (%d, %d)" % [sparks, numbers], sparks > 0 and numbers > 0)
	return true


func _ring_loaded(ctx, c: Variant) -> bool:
	if c == null:
		return true
	var w: Variant = ctx.game.get("world") if "world" in ctx.game else null
	if not (w is Object) or not w.has_method("is_cell_loaded"):
		return true
	var cc: Vector2i = ctx.v2i(c)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			if not w.call("is_cell_loaded", cc + Vector2i(dx, dy)):
				return false
	return true


func _others(ctx) -> Array:
	## other Godot / converter processes (another teammate's run) - not a criterion, recorded with the numbers
	var r: Dictionary = await ctx.run_cmd(load("res://autotest/lib/proc.gd").system32("tasklist.exe"), PackedStringArray(["/FO", "CSV", "/NH"]))
	var out := []
	var me := OS.get_process_id()
	for raw in str(r.get("out", "")).split("\n"):
		var f := raw.strip_edges().split("\",\"")
		if f.size() < 2:
			continue
		var img := f[0].trim_prefix("\"").to_lower()
		if (img.begins_with("godot") or img.begins_with("hzsconv") or img.begins_with("horizonstrike")) and f[1].is_valid_int() and int(f[1]) != me:
			out.append("%s %s" % [img, f[1]])
	return out
