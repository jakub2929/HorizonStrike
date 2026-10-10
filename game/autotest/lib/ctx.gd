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

	func on(a: Variant = null, b: Variant = null, c: Variant = null, d: Variant = null, e: Variant = null, f: Variant = null) -> void:
		# up to 6 signal arguments (0.3 player_hit_machine has 5: a 4-parameter callable never received it)
		events.append({"t": (Time.get_ticks_msec() - t0) / 1000.0, "args": [a, b, c, d, e, f]})


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
var spawned: Array = []  # machines the current scenario spawned through the API (removed afterwards)
var ai_changed: Array = []  # [machine, original ai_enabled] of world machines a scenario switched
var _player_state := {}  # player flags at scenario start (restored afterwards)
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


func player_camera() -> Camera3D:
	## the camera mouse look turns and the weapons fire from; differs from camera() only while a recording
	## scenario films through its own camera
	var c: Variant = player.get("camera") if player != null and "camera" in player else null
	return c if c is Camera3D and is_instance_valid(c) else camera()


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


func wheel_on_screen() -> Array:
	## buy wheel slots as the player sees them: a visible "$<price>" label next to a visible item-name label;
	## [{name, price_shown, center}] with center in viewport coordinates; [] when the wheel is not on screen
	var out := []
	for l in tree.root.find_children("*", "Label", true, false):
		var lab := l as Label
		if not lab.is_visible_in_tree():
			continue
		var t := lab.text.strip_edges()
		var digits := t.trim_prefix("$").replace(",", "")
		if not t.begins_with("$") or not digits.is_valid_int():
			continue
		var parent := lab.get_parent()
		# a slot is a small group (icon, name, price); the HUD's money label sits among many HUD nodes
		if not (parent is Control) or parent.get_child_count() > 4 or parent.get_children().filter(func(n): return n is Label).size() != 2:
			continue
		for sib in parent.get_children():
			if sib is Label and sib != lab and (sib as Label).is_visible_in_tree() and not (sib as Label).text.strip_edges().begins_with("$") and (sib as Label).text.strip_edges() != "":
				var pc := parent as Control
				out.append({"name": (sib as Label).text.strip_edges(), "price_shown": int(digits), "center": pc.get_global_transform_with_canvas() * (pc.size * 0.5)})
				break
	return out


func hit_evidence(dmg_rec: Rec, hud_rec: Rec) -> Array:
	## player hits seen during a scenario: the player_damaged signal, or the game's "Hit: ..." HUD message that it
	## emits for an invulnerable player
	var out := []
	for e in dmg_rec.events:
		out.append("player_damaged %s %s" % [str(e.args[0]), str(e.args[1]) if e.args[1] != null else ""])
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
	## The spot must be visible from the camera (a tree or a hill between would make every shot miss): the requested
	## angle first, then up to +-90 deg around it in 15 deg steps; the first spot with a clear line of sight wins.
	var base := base_dir if base_dir.length() > 0.001 else forward()
	var pos := player_pos() + base.rotated(Vector3.UP, deg_to_rad(angle_deg)) * dist_m
	var cam := camera()
	if cam != null:
		var world := runner.get_viewport().get_world_3d()
		for k in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]:
			var p := player_pos() + base.rotated(Vector3.UP, deg_to_rad(angle_deg + 15.0 * k)) * dist_m
			var gy: Variant = await ground_y(p.x, p.z, p.y + 200.0)
			if gy != null:
				p.y = float(gy)
			var q := PhysicsRayQueryParameters3D.create(cam.global_position, p + Vector3(0, 1.0, 0))
			q.exclude = player_rids()
			if world.direct_space_state.intersect_ray(q).is_empty():
				pos = p
				if k != 0:
					note("spawn %s: %d deg blocked, used %d deg" % [machine_type, int(angle_deg), int(angle_deg + 15.0 * k)])
				break
	var m: Variant = await call_api(game, "spawn_machine", [machine_type, pos])
	if m is Node:
		spawned.append(m)
		if "ai_enabled" in m:
			m.set("ai_enabled", ai)
		note("spawned %s at %s (%.1f m, ai=%s)" % [machine_type, str(pos), dist_m, str(ai)])
		return m
	note("spawn_machine(%s) returned %s" % [machine_type, str(m)])
	return null


func despawn(m: Variant) -> void:
	## frees a machine this scenario spawned (setup between sub-tests; cleanup() would free it at the end anyway)
	if m is Node and is_instance_valid(m):
		spawned.erase(m)
		(m as Node).queue_free()


func clear_spot(base: Vector3, ring_m: float, max_m: float = 160.0, step_m: float = 16.0) -> Dictionary:
	## nearest ground point to base from which eye-height rays from 8 points on a ring_m ring to 1 m above the centre
	## meet no world geometry (an open, flat-enough spot for ring tests); {pos, tried, clear}
	var world := runner.get_viewport().get_world_3d()
	var tried := 0
	var r := 0.0
	while r <= max_m:
		var n := 1 if r == 0.0 else int(ceil(TAU * r / step_m))
		for k in n:
			var a := TAU * k / n
			var c := base + Vector3(sin(a), 0.0, cos(a)) * r
			var gy: Variant = await ground_y(c.x, c.z)
			if gy == null:
				continue
			c.y = float(gy)
			tried += 1
			var ok := true
			for j in 8:
				var b := deg_to_rad(45.0 * j)
				var p := c + Vector3(sin(b), 0.0, cos(b)) * ring_m
				var py: Variant = await ground_y(p.x, p.z)
				if py == null or absf(float(py) - c.y) > ring_m * 0.35:
					ok = false
					break
				var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, float(py) + 1.6, p.z), c + Vector3(0, 1.0, 0))
				q.exclude = player_rids()
				if not world.direct_space_state.intersect_ray(q).is_empty():
					ok = false
					break
			if ok:
				return {"pos": c, "tried": tried, "clear": true}
		r += step_m
	return {"pos": base, "tried": tried, "clear": false}


func set_ai(m: Node, on: bool) -> void:
	## switch a machine's AI for test setup; world machines get their original flag back after the scenario
	if not is_instance_valid(m) or not ("ai_enabled" in m):
		return
	if not spawned.has(m) and ai_changed.filter(func(e): return e[0] == m).is_empty():
		ai_changed.append([m, m.get("ai_enabled")])
	m.set("ai_enabled", on)


func begin_scenario() -> void:
	spawned.clear()
	ai_changed.clear()
	_player_state = {}
	var p := player
	if p != null:
		for k in ["invulnerable", "crouched", "crouching"]:
			if k in p:
				_player_state[k] = p.get(k)
		if "inventory" in p:
			_player_state.inventory = Array(p.get("inventory")).map(func(x): return str(x))


func cleanup() -> Dictionary:
	## makes scenarios independent of their order: frees the machines this scenario spawned (they would hold slots
	## of spawning.max_active_machines and block later lines of fire), gives world machines their AI flag back
	## (an alerted one stays frozen so it cannot chase the player into the next scenario), restores player flags
	var out := {"removed": 0, "ai_restored": 0, "kept_frozen": []}
	for m in spawned:
		if is_instance_valid(m):
			(m as Node).queue_free()
			out.removed += 1
	spawned.clear()
	for e in ai_changed:
		var m: Variant = e[0]
		if not is_instance_valid(m):
			continue
		if e[1] == true and str(m.get("state")) in ["alert", "attack"]:
			m.set("ai_enabled", false)
			out.kept_frozen.append("%s %s" % [m.name, m.get("state")])
		else:
			m.set("ai_enabled", e[1])
			out.ai_restored += 1
	ai_changed.clear()
	var p := player
	if p != null:
		if _player_state.has("crouched") or _player_state.has("crouching"):
			var was: bool = bool(_player_state.get("crouched", _player_state.get("crouching", false)))
			if p.has_method("set_crouch"):
				p.call("set_crouch", was)
		if _player_state.has("invulnerable"):
			p.set("invulnerable", _player_state.invulnerable)
		# a scenario that began with the start loadout (knife + Glock) and lost part of it (buying a pistol replaces
		# the Glock, CS rule) gives it back through the game's own path: death -> respawn at the last campfire
		var start_ids: Array = oracle.start_loadout() if oracle != null else []
		var had: Array = _player_state.get("inventory", [])
		var now: Array = Array(p.get("inventory")).map(func(x): return str(x)) if "inventory" in p else []
		# (had is empty when the scenario started before the player existed: the game then hands out the start loadout)
		var lost := not start_ids.is_empty() and (had.is_empty() or start_ids.all(func(i): return had.has(i))) and not start_ids.all(func(i): return now.has(i))
		if lost and game != null and game.has_method("kill_player"):
			var resp := record(game, "player_respawned")
			if "invulnerable" in p:
				p.set("invulnerable", false)
			game.call("kill_player")
			var ok: bool = await wait_until(func(): return not resp.events.is_empty(), float(oracle.f(oracle.system("respawn.delay_s"))) + 20.0)
			disconnect_all()
			if _player_state.has("invulnerable"):
				p.set("invulnerable", _player_state.invulnerable)
			out.start_loadout_restored = {"via": "kill_player + respawn", "ok": ok, "inventory": Array(p.get("inventory"))}
	# never leave the user's mouse captured (t03 captures it for a moment, as during play)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# keys a scenario may still hold (an aborted scenario never released them)
	for action in ["crouch", "buy", "fire", "walk", "alt_fire"]:
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			Input.action_release(action)
	var g := game
	if g != null and g.has_method("close_buy_wheel"):
		g.call("close_buy_wheel")
	await frames(2)
	return out


func line_of_sight_to(m: Node, part: String = "body") -> Dictionary:
	## camera -> the machine's aim point for `part` (or its origin + 1 m): {clear, by}
	var cam := camera()
	if cam == null or not is_instance_valid(m):
		return {"clear": false, "by": "no camera / machine"}
	var to: Vector3 = m.call("aim_point", part) if m.has_method("aim_point") else (m as Node3D).global_position + Vector3(0, 1.0, 0)
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, to)
	q.exclude = player_rids()
	q.collide_with_areas = true
	var hit := runner.get_viewport().get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"clear": true, "by": ""}
	var col: Variant = hit.get("collider")
	if col is Node and (col == m or m.is_ancestor_of(col) or ((col as Node).has_meta("machine") and (col as Node).get_meta("machine") == m)):
		return {"clear": true, "by": str((col as Node).name)}
	return {"clear": false, "by": str((col as Node).name) if col is Node else str(col)}


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
