extends RefCounted
## Walks the player along waypoints by input only: the forward key held down, the camera steered with relative mouse
## motion. Stuck for STUCK_JUMP_S -> jump key; no progress for STUCK_TELEPORT_S -> teleport to the waypoint (setup
## fallback, counted).

const STUCK_JUMP_S := 5.0
const STUCK_TELEPORT_S := 15.0
const ARRIVE_M := 20.0

var ctx
var inp
var teleports := 0
var jumps := 0
var legs: Array = []
var cells_visited := {}


func _init(p_ctx, p_inp) -> void:
	ctx = p_ctx
	inp = p_inp


static func cell_center(c: Vector2i, cell_size: float) -> Vector3:
	## centre of cell (x, y): cell x spans x*size..(x+1)*size, z spans -(y+1)*size..-y*size (docs: hzd index axes)
	return Vector3((c.x + 0.5) * cell_size, 0.0, -(c.y + 0.5) * cell_size)


func walk(waypoints: Array, leg_timeout_s: float = 240.0, on_cell: Callable = Callable()) -> void:
	inp.press("move_forward")
	for wp in waypoints:
		await _leg(wp, leg_timeout_s, on_cell)
	inp.release("move_forward")
	await ctx.frames(2)


func _leg(wp: Vector3, timeout_s: float, on_cell: Callable) -> void:
	var t0 := Time.get_ticks_msec()
	var info := {"to": str(wp.round()), "teleported": false, "jumps": 0}
	var best := INF
	var best_t := t0
	var last_jump := 0
	while true:
		var p: Vector3 = ctx.player_pos()
		var c: Variant = ctx.cell_of(p)
		if c != null:
			var key := "%d_%d" % [c.x, c.y]
			if not cells_visited.has(key):
				cells_visited[key] = true
				if on_cell.is_valid():
					on_cell.call(key)
		var d := Vector2(wp.x - p.x, wp.z - p.z).length()
		if d < ARRIVE_M:
			break
		var now := Time.get_ticks_msec()
		if d < best - 1.0:
			best = d
			best_t = now
		if (now - best_t) / 1000.0 > STUCK_TELEPORT_S or (now - t0) / 1000.0 > timeout_s:
			var gy: Variant = await ctx.ground_y(wp.x, wp.z)
			await ctx.call_api(ctx.game, "teleport", [Vector3(wp.x, float(gy) + 0.5 if gy != null else p.y + 50.0, wp.z)])
			teleports += 1
			info.teleported = true
			await ctx.physics_frames(5)
			break
		if (now - best_t) / 1000.0 > STUCK_JUMP_S and now - last_jump > 1500:
			last_jump = now
			jumps += 1
			info.jumps += 1
			await inp.tap("jump")
		# steer: yaw towards the waypoint, eyes slightly down to the horizon
		var cam: Camera3D = ctx.camera()
		if cam != null:
			var t: Vector2 = inp.yaw_pitch_to(cam.global_position, Vector3(wp.x, cam.global_position.y - 3.0, wp.z))
			var before: Vector2 = inp.yaw_pitch()
			var err: Vector2 = inp.look_step(t.x, t.y, 60.0)
			await ctx.frames(1)
			inp.learn_sensitivity(before, inp.yaw_pitch(), clampf(-err.x / inp.rad_per_px, -60.0, 60.0))
		else:
			await ctx.frames(1)
	info.seconds = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	legs.append(info)
	ctx.note("route leg %d -> %s: %s s, jumps %d, teleported %s, cells visited %d" % [legs.size(), info.to, str(info.seconds), info.jumps, str(info.teleported), cells_visited.size()])
