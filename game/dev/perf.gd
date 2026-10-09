extends SceneTree
## Dev only (windowed): spawn spawning.max_active_machines machines around the player and log frame times.
##   godot --path game --script res://dev/perf.gd -- --mock-data --seed-cache <dev> --cache-dir <d>

const Sheets := preload("res://core/sheets.gd")


func _initialize() -> void:
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _run() -> void:
	var game: Node = root.get_node("Game")
	while not game.is_world_ready:
		await process_frame
	game.world.spawner.set_process(false)
	for m in game.machines.duplicate():
		m.queue_free()
	var p: Node3D = game.player
	var n := int(Sheets.sys_num("spawning.max_active_machines", 24))
	var types := ["watcher", "strider", "grazer"]
	for i in n:
		var a := TAU * i / n
		var r := 25.0 + 10.0 * (i % 3)
		var pos: Vector3 = p.global_position + Vector3(cos(a) * r, 2.0, sin(a) * r)
		game.spawn_machine(types[i % 3], pos)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		await process_frame
	var frames := 0
	var worst := 0.0
	var t1 := Time.get_ticks_usec()
	var last := t1
	while Time.get_ticks_usec() - t1 < 10000000:
		await process_frame
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		frames += 1
	var avg := 10000.0 / frames
	print("PERF %d machines: %d frames in 10 s, avg %.2f ms (%.0f fps), worst %.1f ms, physics %.2f ms, process %.2f ms" % [
		game.machines.size(), frames, avg, 1000.0 / avg, worst,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	quit(0)
