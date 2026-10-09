extends SceneTree
## Dev only: my own versions of autotest scenarios t05, t06, t07, t10 driven through the Game API (the real runner
## belongs to "test"; this lets hra verify AI, respawn and eviction before it lands).
##   godot --headless --path game --script res://dev/scenarios.gd -- --mock-data [--seed-cache <dev>] [--cache-dir <d>]
##         --only t05,t06,t07,t10 [--mock-cell-mib 30]

const Sheets := preload("res://core/sheets.gd")

var _game: Node
var _results: Array = []


func _initialize() -> void:
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _wait(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		await physics_frame


func _report(id: String, ok: bool, details: String) -> void:
	_results.append([id, ok, details])
	print("%s %s  %s" % ["PASS" if ok else "FAIL", id, details])


func _clear_machines() -> void:
	for m in _game.machines.duplicate():
		if is_instance_valid(m):
			m.queue_free()
	await _wait(0.2)


func _ground(pos: Vector3) -> Vector3:
	var h: float = _game.world.height_at(pos)
	return Vector3(pos.x, (h if not is_nan(h) else pos.y) + 0.1, pos.z)


func _run() -> void:
	_game = root.get_node("Game")
	var only := ["t05", "t06", "t07", "t10"]
	var ua := OS.get_cmdline_user_args()
	var oi := ua.find("--only")
	if oi >= 0 and oi + 1 < ua.size():
		only = Array(ua[oi + 1].split(","))
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	await _wait(1.0)
	# keep the spawner from adding site machines into the scenarios
	_game.world.spawner.set_process(false)
	await _clear_machines()
	if "t05" in only:
		await _t05()
	if "t06" in only:
		await _t06()
	if "t07" in only:
		await _t07()
	if "t10" in only:
		await _t10()
	var fails := 0
	for r in _results:
		if not r[1]:
			fails += 1
	print("SCENARIOS %s (%d/%d)" % ["OK" if fails == 0 else "FAIL", _results.size() - fails, _results.size()])
	quit(0 if fails == 0 else 1)


func _t05() -> void:
	await _clear_machines()
	var p: Node3D = _game.player
	p.invulnerable = true
	var f: Vector3 = -p.global_transform.basis.z
	var w: Node = _game.spawn_machine("watcher", _ground(p.global_position + f * 35.0) + Vector3(0, 1.0, 0))
	var states: Array = []
	var hits := [0]
	var cb := func(m, _o, n): if m == w: states.append(n)
	_game.machine_state_changed.connect(cb)
	var hb := func(_a, _c): hits[0] += 1
	_game.player_damaged.connect(hb)
	states.append(w.state)
	var t := 0.0
	var walked := false
	var projectile := false
	while t < 25.0:
		_game.aim_at(w, "body")
		await _wait(0.25)
		t += 0.25
		if not get_nodes_in_group("machine_projectiles").is_empty():
			projectile = true
		if "attack" in states and (projectile or hits[0] > 0):
			break
		if t > 15.0 and not walked:
			walked = true
			p.scripted = true
			p.scripted_move = Vector2(0, -1)
		if walked and p.global_position.distance_to(w.global_position) < 10.0:
			p.scripted_move = Vector2.ZERO
	p.scripted = false
	_game.machine_state_changed.disconnect(cb)
	_game.player_damaged.disconnect(hb)
	w.ai_enabled = false
	var seq := ",".join(states)
	var ordered := _ordered(states, [["idle", "patrol"], ["suspicious"], ["alert"], ["attack"]])
	_report("t05", ordered and (projectile or hits[0] > 0), "states %s, projectile %s, hits %d, %.1f s, walked %s" % [seq, projectile, hits[0], t, walked])
	p.invulnerable = false


func _ordered(states: Array, steps: Array) -> bool:
	var i := 0
	for s in states:
		if i < steps.size() and s in steps[i]:
			i += 1
	return i == steps.size()


func _t06() -> void:
	await _clear_machines()
	var p: Node3D = _game.player
	p.set_crouch(true)
	await _wait(0.3)
	var f: Vector3 = -p.global_transform.basis.z
	var r: Vector3 = p.global_transform.basis.x
	var herd: Array = []
	var n := int(Sheets.machine_num("grazer", "herd_size_min", 3))
	for i in n:
		var pos: Vector3 = p.global_position + f * (30.0 + i * 2.0) + r * (i - 1) * 4.0
		var m: Node = _game.spawn_machine("grazer", _ground(pos) + Vector3(0, 1.0, 0))
		m.rotation.y += PI  # facing away: undetected
		herd.append(m)
	await _wait(2.0)
	var d0 := 0.0
	for m in herd:
		d0 += m.global_position.distance_to(p.global_position)
	d0 /= herd.size()
	var pre: Array = herd.map(func(m): return m.state)
	var hp0: float = p.health
	_game.equip("glock")
	await _wait(0.2)
	p.look_at_point(p.head_position() + Vector3(0, 100, 0) + f)
	_game.fire()
	var all_flee := false
	var t := 0.0
	while t < 3.0:
		await _wait(0.1)
		t += 0.1
		all_flee = herd.all(func(m): return m.state == "flee")
		if all_flee:
			break
	await _wait(10.0 - t)
	var d1 := 0.0
	for m in herd:
		d1 += m.global_position.distance_to(p.global_position)
	d1 /= herd.size()
	_report("t06", all_flee and d1 - d0 >= 30.0 and p.health >= hp0, "before %s, all flee in %.1f s: %s, mean distance %.1f -> %.1f m" % [pre, t, all_flee, d0, d1])
	p.set_crouch(false)


func _t07() -> void:
	await _clear_machines()
	var p: Node3D = _game.player
	var start_cf: String = _game.world.index.get("start_campfire", "")
	var a: Node3D = _game.campfires.get(start_cf)
	if a == null:
		_report("t07", false, "start campfire %s not loaded" % start_cf)
		return
	_game.teleport(a.global_position + Vector3(2, 0.5, 0))
	await _wait(0.6)
	# campfire B in another loaded cell
	var b: Node3D = null
	for id in _game.campfires:
		if id != start_cf:
			b = _game.campfires[id]
			break
	if b == null:
		_report("t07", false, "no second campfire loaded")
		return
	_game.teleport(b.global_position + Vector3(2, 0.5, 0))
	await _wait(1.0)
	var bid: String = b.campfire_id
	var act_ok: bool = _game.last_campfire_id == bid
	_game.money = 16000
	_game.buy("ak47")
	_game.buy("hegrenade")
	_game.buy("kevlar")
	_game.money = 5000
	_game.teleport(b.global_position + Vector3(60, 2, 0))
	await _wait(1.5)
	var got := [""]
	var cb := func(id): got[0] = id
	_game.player_respawned.connect(cb)
	_game.kill_player()
	var t := 0.0
	while got[0] == "" and t < 10.0:
		await _wait(0.2)
		t += 0.2
	_game.player_respawned.disconnect(cb)
	await _wait(0.5)
	var inv: Array = p.inventory
	var dist: float = p.global_position.distance_to(b.global_position)
	var calm: bool = _game.machines.all(func(m): return not is_instance_valid(m) or not (m.state in ["alert", "attack"]))
	var ok: bool = act_ok and got[0] == bid and inv == Sheets.start_loadout_ids() and p.armor == 0.0 and _game.money == 5000 \
		and dist <= Sheets.sys_num("respawn.campfire_activate_radius_m", 4.0) and p.health == Sheets.sys_num("respawn.health", 100) and calm
	_report("t07", ok, "activated B %s, respawned at %s (B=%s), inventory %s, armor %.0f, money %d, dist %.2f, health %.0f" % [act_ok, got[0], bid, inv, p.armor, _game.money, dist, p.health])


func _t10() -> void:
	await _clear_machines()
	var p: Node3D = _game.player
	var start: Vector3 = p.global_position
	await _wait(3.0)
	var cap: int = _game.cache_bytes() + int(Sheets.sys_num("cache.reserve_mib", 600) * 1048576.0) + 300 * 1048576
	_game.cache_cap_bytes = cap
	var evicted: Array = []
	var cb := func(c): evicted.append(c)
	_game.cell_evicted.connect(cb)
	var max_b := 0
	var size: float = _game.world.cell_size
	for step in 5:
		var target: Vector3 = start + Vector3(size * (step + 1), 0, 0)
		var tc: Vector2i = _game.world.cell_of(target)
		_game.teleport(target + Vector3(0, 200, 0))
		var t := 0.0
		while not _game.world.is_cell_loaded(tc) and t < 60.0:
			await _wait(0.5)
			t += 0.5
			max_b = maxi(max_b, _game.cache_bytes())
		max_b = maxi(max_b, _game.cache_bytes())
		print("  t10 step %d -> cell %s loaded=%s cache %d / cap %d" % [step + 1, tc, _game.world.is_cell_loaded(tc), _game.cache_bytes(), cap])
	_game.teleport(start + Vector3(0, 200, 0))
	var back := false
	var t2 := 0.0
	while t2 < 60.0:
		await _wait(0.5)
		t2 += 0.5
		max_b = maxi(max_b, _game.cache_bytes())
		if _game.world.is_cell_loaded(_game.world.cell_of(start)):
			back = true
			break
	_game.cell_evicted.disconnect(cb)
	_report("t10", max_b <= cap and evicted.size() >= 1 and back, "max %d <= cap %d, evicted %d %s, start cell back %s" % [max_b, cap, evicted.size(), evicted.slice(0, 6), back])
