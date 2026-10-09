extends SceneTree
## Weak-spot check (dev only, not exported): for every machine type, spawn one in 8 directions around the player
## (12 m, AI off), aim with Game.aim_at(machine, part) at each weak-spot part and shoot with Game.fire(). Counts how
## many exact shots (the weapon's hit trace along the aim line) and real shots (CS inaccuracy) register the weak part;
## a line stopped by the world (rock, tree) is counted separately. FAIL when a weak spot is hit from no direction.
##   godot --path game --script res://dev/weak_spots.gd -- --game ... --cache-dir ...
## Prints one "WEAK <type> <part>: ..." line per machine/part and "WEAKSPOTS OK|FAIL".

const Sheets := preload("res://core/sheets.gd")

var _fail := false


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	var g: Node = root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not g.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	await _frames(60)
	var p: Node3D = g.player
	p.invulnerable = true
	var home: Vector3 = p.global_position
	for type in Sheets.machine_ids():
		var stats := {}
		for k in 8:
			var dir := Vector3.FORWARD.rotated(Vector3.UP, TAU * k / 8.0)
			var pos := home + dir * 12.0
			var gh: float = g.world.height_at(pos)
			pos.y = (gh if not is_nan(gh) else home.y) + 0.2
			var m: Node3D = g.spawn_machine(type, pos)
			m.set("ai_enabled", false)
			await _frames(20)
			for part in m.weak_spots():
				if not stats.has(part):
					stats[part] = {"exact": 0, "fired": 0, "body": 0, "world": 0, "n": 0}
				var st: Dictionary = stats[part]
				g.player.teleport(home)
				await _frames(3)
				g.aim_at(m, part)
				await _frames(2)
				st.n += 1
				# the exact shot: the weapon's own hit trace along the aim line (what a shot without spread registers)
				var cam: Camera3D = p.camera
				var h: Dictionary = p.weapons._trace(cam.global_position, -cam.global_transform.basis.z, 200.0)
				var col: Object = h.get("collider") if not h.is_empty() else null
				if col == null or not (col.has_meta("machine") and col.get_meta("machine") == m):
					st.world += 1   # the world (rock, tree) or nothing in the way from this side
					continue
				if str(col.get_meta("part", "")) == part:
					st.exact += 1
				else:
					st.body += 1
				# the real shot (CS inaccuracy + spread), with a full clip and the machine kept alive
				p.weapons._ammo[p.current_weapon] = Vector2i(20, 120)
				var hp: float = m.get("health")
				m.set("health", 100000.0)
				var r: Dictionary = g.fire()
				m.set("health", hp)
				if str(r.get("part", "")) == part:
					st.fired += 1
			m.queue_free()
			await _frames(5)
		for part in stats:
			var st: Dictionary = stats[part]
			print("WEAK %s %s: exact shot weak from %d of %d directions (body %d, world in the way %d); real shots weak %d" % [type, part, st.exact, st.n, st.body, st.world, st.fired])
			if st.exact == 0:
				_fail = true   # this weak spot cannot be hit from any side
	print("WEAKSPOTS " + ("FAIL" if _fail else "OK"))
	quit(1 if _fail else 0)
