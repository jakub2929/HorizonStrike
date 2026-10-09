extends SceneTree
## Dev only (windowed): boot, then take screenshots of the viewmodel, firing, and the buy wheel.
##   godot --path game --script res://dev/shots.gd -- --mock-data --seed-cache <dev cache> --cache-dir <dir> --shots <dir>

var _game: Node
var _dir := ""


func _initialize() -> void:
	var ua := OS.get_cmdline_user_args()
	var i := ua.find("--shots")
	_dir = ua[i + 1] if i >= 0 and i + 1 < ua.size() else OS.get_user_data_dir()
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _wait(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		await process_frame


func _shot(name: String) -> void:
	await process_frame
	_game.screenshot(_dir.path_join(name))


func _run() -> void:
	_game = root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	if not _game.is_world_ready:
		print("SHOTS: world not ready")
		quit(1)
		return
	await _wait(2.5)
	await _shot("vm_glock.png")
	_game.money = 16000
	_game.buy("ak47")
	await _wait(1.6)
	await _shot("vm_ak47.png")
	for k in 3:
		_game.fire()
		await _wait(0.1)
	await _shot("vm_ak47_fire.png")
	await _wait(1.0)
	_game.open_buy_wheel()
	await _wait(0.6)
	await _shot("buy_wheel.png")
	_game.close_buy_wheel()
	var m: Node = _game.spawn_machine("watcher", _game.player.global_position - _game.player.global_transform.basis.z * 9.0 + Vector3(0, 1.5, 0))
	m.ai_enabled = false
	await _wait(2.0)
	_game.aim_at(m, "body")
	await _wait(0.3)
	await _shot("watcher_front.png")
	print("SHOTS done -> %s" % _dir)
	quit(0)
