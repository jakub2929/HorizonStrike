extends Node3D
## World streaming (systems streaming.* / cache.*): requests cells from the converter ahead of the player, builds
## finished cells on worker threads, unloads far cells, evicts the farthest cells from disk over the cache cap and
## removes shared meshes no remaining cell references.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const FsUtil := preload("res://core/fsutil.gd")
const MeshLib := preload("res://world/mesh_library.gd")
const CellBuilder := preload("res://world/cell_builder.gd")
const Machine := preload("res://machines/machine.gd")
const Spawner := preload("res://machines/spawner.gd")
const Campfire := preload("res://world/campfire.gd")

var cache_root := ""
var index := {}
var cell_size := 512.0
var converter: Node = null
var meshes: RefCounted
var spawner: Node

var valid_cells := {}          # Vector2i -> true (from index.json)
var on_disk := {}              # Vector2i -> true
var loaded := {}               # Vector2i -> Node3D
var cell_data := {}            # Vector2i -> {real, veg, heights...} kept for queries
var building := {}             # Vector2i -> {task, result}
var requested := {}            # Vector2i -> prio last sent
var request_ids := {}          # request id -> Vector2i
var failed := {}               # Vector2i -> retry time (ticks ms)
var loaded_at := {}            # Vector2i -> ticks ms of last load (eviction tie-break)
var campfire_positions := {}   # id -> Vector3 (every campfire seen in a loaded cell)
var site_records := {}         # Vector2i -> Array of spawn dicts

var _stream_timer := 0.0
var _evict_timer := 0.0
var _size_timer := 0.0
var _cache_bytes := 0
var _delta_since_scan := 0     # bytes added/removed since the running background size scan started
var _size_task := -1
var _size_result := [0]
var _bootstrap_cells_on_disk := 0
var _last_player_cell := Vector2i(1 << 20, 0)
var _converter_idle := false
var _status_pending := false
var _gc_needed := false


func setup(root: String, idx: Dictionary, conv: Node) -> void:
	cache_root = root
	index = idx
	cell_size = float(idx.get("cell_size", Sheets.sys_num("streaming.cell_size_m", 512.0)))
	converter = conv
	meshes = MeshLib.new(root.path_join("hzd/meshes"))
	for c in idx.get("cells", []):
		valid_cells[Vector2i(int(c[0]), int(c[1]))] = true
	for c in Game.cells_on_disk():
		on_disk[c] = true
	_cache_bytes = FsUtil.dir_bytes(root)
	if converter:
		converter.event_received.connect(_on_converter_event)
	spawner = Spawner.new()
	spawner.name = "Spawner"
	spawner.world = self
	add_child(spawner)
	Log.info("world: cell_size=%.1f cells=%d on_disk=%d cache=%d bytes" % [cell_size, valid_cells.size(), on_disk.size(), _cache_bytes])


# ------------------------------------------------------------------ cell math

func cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(-pos.z / cell_size))


func cell_origin(c: Vector2i) -> Vector3:
	return Vector3(c.x * cell_size, 0.0, -(c.y + 1) * cell_size)


func cell_dir(c: Vector2i) -> String:
	return cache_root.path_join("hzd/cells/%d_%d" % [c.x, c.y])


static func cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func ring(center: Vector2i, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := Vector2i(center.x + dx, center.y + dy)
			if valid_cells.is_empty() or valid_cells.has(c):
				out.append(c)
	return out


func is_cell_loaded(c: Vector2i) -> bool:
	return loaded.has(c)


func has_ground_at(pos: Vector3) -> bool:
	return loaded.has(cell_of(pos))


func height_at(pos: Vector3) -> float:
	var c := cell_of(pos)
	if not cell_data.has(c):
		return NAN
	var d: Dictionary = cell_data[c]
	return CellBuilder.sample_height(d["heights"], d["w"], d["h"], d["origin"], d["size"], pos.x, pos.z)


## Stealth plant density 0..1 at a position (vegetation channel "stealthplants").
func stealth_at(pos: Vector3) -> float:
	var c := cell_of(pos)
	if not cell_data.has(c):
		return 0.0
	var d: Dictionary = cell_data[c]
	var img: Image = d.get("density")
	var chans: Array = d.get("channels", [])
	var ci := chans.find("stealthplants")
	if img == null or ci < 0 or ci > 3:
		return 0.0
	var o: Vector3 = d["origin"]
	var u := clampf((pos.x - o.x) / cell_size, 0.0, 0.999)
	var v := clampf((pos.z - o.z) / cell_size, 0.0, 0.999)
	return img.get_pixel(int(u * img.get_width()), int(v * img.get_height()))[ci]


# ------------------------------------------------------------------ streaming

func player_pos() -> Vector3:
	if Game.player:
		return Game.player.global_position
	var sp: Array = index.get("start_pos", [0, 0, 0])
	return Vector3(float(sp[0]), float(sp[1]), float(sp[2]))


func player_vel() -> Vector3:
	if Game.player and "velocity" in Game.player:
		return Game.player.velocity
	return Vector3.ZERO


func _process(delta: float) -> void:
	_poll_builds()
	_stream_timer -= delta
	if _stream_timer <= 0.0:
		_stream_timer = 0.25
		_update_streaming()
	_size_timer -= delta
	if _size_timer <= 0.0:
		_size_timer = Sheets.sys_num("cache.size_refresh_s", 5.0)
		_refresh_size_async()
	_evict_timer -= delta
	if _evict_timer <= 0.0:
		_evict_timer = 1.0
		enforce_cap()


func _update_streaming() -> void:
	var pp := player_pos()
	var pc := cell_of(pp)
	var lead := cell_of(pp + player_vel() * Sheets.sys_num("streaming.lead_time_s", 60.0))
	var load_r := int(Sheets.sys_num("streaming.load_ring", 1))
	var req_r := int(Sheets.sys_num("streaming.request_ring", 2))
	var unload_r := int(Sheets.sys_num("streaming.unload_ring", 3))
	var now := Time.get_ticks_msec()
	# load finished cells near the player (nearest first)
	var near := ring(pc, load_r)
	near.sort_custom(func(a, b): return cheb(a, pc) < cheb(b, pc))
	for c in near:
		if on_disk.has(c) and not loaded.has(c) and not building.has(c):
			_start_build(c)
	# request conversions: prio 0 inside load ring of the player or the lead point, else ring distance.
	# The wider request_ring is only used while the player moves (a player standing at the start needs just the
	# bootstrap ring, so the first launch converts 3x3 cells, BRIEF/t09).
	var want := {}
	var moving := Vector2(player_vel().x, player_vel().z).length() > 1.0
	if moving:
		for c in ring(pc, req_r):
			want[c] = cheb(c, pc)
	for c in ring(lead, load_r):
		want[c] = 0
	for c in ring(pc, load_r):
		want[c] = 0
	var room := _room_for_requests()
	# until the game is playable only the bootstrap's start cell exists (t09); ring cells are requested after
	if not Game.is_world_ready:
		want.clear()
	for c in want:
		if on_disk.has(c) or (failed.has(c) and failed[c] > now):
			continue
		var prio: int = want[c]
		if requested.get(c, -1) == prio:
			continue
		if not requested.has(c) and not room and prio > 0:
			continue
		_request(c, prio)
	# cancel queued requests that drifted out of range
	for c in requested.keys():
		if not want.has(c) and cheb(c, pc) > req_r + 1:
			if converter:
				converter.send({"op": "cancel", "cell": [c.x, c.y]})
			requested.erase(c)
	# unload cells beyond the unload ring
	for c in loaded.keys():
		if cheb(c, pc) > unload_r:
			_unload(c)
	if pc != _last_player_cell:
		_last_player_cell = pc
		Log.info("player cell %s (loaded %d, on disk %d, requested %d)" % [pc, loaded.size(), on_disk.size(), requested.size()])


func _request(c: Vector2i, prio: int) -> void:
	if converter == null:
		return
	var id: int = converter.send({"op": "cell", "cell": [c.x, c.y], "prio": prio})
	request_ids[id] = c
	requested[c] = prio


## Ask for the start cell before the player exists (bootstrap radius 0 covers it; ring cells come from here).
func request_ring_now() -> void:
	_update_streaming()


func _on_converter_event(e: Dictionary) -> void:
	var ev := str(e.get("event", ""))
	var id := int(e.get("id", -1))
	match ev:
		"done":
			if e.has("cell"):
				var a: Array = e["cell"]
				var c := Vector2i(int(a[0]), int(a[1]))
				on_disk[c] = true
				requested.erase(c)
				failed.erase(c)
				request_ids.erase(id)
				Game.cells_converted += 1
				_add_bytes(int(e.get("bytes", 0)))
				Log.info("cell %s converted (%d bytes, cache %d)" % [c, int(e.get("bytes", 0)), _cache_bytes])
				enforce_cap()
		"error":
			if request_ids.has(id):
				var c2: Vector2i = request_ids[id]
				request_ids.erase(id)
				requested.erase(c2)
				failed[c2] = Time.get_ticks_msec() + 30000
				Log.error("cell %s conversion failed: %s" % [c2, e.get("message", "")])
		"cancelled":
			if request_ids.has(id):
				requested.erase(request_ids[id])
				request_ids.erase(id)
		"status":
			_status_pending = false
			_converter_idle = int(e.get("pending", 1)) == 0 and int(e.get("running", 1)) == 0
			if _gc_needed and _converter_idle:
				_mesh_gc()


# ------------------------------------------------------------------ building

func _start_build(c: Vector2i) -> void:
	var dir := cell_dir(c)
	var job := {"result": {}, "stage": "prepare"}
	job["task"] = WorkerThreadPool.add_task(func(): job["result"] = CellBuilder.prepare(dir), false, "cell %s" % c)
	job["t0"] = Time.get_ticks_msec()
	building[c] = job


## Main-thread budget per frame for glTF mesh loading (RenderingServer resources are created on the main thread).
const MESH_BUDGET_MS := 8


func _poll_builds() -> void:
	var t_frame := Time.get_ticks_msec()
	for c in building.keys():
		var job: Dictionary = building[c]
		if job["stage"] == "prepare":
			if not WorkerThreadPool.is_task_completed(job["task"]):
				continue
			WorkerThreadPool.wait_for_task_completion(job["task"])
			job["stage"] = "meshes"
			var res: Dictionary = job["result"]
			job["pending"] = (res.get("mesh_ids", []) as Array).duplicate()
		var data: Dictionary = job["result"]
		if not data.has("info"):
			building.erase(c)
			Log.error("cell %s build failed: %s" % [c, data.get("error", "?")])
			on_disk.erase(c)
			continue
		if cheb(c, cell_of(player_pos())) > int(Sheets.sys_num("streaming.unload_ring", 3)):
			building.erase(c)
			continue
		var pending: Array = job["pending"]
		while not pending.is_empty() and Time.get_ticks_msec() - t_frame < MESH_BUDGET_MS:
			meshes.get_entry(str(pending.pop_back()))
		if not pending.is_empty():
			return
		building.erase(c)
		var node := CellBuilder.instantiate(data, meshes)
		add_child(node)
		loaded[c] = node
		loaded_at[c] = Time.get_ticks_msec()
		var veg: Dictionary = data.get("vegetation", {})
		cell_data[c] = {"heights": data["heights"], "w": data["w"], "h": data["h"], "origin": data["origin"],
			"size": data["size"], "real": data.get("real", false), "density": veg.get("_density"),
			"channels": veg.get("_channels", []), "veg_count": _veg_count(veg),
			"instances": (data["info"].get("instances", []) as Array).size()}
		var has_start_cf := false
		var start_cf := str(index.get("start_campfire", ""))
		for cf in data["info"].get("campfires", []):
			var p: Array = cf.get("pos", [0, 0, 0])
			campfire_positions[str(cf.get("id", ""))] = Vector3(float(p[0]), float(p[1]), float(p[2]))
			has_start_cf = has_start_cf or str(cf.get("id", "")) == start_cf
		# the index names the start campfire (respawn before any other is activated, D27); place it when the
		# cell itself does not list it
		var scp: Array = index.get("start_campfire_pos", [])
		if not has_start_cf and start_cf != "" and scp.size() == 3:
			var sp := Vector3(float(scp[0]), float(scp[1]), float(scp[2]))
			if cell_of(sp) == c:
				var cf_node := Campfire.new()
				cf_node.campfire_id = start_cf
				cf_node.name = "Campfire_" + start_cf.validate_node_name()
				cf_node.position = sp
				loaded[c].add_child(cf_node)
				campfire_positions[start_cf] = sp
		site_records[c] = data["info"].get("spawns", [])
		spawner.on_cell_loaded(c, site_records[c])
		Log.info("cell %s loaded in %d ms (real terrain %s, %d instances, %d vegetation)" % [c, Time.get_ticks_msec() - int(job["t0"]),
			data.get("real", false), cell_data[c]["instances"], cell_data[c]["veg_count"]])
		Game.cell_loaded.emit(c)
		return  # at most one cell instantiated per frame


static func _veg_count(veg: Dictionary) -> int:
	var n := 0
	for k in veg:
		if not str(k).begins_with("_"):
			n += (veg[k]["xfs"] as Array).size()
	return n


func _unload(c: Vector2i) -> void:
	var node: Node = loaded.get(c)
	loaded.erase(c)
	cell_data.erase(c)
	spawner.on_cell_unloaded(c)
	if node:
		node.queue_free()
	Log.info("cell %s unloaded" % c)


## Never leave worker tasks running into shutdown (they run GDScript lambdas).
func _exit_tree() -> void:
	for c in building.keys():
		if building[c]["stage"] == "prepare":
			WorkerThreadPool.wait_for_task_completion(building[c]["task"])
	building.clear()
	if _size_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_size_task)
		_size_task = -1


# ------------------------------------------------------------------ machines

## Game API spawn: the machine faces the player (so its front weak spots are visible), no site, AI on.
func spawn_machine(type: String, pos: Vector3) -> Node:
	var m: Node3D = spawner.spawn(type, pos, null)
	if Game.player:
		var to: Vector3 = Game.player.global_position - pos
		if Vector2(to.x, to.z).length() > 0.01:
			m.rotation.y = atan2(-to.x, -to.z)
	return m


# ------------------------------------------------------------------ cache size / eviction

func cache_bytes() -> int:
	return _cache_bytes


func _add_bytes(n: int) -> void:
	_cache_bytes += n
	_delta_since_scan += n


func _refresh_size_async() -> void:
	if _size_task >= 0:
		if not WorkerThreadPool.is_task_completed(_size_task):
			return
		WorkerThreadPool.wait_for_task_completion(_size_task)
		# the scan may have missed what changed while it ran: keep those deltas (over-counting is the safe side)
		_cache_bytes = int(_size_result[0]) + _delta_since_scan
		_size_task = -1
	var root := cache_root
	var res := _size_result
	_delta_since_scan = 0
	_size_task = WorkerThreadPool.add_task(func(): res[0] = FsUtil.dir_bytes(root), false, "cache size")


func _room_for_requests() -> bool:
	var cap := Game.cache_cap_bytes
	if cap <= 0:
		return true
	var reserve := int(Sheets.sys_num("cache.reserve_mib", 600.0) * 1048576.0)
	return _cache_bytes <= cap - reserve


## Protected cells (cache.protected): within load_ring of the player, lead cells, queued or converting cells.
func protected_cells() -> Dictionary:
	var out := {}
	var pp := player_pos()
	var load_r := int(Sheets.sys_num("streaming.load_ring", 1))
	for c in ring(cell_of(pp), load_r):
		out[c] = true
	for c in ring(cell_of(pp + player_vel() * Sheets.sys_num("streaming.lead_time_s", 60.0)), load_r):
		out[c] = true
	for c in requested:
		out[c] = true
	for c in building:
		out[c] = true
	return out


## Evicts the farthest unprotected cells until the cache is below cap - reserve (cache.eviction).
func enforce_cap() -> void:
	var cap := Game.cache_cap_bytes
	if cap <= 0:
		return
	var reserve := int(Sheets.sys_num("cache.reserve_mib", 600.0) * 1048576.0)
	var target := maxi(cap - reserve, 0)
	if _cache_bytes <= target:
		return
	var prot := protected_cells()
	var pc := cell_of(player_pos())
	var cands: Array = []
	for c in on_disk:
		if not prot.has(c):
			cands.append(c)
	cands.sort_custom(func(a, b):
		var da := cheb(a, pc)
		var db := cheb(b, pc)
		if da != db:
			return da > db
		return int(loaded_at.get(a, 0)) < int(loaded_at.get(b, 0)))
	for c in cands:
		if _cache_bytes <= target:
			break
		evict(c)
	_gc_needed = true
	_query_status()


func evict(c: Vector2i) -> void:
	var dir := cell_dir(c)
	var bytes := FsUtil.dir_bytes(dir)
	if loaded.has(c):
		_unload(c)
	if FsUtil.remove_tree(dir, cache_root.path_join("hzd/cells")):
		_add_bytes(-bytes)
		on_disk.erase(c)
		Log.info("cell %s evicted (%d bytes, cache %d, cap %d)" % [c, bytes, _cache_bytes, Game.cache_cap_bytes])
		Game.cell_evicted.emit(c)
	else:
		Log.warn("cell %s eviction failed" % c)


func _query_status() -> void:
	if converter == null or _status_pending:
		return
	_status_pending = true
	converter.send({"op": "status"})


## Deletes hzd/meshes/* no remaining cell.json references (only while the converter is idle).
func _mesh_gc() -> void:
	_gc_needed = false
	var used := {}
	for c in on_disk:
		var info = FsUtil.read_json(cell_dir(c).path_join("cell.json"))
		if typeof(info) != TYPE_DICTIONARY:
			continue
		for m in info.get("meshes", []):
			used[str(m)] = true
		for inst in info.get("instances", []):
			used[str(inst.get("mesh", ""))] = true
		var veg = info.get("vegetation", {})
		if typeof(veg) == TYPE_DICTIONARY:
			for sp in veg.get("species", []):
				used[str(sp.get("mesh", ""))] = true
	var mdir := cache_root.path_join("hzd/meshes")
	var d := DirAccess.open(mdir)
	if d == null:
		return
	var removed := 0
	var freed := 0
	for f in d.get_files():
		if not f.ends_with(".glb"):
			continue
		var id := f.get_basename()
		if used.has(id):
			continue
		var p := mdir.path_join(f)
		var sz := 0
		var fa := FileAccess.open(p, FileAccess.READ)
		if fa:
			sz = fa.get_length()
			fa.close()
		if DirAccess.remove_absolute(p) == OK:
			removed += 1
			freed += sz
			meshes.forget(id)
	_add_bytes(-freed)
	if removed > 0:
		Log.info("mesh gc: removed %d unreferenced meshes (%d bytes)" % [removed, freed])
