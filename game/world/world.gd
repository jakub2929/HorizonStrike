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
const PipelineWatch := preload("res://world/pipeline_watch.gd")

var cache_root := ""
var index := {}
var cell_size := 512.0
var converter: Node = null
var meshes: RefCounted
var spawner: Node
var profiler: Node
var pipeline_watch: Node       # started by Main when the precompile is done

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
var far := {}                     # Vector2i -> Node3D far version of a cell (coarse terrain + HLOD proxy)
var _far_jobs := {}                # Vector2i -> {task, out: [Dictionary]}
var _far_none := {}                # cells without an HLOD (not asked again)
const MEM_REPORT_S := 15.0
var _mem_timer := MEM_REPORT_S
var loading_phase := true         # Main clears it when the precompile starts (streaming.main_thread_budget_loading_ms)
var last_process_ms := 0.0        # this node's whole _process last frame (slow frame log)
var last_work := ""                # --profile-cells: what the streaming main-thread work did last frame (steps > 1 ms)
var _finish_detail := ""
var _free_tasks: Array = []        # worker tasks dropping finished cells' prepared data
var _task_info := {}               # task id -> [kind, progress Array (written by the worker)] for quit diagnostics
var _stuck := false                # a worker task did not finish at quit (see Main.quit_game)
const EVICT_RETRY_MS := 30000      # a cell that could not be evicted (in use) is skipped this long
const EVICT_FRESH_S := 10.0        # files written this recently: a converter is still at the cell
const EVICT_PER_CALL := 4          # cells tried per enforce_cap() (it runs every second; renames cost main-thread time)
var _evict_retry := {}             # Vector2i -> ticks ms before which evict() leaves the cell alone
var _trash_running: Array = [false]   # the worker emptying <cache>/trash is running
var _evict_running: Array = [false]   # the eviction worker is running
var _evict_out: Array = []            # its result slot until _poll_evict() applied it
var _evicting := {}                   # cells the eviction worker may be renaming right now (no build / far job)
var _trash_pin: Array = []            # trash folders whose cell.json meshes are to be pinned (next trash worker)
var _trash_out: Array = []            # the trash worker's pins until _poll_trash() applied them
var _gc_running: Array = [false]      # the mesh GC worker is running
var _gc_out: Array = []               # its result slot until _poll_mesh_gc() applied it
var _events: Array = []               # [ticks ms, text] of the last second's world events (slow frame log)
var _col_worst := ""                  # slowest collision op of this frame (slow frame log)


## Records a world event for the slow frame log (cell_profiler.gd).
func note(text: String) -> void:
	var now := Time.get_ticks_msec()
	_events.append([now, text])
	while not _events.is_empty() and now - int(_events[0][0]) > 1000:
		_events.pop_front()


## Events of the last `ms` milliseconds, oldest first ("-" when none).
func recent_events(ms: int) -> String:
	var now := Time.get_ticks_msec()
	var out := PackedStringArray()
	for e in _events:
		if now - int(e[0]) <= ms:
			out.append("%s (%d ms ago)" % [e[1], now - int(e[0])])
	return ", ".join(out) if not out.is_empty() else "-"


func setup(root: String, idx: Dictionary, conv: Node) -> void:
	MeshLib.cancelled = false
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
	_empty_trash()   # cell folders evicted by a run that ended before its trash was deleted
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
	pipeline_watch = PipelineWatch.new()
	pipeline_watch.name = "PipelineWatch"
	pipeline_watch.profile = profiler.profile
	add_child(pipeline_watch)
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
	var t_proc := Time.get_ticks_usec()
	_process_inner(delta)
	last_process_ms = (Time.get_ticks_usec() - t_proc) / 1000.0


func _process_inner(delta: float) -> void:
	_mem_timer -= delta
	if _mem_timer <= 0.0:
		_mem_timer = MEM_REPORT_S
		Log.info("mem: %s" % JSON.stringify(memory_report()))
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
	_poll_evict()
	_poll_trash()
	_poll_mesh_gc()
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
		if on_disk.has(c) and not loaded.has(c) and not building.has(c) and not _evicting.has(c):
			_start_build(c)
	# request conversions: prio 0 inside load ring of the player or the lead point, else ring distance.
	# The wider request_ring (prio = ring, after the near cells) is used while the player moves and, since 0.2, also
	# standing when far cells show HLOD proxies from that ring (render.hlod_from_ring <= request_ring): the horizon
	# is converted cells, not void. Before world_ready only the start cell (t09).
	var want := {}
	var moving := Vector2(player_vel().x, player_vel().z).length() > 1.0
	if moving or int(Sheets.sys_num("render.hlod_from_ring", 2)) <= req_r:
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
	_update_far(pc, unload_r)
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
				# never trust the converter's byte report: a full folder scan on a worker starts right away (no folder
				# walk on the main thread: a stalling disk froze frames)
				_size_timer = 0.0
				Log.info("cell %s converted (reported %d bytes, cache %d before the rescan)" % [c, int(e.get("bytes", 0)), _cache_bytes])
				note("converted %s" % c)
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
		"throttled":
			Log.info("converter throttled: %d workers, %d threads" % [int(e.get("workers", 0)), int(e.get("threads", 0))])
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
	var prog: Array = ["queued"]
	job["task"] = WorkerThreadPool.add_task(func():
		prog[0] = "started"
		var tw := Time.get_ticks_usec()
		var r: Dictionary = CellBuilder.prepare(dir, lib, prog)
		r["prepare_wall_ms"] = (Time.get_ticks_usec() - tw) / 1000.0
		out[0] = r
		prog[0] = "done", false, "cell %s" % c)
	_task_info[job["task"]] = ["prepare %s" % c, prog]
	building[c] = job
	profiler.begin(c)


## Worker results: a finished prepare makes the cell "ready" for insertion (cells that drifted out of range are dropped).
func _poll_builds() -> void:
	for c in building.keys():
		var job: Dictionary = building[c]
		if job["stage"] == "reprep":
			if WorkerThreadPool.is_task_completed(job["task"]):
				WorkerThreadPool.wait_for_task_completion(job["task"])
				_task_info.erase(job["task"])
				job["stage"] = "ready"
			continue
		if job["stage"] != "prepare":
			continue
		if not WorkerThreadPool.is_task_completed(job["task"]):
			continue
		WorkerThreadPool.wait_for_task_completion(job["task"])
		_task_info.erase(job["task"])
		job["result"] = job["out"][0]
		job["stage"] = "ready"
		var data: Dictionary = job["result"]
		if data.has("info"):
			# the cell holds its meshes from now on (mesh_library.gd sharing / release); meshes released while the
			# worker counted them as built are prepared again on a worker, never on the main thread
			meshes.acquire(c, data.get("mesh_ids", []))
			var again: Array = meshes.missing(data.get("mesh_ids", []))
			if not again.is_empty():
				var lib := meshes
				var rprog: Array = ["queued"]
				job["task"] = WorkerThreadPool.add_task(func():
					rprog[0] = "started"
					lib.prepare(again, rprog)
					rprog[0] = "done", false, "cell %s meshes again" % c)
				_task_info[job["task"]] = ["prepare again %s (%d meshes)" % [c, again.size()], rprog]
				job["stage"] = "reprep"
		if not data.has("info"):
			building.erase(c)
			if not FileAccess.file_exists(cell_dir(c).path_join("cell.json")):
				# this game never deletes a cell it builds (protected_cells); another instance sharing the cache can
				Log.warn("cell %s left the disk before its build (another game instance evicted it?); converting it again" % c)
			else:
				Log.error("cell %s build failed: %s" % [c, data.get("error", "?")])
			on_disk.erase(c)


## All streaming work on the main thread shares one per-frame budget (streaming.main_thread_budget_ms): inserting the
## current cell step by step (one cell at a time), object collision around the player, freeing unloaded cells.
func _main_thread_work(delta: float) -> void:
	# the loading screen (until the precompile starts) gets a much larger budget: nobody plays yet
	var budget_us := int(Sheets.sys_num("streaming.main_thread_budget_loading_ms" if loading_phase else "streaming.main_thread_budget_ms", 6.0) * 1000.0)
	var t_start := Time.get_ticks_usec()
	var deadline := t_start + budget_us
	last_work = ""
	var pc := cell_of(player_pos())
	var unload_r := int(Sheets.sys_num("streaming.unload_ring", 3))
	if _inserter and cheb(_inserter.cell, pc) > unload_r:
		Log.info("cell %s insertion dropped (out of range)" % _inserter.cell)
		meshes.release(_inserter.cell)
		_bury(_inserter.root)
		_drop_later([building.get(_inserter.cell), cell_data.get(_inserter.cell), _inserter.data], "dropped insert %s" % _inserter.cell)
		_inserter.data = {}
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
	# one finished far cell per frame (when time is left)
	if Time.get_ticks_usec() < deadline:
		for c in _far_jobs.keys():
			var fj: Dictionary = _far_jobs[c]
			if not WorkerThreadPool.is_task_completed(fj["task"]):
				continue
			WorkerThreadPool.wait_for_task_completion(fj["task"])
			_task_info.erase(fj["task"])
			_far_jobs.erase(c)
			var fd: Dictionary = fj["out"][0]
			if fd.is_empty():
				_far_none[c] = true
			elif not loaded.has(c):
				var fn := CellBuilder.make_far(fd)
				fn.name = "Far_%d_%d" % [c.x, c.y]
				add_child(fn)
				far[c] = fn
				Log.info("far cell %s shown (HLOD %s)" % [c, fd.has("hlod_surfaces")])
				note("far %s shown" % c)
			break
	var tc := Time.get_ticks_usec()
	_collision_ring(delta, deadline)
	last_work += "collision %.1f%s | " % [(Time.get_ticks_usec() - tc) / 1000.0, (" (" + _col_worst + ")") if _col_worst != "" else ""]
	while not _free_tasks.is_empty() and WorkerThreadPool.is_task_completed(_free_tasks[0]):
		_task_info.erase(_free_tasks[0])
		WorkerThreadPool.wait_for_task_completion(_free_tasks.pop_front())
	tc = Time.get_ticks_usec()
	var freed := 0
	while not _graveyard.is_empty() and Time.get_ticks_usec() < deadline:
		var n: Node = _graveyard.pop_back()
		if not is_instance_valid(n):
			continue
		if n.get_child_count() > 0:
			# children first (expanded lazily: walking a whole cell tree at unload time was a 60 ms frame); the node
			# stops processing so it never touches a child that is already gone
			n.set_process(false)
			n.set_physics_process(false)
			_graveyard.append(n)
			_graveyard.append_array(n.get_children())
			continue
		n.free()
		freed += 1
	last_work += "free %d %.1f | total %.1f" % [freed, (Time.get_ticks_usec() - tc) / 1000.0, (Time.get_ticks_usec() - t_start) / 1000.0]


## Drops the last references of large data (prepared cells: transforms, buffers, heights) on a worker: freeing them
## on the main thread was tens of ms per cell.
func _drop_later(items: Array, what: String) -> void:
	var holder: Array = items.filter(func(x): return x != null)
	if holder.is_empty():
		return
	var dprog: Array = ["queued"]
	var t := WorkerThreadPool.add_task(func():
		dprog[0] = "started"
		holder.clear()
		dprog[0] = "done", true, "drop " + what)
	_free_tasks.append(t)
	_task_info[t] = ["drop " + what, dprog]


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
			_drop_later([job], "dropped build %s" % c)   # its prepared data is large: freed on a worker
			building.erase(c)
			meshes.release(c)
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
	Log.info("cell %s loaded in %d ms (real terrain %s, %d instances, %d vegetation, %d water surfaces, %d steps, %d collision items in %d buckets near the player only)" % [c,
		Time.get_ticks_msec() - int(job.get("t0", Time.get_ticks_msec())), data.get("real", false), cell_data[c]["instances"], cell_data[c]["veg_count"],
		(data.get("water", {}) as Dictionary).values().reduce(func(a, l): return a + (l as Array).size(), 0),
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
	var fprog: Array = ["queued"]
	var ft := WorkerThreadPool.add_task(func():
		fprog[0] = "started"
		holder.clear()
		fprog[0] = "done", true, "free cell data")
	_free_tasks.append(ft)
	_task_info[ft] = ["free cell data %s" % c, fprog]


## Object collision exists only within streaming.collision_radius_m of the player: buckets (CellBuilder
## COLLISION_BUCKET_M) are re-evaluated every streaming.collision_update_s; bodies are added one per step (nearest
## first) and removed beyond the radius plus one bucket (hysteresis).
func _collision_ring(delta: float, deadline: int) -> void:
	_col_timer -= delta
	if _col_timer <= 0.0:
		_col_timer = Sheets.sys_num("streaming.collision_update_s", 0.5)
		_plan_collision_ops()
	_col_worst = ""
	var worst_us := 0
	while not _col_ops.is_empty() and Time.get_ticks_usec() < deadline:
		var op: Array = _col_ops[0]
		var c: Vector2i = op[0]
		if not _col.has(c):
			_col_ops.pop_front()
			continue
		var cc: Dictionary = _col[c]
		var key: Vector2i = op[1]
		var t0 := Time.get_ticks_usec()
		var what := str(op[2])
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
					var sh: Shape3D = meshes.get_shape(missing)
					if sh != null:
						_warm_shape(sh)
					what = "shape %s (%d tris)" % [missing, int(meshes.info(missing).get("tris", 0))]
				else:
					# then one body (<= SHAPES_PER_BODY shapes) per step: making all of a dense bucket at once was 15+ ms
					_col_ops.pop_front()
					cc["bodies"][key] = []
					var n: int = (cc["buckets"][key] as Array).size()
					var parts: Array = []
					for i0 in range(0, n, CellBuilder.SHAPES_PER_BODY):
						parts.append([c, key, "body", 0.0, i0])
					_col_ops = parts + _col_ops
			"body":
				_col_ops.pop_front()
				if (cc["bodies"] as Dictionary).has(key):
					var items: Array = (cc["buckets"][key] as Array).slice(int(op[4]), int(op[4]) + CellBuilder.SHAPES_PER_BODY)
					for b in CellBuilder.make_bucket_bodies(items, meshes):
						cc["bodies"][key].append(b)
						(cc["parent"] as Node).add_child(b)
					what = "body of %d shapes (%s)" % [items.size(), ", ".join(items.map(func(it): return str(it[0]).left(8)))]
			_:
				_col_ops.pop_front()
				for b in cc["bodies"].get(key, []):
					if is_instance_valid(b):
						_graveyard.append(b)
				cc["bodies"].erase(key)
		var us := Time.get_ticks_usec() - t0
		if us > worst_us:
			worst_us = us
			_col_worst = "slowest op %s %.1f ms" % [what, us / 1000.0]
		profiler.add_main(c, "collision", us / 1000.0)


## Jolt builds a shape (trimesh BVH) when the first body using it enters the tree and keeps it with the Shape3D: a
## bucket body with 16 new trimeshes was a 42 ms step (t15). A throwaway single-shape body (no layers) builds each
## new shape in its own step; the graveyard frees the body within the budget.
func _warm_shape(sh: Shape3D) -> void:
	var b := StaticBody3D.new()
	b.collision_layer = 0
	b.collision_mask = 0
	var o := b.create_shape_owner(b)
	b.shape_owner_add_shape(o, sh)
	add_child(b)
	_graveyard.append(b)


func _plan_collision_ops() -> void:
	var p := player_pos()
	var p2 := Vector2(p.x, p.z)
	var r := Sheets.sys_num("streaming.collision_radius_m", 150.0)
	var b: float = CellBuilder.COLLISION_BUCKET_M
	var adds: Array = []
	# keep pending attaches of bodies already built; everything else is re-planned
	var keep: Array = _col_ops.filter(func(o): return str(o[2]) == "body")
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


## Far cells (render.hlod_from_ring .. unload ring) show a coarse terrain + the converter's HLOD proxy instead of
## nothing; a far cell stays until its full version is in, and goes when it leaves the ring.
func _update_far(pc: Vector2i, unload_r: int) -> void:
	var r_min := int(Sheets.sys_num("render.hlod_from_ring", 2))
	for c in far.keys():
		var d := cheb(c, pc)
		if d > unload_r or loaded.has(c):
			_bury(far[c])
			far.erase(c)
	for c in ring(pc, unload_r):
		if cheb(c, pc) < r_min and not loaded.has(c) and not far.has(c):
			continue
		if loaded.has(c) or far.has(c) or _far_jobs.has(c) or _far_none.has(c) or not on_disk.has(c) or _evicting.has(c):
			continue
		if _far_jobs.size() >= 2:
			break
		var out: Array = [{}]
		var dir := cell_dir(c)
		var prog: Array = ["queued"]
		_far_jobs[c] = {"out": out, "task": WorkerThreadPool.add_task(func():
			prog[0] = "started"
			out[0] = CellBuilder.prepare_far(dir)
			prog[0] = "done", true, "far cell %s" % c)}
		_task_info[_far_jobs[c]["task"]] = ["far %s" % c, prog]


## Frees a node tree a few nodes per frame (leaves first) instead of all at once. disable_collision: every
## collision object in the (small) tree stops colliding at once (machines: body and hitboxes).
func bury(node: Node, disable_collision: bool = false) -> void:
	if disable_collision and is_instance_valid(node):
		var stack: Array = [node]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is CollisionObject3D:
				(n as CollisionObject3D).collision_layer = 0
				(n as CollisionObject3D).collision_mask = 0
			stack.append_array(n.get_children())
	_bury(node, disable_collision)


## Cells stay as they are until freed (hiding or disabling a whole cell tree notifies every node: ~20 ms per cell);
## small trees (machines) are hidden and stopped at once.
func _bury(node: Node, small: bool = false) -> void:
	if node == null or not is_instance_valid(node):
		return
	if small:
		if node is Node3D:
			(node as Node3D).visible = false
		node.process_mode = Node.PROCESS_MODE_DISABLED
	_graveyard.append(node)


static func _veg_count(veg: Dictionary) -> int:
	var n := 0
	for k in veg:
		if not str(k).begins_with("_"):
			n += (veg[k]["xfs"] as Array).size()
	return n


func _unload(c: Vector2i) -> void:
	meshes.release(c)   # meshes, materials and textures no other cell holds leave RAM and VRAM with this cell
	var node: Node = loaded.get(c)
	loaded.erase(c)
	_ground.erase(c)
	var drop: Array = [cell_data.get(c)]
	cell_data.erase(c)
	if _col.has(c):
		drop.append(_col[c])
	_col.erase(c)
	# collision buckets (tens of thousands of transforms) and heights: a worker drops the last reference (~15 ms here)
	var uprog: Array = ["queued"]
	var ut := WorkerThreadPool.add_task(func():
		uprog[0] = "started"
		drop.clear()
		uprog[0] = "done", true, "free unloaded cell data")
	_free_tasks.append(ut)
	_task_info[ut] = ["free unloaded %s" % c, uprog]
	spawner.on_cell_unloaded(c)
	if node:
		_bury(node)
	Log.info("cell %s unloaded" % c)
	note("unload %s" % c)


## Never leave worker tasks running into shutdown (they run GDScript lambdas). Any quit (also a bare SceneTree.quit)
## passes here before the converter node exits: stop the converter first, then wait (bounded) for the workers.
func _exit_tree() -> void:
	MeshLib.cancelled = true   # workers stop at their next mesh / phase
	if converter and converter.has_method("stop"):
		converter.stop()
	var t0 := Time.get_ticks_msec()
	var tasks: Array = []
	for c in building.keys():
		if building[c]["stage"] in ["prepare", "reprep"]:
			tasks.append(building[c]["task"])
	if _size_task >= 0:
		tasks.append(_size_task)
	tasks.append_array(_free_tasks)
	for c in _far_jobs:
		tasks.append(_far_jobs[c]["task"])
	for t in tasks:
		while not WorkerThreadPool.is_task_completed(t) and Time.get_ticks_msec() - t0 < 60000:
			OS.delay_msec(5)
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
		else:
			var ti: Array = _task_info.get(t, ["?", ["?"]])
			Log.warn("world exit: worker task %d (%s, state %s) still running after 60 s" % [t, ti[0], ti[1][0]])
			_stuck = true
	Log.info("world exit: %d worker tasks finished in %d ms" % [tasks.size(), Time.get_ticks_msec() - t0])
	if _stuck:
		# never let the engine free scripts and resources under a running worker (that crashed with 0xC0000005):
		# everything worth keeping is on disk already, so the process ends here with the quit's exit code
		Log.warn("world exit: terminating the process instead of a teardown under a running worker")
		load("res://core/file_writer.gd").close()
		Log.close()
		OS.kill(OS.get_process_id())
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

## RAM / VRAM picture of the world (0.3 optimisation; logged every MEM_REPORT_S as `mem: {...}`): Godot's static
## memory, video memory, object counts, the mesh library (resident / held / released / reloaded / duplicates) and the
## per-cell data still in memory.
func memory_report() -> Dictionary:
	var d := {"static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"vram_tex_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"vram_buf_mb": snappedf(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, 0.1),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)), "resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"cells_loaded": loaded.size(), "cell_data": cell_data.size(), "col": _col.size(), "far": far.size(),
		"building": building.size(), "graveyard": _graveyard.size()}
	var col_items := 0
	for c in _col:
		for k in _col[c]["buckets"]:
			col_items += (_col[c]["buckets"][k] as Array).size()
	var heights := 0
	for c in cell_data:
		heights += (cell_data[c]["heights"] as PackedFloat32Array).size() if cell_data[c]["heights"] is PackedFloat32Array else 0
	d["col_items"] = col_items
	d["col_bodies"] = _col.values().reduce(func(a, cc): return a + (cc["bodies"] as Dictionary).size(), 0)
	d["heights_mb"] = snappedf(heights * 4 / 1048576.0, 0.1)
	d["lib"] = meshes.memory_stats() if meshes else {}
	return d


func cache_bytes() -> int:
	return _cache_bytes


func _add_bytes(n: int) -> void:
	_cache_bytes += n
	_delta_since_scan += n


## Applies a finished background folder scan: the cache size is what is on disk (+ changes made since it started).
func _poll_size() -> void:
	if _size_task >= 0 and WorkerThreadPool.is_task_completed(_size_task):
		WorkerThreadPool.wait_for_task_completion(_size_task)
		_task_info.erase(_size_task)
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
	var sprog: Array = ["queued"]
	_size_task = WorkerThreadPool.add_task(func():
		sprog[0] = "started"
		res[0] = FsUtil.dir_bytes(root)
		sprog[0] = "done", true, "cache size")
	_task_info[_size_task] = ["cache size", sprog]


func _room_for_requests() -> bool:
	var cap := Game.cache_cap_bytes
	if cap <= 0:
		return true
	var reserve := int(Sheets.sys_num("cache.reserve_mib", 600.0) * 1048576.0)
	return _cache_bytes <= cap - reserve


## Protected cells (cache.protected): within request_ring of the player, lead cells, queued or converting cells,
## cells being built, loaded cells and far cells being read.
func protected_cells() -> Dictionary:
	var out := {}
	var pp := player_pos()
	var load_r := int(Sheets.sys_num("streaming.load_ring", 1))
	var req_r := maxi(int(Sheets.sys_num("streaming.request_ring", 2)), load_r)
	for c in ring(cell_of(pp), req_r):
		out[c] = true
	for c in ring(cell_of(pp + player_vel() * Sheets.sys_num("streaming.lead_time_s", 60.0)), load_r):
		out[c] = true
	for d in [requested, building, loaded, _far_jobs]:
		for c in d:
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
	var now := Time.get_ticks_msec()
	var cands: Array = []
	for c in on_disk:
		if not prot.has(c) and int(_evict_retry.get(c, 0)) <= now:
			cands.append(c)
	cands.sort_custom(func(a, b):
		var da := cheb(a, pc)
		var db := cheb(b, pc)
		if da != db:
			return da > db
		return int(loaded_at.get(a, 0)) < int(loaded_at.get(b, 0)))
	# the folder work (busy check, size, rename) runs on a worker: a stalling disk must not freeze a frame
	if _evict_running[0] or cands.is_empty():
		return
	var items: Array = []
	for c in cands.slice(0, EVICT_PER_CALL):
		items.append([c, cell_dir(c)])
		_evicting[c] = true
	var out: Array = [[]]
	var running: Array = [true]
	var eprog: Array = ["queued"]
	var root := cache_root
	var since: float = float(converter.started_unix) - 2.0 if converter else INF
	var need := _cache_bytes - target
	_evict_running = running
	_evict_out = out
	var t := WorkerThreadPool.add_task(func():
		eprog[0] = "started"
		out[0] = _evict_work(items, root, since, need)
		eprog[0] = "done"
		running[0] = false, true, "evict cells")
	_free_tasks.append(t)
	_task_info[t] = ["evict %d cells" % items.size(), eprog]


## Worker: evicts cells of the list (farthest first) until `need` bytes are gone. Per cell
## {c, result: ok|gone|busy|fail, reason, bytes, pin, trash}.
static func _evict_work(items: Array, root: String, pin_since: float, need: int) -> Array:
	var res: Array = []
	var freed := 0
	var trash_root := root.path_join("trash")
	DirAccess.make_dir_recursive_absolute(trash_root)
	for it in items:
		var c: Vector2i = it[0]
		var dir: String = it[1]
		if freed >= need or MeshLib.cancelled:
			res.append({"c": c, "result": "skipped"})
			continue
		if not DirAccess.dir_exists_absolute(dir):
			res.append({"c": c, "result": "gone"})
			continue
		var busy := _cell_busy(dir)
		if busy != "":
			res.append({"c": c, "result": "busy", "reason": busy})
			continue
		var bytes := FsUtil.dir_bytes(dir)
		var cj := dir.path_join("cell.json")
		var pin := FileAccess.file_exists(cj) and float(FileAccess.get_modified_time(cj)) >= pin_since
		var trash := trash_root.path_join("cell_%d_%d_%d" % [c.x, c.y, Time.get_ticks_usec()])
		var err := DirAccess.rename_absolute(dir, trash)
		if err != OK:
			res.append({"c": c, "result": "busy", "reason": "folder in use (rename error %d)" % err})
			continue
		freed += bytes
		res.append({"c": c, "result": "ok", "bytes": bytes, "pin": pin, "trash": trash})
	return res


## Main thread: applies a finished eviction worker.
func _poll_evict() -> void:
	if _evict_out.is_empty() or _evict_running[0]:
		return
	var res: Array = _evict_out[0]
	_evict_out = []
	var any := false
	for r in res:
		var c: Vector2i = r["c"]
		_evicting.erase(c)
		match str(r["result"]):
			"gone":
				on_disk.erase(c)
				Log.info("cell %s is no longer on disk (removed by another game instance); dropped from the cache list" % c)
			"busy":
				_evict_retry[c] = Time.get_ticks_msec() + EVICT_RETRY_MS
				Log.info("cell %s not evicted now: %s (retry in %d s)" % [c, r.get("reason", "?"), EVICT_RETRY_MS / 1000])
			"ok":
				any = true
				if bool(r["pin"]):
					_trash_pin.append(str(r["trash"]))
				if loaded.has(c):
					_unload(c)
				_evict_retry.erase(c)
				_add_bytes(-int(r["bytes"]))
				on_disk.erase(c)
				Log.info("cell %s evicted (%d bytes, cache %d, cap %d)" % [c, int(r["bytes"]), _cache_bytes, Game.cache_cap_bytes])
				note("evict %s" % c)
				Game.cell_evicted.emit(c)
	if any:
		_empty_trash()
		_gc_needed = true
		_query_status()


## A cell folder leaves in one step: it is renamed into <cache>/trash (Windows refuses that while any file in it is
## open - the converter writing it, a reader in another game instance) and the trash is deleted on a worker. So a
## cell is either complete on disk or gone, never a folder without cell.json (F10: "build failed: cell.json missing").
## A cell that cannot go now is skipped for EVICT_RETRY_MS with the reason logged.
func evict(c: Vector2i) -> void:
	var dir := cell_dir(c)
	if not DirAccess.dir_exists_absolute(dir):
		on_disk.erase(c)
		Log.info("cell %s is no longer on disk (removed by another game instance); dropped from the cache list" % c)
		return
	var busy := _cell_busy(dir)
	if busy != "":
		_evict_retry[c] = Time.get_ticks_msec() + EVICT_RETRY_MS
		Log.info("cell %s not evicted now: %s (retry in %d s)" % [c, busy, EVICT_RETRY_MS / 1000])
		return
	var bytes := FsUtil.dir_bytes(dir)
	var cj := dir.path_join("cell.json")
	# converted by the running converter: its meshes stay (the converter would not write them again); the cell.json
	# (MBs) is parsed by the trash worker, not here
	var pin: bool = converter != null and FileAccess.file_exists(cj) and float(FileAccess.get_modified_time(cj)) >= float(converter.started_unix) - 2.0
	var trash_root := cache_root.path_join("trash")
	DirAccess.make_dir_recursive_absolute(trash_root)
	var trash := trash_root.path_join("cell_%d_%d_%d" % [c.x, c.y, Time.get_ticks_usec()])
	var err := DirAccess.rename_absolute(dir, trash)
	if err != OK:
		_evict_retry[c] = Time.get_ticks_msec() + EVICT_RETRY_MS
		Log.info("cell %s not evicted now: folder in use (rename error %d, retry in %d s)" % [c, err, EVICT_RETRY_MS / 1000])
		return
	if pin:
		_trash_pin.append(trash)
	if loaded.has(c):
		_unload(c)   # only a direct call (dev tools); enforce_cap() never picks a loaded cell
	_evict_retry.erase(c)
	_add_bytes(-bytes)
	on_disk.erase(c)
	Log.info("cell %s evicted (%d bytes, cache %d, cap %d)" % [c, bytes, _cache_bytes, Game.cache_cap_bytes])
	note("evict %s" % c)
	Game.cell_evicted.emit(c)
	_empty_trash()


## Why a cell folder must not go now ("" = it may): a converter's temporary file in it or a write in the last
## EVICT_FRESH_S seconds (a converter - this game's or another instance's - is still writing it).
static func _cell_busy(dir: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return "folder not readable"
	var now := Time.get_unix_time_from_system()
	for f in d.get_files():
		var ext := f.get_extension().to_lower()
		if ext == "tmp" or ext == "part":
			return "converter file %s in it" % f
		if now - float(FileAccess.get_modified_time(dir.path_join(f))) < EVICT_FRESH_S:
			return "written %d s ago" % int(now - float(FileAccess.get_modified_time(dir.path_join(f))))
	return ""


## Deletes <cache>/trash on a worker (cell folders renamed there by evict(); leftovers from a crash are retried at the
## next eviction). Pinned folders' cell.json are read first; _poll_trash() pins their meshes. The cache size follows
## from the next folder scan.
func _empty_trash() -> void:
	var trash_root := cache_root.path_join("trash")
	if not DirAccess.dir_exists_absolute(trash_root) or _trash_running[0]:
		return
	var pins := _trash_pin.duplicate()
	_trash_pin.clear()
	var tprog: Array = ["queued"]
	var running: Array = [true]
	var out: Array = [{}]
	_trash_running = running
	_trash_out = out
	var t := WorkerThreadPool.add_task(func():
		tprog[0] = "started"
		var m := {}
		var tx := {}
		for p in pins:
			var info = FsUtil.read_json(str(p).path_join("cell.json"))
			if typeof(info) == TYPE_DICTIONARY:
				_cell_refs(info, m, tx)
		out[0] = {"meshes": m, "tex": tx}
		for sub in DirAccess.get_directories_at(trash_root):
			FsUtil.remove_tree(trash_root.path_join(sub), trash_root)
		tprog[0] = "done"
		running[0] = false, true, "empty cache trash")
	_free_tasks.append(t)
	_task_info[t] = ["empty cache trash", tprog]


## Main thread: pins the meshes of evicted cells the running converter made; trash that came in meanwhile goes next.
func _poll_trash() -> void:
	if _trash_running[0]:
		return
	if not _trash_out.is_empty():
		var r: Dictionary = _trash_out[0]
		_trash_out = []
		_pinned_meshes.merge(r.get("meshes", {}))
		_pinned_tex.merge(r.get("tex", {}))
	if not _trash_pin.is_empty():
		_empty_trash()


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
## the converter is idle and no conversion is requested; otherwise it is retried). Reading every cell.json and
## deleting runs on a worker (on the main thread it was a 50 ms frame with a full cache); _poll_mesh_gc() then drops
## the deleted meshes from the library.
func _mesh_gc() -> void:
	# evicted cells' pins must be in first (the trash worker reads them)
	if not requested.is_empty() or _gc_running[0] or _trash_running[0] or not _trash_pin.is_empty() or not _trash_out.is_empty():
		return
	_gc_needed = false
	var dirs: Array = []
	for c in on_disk:
		dirs.append(cell_dir(c))
	var used := _pinned_meshes.duplicate()
	var used_tex := _pinned_tex.duplicate()
	var root := cache_root
	var since := Time.get_unix_time_from_system() - 5.0
	var out: Array = [{}]
	var running: Array = [true]
	var gprog: Array = ["queued"]
	_gc_running = running
	_gc_out = out
	var t := WorkerThreadPool.add_task(func():
		gprog[0] = "started"
		out[0] = _mesh_gc_work(root, dirs, used, used_tex, since)
		gprog[0] = "done"
		running[0] = false, true, "mesh gc")
	_free_tasks.append(t)
	_task_info[t] = ["mesh gc", gprog]
	note("mesh gc started")


## Main thread: applies a finished mesh GC (library entries of deleted meshes, cache size).
func _poll_mesh_gc() -> void:
	if _gc_out.is_empty() or _gc_running[0]:
		return
	var r: Dictionary = _gc_out[0]
	_gc_out = []
	for id in r.get("forget", []):
		meshes.forget(str(id))
	note("mesh gc applied (%d meshes dropped)" % (r.get("forget", []) as Array).size())
	_add_bytes(-int(r.get("freed", 0)))
	if r.has("kept"):
		Log.info("mesh gc: %s, nothing removed" % r["kept"])
	elif int(r.get("removed", 0)) > 0:
		Log.info("mesh gc: removed %d unreferenced meshes/textures (%d bytes)" % [int(r["removed"]), int(r["freed"])])


## Worker: files written after `since` (a conversion that started meanwhile) are kept.
static func _mesh_gc_work(root: String, dirs: Array, used: Dictionary, used_tex: Dictionary, since: float) -> Dictionary:
	for dir in dirs:
		if MeshLib.cancelled:
			return {"kept": "cancelled"}
		if not DirAccess.dir_exists_absolute(str(dir)):
			continue   # evicted since the GC started: its meshes are not needed for it
		var info = FsUtil.read_json(str(dir).path_join("cell.json"))
		if typeof(info) != TYPE_DICTIONARY:
			return {"kept": "unreadable %s/cell.json" % str(dir).get_file()}   # the next eviction asks again
		_cell_refs(info, used, used_tex)
	var forget: Array = []
	var removed := 0
	var freed := 0
	var mdir := root.path_join("hzd/meshes")
	for f in DirAccess.get_files_at(mdir):
		if not f.ends_with(".glb") or used.has(f.get_basename()):
			continue
		var p := mdir.path_join(f)
		if float(FileAccess.get_modified_time(p)) >= since:
			continue
		var sz := FsUtil.file_bytes(p)
		if DirAccess.remove_absolute(p) == OK:
			removed += 1
			freed += sz
			forget.append(f.get_basename())
	# textures referenced by meshes: keep the ones any remaining cell.json lists in `textures`
	var tdir := root.path_join("hzd/textures")
	if not used_tex.is_empty():
		for f in DirAccess.get_files_at(tdir):
			if used_tex.has(f.get_basename()) or used_tex.has(f) or f.ends_with(".tmp"):
				continue
			var tp := tdir.path_join(f)
			if not FileAccess.file_exists(tp) or float(FileAccess.get_modified_time(tp)) >= since:
				continue
			var sz2 := FsUtil.file_bytes(tp)
			if DirAccess.remove_absolute(tp) == OK:
				removed += 1
				freed += sz2
	return {"forget": forget, "removed": removed, "freed": freed}
