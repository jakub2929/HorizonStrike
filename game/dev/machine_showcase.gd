extends SceneTree
## Dev only (not exported): showcase recording of one machine on the real world for Godot's movie writer.
## Boots the real game (any cache: real or --mock-data), waits for world_ready, finds a flat open spot near the start
## (Mother's Heart on the real world), spawns the machine with its AI off, hides every UI layer (HUD, viewmodel,
## loading screen) and films it with its own camera: a three-quarter view (35 deg off the side) that keeps a fixed
## offset to the machine, sized so the machine fills ~50 % of the frame height. Then it runs the action and quits.
##   walk    1.0 s standing, ~5.5 s walking across the terrain, 0.5 s stop               (7 s)
##   attack  1.0 s standing, its first attack, then its second one (or --attack <id>)   (7-8 s)
##   death   1.5 s standing, a lethal hit, the machine falls and settles                (6 s)
## Every frame before the action (boot, loading screen) is also written by --write-movie; the script prints
## "SHOWCASE start frame <n>" so the clip can be trimmed exactly (ffmpeg -ss <n/fps>).
##   godot --path game --write-movie <file.avi> --fixed-fps 30 --resolution 1280x720 --script res://dev/machine_showcase.gd
##         -- --game <CS2 dir> --cache-dir <copy of a real cache> --machine watcher --action walk
## Prints "SHOWCASE OK <machine> <action> frames <start>..<end>" and exits 0; exits 1 when it cannot run.

const ACTIONS := ["walk", "attack", "death"]
const FILL := 0.5              # machine height / frame height
const VFOV := 50.0
const SIDE_ANGLE_DEG := 35.0   # camera direction: from the machine's side, 35 deg towards its front

var _machine_id := "watcher"
var _action := "walk"
var _attack_id := ""
var _game: Node
var _m   # the machine (untyped: machine.gd members are accessed directly)
var _cam: Camera3D
var _cam_offset := Vector3.ZERO
var _look_h := 1.0
var _start_frame := 0


func _initialize() -> void:
	var ua := OS.get_cmdline_user_args()
	for i in ua.size():
		var nxt := ua[i + 1] if i + 1 < ua.size() else ""
		match ua[i]:
			"--machine":
				_machine_id = nxt
			"--action":
				_action = nxt
			"--attack":
				_attack_id = nxt
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _fail(msg: String) -> void:
	print("SHOWCASE FAIL %s" % msg)
	quit(1)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Seconds of game time (works with --fixed-fps, where wall-clock time is meaningless).
func _wait(sec: float) -> void:
	var t := 0.0
	while t < sec:
		await process_frame
		t += root.get_process_delta_time()
		_update_cam()


func _run() -> void:
	_game = root.get_node("Game")
	var Sheets: GDScript = load("res://core/sheets.gd")
	if not ACTIONS.has(_action):
		_fail("unknown --action %s (walk|attack|death)" % _action)
		return
	if not Sheets.machine_ids().has(_machine_id):
		_fail("unknown --machine %s (%s)" % [_machine_id, ", ".join(PackedStringArray(Sheets.machine_ids()))])
		return
	var frames0 := Engine.get_process_frames()
	while not _game.is_world_ready:
		await process_frame
		if Engine.get_process_frames() - frames0 > 30 * 600:
			_fail("world not ready")
			return
	await _frames(30)
	var p: Node3D = _game.player
	p.set("invulnerable", true)
	var walk_speed: float = Sheets.machine_num(_machine_id, "walk_speed_mps", 1.6)
	var path_len := walk_speed * 5.5 + 2.0
	var spot := _find_spot(p.global_position, path_len)
	if spot.is_empty():
		_fail("no open spot near the start")
		return
	var c: Vector3 = spot["pos"]
	var dir: Vector3 = spot["dir"]
	var start := c - dir * (path_len * 0.5 if _action == "walk" else 0.0)
	start.y = _game.world.height_at(start) + 0.3
	_m = _game.spawn_machine(_machine_id, start)
	if _m == null:
		_fail("spawn failed")
		return
	_m.set("ai_enabled", false)
	_m.rotation.y = atan2(-dir.x, -dir.z)
	# the player stands behind the camera, far enough not to be noticed or drawn
	_hide_ui()
	await _frames(10)
	_setup_camera(dir)
	await _wait(0.4)
	_start_frame = Engine.get_process_frames()
	print("SHOWCASE start frame %d (%.2f s at 30 fps) %s %s at %s dir %s" % [_start_frame, _start_frame / 30.0, _machine_id, _action, str(start), str(dir)])
	match _action:
		"walk":
			await _wait(1.0)
			_m.drive_dir = dir
			_m.drive_speed = walk_speed
			await _wait(5.5)
			_m.drive_speed = 0.0
			await _wait(0.5)
		"attack":
			await _wait(1.0)
			var rows: Array = _m.attacks
			if _attack_id != "":
				rows = rows.filter(func(a): return str(a["id"]) == _attack_id)
			if rows.is_empty():
				_fail("no attack %s" % _attack_id)
				return
			for k in mini(rows.size(), 2):
				await _attack(rows[k], dir)
		"death":
			await _wait(1.5)
			_m.take_hit("ak47", 1.0e6, "body", true)
			await _wait(4.5)
	print("SHOWCASE OK %s %s frames %d..%d" % [_machine_id, _action, _start_frame, Engine.get_process_frames()])
	quit(0)


## One attack with its row timing: the pose (wind-up, strike, recovery); charges lunge a few metres, ranged attacks
## send their bolts forward from the attack origin point.
func _attack(a: Dictionary, dir: Vector3) -> void:
	_m.rig.play_attack(a)
	var windup := float(a["windup_s"])
	var active := float(a["active_s"])
	await _wait(windup)
	match str(a["kind"]):
		"charge":
			_m.drive_dir = dir
			_m.drive_speed = float(_m.run_speed) * 0.6
			await _wait(minf(active, 1.0))
			_m.drive_speed = 0.0
			await _wait(maxf(active - 1.0, 0.0))
		"ranged":
			var shots := maxi(1, roundi(active / 0.15))
			for k in shots:
				_bolt(a, dir)
				await _wait(active / shots)
		_:
			await _wait(active)
	await _wait(2.0)


func _bolt(a: Dictionary, dir: Vector3) -> void:
	var proj: Node3D = load("res://machines/projectile.gd").new()
	proj.attack = a
	proj.source = _m
	_m.get_parent().add_child(proj)
	var aid := str(a["id"])
	var from: Vector3 = _m.rig.point_global("attack_" + aid, _m.rig.point_global("attack_" + aid.substr(aid.find("_") + 1), _m.eye_position()))
	proj.global_position = from
	proj.velocity = (dir + Vector3(0, -0.05, 0)).normalized() * maxf(float(a["projectile_speed_mps"]), 1.0)


## A flat, open spot 14-40 m from the player: path_len of walkable terrain (max climb 1.2 m, no step > 0.35 m per
## metre) with nothing in the way at body height along the path and between the camera and the path.
func _find_spot(origin: Vector3, path_len: float) -> Dictionary:
	var best := {}
	var best_score := INF
	var space := root.get_world_3d().direct_space_state
	var h: float = _height_guess()
	for ri in [24.0, 34.0, 46.0, 60.0]:
		for ai in 16:
			var a := TAU * ai / 16.0
			var c: Vector3 = origin + Vector3(cos(a), 0, sin(a)) * float(ri)
			var ch: float = _game.world.height_at(c)
			if is_nan(ch):
				continue
			c.y = ch
			for di in 8:
				var dir := Vector3(cos(TAU * di / 8.0), 0, sin(TAU * di / 8.0))
				var score := _path_score(c, dir, path_len, space, h)
				if score < best_score:
					best_score = score
					best = {"pos": c, "dir": dir, "score": score}
		if not best.is_empty() and best_score < 0.6:
			break
	return best


func _path_score(c: Vector3, dir: Vector3, path_len: float, space: PhysicsDirectSpaceState3D, h: float) -> float:
	var n := 12
	var lo := INF
	var hi := -INF
	var prev := NAN
	var rough := 0.0
	var pts: Array = []
	for k in n + 1:
		var p := c + dir * (path_len * (float(k) / n - 0.5))
		var y: float = _game.world.height_at(p)
		if is_nan(y):
			return INF
		p.y = y
		pts.append(p)
		lo = minf(lo, y)
		hi = maxf(hi, y)
		if not is_nan(prev):
			var step := absf(y - prev) / (path_len / n)
			if step > 0.35:
				return INF
			rough += step
		prev = y
	if hi - lo > 1.2:
		return INF
	# nothing solid along the path at body height, nor between the camera and the path
	var up := Vector3(0, clampf(h * 0.5, 0.5, 2.0), 0)
	if _blocked(space, pts[0] + up, pts[n] + up):
		return INF
	var right := dir.cross(Vector3.UP).normalized()
	var cam_dir := right.rotated(Vector3.UP, deg_to_rad(SIDE_ANGLE_DEG))
	var dist := _cam_distance(h)
	var low := Vector3(0, 0.35, 0)
	for k in [0, n / 4, n / 2, 3 * n / 4, n]:
		var p: Vector3 = pts[k]
		var cam_p := p + cam_dir * dist + Vector3(0, h * 0.5, 0)
		if _blocked(space, p + up, cam_p) or _blocked(space, p + low, cam_p) or _blocked(space, p + up * 1.6, cam_p):
			return INF
	return (hi - lo) + rough * 0.5


func _blocked(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	return not space.intersect_ray(q).is_empty()


func _height_guess() -> float:
	var Sheets: GDScript = load("res://core/sheets.gd")
	var Content: GDScript = load("res://core/content.gd")
	var meta: Dictionary = Content.machine_meta(_machine_id)
	return float(meta.get("height_m", Sheets.machine_num(_machine_id, "body_height_m", 2.0)))


## Distance at which a machine of height h fills FILL of the frame height.
func _cam_distance(h: float) -> float:
	return h / (2.0 * FILL * tan(deg_to_rad(VFOV * 0.5)))


func _setup_camera(dir: Vector3) -> void:
	var h: float = _m.rig.body_height
	var right := dir.cross(Vector3.UP).normalized()
	var cam_dir := right.rotated(Vector3.UP, deg_to_rad(SIDE_ANGLE_DEG))   # side, turned towards the machine's front
	var dist := _cam_distance(h)
	# long machines (neck + tail): the whole skeleton, seen from 35 deg off the side, inside 75 % of the frame width
	var bounds: AABB = _m.rig._skeleton_aabb()
	var length := maxf(bounds.size.z, bounds.size.x)
	var aspect := float(root.get_visible_rect().size.x) / maxf(root.get_visible_rect().size.y, 1.0)
	var hfov_half := atan(tan(deg_to_rad(VFOV * 0.5)) * aspect)
	dist = maxf(dist, length * cos(deg_to_rad(SIDE_ANGLE_DEG)) / (2.0 * 0.75 * tan(hfov_half)) + length * 0.3)
	_look_h = h * 0.45
	_cam_offset = cam_dir * dist + Vector3(0, h * 0.5, 0)
	_cam = Camera3D.new()
	_cam.fov = VFOV
	_cam.near = 0.05
	_m.get_parent().add_child(_cam)
	_cam.current = true
	_update_cam(true)


## The camera keeps its offset to the machine (smoothed, never below the terrain) and looks at its body.
func _update_cam(snap: bool = false) -> void:
	if _cam == null or not is_instance_valid(_m):
		return
	var target: Vector3 = (_m as Node3D).global_position + _cam_offset
	var gh: float = _game.world.height_at(target)
	if not is_nan(gh):
		target.y = maxf(target.y, gh + 0.6)
	_cam.global_position = target if snap else _cam.global_position.lerp(target, 0.12)
	_cam.look_at((_m as Node3D).global_position + Vector3(0, _look_h, 0), Vector3.UP)


func _hide_ui() -> void:
	for n in _all(root):
		if n is CanvasLayer:
			(n as CanvasLayer).visible = false


func _all(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_all(c))
	return out
