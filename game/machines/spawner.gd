extends Node
## Spawn sites from cell.json `spawns` (variant B mapping already done by the converter: `type` is a v1 machine;
## when missing, sheets site_map decides). Sites activate within spawning.activation_radius_m, respect
## spawning.max_active_machines, and a cleared site refills after spawning.respawn_delay_s when the player is farther
## than spawning.respawn_min_distance_m (D24).

const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Machine := preload("res://machines/machine.gd")

var world: Node3D
var sites := {}            # site id -> {id, type, count, pos, radius, cell, alive, members, cleared_at, active}
var _metas := {}           # machine type -> meta.json dict
var _timer := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func meta_for(type: String) -> Dictionary:
	if _metas.has(type):
		return _metas[type]
	var m = FsUtil.read_json(Game.cache_root.path_join("hzd/machines/%s/meta.json" % type))
	var d: Dictionary = m if typeof(m) == TYPE_DICTIONARY else {"mock": true}
	_metas[type] = d
	return d


func on_cell_loaded(c: Vector2i, spawns: Array) -> void:
	for s in spawns:
		var id := str(s.get("site", "site_%d_%d_%d" % [c.x, c.y, sites.size()]))
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


func _process(delta: float) -> void:
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
	for id in sites:
		var s: Dictionary = sites[id]
		var d := pp.distance_to(s["pos"])
		# refill a cleared site (D24)
		if s["alive"] <= 0 and s["cleared_at"] >= 0.0:
			if now - float(s["cleared_at"]) >= Sheets.sys_num("spawning.respawn_delay_s", 300.0) and d > Sheets.sys_num("spawning.respawn_min_distance_m", 200.0):
				s["alive"] = s["count"]
				s["cleared_at"] = -1.0
				Log.info("site %s refilled (%d %s)" % [id, s["count"], s["type"]])
		if not s["active"] and d <= act_r and world.is_cell_loaded(s["cell"]):
			_activate(s)
		elif s["active"] and d > act_r + 60.0 and not _engaged(s):
			_deactivate(s)


func _engaged(s: Dictionary) -> bool:
	for m in s["members"]:
		if is_instance_valid(m) and m.state in ["alert", "attack", "flee", "suspicious"]:
			return true
	return false


func _activate(s: Dictionary) -> void:
	var n := mini(int(s["alive"]), int(Sheets.sys_num("spawning.max_active_machines", 24)) - Game.machines.size())
	if n <= 0:
		return
	s["active"] = true
	var herd: Array = []
	for i in n:
		var a := TAU * i / maxf(n, 1) + _rng.randf() * 0.5
		var r := _rng.randf_range(2.0, minf(float(s["radius"]) * 0.5, 12.0))
		var pos: Vector3 = s["pos"] + Vector3(cos(a) * r, 0.0, sin(a) * r)
		var gh: float = world.height_at(pos)
		if not is_nan(gh):
			pos.y = gh + 0.2
		var m := spawn(s["type"], pos, s)
		herd.append(m)
	for m in herd:
		m.herd = herd
	s["members"] = herd
	Log.info("site %s active: %d %s (orig %s) at %s" % [s["id"], n, s["type"], s["orig_type"], s["pos"]])


func _deactivate(s: Dictionary) -> void:
	s["active"] = false
	for m in s["members"]:
		if is_instance_valid(m) and not m.is_dead():
			m.queue_free()
	s["members"] = []


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
