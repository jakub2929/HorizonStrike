extends Node
## Cell loading profile (0.2 H1). Always: one log line per inserted cell with its phase times. With --profile-cells:
## vsync off, after the start area is in it walks perf.route_cells (teleport into each next cell once the current one
## is in), writes <logs>/cell_phases.csv and logs `cell phases: top=<phase> <ms>`; --quit-after-cells N quits after N
## inserted cells. Worker phases run off the main thread (they cost no frame time); main-thread phases and the frame
## times around an insertion are what a player feels.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const Paths := preload("res://core/paths.gd")

const POST_FRAMES := 5          # frames after add_child that count as "first draw" (shader compile, uploads)

const WORKER_COLS := ["read_json", "terrain", "terrain_tex", "instances", "scatter", "mesh_parse", "mesh_lod", "tex_decode"]
const MAIN_COLS := ["mesh_upload", "tex_upload", "terrain", "terrain_collision", "multimesh", "collision", "instantiate_other", "add_child", "first_draw"]

var world: Node3D
var profile := false
var quit_after := 0
var rows: Array = []                 # finished rows (Dictionary)
var _active := {}                    # Vector2i -> row being measured
var _last_usec := 0
var _route: Array = []
var _route_i := -1
var _route_wait := 0.0
var _start_done := false
var vram_start_mb := -1.0


func _ready() -> void:
	process_priority = -100          # measure the frame before other nodes run this frame
	if profile:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		for c in Sheets.sys("perf.route_cells"):
			_route.append(Vector2i(int(c[0]), int(c[1])))
		Log.info("cell profiler: on (route %d cells, quit after %d cells, window %s, vsync off)" % [_route.size(), quit_after, DisplayServer.window_get_size()])


## A cell build started (worker prepare queued).
func begin(c: Vector2i) -> void:
	_active[c] = {"cell": "%d_%d" % [c.x, c.y], "t0": Time.get_ticks_msec(), "worst_frame_ms": 0.0, "post": -1,
		"first_draw": 0.0, "mesh_upload": 0.0, "tex_upload": 0.0}


func add_main(c: Vector2i, key: String, ms: float) -> void:
	if _active.has(c):
		_active[c][key] = float(_active[c].get(key, 0.0)) + ms


## The cell node was added to the tree: phases from the builder, worker times, counts.
func inserted(c: Vector2i, phases: Dictionary, worker: Dictionary, prepare_wall_ms: float, instantiate_ms: float, add_child_ms: float, counts: Dictionary) -> void:
	if not _active.has(c):
		return
	var r: Dictionary = _active[c]
	for k in WORKER_COLS:
		r["w_" + k] = float(worker.get(k, 0.0))
	r["prepare_wall"] = prepare_wall_ms
	r["mesh_upload"] = float(r["mesh_upload"]) + float(phases.get("mesh_upload", 0.0))
	for k in ["terrain", "terrain_collision", "multimesh", "collision"]:
		r[k] = float(phases.get(k, 0.0))
	var known := float(phases.get("terrain", 0.0)) + float(phases.get("terrain_collision", 0.0)) + float(phases.get("multimesh", 0.0)) + float(phases.get("collision", 0.0)) + float(phases.get("mesh_upload", 0.0))
	r["instantiate_other"] = maxf(instantiate_ms - known, 0.0)
	r["add_child"] = add_child_ms
	r["post"] = 0
	r.merge(counts)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := (now - _last_usec) / 1000.0 if _last_usec > 0 else 0.0
	_last_usec = now
	if profile and dt > float(Sheets.sys_num("perf.max_load_frame_ms", 50.0)) and Game.is_world_ready:
		Log.info("slow frame %.1f ms; machines %d; previous streaming work: %s; physics %.1f ms, process %.1f ms" % [dt, Game.machines.size(), world.last_work,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	for c in _active.keys():
		var r: Dictionary = _active[c]
		r["worst_frame_ms"] = maxf(float(r["worst_frame_ms"]), dt)
		if int(r["post"]) >= 0:
			if int(r["post"]) > 0:
				r["first_draw"] = maxf(float(r["first_draw"]), dt)
			r["post"] = int(r["post"]) + 1
			if int(r["post"]) > POST_FRAMES:
				_active.erase(c)
				_finish(r)
	if profile:
		_walk(_delta)


func _finish(r: Dictionary) -> void:
	r["load_ms"] = Time.get_ticks_msec() - int(r["t0"])
	var main_total := 0.0
	for k in MAIN_COLS:
		main_total += float(r.get(k, 0.0))
	r["main_total"] = main_total
	rows.append(r)
	Log.info("cell phases %s: worst frame %.1f ms | main %s | worker %s" % [r["cell"], r["worst_frame_ms"],
		", ".join(MAIN_COLS.map(func(k): return "%s %.1f" % [k, float(r.get(k, 0.0))])),
		", ".join(WORKER_COLS.map(func(k): return "%s %.1f" % [k, float(r.get("w_" + k, 0.0))]))])
	if profile and quit_after > 0 and rows.size() >= quit_after:
		write_csv()
		if Game.main and Game.main.has_method("quit_game"):
			Game.main.quit_game(0)


## Writes <logs>/cell_phases.csv and logs the top main-thread phase (largest single-cell value).
func write_csv() -> String:
	var path := Paths.logs_dir().path_join("cell_phases.csv")
	var cols := ["cell", "load_ms", "worst_frame_ms", "main_total"] + MAIN_COLS + WORKER_COLS.map(func(k): return "w_" + k) + ["prepare_wall", "instances", "vegetation", "shapes", "bodies"]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		Log.warn("cell profiler: cannot write %s" % path)
		return ""
	f.store_line(",".join(cols))
	for r in rows:
		f.store_line(",".join(cols.map(func(k): return (str(r.get(k, "")) if k == "cell" else ("%.1f" % float(r.get(k, 0.0)))))))
	f.close()
	var top := ""
	var top_ms := -1.0
	for k in MAIN_COLS:
		for r in rows:
			if float(r.get(k, 0.0)) > top_ms:
				top_ms = float(r.get(k, 0.0))
				top = k
	var worst := 0.0
	for r in rows:
		worst = maxf(worst, float(r["worst_frame_ms"]))
	Log.info("cell phases: top=%s %.1f ms (worst frame %.1f ms over %d cells, vram at start %.0f MB) -> %s" % [top, top_ms, worst, rows.size(), vram_start_mb, path])
	return path


# ------------------------------------------------------------------ route walk (--profile-cells)

func _walk(delta: float) -> void:
	if not Game.is_world_ready or Game.player == null or world == null:
		return
	if not _start_done:
		# start area: every cell of the load ring around the player is in and nothing is building
		var pc: Vector2i = world.cell_of(Game.player.global_position)
		for c in world.ring(pc, int(Sheets.sys_num("streaming.load_ring", 1))):
			if world.on_disk.has(c) and not world.is_cell_loaded(c):
				return
		if not world.building.is_empty():
			return
		_route_wait += delta
		if _route_wait < 2.0:
			return
		_start_done = true
		vram_start_mb = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
		Log.info("vram at start: %.0f MB (texture %.0f MB, buffer %.0f MB)" % [vram_start_mb,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0])
		_route_wait = 0.0
		_route_i = 0
		Game.player.set("invulnerable", true)
		_go(_route_i)
		return
	if _route_i < 0 or _route_i >= _route.size():
		return
	var want: Vector2i = _route[_route_i]
	if not world.is_cell_loaded(want) or not world.building.is_empty():
		_route_wait = 0.0
		return
	_route_wait += delta
	if _route_wait < 1.5:
		return
	_route_wait = 0.0
	_route_i += 1
	if _route_i < _route.size():
		_go(_route_i)
	else:
		Log.info("cell profiler: route done (%d cells inserted)" % rows.size())
		if quit_after > 0:
			write_csv()
			if Game.main and Game.main.has_method("quit_game"):
				Game.main.quit_game(0)


func _go(i: int) -> void:
	var c: Vector2i = _route[i]
	var p: Vector3 = world.cell_origin(c) + Vector3(world.cell_size * 0.5, -1000.0, world.cell_size * 0.5)
	Log.info("cell profiler: route %d/%d -> cell %s" % [i + 1, _route.size(), c])
	Game.teleport(p)
