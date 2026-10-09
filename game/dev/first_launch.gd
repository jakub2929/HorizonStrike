extends SceneTree
## Dev only: first-launch measurement (like t09) in real mode. Boots, records bootstrap time and cells on disk at
## world_ready, waits until the 3x3 ring is on disk (or 300 s), records cache size, quits.
##   godot --headless --path game --script res://dev/first_launch.gd -- --game <cs2> --cache-dir <empty dir>


func _initialize() -> void:
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _run() -> void:
	var game: Node = root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not game.is_world_ready and Time.get_ticks_msec() - t0 < 900000:
		await process_frame
	if not game.is_world_ready:
		print("FIRST world never became ready")
		quit(1)
		return
	print("FIRST world_ready: bootstrap_seconds %.1f, cells on disk %s, cache %d bytes" % [game.bootstrap_seconds, game.cells_on_disk(), game.cache_bytes()])
	var t1 := Time.get_ticks_msec()
	while game.cells_on_disk().size() < 9 and Time.get_ticks_msec() - t1 < 300000:
		await process_frame
	await create_timer(6.0).timeout
	print("FIRST ring: %d cells on disk %s after %.1f s more, cache %d bytes, weapons dirs %d, machines %d" % [game.cells_on_disk().size(),
		game.cells_on_disk(), (Time.get_ticks_msec() - t1) / 1000.0, game.cache_bytes(),
		DirAccess.get_directories_at(game.cache_root.path_join("cs2/weapons")).size(), DirAccess.get_directories_at(game.cache_root.path_join("hzd/machines")).size()])
	game.main.quit_game(0)
