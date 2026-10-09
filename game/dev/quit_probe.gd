extends SceneTree
## Quit-path probe (dev only, not exported): boots the real main scene and quits after a delay while the converter is
## busy, through a bare SceneTree.quit (default) or the game's quit path (--quit-via-main).
##   godot --path game --script res://dev/quit_probe.gd -- --game ... --cache-dir <empty dir> --quit-at 30 [--quit-via-main]
##   ... --t10   instead of a delay: like autotest t10 (tight cache cap, teleport one cell east 5 times, back), then quit
## Prints "QUITPROBE quit requested" just before quitting; the caller measures how long the process takes to exit and
## whether the converter (logged pid) is still running afterwards.

var _at := 30.0
var _via_main := false
var _t10 := false


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var i := a.find("--quit-at")
	if i >= 0 and i + 1 < a.size():
		_at = float(a[i + 1])
	_via_main = a.has("--quit-via-main")
	_t10 = a.has("--t10")
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _wait_until(cond: Callable, sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		if cond.call():
			return true
		await process_frame
	return false


func _t10_walk(game: Node) -> void:
	await _wait_until(func(): return game.is_world_ready and game.world.loaded.size() >= 9, 600.0)
	game.player.invulnerable = true
	var cap0: int = game.cache_cap_bytes
	game.set_cache_cap(game.cache_bytes() + (600 + 50) * 1048576, false)
	var p0: Vector3 = game.player.global_position
	var start: Vector2i = game.world.cell_of(p0)
	for k in range(1, 6):
		var want := start + Vector2i(k, 0)
		game.teleport(p0 + Vector3(game.world.cell_size * k, 30.0, 0.0))
		var ok: bool = await _wait_until(func(): return game.world.is_cell_loaded(want), 300.0)
		print("QUITPROBE step %d cell %s loaded %s" % [k, want, ok])
		var t1 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t1 < 3000:
			await process_frame
	game.teleport(p0 + Vector3(0, 0.5, 0))
	await _wait_until(func(): return game.world.is_cell_loaded(start), 300.0)
	var t2 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t2 < 2000:
		await process_frame
	game.set_cache_cap(cap0, false)


func _run() -> void:
	var game: Node = root.get_node("Game")
	if _t10:
		await _t10_walk(game)
	else:
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < int(_at * 1000.0):
			await process_frame
	print("QUITPROBE quit requested at %.1f s (world ready %s, converter pid %d, via main %s)" % [_at, game.is_world_ready, game.converter_pid, _via_main])
	if _via_main:
		root.get_node("Main").quit_game(0)
	else:
		quit(0)
