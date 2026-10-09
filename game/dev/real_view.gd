extends SceneTree
## Dev only (windowed): go to a position, wait for its cell, report load stats and take screenshots in 4 directions.
##   godot --path game --script res://dev/real_view.gd -- --mock-data --seed-cache <dev> --cache-dir <d>
##         --goto x,y,z --shots <dir> [--perf 10]

var _game: Node


func _initialize() -> void:
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _arg(name: String, def: String) -> String:
	var ua := OS.get_cmdline_user_args()
	var i := ua.find(name)
	return ua[i + 1] if i >= 0 and i + 1 < ua.size() else def


func _wait(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		await process_frame


func _run() -> void:
	_game = root.get_node("Game")
	while not _game.is_world_ready:
		await process_frame
	var dir := _arg("--shots", OS.get_user_data_dir())
	var g := _arg("--goto", "").split(",")
	var p: Node3D = _game.player
	if g.size() == 3:
		var target := Vector3(float(g[0]), float(g[1]), float(g[2]))
		var c: Vector2i = _game.world.cell_of(target)
		var t0 := Time.get_ticks_msec()
		_game.teleport(target + Vector3(0, 1.0, 0))
		while not _game.world.is_cell_loaded(c) and Time.get_ticks_msec() - t0 < 180000:
			await process_frame
		var node: Node = _game.world.loaded.get(c)
		print("REAL cell %s loaded=%s after %d ms, nodes %d, collision shapes %s" % [c, _game.world.is_cell_loaded(c),
			Time.get_ticks_msec() - t0, _count(node) if node else 0, node.get_meta("collision_shapes", -1) if node else -1])
	await _wait(4.0)
	for i in 4:
		p.rotation.y = i * PI * 0.5
		await _wait(0.8)
		_game.screenshot(dir.path_join("real_%d.png" % i))
	var perf := float(_arg("--perf", "0"))
	if perf > 0.0:
		var frames := 0
		var t1 := Time.get_ticks_usec()
		var worst := 0.0
		var last := t1
		while Time.get_ticks_usec() - t1 < int(perf * 1000000.0):
			await process_frame
			var now := Time.get_ticks_usec()
			worst = maxf(worst, (now - last) / 1000.0)
			last = now
			frames += 1
		print("REAL perf: %.1f fps avg, worst frame %.1f ms, draw calls %d, primitives %d, machines %d" % [frames / perf, worst,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			_game.machines.size()])
		var vp_rid := root.get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(vp_rid, true)
		await _wait(1.0)
		print("REAL timings: process %.2f ms, physics %.2f ms, cpu render %.2f ms, gpu render %.2f ms, objects %d, nodes %d, physics active %d, collision pairs %d" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			RenderingServer.viewport_get_measured_render_time_cpu(vp_rid), RenderingServer.viewport_get_measured_render_time_gpu(vp_rid),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)])
	print("REAL done")
	quit(0)


func _count(n: Node) -> int:
	var k := 1
	for c in n.get_children():
		k += _count(c)
	return k
