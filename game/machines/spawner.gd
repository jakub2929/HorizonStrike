extends Node
## Spawn sites from cell.json `spawns` (variant B mapping already done by the converter: `type` is a v1 machine;
## when missing, sheets site_map decides). Sites activate within spawning.activation_radius_m, respect
## spawning.max_active_machines, and a cleared site refills after spawning.respawn_delay_s when the player is farther
## than spawning.respawn_min_distance_m (D24).

const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Machine := preload("res://machines/machine.gd")
const Content := preload("res://core/content.gd")

var world: Node3D
var sites := {}            # site id -> {id, type, count, pos, radius, cell, alive, members, cleared_at, active}
var _metas := {}           # machine type -> meta.json dict
var _timer := 0.0
var _queue: Array = []     # herd members still to spawn: [site, member index, herd size, herd Array] (one per frame)
var _warm: Array = []      # warm-up machines to free next frame
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func meta_for(type: String) -> Dictionary:
	if _metas.has(type):
		return _metas[type]
	var m: Dictionary = Content.machine_meta(type)
	var d: Dictionary = m if not m.is_empty() else {"mock": true}
	_metas[type] = d
	return d


func on_cell_loaded(c: Vector2i, spawns: Array) -> void:
	for si in spawns.size():
		var s: Dictionary = spawns[si]
		# one HZD site can hold several machine groups (e.g. Grazers + their Watchers): key by cell, site, entry
		var id := "%d_%d/%s/%d" % [c.x, c.y, str(s.get("site", "site")), si]
		if sites.has(id):
			sites[id]["cell"] = c
			continue
		var type := str(s.get("type", ""))
		if type == "" or not Sheets.machine_ids().has(type):
			var rule := Sheets.site_rule(str(s.get("group", "")), str(s.get("orig_type", "")))
			if rule.is_empty():
				type = "watcher"
				Log.warn("site %s: no site_map rule for %s/%s, using watcher" % [id, s.get("group", ""), s.get("orig_type", "")])
			elif not rule.get("populate", true):
				continue
			else:
				type = str(rule.get("machine", "watcher"))
		var p: Array = s.get("pos", [0, 0, 0])
		var count := clampi(int(s.get("count", 1)), int(Sheets.machine_num(type, "herd_size_min", 1)), int(Sheets.machine_num(type, "herd_size_max", 3)))
		sites[id] = {"id": id, "type": type, "orig_type": str(s.get("orig_type", "")), "count": count, "alive": count,
			"pos": Vector3(float(p[0]), float(p[1]), float(p[2])), "radius": float(s.get("radius", 30.0)), "cell": c,
			"members": [], "cleared_at": -1.0, "active": false}


func on_cell_unloaded(c: Vector2i) -> void:
	for id in sites:
		var s: Dictionary = sites[id]
		if s["cell"] == c and s["active"]:
			_deactivate(s)


## Builds one machine of every type off-screen and frees it next frame: the first machine of a type loads its model
## and computes its hitbox boxes (100+ ms); doing that while the loading screen is up keeps it out of play.
func warm_up() -> void:
	for type in Sheets.machine_ids():
		var meta := meta_for(type)
		if meta.get("mock", false):
			continue
		var t0 := Time.get_ticks_msec()
		var m := Machine.new()
		m.setup(type, meta)
		world.add_child(m)
		m.global_position = Vector3(0.0, -5000.0, 0.0)
		m.set("ai_enabled", false)
		_warm.append(m)
		Log.info("spawner: warmed up %s in %d ms" % [type, Time.get_ticks_msec() - t0])


## One machine of every type at `pos` (AI off), kept until the caller frees them: drawn once on the loading screen
## so their shaders and skinned pipelines compile there (world/precompile.gd).
func warm_up_visible(pos: Vector3) -> Array:
	var out: Array = []
	var i := 0
	for type in Sheets.machine_ids():
		var meta := meta_for(type)
		if meta.get("mock", false):
			continue
		var m := Machine.new()
		m.setup(type, meta)
		world.add_child(m)
		m.global_position = pos + Vector3((i - 2.5) * 3.0, 0.0, 0.0)
		m.set("ai_enabled", false)
		out.append(m)
		i += 1
	return out


func _process(delta: float) -> void:
	for m in _warm:
		if is_instance_valid(m):
			_remove(m)
	_warm.clear()
	# herd members enter one per frame (a whole herd in one frame was a 100+ ms hitch)
	if not _queue.is_empty():
		var q: Array = _queue.pop_front()
		_spawn_member(q[0], int(q[1]), int(q[2]), q[3])
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = 0.5
	var p: Node3D = Game.player
	if p == null or not Game.is_world_ready:
		return
	var pp := p.global_position
	var act_r := Sheets.sys_num("spawning.activation_radius_m", 250.0)
	var now := Time.get_ticks_msec() / 1000.0
	var candidates: Array = []
	for id in sites:
		var s: Dictionary = sites[id]
		var d := pp.distance_to(s["pos"])
		# refill a cleared site (D24)
		if s["alive"] <= 0 and s["cleared_at"] >= 0.0:
			if now - float(s["cleared_at"]) >= Sheets.sys_num("spawning.respawn_delay_s", 300.0) and d > Sheets.sys_num("spawning.respawn_min_distance_m", 200.0):
				s["alive"] = s["count"]
				s["cleared_at"] = -1.0
				Log.info("site %s refilled (%d %s)" % [id, s["count"], s["type"]])
		if not s["active"] and d <= act_r and int(s["alive"]) > 0 and world.is_cell_loaded(s["cell"]):
			candidates.append(s)
		elif s["active"] and d > act_r + 60.0 and not _engaged(s):
			_deactivate(s)
	# nearest sites first; a site only activates when its whole herd fits under spawning.max_active_machines
	candidates.sort_custom(func(a, b): return pp.distance_squared_to(a["pos"]) < pp.distance_squared_to(b["pos"]))
	for s in candidates:
		if _make_room(int(s["alive"]), pp.distance_to(s["pos"]), pp):
			_activate(s)


## Active machines (alive, not freed; corpses do not count) plus herd members still queued.
func _active_count() -> int:
	var n := _queue.size()
	for m in Game.machines:
		if is_instance_valid(m) and not m.is_queued_for_deletion() and not m.is_dead():
			n += 1
	return n


## True when `need` more machines fit under spawning.max_active_machines. If not, idle (not engaged) active sites
## farther from the player than `dist` are deactivated, farthest first, until the herd fits; nothing is deactivated
## when even that would not make enough room.
func _make_room(need: int, dist: float, pp: Vector3) -> bool:
	var cap := int(Sheets.sys_num("spawning.max_active_machines", 24))
	var free := cap - _active_count()
	if need <= free:
		return true
	var far: Array = []
	var gain := 0
	for id in sites:
		var s: Dictionary = sites[id]
		if s["active"] and not _engaged(s) and pp.distance_to(s["pos"]) > dist:
			far.append(s)
	far.sort_custom(func(a, b): return pp.distance_squared_to(a["pos"]) > pp.distance_squared_to(b["pos"]))
	var drop: Array = []
	for s in far:
		if free + gain >= need:
			break
		drop.append(s)
		gain += _live_members(s)
	if free + gain < need:
		return false
	for s in drop:
		Log.info("site %s deactivated to make room for a nearer herd" % s["id"])
		_deactivate(s)
	return true


func _live_members(s: Dictionary) -> int:
	var n := 0
	for m in s["members"]:
		if is_instance_valid(m) and not m.is_queued_for_deletion() and not m.is_dead():
			n += 1
	return n


func _engaged(s: Dictionary) -> bool:
	for m in s["members"]:
		if is_instance_valid(m) and m.state in ["alert", "attack", "flee", "suspicious", "stalk"]:
			return true
	return false


func _activate(s: Dictionary) -> void:
	var n := int(s["alive"])
	if n <= 0:
		return
	s["active"] = true
	var herd: Array = []
	s["members"] = herd
	for i in n:
		_queue.append([s, i, n, herd])
	Log.info("site %s active: %d %s (orig %s) at %s" % [s["id"], n, s["type"], s["orig_type"], s["pos"]])


## One herd member; the herd Array is shared, so members spawned earlier see the later ones.
func _spawn_member(s: Dictionary, i: int, n: int, herd: Array) -> void:
	if not s["active"] or not is_same(s["members"], herd):
		return
	var a := TAU * i / maxf(n, 1) + _rng.randf() * 0.5
	var r := _rng.randf_range(2.0, minf(float(s["radius"]) * 0.5, 12.0))
	var pos: Vector3 = s["pos"] + Vector3(cos(a) * r, 0.0, sin(a) * r)
	var gh: float = world.height_at(pos)
	if not is_nan(gh):
		pos.y = gh + 0.2
	var m := spawn(s["type"], pos, s)
	herd.append(m)
	m.herd = herd


func _deactivate(s: Dictionary) -> void:
	s["active"] = false
	_queue = _queue.filter(func(q): return q[0] != s)
	for m in s["members"]:
		if is_instance_valid(m) and not m.is_dead():
			_remove(m)
	s["members"] = []


## A machine leaves play at once (no longer in Game.machines, no collision, hidden) and is freed a few nodes per
## frame by the world (freeing several skinned machines in one frame was an 80 ms hitch).
func _remove(m: Node) -> void:
	Game.unregister_machine(m)
	if world and world.has_method("bury"):
		world.bury(m, true)
	else:
		m.queue_free()


func _on_member_died(s: Dictionary) -> void:
	s["alive"] = maxi(int(s["alive"]) - 1, 0)
	if s["alive"] == 0:
		s["cleared_at"] = Time.get_ticks_msec() / 1000.0
		Log.info("site %s cleared" % s["id"])


func spawn(type: String, pos: Vector3, s: Variant) -> Node:
	var m := Machine.new()
	m.setup(type, meta_for(type))
	if s != null:
		var site: Dictionary = s
		m.site = {"radius": site["radius"], "id": site["id"], "on_death": func(_mm): _on_member_died(site)}
	world.add_child(m)
	m.global_position = pos
	m.home = pos
	m.rotation.y = _rng.randf() * TAU
	return m


## Calm every machine near a position (respawn.reset_machine_alert).
func calm_near(pos: Vector3, radius: float) -> void:
	for m in Game.machines:
		if is_instance_valid(m) and m.global_position.distance_to(pos) <= radius:
			m.reset_calm()
