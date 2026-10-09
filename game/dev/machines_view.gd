extends SceneTree
## Dev only (windowed): spawn the three machines in front of the player, screenshot them standing, walking and up
## close, and check weak-spot hits on the real models.
##   godot --path game --script res://dev/machines_view.gd -- --mock-data --seed-cache <dev cache> --cache-dir <dir> --shots <dir>

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


func _shot(n: String) -> void:
	await process_frame
	_game.screenshot(_dir.path_join(n))


func _run() -> void:
	_game = root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	var p: Node3D = _game.player
	await _wait(1.0)
	var f: Vector3 = -p.global_transform.basis.z
	var r: Vector3 = p.global_transform.basis.x
	var base: Vector3 = p.global_position
	var ms: Array = []
	var specs := [["watcher", f * 8.0], ["strider", f * 10.0 - r * 5.0], ["grazer", f * 11.0 + r * 5.5]]
	for s in specs:
		var m: Node = _game.spawn_machine(s[0], base + s[1] + Vector3(0, 1.5, 0))
		m.ai_enabled = false
		ms.append(m)
	await _wait(2.5)
	_game.aim_at(ms[0], "body")
	await _wait(0.2)
	await _shot("m_idle.png")
	for m in ms:
		print("  %s weak=%s hitboxes=%d" % [m.machine_type, m.weak_spots(), m.rig.hitboxes.size()])
	# walking: drive them with AI on (patrol/graze around their spawn point)
	for m in ms:
		m.ai_enabled = true
		m.home = m.global_position
	await _wait(4.0)
	await _shot("m_walk1.png")
	await _wait(1.5)
	await _shot("m_walk2.png")
	# close side view of the watcher
	var w: Node3D = ms[0]
	w.ai_enabled = false
	await _wait(1.0)
	var side: Vector3 = w.global_transform.basis.x * 4.0
	p.teleport(w.global_position + side + Vector3(0, 0.2, 0))
	await _wait(0.6)
	_game.aim_at(w, "body")
	await _wait(0.3)
	await _shot("m_watcher_side.png")
	# front: eye shot
	p.teleport(w.global_position - w.global_transform.basis.z * 6.0 + Vector3(0, 0.2, 0))
	await _wait(0.6)
	_game.equip("glock")
	await _wait(0.3)
	_game.aim_at(w, "eye")
	await _wait(0.2)
	await _shot("m_watcher_front.png")
	var res: Dictionary = _game.fire()
	print("  eye shot: %s" % res)
	await _wait(0.5)
	for m in ms:
		if is_instance_valid(m) and m != w:
			_game.aim_at(m, m.weak_spots()[0] if not m.weak_spots().is_empty() else "body")
			p.teleport(m.global_position + (p.global_position - m.global_position).normalized() * 8.0)
			await _wait(0.5)
			_game.aim_at(m, m.weak_spots()[0])
			await _wait(0.2)
			print("  %s weak shot: %s" % [m.machine_type, _game.fire()])
			await _wait(0.4)
	print("MACHINES done")
	quit(0)
