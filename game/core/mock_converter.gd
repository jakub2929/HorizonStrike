extends Node
## In-process stand-in for `hzsconv serve` used with --mock-data. Same interface and events as converter_client.gd
## (bootstrap/cell/cancel/status/quit -> progress/done/error/cancelled/status/bye), work runs on a worker thread and
## writes synthetic content (core/mock_data.gd) into the cache with the converter's layout.

signal event_received(evt: Dictionary)

const Log := preload("res://core/log.gd")
const MockData := preload("res://core/mock_data.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Sheets := preload("res://core/sheets.gd")

var pid := 0
var started_unix := 0.0   # same field as converter_client.gd
var cache_root := ""
var cell_size := 512.0
var cell_delay_ms := 150
var pad_bytes := 0
var seed_cache := ""   ## real content to copy in (cs2/, hzd/machines/, resolved json), read-only source

var _thread: Thread
var _sem := Semaphore.new()
var _mutex := Mutex.new()
var _jobs: Array = []          # [{id, op, cell: Vector2i, prio, seq, radius}]
var _running_cells := {}
var _events: Array = []
var _quit := false
var _bootstrapped := false
var _seq := 0
var _next_id := 1
var _mesh_bytes := 0


func start(root: String) -> String:
	cache_root = root
	started_unix = Time.get_unix_time_from_system()
	DirAccess.make_dir_recursive_absolute(root)
	# placeholder glTF meshes are made here on the main thread (they need RenderingServer resources)
	_mesh_bytes = MockData.write_meshes(root)
	_thread = Thread.new()
	_thread.start(_worker)
	Log.info("mock converter started (cache %s)" % root)
	return ""


func is_running() -> bool:
	return _thread != null and not _quit


func send(req: Dictionary) -> int:
	if not req.has("id"):
		req["id"] = _next_id
		_next_id += 1
	var id := int(req["id"])
	var op := str(req.get("op", ""))
	_mutex.lock()
	match op:
		"bootstrap":
			_jobs.append({"id": id, "op": "bootstrap", "prio": -1000000, "seq": _seq, "radius": int(req.get("radius", 1))})
		"cell":
			var c: Array = req.get("cell", [0, 0])
			var key := Vector2i(int(c[0]), int(c[1]))
			var prio := int(req.get("prio", 0))
			var found := false
			for j in _jobs:
				if j["op"] == "cell" and j["cell"] == key:
					j["prio"] = prio
					found = true
			if not found and not _running_cells.has(key):
				_jobs.append({"id": id, "op": "cell", "cell": key, "prio": prio, "seq": _seq})
		"cancel":
			var c2: Array = req.get("cell", [0, 0])
			var key2 := Vector2i(int(c2[0]), int(c2[1]))
			for j in _jobs.duplicate():
				if j["op"] == "cell" and j["cell"] == key2:
					_jobs.erase(j)
					_events.append({"id": j["id"], "event": "cancelled", "cell": [key2.x, key2.y]})
		"status":
			_jobs.append({"id": id, "op": "status", "prio": -2000000, "seq": _seq})
		"quit":
			_events.append({"id": id, "event": "bye"})
			_quit = true
		_:
			_events.append({"id": id, "event": "error", "message": "unknown op '%s'" % op})
	_seq += 1
	_mutex.unlock()
	_sem.post()
	return id


func _next_job() -> Dictionary:
	_mutex.lock()
	var best := -1
	for i in _jobs.size():
		var j: Dictionary = _jobs[i]
		if j["op"] == "cell" and not _bootstrapped:
			continue
		if best < 0:
			best = i
			continue
		var b: Dictionary = _jobs[best]
		if j["prio"] < b["prio"] or (j["prio"] == b["prio"] and j["seq"] < b["seq"]):
			best = i
	var job: Dictionary = {}
	if best >= 0:
		job = _jobs[best]
		_jobs.remove_at(best)
		if job["op"] == "cell":
			_running_cells[job["cell"]] = true
	_mutex.unlock()
	return job


func _emit(e: Dictionary) -> void:
	_mutex.lock()
	_events.append(e)
	_mutex.unlock()


func _worker() -> void:
	while not _quit:
		_sem.wait()
		while not _quit:
			var job := _next_job()
			if job.is_empty():
				break
			match str(job["op"]):
				"bootstrap":
					_do_bootstrap(job)
				"cell":
					var c: Vector2i = job["cell"]
					OS.delay_msec(cell_delay_ms)
					var bytes := MockData.write_cell(cache_root, c.x, c.y, cell_size, pad_bytes)
					_mutex.lock()
					_running_cells.erase(c)
					_mutex.unlock()
					_emit({"id": job["id"], "event": "done", "ok": true, "bytes": bytes, "cell": [c.x, c.y]})
				"status":
					var b := FsUtil.dir_bytes(cache_root)
					_mutex.lock()
					var pending := 0
					for j in _jobs:
						if j["op"] == "cell":
							pending += 1
					var e := {"id": job["id"], "event": "status", "bytes": b, "pending": pending,
						"running": _running_cells.size(), "bootstrapped": _bootstrapped}
					_events.append(e)
					_mutex.unlock()


func _do_bootstrap(job: Dictionary) -> void:
	var id: int = job["id"]
	var bytes := 0
	_emit({"id": id, "event": "progress", "stage": "weapons", "done": 0, "total": 1})
	if seed_cache != "":
		for rel in ["cs2", "hzd/machines", "hzd/audio", "hzd/cells", "hzd/meshes", "hzd/textures"]:
			bytes += FsUtil.copy_tree(seed_cache.path_join(rel), cache_root.path_join(rel))
		for rel in ["hzd/machines.json", "hzd/systems.json", "hzd/index.json"]:
			if FileAccess.file_exists(seed_cache.path_join(rel)) and not FileAccess.file_exists(cache_root.path_join(rel)):
				DirAccess.copy_absolute(seed_cache.path_join(rel), cache_root.path_join(rel))
		Log.info("mock: seeded real content from %s (%d bytes)" % [seed_cache, bytes])
	FsUtil.write_json_atomic(cache_root.path_join("manifest.json"), {"format": 1, "converter": "mock", "mock": true, "seed": seed_cache})
	if not FileAccess.file_exists(cache_root.path_join("cs2/weapons.json")):
		FsUtil.write_json_atomic(cache_root.path_join("cs2/weapons.json"), MockData.weapons_json())
	_emit({"id": id, "event": "progress", "stage": "weapons", "done": 1, "total": 1})
	var ids := Sheets.machine_ids()
	for i in ids.size():
		_emit({"id": id, "event": "progress", "stage": "machines", "done": i, "total": ids.size()})
		var mp := cache_root.path_join("hzd/machines/%s/meta.json" % ids[i])
		if not FileAccess.file_exists(mp):
			FsUtil.write_json_atomic(mp, MockData.machine_meta(ids[i]))
	_emit({"id": id, "event": "progress", "stage": "machines", "done": ids.size(), "total": ids.size()})
	_emit({"id": id, "event": "progress", "stage": "audio", "done": 1, "total": 1})
	bytes += _mesh_bytes
	var index: Dictionary = {}
	var existing = FsUtil.read_json(cache_root.path_join("hzd/index.json"))
	if typeof(existing) == TYPE_DICTIONARY and existing.has("start_cell"):
		index = existing   # seeded real index
	else:
		index = MockData.index_json(cell_size)
		FsUtil.write_json_atomic(cache_root.path_join("hzd/index.json"), index)
	_emit({"id": id, "event": "progress", "stage": "index", "done": 1, "total": 1})
	_mutex.lock()
	_bootstrapped = true
	_mutex.unlock()
	_sem.post()
	var sc: Array = index["start_cell"]
	var r: int = job.get("radius", 0)
	var cells: Array = []
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			cells.append(Vector2i(int(sc[0]) + dx, int(sc[1]) + dy))
	cells.sort_custom(func(a, b): return absi(a.x - int(sc[0])) + absi(a.y - int(sc[1])) < absi(b.x - int(sc[0])) + absi(b.y - int(sc[1])))
	for i in cells.size():
		_emit({"id": id, "event": "progress", "stage": "start-area", "done": i, "total": cells.size()})
		var c: Vector2i = cells[i]
		if not DirAccess.dir_exists_absolute(cache_root.path_join("hzd/cells/%d_%d" % [c.x, c.y])):
			OS.delay_msec(cell_delay_ms)
			bytes += MockData.write_cell(cache_root, c.x, c.y, cell_size, pad_bytes)
	_emit({"id": id, "event": "progress", "stage": "start-area", "done": cells.size(), "total": cells.size()})
	_emit({"id": id, "event": "done", "ok": true, "bytes": bytes})


func _process(_delta: float) -> void:
	if _events.is_empty():
		return
	_mutex.lock()
	var batch := _events.duplicate()
	_events.clear()
	_mutex.unlock()
	for e in batch:
		event_received.emit(e)


func stop() -> void:
	if _thread == null:
		return
	_quit = true
	_sem.post()
	if _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


func _exit_tree() -> void:
	stop()
