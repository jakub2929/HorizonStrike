extends "res://autotest/lib/scenario.gd"
## r03walk (movie-maker child of r03): from 45 m inside a corner of the first perf.route_cells cell, walk 25 s
## (game time, 30 fps fixed) with held W and mouse steering along a terrain path (lib/nav.gd) diagonally across that
## corner, so two cell borders are crossed. The corner whose path is closest to straight is used.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Nav := preload("res://autotest/lib/nav.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const FPS := 30
const INSIDE_M := 45.0
const BEYOND_M := 110.0


func _init() -> void:
	timeout_s = 780.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(500.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	var o = ctx.oracle
	p.set("invulnerable", true)
	var inp = InputSim.new(ctx)
	await inp.equip("knife")
	inp.capture_for_look()
	var cs := float(o.f(o.system("streaming.cell_size_m")))
	var c0: Vector2i = ctx.v2i(o.system("perf.route_cells")[0])
	# corners of the cell (x0/x1, z0/z1) and the diagonal pointing out of the cell through each
	var x0 := cs * c0.x
	var z1 := -cs * c0.y
	var corners := []
	for sx in [0, 1]:
		for sz in [0, 1]:
			var corner := Vector3(x0 + cs * sx, 0.0, z1 - cs * (1 - sz))
			var out := Vector3(1.0 if sx == 1 else -1.0, 0.0, 1.0 if sz == 1 else -1.0).normalized()
			corners.append({"corner": corner, "out": out})
	await ctx.call_api(g, "teleport", [Vector3(x0 + cs * 0.5, 400.0, z1 - cs * 0.5)])
	var w: Variant = g.get("world") if "world" in g else null
	if w is Object and w.has_method("is_cell_loaded"):
		var want := []
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				want.append(c0 + Vector2i(dx, dy))
		await ctx.wait_until(func(): return want.all(func(c): return bool(w.call("is_cell_loaded", c))), 400.0)
	await ctx.wait(1.0)
	var best := {}
	for k in corners:
		var a: Vector3 = k.corner - k.out * INSIDE_M
		var b: Vector3 = k.corner + k.out * BEYOND_M
		var ga: Variant = await _height(ctx, w, a)
		var gb: Variant = await _height(ctx, w, b)
		if ga == null or gb == null:
			continue
		a.y = float(ga)
		b.y = float(gb)
		var path: Array = Nav.plan(ctx, a, b)
		var length := 0.0
		for i in range(1, path.size()):
			length += (path[i] as Vector3).distance_to(path[i - 1])
		var ratio := length / a.distance_to(b) if path.size() >= 2 else INF
		if best.is_empty() or ratio < float(best.ratio):
			best = {"a": a, "b": b, "path": path, "ratio": ratio, "corner": k.corner}
	if not check("a walkable corner path", not best.is_empty() and float(best.ratio) < 1.6, str(best.get("ratio"))):
		return false
	data.corner = str(best.corner)
	data.path_ratio = snappedf(float(best.ratio), 0.01)
	var start: Vector3 = best.a + Vector3(0, 0.5, 0)
	await ctx.call_api(g, "teleport", [start])
	await ctx.wait(2.0)
	# ground collision is built near the player only: set the start again once it is there
	await ctx.call_api(g, "teleport", [start])
	await ctx.wait(2.0)
	var path: Array = best.path
	var next := 1
	var t := InputSim.yaw_pitch_to(ctx.player_camera().global_position, (path[mini(next, path.size() - 1)] as Vector3) + Vector3(0, 1.6, 0))
	for i in 60:
		inp.look_step(t.x, 0.0)
		await ctx.frames(1)
	var cells := [ctx.cell_of(ctx.player_pos())]
	var f0 := Movie.frame_now()
	var last_pos: Vector3 = ctx.player_pos()
	var still := 0
	var jumps := 0
	var heading := t.x
	for f in 25 * FPS:
		if not Input.is_action_pressed("move_forward"):
			inp.press("move_forward")
		var pp: Vector3 = ctx.player_pos()
		while next < path.size() and Vector2(pp.x, pp.z).distance_to(Vector2(path[next].x, path[next].z)) < 6.0:
			next += 1
		if next < path.size():
			heading = InputSim.yaw_pitch_to(pp, path[next]).x
		inp.look_step(heading, 0.0, 40.0)
		var cc: Variant = ctx.cell_of(pp)
		if cc != cells[cells.size() - 1]:
			cells.append(cc)
		if f % FPS == 0:
			if pp.distance_to(last_pos) < 1.0:
				still += 1
				if still >= 2:
					await inp.tap("jump")
					jumps += 1
			else:
				still = 0
			last_pos = pp
		await ctx.frames(1)
	var f1 := Movie.frame_now()
	inp.release("move_forward")
	ctx.write_json(ctx.out_dir.path_join("clips.json"), {"walk": [f0, f1]})
	data.cells = cells.map(func(c): return str(c))
	data.crossings = cells.size() - 1
	data.jumps = jumps
	data.walked_m = snappedf(start.distance_to(ctx.player_pos()), 0.1)
	check("2 cell borders crossed in 25 s", cells.size() - 1 >= 2, str(data.cells))
	return true


static func _height(ctx, w: Variant, p: Vector3) -> Variant:
	## terrain height from the loaded cell data (collision exists near the player only), else a physics ray
	if w is Object and (w as Object).has_method("height_at"):
		var h := float((w as Object).call("height_at", p))
		if not is_nan(h):
			return h
	return await ctx.ground_y(p.x, p.z)
