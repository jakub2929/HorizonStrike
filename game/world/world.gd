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
const CellProfiler := preload("res://world/cell_profiler.gd")
const CellInserter := preload("res://world/cell_inserter.gd")

var cache_root := ""
var index := {}
var cell_size := 512.0
var converter: Node = null
var meshes: RefCounted
var spawner: Node
var profiler: Node

var valid_cells := {}          # Vector2i -> true (from index.json)
var on_disk := {}              # Vector2i -> true
var loaded := {}               # Vector2i -> Node3D
var cell_data := {}            # Vector2i -> {real, veg, heights...} kept for queries
var building := {}             # Vector2i -> {task, result, stage: prepare (worker) | ready | insert}
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
var _gc_timer := 0.0
# Meshes/textures of evicted cells that the running converter process converted. The converter remembers every mesh
# it exported (or found on disk) for its whole lifetime and never writes it again, so deleting one of these would
# leave a later re-conversion of that cell (or any cell sharing it) with a missing mesh.
var _pinned_meshes := {}
var _pinned_tex := {}
var _inserter: RefCounted = null   # the one cell being inserted (world/cell_inserter.gd)
var _ground := {}                  # Vector2i -> true once the cell's terrain collision is complete
var _col := {}                     # Vector2i -> {buckets, origin, bodies: key -> Array[StaticBody3D], parent}
var _col_ops: Array = []           # [cell, bucket key, "add"|"remove", distance]
var _col_timer := 0.0
var _graveyard: Array = []         # nodes of unloaded cells, freed a few per frame (leaves first)
var last_work := ""                # --profile-cells: what the streaming main-thread work did last frame (steps > 1 ms)
var _finish_detail := ""
var _free_tasks: Array = []        # worker tasks dropping finished cells' prepared data


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
	spawner.warm_up()
	profiler = CellProfiler.new()
	profiler.name = "CellProfiler"
	profiler.world = self
	if Game.args:
		profiler.profile = bool(Game.args.get("profile_cells"))
		profiler.quit_after = int(Game.args.get("quit_after_cells"))
	add_child(profiler)
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
	return _ground.has(cell_of(pos))


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
	_main_thread_work(delta)
	_stream_timer -= delta
	if _stream_timer <= 0.0:
		_stream_timer = 0.25
		_update_streaming()
	_poll_size()
	_size_timer -= delta
	if _size_timer <= 0.0:
		_size_timer = Sheets.sys_num("cache.size_refresh_s", 5.0)
		_refresh_size_async()
	_evict_timer -= delta
	if _evict_timer <= 0.0:
		_evict_timer = 1.0
		enforce_cap()
	# a deferred mesh GC asks the converter again until it is idle and nothing is requested
	_gc_timer -= delta
	if _gc_needed and _gc_timer <= 0.0:
		_gc_timer = 5.0
		_query_status()


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
				# never trust the converter's byte report: measure the cell folder, and re-anchor on a full folder scan
				# right away (shared meshes/textures the job wrote are caught by that scan)
				var cb := FsUtil.dir_bytes(cell_dir(c))
				_add_bytes(cb)
				_size_timer = 0.0
				Log.info("cell %s converted (folder %d bytes, reported %d, cache %d)" % [c, cb, int(e.get("bytes", 0)), _cache_bytes])
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
			if _gc_needed and _converter_idle and requested.is_empty():
				_mesh_gc()


# ------------------------------------------------------------------ building

func _start_build(c: Vector2i) -> void:
	var dir := cell_dir(c)
	# the worker only writes slot 0 of its own pre-sized array; the job dictionary is main-thread only (inserting a key
	# while a worker writes into the same dictionary is a data race)
	var out: Array = [{}]
	var lib := meshes
	var job := {"result": {}, "stage": "prepare", "out": out, "t0": Time.get_ticks_msec(), "task": -1}
	job["task"] = WorkerThreadPool.add_task(func():
		var tw := Time.get_ticks_usec()
		var r: Dictionary = CellBuilder.prepare(dir, lib)
		r["prepare_wall_ms"] = (Time.get_ticks_usec() - tw) / 1000.0
		out[0] = r, false, "cell %s" % c)
	building[c] = job
	profiler.begin(c)


## Worker results: a finished prepare makes the cell "ready" for insertion (cells that drifted out of range are dropped).
func _poll_builds() -> void:
	for c in building.keys():
		var job: Dictionary = building[c]
		if job["stage"] != "prepare":
			continue
		if not WorkerThreadPool.is_task_completed(job["task"]):
			continue
		WorkerThreadPool.wait_for_task_completion(job["task"])
		job["result"] = job["out"][0]
		job["stage"] = "ready"
		var data: Dictionary = job["result"]
		if not data.has("info"):
			building.erase(c)
			Log.error("cell %s build failed: %s" % [c, data.get("error", "?")])
			on_disk.erase(c)


## All streaming work on the main thread shares one per-frame budget (streaming.main_thread_budget_ms): inserting the
## current cell step by step (one cell at a time), object collision around the player, freeing unloaded cells.
func _main_thread_work(delta: float) -> void:
	var budget_us := int(Sheets.sys_num("streaming.main_thread_budget_ms", 6.0) * 1000.0)
	var t_start := Time.get_ticks_usec()
	var deadline := t_start + budget_us
	last_work = ""
	var pc := cell_of(player_pos())
	var unload_r := int(Sheets.sys_num("streaming.unload_ring", 3))
	if _inserter and cheb(_inserter.cell, pc) > unload_r:
		Log.info("cell %s insertion dropped (out of range)" % _inserter.cell)
		_bury(_inserter.root)
		building.erase(_inserter.cell)
		cell_data.erase(_inserter.cell)
		_ground.erase(_inserter.cell)
		_inserter = null
	if _inserter == null:
		var tb := Time.get_ticks_usec()
		_begin_insert(pc, unload_r)
		if _inserter:
			last_work += "begin %.1f | " % ((Time.get_ticks_usec() - tb) / 1000.0)
	if _inserter:
		var ins: RefCounted = _inserter
		var ts := Time.get_ticks_usec()
		var done: bool = ins.step(deadline)
		last_work += "insert %s (step() %.1f ms): %s| " % [ins.cell, (Time.get_ticks_usec() - ts) / 1000.0, ins.last_steps]
		if ins.ground_ready:
			_ground[ins.cell] = true
		if done:
			_inserter = null
			var tf := Time.get_ticks_usec()
			_finish_insert(ins)
			last_work += "finish %.1f (%s) | " % [(Time.get_ticks_usec() - tf) / 1000.0, _finish_detail]
	var tc := Time.get_ticks_usec()
	_collision_ring(delta, deadline)
	last_work += "collision %.1f | " % ((Time.get_ticks_usec() - tc) / 1000.0)
	while not _free_tasks.is_empty() and WorkerThreadPool.is_task_completed(_free_tasks[0]):
		WorkerThreadPool.wait_for_task_completion(_free_tasks.pop_front())
	tc = Time.get_ticks_usec()
	var freed := 0
	while not _graveyard.is_empty() and Time.get_ticks_usec() < deadline:
		var n: Node = _graveyard.pop_back()
		if is_instance_valid(n):
			n.free()
			freed += 1
	last_work += "free %d %.1f | total %.1f" % [freed, (Time.get_ticks_usec() - tc) / 1000.0, (Time.get_ticks_usec() - t_start) / 1000.0]


## Starts inserting the nearest ready cell.
func _begin_insert(pc: Vector2i, unload_r: int) -> void:
	var best := Vector2i.ZERO
	var best_d := 1 << 30
	for c in building.keys():
		var job: Dictionary = building[c]
		if job["stage"] != "ready":
			continue
		var d := cheb(c, pc)
		if d > unload_r:
			building.erase(c)
			continue
		if d < best_d:
			best_d = d
			best = c
	if best_d == 1 << 30:
		return
	var job2: Dictionary = building[best]
	job2["stage"] = "insert"
	var data: Dictionary = job2["result"]
	var veg: Dictionary = data.get("vegetation", {})
	# queries (height, stealth) work from the data at once; the ground counts once its collision tiles are in
	cell_data[best] = {"heights": data["heights"], "w": data["w"], "h": data["h"], "origin": data["origin"],
		"size": data["size"], "real": data.get("real", false), "density": veg.get("_density"),
		"channels": veg.get("_channels", []), "veg_count": _veg_count(veg),
		"instances": (data["info"].get("instances", []) as Array).size()}
	_inserter = CellInserter.new(best, data, meshes, self, player_pos())
	_inserter.trace = profiler.profile
	Game.cell_insert_started.emit(best)


func _finish_insert(ins: RefCounted) -> void:
	var c: Vector2i = ins.cell
	var job: Dictionary = building.get(c, {})
	building.erase(c)
	var data: Dictionary = ins.data
	var node: Node3D = ins.root
	loaded[c] = node
	loaded_at[c] = Time.get_ticks_msec()
	_ground[c] = true
	_col[c] = {"buckets": data.get("col_buckets", {}), "origin": data["origin"], "bodies": {},
		"parent": node.get_node("ObjectBodies")}
	_col_timer = 0.0
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
			node.add_child(cf_node)
			campfire_positions[start_cf] = sp
	var tf := Time.get_ticks_usec()
	site_records[c] = data["info"].get("spawns", [])
	spawner.on_cell_loaded(c, site_records[c])
	_finish_detail = "spawner %.1f" % ((Time.get_ticks_usec() - tf) / 1000.0)
	tf = Time.get_ticks_usec()
	profiler.inserted(c, ins.phases, data.get("t", {}), float(data.get("prepare_wall_ms", 0.0)), 0.0, float(ins.phases["add_child"]),
		{"instances": cell_data[c]["instances"], "vegetation": cell_data[c]["veg_count"], "shapes": int(data.get("col_items", 0)),
		"bodies": (data.get("col_buckets", {}) as Dictionary).size()})
	Log.info("cell %s loaded in %d ms (real terrain %s, %d instances, %d vegetation, %d steps, %d collision items in %d buckets near the player only)" % [c,
		Time.get_ticks_msec() - int(job.get("t0", Time.get_ticks_msec())), data.get("real", false), cell_data[c]["instances"], cell_data[c]["veg_count"],
		ins.steps_done, int(data.get("col_items", 0)), (data.get("col_buckets", {}) as Dictionary).size()])
	_finish_detail += ", log %.1f" % ((Time.get_ticks_usec() - tf) / 1000.0)
	tf = Time.get_ticks_usec()
	Game.cell_loaded.emit(c)
	_finish_detail += ", cell_loaded %.1f" % ((Time.get_ticks_usec() - tf) / 1000.0)
	# the prepared data (instance transforms, chunk buffers, terrain arrays) is large: dropping the last reference on
	# the main thread cost ~50 ms of destructor work, so a worker drops it
	var holder: Array = [ins.data]
	ins.data = {}
	data = {}
	job.clear()
	_free_tasks.append(WorkerThreadPool.add_task(func(): holder.clear(), false, "free cell data"))


## Object collision exists only within streaming.collision_radius_m of the player: buckets (CellBuilder
## COLLISION_BUCKET_M) are re-evaluated every streaming.collision_update_s; bodies are added one per step (nearest
## first) and removed beyond the radius plus one bucket (hysteresis).
func _collision_ring(delta: float, deadline: int) -> void:
	_col_timer -= delta
	if _col_timer <= 0.0:
		_col_timer = Sheets.sys_num("streaming.collision_update_s", 0.5)
		_plan_collision_ops()
	while not _col_ops.is_empty() and Time.get_ticks_usec() < deadline:
		var op: Array = _col_ops[0]
		var c: Vector2i = op[0]
		if not _col.has(c):
			_col_ops.pop_front()
			continue
		var cc: Dictionary = _col[c]
		var key: Vector2i = op[1]
		var t0 := Time.get_ticks_usec()
		match str(op[2]):
			"add":
				if (cc["bodies"] as Dictionary).has(key):
					_col_ops.pop_front()
					continue
				# first every missing collision shape of the bucket, one per step (a trimesh build is the slow part)
				var missing := ""
				for it in cc["buckets"][key]:
					if not meshes.has_shape(str(it[0])):
						missing = str(it[0])
						break
				if missing != "":
					meshes.get_shape(missing)
				else:
					_col_ops.pop_front()
					var bodies: Array = CellBuilder.make_bucket_bodies(cc["buckets"][key], meshes)
					cc["bodies"][key] = bodies
					var attach: Array = []
					for b in bodies:
						attach.append([c, key, "attach", 0.0, b])
					_col_ops = attach + _col_ops
			"attach":
				_col_ops.pop_front()
				if is_instance_valid(op[4]) and (cc["bodies"] as Dictionary).has(key):
					(cc["parent"] as Node).add_child(op[4])
			_:
				_col_ops.pop_front()
				for b in cc["bodies"].get(key, []):
					if is_instance_valid(b):
						_graveyard.append(b)
				cc["bodies"].erase(key)
		profiler.add_main(c, "collision", (Time.get_ticks_usec() - t0) / 1000.0)


func _plan_collision_ops() -> void:
	var p := player_pos()
	var p2 := Vector2(p.x, p.z)
	var r := Sheets.sys_num("streaming.collision_radius_m", 150.0)
	var b: float = CellBuilder.COLLISION_BUCKET_M
	var adds: Array = []
	# keep pending attaches of bodies already built; everything else is re-planned
	var keep: Array = _col_ops.filter(func(o): return str(o[2]) == "attach")
	_col_ops.clear()
	for c in _col:
		var cc: Dictionary = _col[c]
		var o: Vector3 = cc["origin"]
		for key in cc["buckets"]:
			var k: Vector2i = key
			var d := p2.distance_to(Vector2(o.x + (k.x + 0.5) * b, o.z + (k.y + 0.5) * b))
			var has: bool = (cc["bodies"] as Dictionary).has(k)
			if not has and d <= r + b * 0.71:
				adds.append([c, k, "add", d])
			elif has and d > r + b * 1.71:
				_col_ops.append([c, k, "remove", d])
	adds.sort_custom(func(x, y): return x[3] < y[3])
	_col_ops = keep + adds + _col_ops


## Frees a node tree a few nodes per frame (leaves first) instead of all at once.
func _bury(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node is Node3D:
		(node as Node3D).visible = false
	node.process_mode = Node.PROCESS_MODE_DISABLED   # children freed first must not be touched by their parents
	_graveyard.append(node)
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			_graveyard.append(ch)
			stack.append(ch)


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
	_ground.erase(c)
	if _col.has(c):
		# bodies built but not attached yet are not under the cell node
		for key in _col[c]["bodies"]:
			for b in _col[c]["bodies"][key]:
				if is_instance_valid(b) and not (b as Node).is_inside_tree():
					_graveyard.append(b)
	_col.erase(c)
	spawner.on_cell_unloaded(c)
	if node:
		_bury(node)
	Log.info("cell %s unloaded" % c)


## Never leave worker tasks running into shutdown (they run GDScript lambdas). Any quit (also a bare SceneTree.quit)
## passes here before the converter node exits: stop the converter first, then wait (bounded) for the workers.
func _exit_tree() -> void:
	if converter and converter.has_method("stop"):
		converter.stop()
	var t0 := Time.get_ticks_msec()
	var tasks: Array = []
	for c in building.keys():
		if building[c]["stage"] == "prepare":
			tasks.append(building[c]["task"])
	if _size_task >= 0:
		tasks.append(_size_task)
	tasks.append_array(_free_tasks)
	for t in tasks:
		while not WorkerThreadPool.is_task_completed(t) and Time.get_ticks_msec() - t0 < 10000:
			OS.delay_msec(5)
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
		else:
			Log.warn("world exit: worker task %d still running after 10 s, not waiting for it" % t)
	building.clear()
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


## Applies a finished background folder scan: the cache size is what is on disk (+ changes made since it started).
func _poll_size() -> void:
	if _size_task >= 0 and WorkerThreadPool.is_task_completed(_size_task):
		WorkerThreadPool.wait_for_task_completion(_size_task)
		_cache_bytes = int(_size_result[0]) + _delta_since_scan
		_size_task = -1


func _refresh_size_async() -> void:
	_poll_size()
	if _size_task >= 0:
		_size_timer = 0.2   # a scan is still running: try again shortly
		return
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
	var cj := dir.path_join("cell.json")
	if converter and FileAccess.file_exists(cj) and float(FileAccess.get_modified_time(cj)) >= float(converter.started_unix) - 2.0:
		var info = FsUtil.read_json(cj)
		if typeof(info) == TYPE_DICTIONARY:
			_cell_refs(info, _pinned_meshes, _pinned_tex)
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


## Meshes and textures a cell.json references.
static func _cell_refs(info: Dictionary, used: Dictionary, used_tex: Dictionary) -> void:
	for m in info.get("meshes", []):
		used[str(m)] = true
	for inst in info.get("instances", []):
		used[str(inst.get("mesh", ""))] = true
	var veg = info.get("vegetation", {})
	if typeof(veg) == TYPE_DICTIONARY:
		for sp in veg.get("species", []):
			used[str(sp.get("mesh", ""))] = true
	for t in info.get("textures", []):
		used_tex[str(t)] = true


## Deletes hzd/meshes/* that no cell on disk references and the running converter has not converted (only while
## the converter is idle and no conversion is requested; otherwise it is retried).
func _mesh_gc() -> void:
	if not requested.is_empty():
		return
	_gc_needed = false
	var used := _pinned_meshes.duplicate()
	var used_tex := _pinned_tex.duplicate()
	for c in on_disk:
		var info = FsUtil.read_json(cell_dir(c).path_join("cell.json"))
		if typeof(info) != TYPE_DICTIONARY:
			return   # unreadable cell.json: keep everything (the next eviction asks again)
		_cell_refs(info, used, used_tex)
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
		var sz := FsUtil.file_bytes(p)
		if DirAccess.remove_absolute(p) == OK:
			removed += 1
			freed += sz
			meshes.forget(id)
	_add_bytes(-freed)
	# textures referenced by meshes: keep the ones any remaining cell.json lists in `textures`
	var tdir := cache_root.path_join("hzd/textures")
	var td := DirAccess.open(tdir)
	if td and not used_tex.is_empty():
		for f in td.get_files():
			if used_tex.has(f.get_basename()) or used_tex.has(f):
				continue
			var tp := tdir.path_join(f)
			if tp.ends_with(".tmp") or not FileAccess.file_exists(tp):
				continue
			var sz2 := FsUtil.file_bytes(tp)
			if DirAccess.remove_absolute(tp) == OK:
				removed += 1
				freed += sz2
				_add_bytes(-sz2)
	if removed > 0:
		Log.info("mesh gc: removed %d unreferenced meshes/textures (%d bytes)" % [removed, freed])
