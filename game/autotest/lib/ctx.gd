extends RefCounted
## Shared context for scenarios: Game API access, waiting helpers, signal recording, screenshots, oracle.

const Args := preload("res://autotest/lib/args.gd")
const Oracle := preload("res://autotest/lib/oracle.gd")
const Frame := preload("res://autotest/lib/frame.gd")
const Proc := preload("res://autotest/lib/proc.gd")

const MIB := 1048576


class Rec:
	## records the emissions of one or more signals: [{t, args}]
	var events: Array = []
	var t0 := 0

	func _init() -> void:
		t0 = Time.get_ticks_msec()

	func on(a: Variant = null, b: Variant = null, c: Variant = null, d: Variant = null) -> void:
		events.append({"t": (Time.get_ticks_msec() - t0) / 1000.0, "args": [a, b, c, d]})


class ErrLogger extends Logger:
	## collects engine/script errors so a scenario's details can show them
	var mutex := Mutex.new()
	var errors: Array = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		mutex.lock()
		if errors.size() < 40:
			errors.append("%s:%d %s: %s %s" % [file.get_file(), line, function, code, rationale])
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func take() -> Array:
		mutex.lock()
		var out := errors
		errors = []
		mutex.unlock()
		return out


var runner: Node
var tree: SceneTree
var args
var oracle
var out_dir := ""
var is_child := false
var run_start_unix := 0
var world_ready_seen := false
var world_ready_t := -1.0
var errlog := ErrLogger.new()
var wanted := PackedStringArray()  # ids requested in this process (scenarios may host other rows, e.g. s02 in t05)
var extra_results := {}  # id -> {pass, details} produced by a hosting scenario
var _conns: Array = []  # [signal, callable] connected during the current scenario
var _log_file: FileAccess


func _init(p_runner: Node, p_args, p_out_dir: String, p_is_child: bool) -> void:
	runner = p_runner
	tree = p_runner.get_tree()
	args = p_args
	out_dir = p_out_dir
	is_child = p_is_child
	run_start_unix = int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(out_dir)
	_log_file = FileAccess.open(out_dir.path_join("autotest.log"), FileAccess.WRITE)
	OS.add_logger(errlog)


func close() -> void:
	OS.remove_logger(errlog)
	if _log_file:
		_log_file.close()


func note(msg: String) -> void:
	var line := "[autotest %s] %s" % [Time.get_time_string_from_system(), msg]
	print(line)
	if _log_file:
		_log_file.store_line(line)
		_log_file.flush()


# --- Game API access -------------------------------------------------------------------------------------------

var game: Node:
	get:
		return tree.root.get_node_or_null("Game")

var player: Node:
	get:
		var g := game
		return g.get("player") if g != null and "player" in g else null


func camera() -> Camera3D:
	return runner.get_viewport().get_camera_3d()


func missing_api(obj: Object, props: Array, methods: Array = [], signals: Array = []) -> Array:
	## names of documented Game API members that `obj` lacks (obj == null -> all of them)
	var out := []
	var label := "Game" if obj == game else ("player" if obj == player else (str(obj.get("machine_type")) if obj != null and "machine_type" in obj else "node"))
	for p in props:
		if obj == null or not (p in obj):
			out.append("%s.%s" % [label, p])
	for m in methods:
		if obj == null or not obj.has_method(m):
			out.append("%s.%s()" % [label, m])
	for s in signals:
		if obj == null or not obj.has_signal(s):
			out.append("%s signal %s" % [label, s])
	return out


func call_api(obj: Object, method: String, call_args: Array = []) -> Variant:
	## calls a Game API method; awaits it when it is a coroutine; null when missing
	if obj == null or not obj.has_method(method):
		note("API missing: %s()" % method)
		return null
	return await obj.callv(method, call_args)


func record(obj: Object, sig: String) -> Rec:
	var rec := Rec.new()
	if obj != null and obj.has_signal(sig):
		var c := Callable(rec, "on")
		obj.connect(sig, c)
		_conns.append([obj, sig, c])
	return rec


func disconnect_all() -> void:
	for c in _conns:
		if is_instance_valid(c[0]) and c[0].is_connected(c[1], c[2]):
			c[0].disconnect(c[1], c[2])
	_conns.clear()


# --- waiting ---------------------------------------------------------------------------------------------------

func frames(n: int = 1) -> void:
	for i in n:
		await tree.process_frame


func physics_frames(n: int = 1) -> void:
	for i in n:
		await tree.physics_frame


func wait(seconds: float) -> void:
	if seconds <= 0.0:
		await tree.process_frame
		return
	await tree.create_timer(seconds, true, false, true).timeout


func wait_until(cond: Callable, timeout_s: float) -> bool:
	var t_end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while true:
		if cond.call():
			return true
		if Time.get_ticks_msec() >= t_end:
			return false
		await tree.process_frame
	return false


func in_thread(fn: Callable) -> Variant:
	## runs fn on a worker thread (disk walks, netstat) so the game keeps rendering; returns fn's result
	var th := Thread.new()
	th.start(fn)
	while th.is_alive():
		await tree.process_frame
	return th.wait_to_finish()


func run_cmd(path: String, cmd_args: PackedStringArray) -> Dictionary:
	## OS.execute on a worker thread; {code, out}
	var fn := func() -> Dictionary:
		var out := []
		var code := OS.execute(path, cmd_args, out, true)
		return {"code": code, "out": "".join(out)}
	return await in_thread(fn)


func need_world(timeout_s: float) -> bool:
	## waits for Game.world_ready (playable); remembered once seen
	if not world_ready_seen and _ready_property() != "":
		_mark_world_ready("property " + _ready_property())
	if world_ready_seen:
		return true
	note("waiting for world_ready (up to %d s)" % int(timeout_s))
	var ok := await wait_until(func(): return world_ready_seen or _ready_property() != "", timeout_s)
	if ok and not world_ready_seen:
		_mark_world_ready("property " + _ready_property())
	return ok


func _ready_property() -> String:
	var g := game
	if g != null:
		for p in ["world_is_ready", "is_world_ready"]:
			if p in g and g.get(p) == true:
				return p
	return ""


func _mark_world_ready(how: String) -> void:
	if world_ready_seen:
		return
	world_ready_seen = true
	world_ready_t = Time.get_ticks_msec() / 1000.0
	note("world ready (%s) at %.1f s after engine start" % [how, world_ready_t])


func on_world_ready(_a: Variant = null) -> void:
	_mark_world_ready("signal")


# --- geometry / placement ---------------------------------------------------------------------------------------

func cell_of(pos: Vector3) -> Variant:
	## cell id of a world position from the game (Game.cell_of or Game.world.cell_of); null when not exposed
	var g := game
	if g == null:
		return null
	if g.has_method("cell_of"):
		return v2i(g.call("cell_of", pos))
	var w: Variant = g.get("world") if "world" in g else null
	if w is Object and w.has_method("cell_of"):
		return v2i(w.call("cell_of", pos))
	return null


func set_cache_cap(bytes: int) -> void:
	## runtime cap without persisting it to settings.json when the game offers that
	var g := game
	if g.has_method("set_cache_cap"):
		g.call("set_cache_cap", bytes, false)
	else:
		g.set("cache_cap_bytes", bytes)


func read_wheel() -> Dictionary:
	## buy wheel as displayed: {source, items: [{id, price}]}. Game.buy_wheel_items() if it exists, else the wheel's
	## visible UI nodes "BuyItem_<id>" with a "Price" label, else Game.buy_wheel_item_ids() (ids only, price -1)
	var g := game
	var items := []
	if g != null and g.has_method("buy_wheel_items"):
		for it in await call_api(g, "buy_wheel_items"):
			if it is Dictionary:
				items.append({"id": str(it.get("id")), "price": int(it.get("price", -1))})
		return {"source": "Game.buy_wheel_items()", "items": items}
	for n in tree.root.find_children("BuyItem_*", "", true, false):
		if n is CanvasItem and (n as CanvasItem).is_visible_in_tree():
			var price := -1
			var pl := n.get_node_or_null("Price")
			if pl != null:
				var t := str(pl.get("text")).strip_edges().trim_prefix("$").replace(",", "")
				price = int(t) if t.is_valid_int() else -1
			items.append({"id": str(n.name).trim_prefix("BuyItem_"), "price": price})
	if not items.is_empty():
		return {"source": "wheel UI nodes BuyItem_<id>/Price", "items": items}
	if g != null and g.has_method("buy_wheel_item_ids"):
		for id in await call_api(g, "buy_wheel_item_ids"):
			items.append({"id": str(id), "price": -1})
		return {"source": "Game.buy_wheel_item_ids() (no prices)", "items": items}
	return {"source": "none", "items": items}


func hit_evidence(dmg_rec: Rec, hud_rec: Rec) -> Array:
	## player hits seen during a scenario: the player_damaged signal, or the game's "Hit: ..." HUD message that it
	## emits for an invulnerable player
	var out := []
	for e in dmg_rec.events:
		out.append("player_damaged %s" % str(e.args[0]))
	for e in hud_rec.events:
		if str(e.args[0]).begins_with("Hit"):
			out.append(str(e.args[0]))
	return out

func forward() -> Vector3:
	## horizontal view direction of the player camera
	var cam := camera()
	var f := Vector3.FORWARD
	if cam != null:
		f = -cam.global_transform.basis.z
	elif player is Node3D:
		f = -(player as Node3D).global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.FORWARD


func player_pos() -> Vector3:
	return (player as Node3D).global_position if player is Node3D else Vector3.ZERO


func spawn_ahead(machine_type: String, dist_m: float, angle_deg: float = 0.0, ai: bool = false, base_dir: Vector3 = Vector3.ZERO) -> Node:
	## spawns dist_m from the player, angle_deg off base_dir (default: current view). Scenarios that spawn several
	## machines pass one base_dir so a later spawn never lands on an earlier (dead) one after aim_at turned the view.
	var base := base_dir if base_dir.length() > 0.001 else forward()
	var dir := base.rotated(Vector3.UP, deg_to_rad(angle_deg))
	var pos := player_pos() + dir * dist_m
	var m: Variant = await call_api(game, "spawn_machine", [machine_type, pos])
	if m is Node:
		if "ai_enabled" in m:
			m.set("ai_enabled", ai)
		note("spawned %s at %s (%.1f m, ai=%s)" % [machine_type, str(pos), dist_m, str(ai)])
		return m
	note("spawn_machine(%s) returned %s" % [machine_type, str(m)])
	return null


func ground_y(x: float, z: float, from_y: float = 3000.0) -> Variant:
	## terrain/static height under (x, z) from the loaded collision; null when nothing is loaded there
	await physics_frames(1)
	var world := runner.get_viewport().get_world_3d()
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, -3000.0, z))
	q.exclude = player_rids()
	var hit := world.direct_space_state.intersect_ray(q)
	return null if hit.is_empty() else float(hit.position.y)


func player_rids() -> Array[RID]:
	var out: Array[RID] = []
	var p := player
	if p is CollisionObject3D:
		out.append((p as CollisionObject3D).get_rid())
	if p != null:
		for c in p.find_children("*", "CollisionObject3D", true, false):
			out.append((c as CollisionObject3D).get_rid())
	return out


func machines_of(machine_type: String) -> Array:
	var out := []
	var g := game
	if g == null or not ("machines" in g):
		return out
	for m in g.get("machines"):
		if is_instance_valid(m) and str(m.get("machine_type")) == machine_type:
			out.append(m)
	return out


static func chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


static func v2i(v: Variant) -> Vector2i:
	if v is Vector2i:
		return v
	if v is Vector2:
		return Vector2i(int(v.x), int(v.y))
	if v is Array and v.size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	return Vector2i(2147483647, 2147483647)


static func v3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.INF


# --- screenshots -------------------------------------------------------------------------------------------------

func screenshot(file_name: String) -> Dictionary:
	## Game.screenshot(path) (the game's own viewport), then reads the PNG back and measures it
	var path := out_dir.path_join(file_name)
	await RenderingServer.frame_post_draw
	var via := "Game.screenshot"
	if game != null and game.has_method("screenshot"):
		await game.screenshot(path)
	else:
		via = "viewport (Game.screenshot missing)"
		var img := runner.get_viewport().get_texture().get_image()
		if img != null:
			img.save_png(path)
	await wait_until(func(): return FileAccess.file_exists(path) and FileAccess.get_modified_time(path) >= run_start_unix, 3.0)
	var r := Frame.analyze_png(path, run_start_unix)
	r.via = via
	return r


# --- results -----------------------------------------------------------------------------------------------------

func write_json(path: String, data: Variant) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		note("cannot write %s: %s" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(JSON.stringify(data, "  ", false))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path) == OK
