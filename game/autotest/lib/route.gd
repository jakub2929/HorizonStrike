extends RefCounted
## Walks the player along waypoints by input only: the forward key held down, the camera steered with relative mouse
## motion. Local navigation like a player looking ahead: every PROBE_S the walker probes headings around the goal
## bearing with physics rays (reading state: a chest-height ray for walls/rocks, ground heights ahead for slopes and
## drops) and steers to the best open heading. The route is split into sub-waypoints SUB_M apart. No progress for
## STUCK_JUMP_S -> jump key; no progress for STUCK_TELEPORT_S -> teleport to the next sub-waypoint (setup fallback,
## counted, short hop).

const SUB_M := 128.0
const ARRIVE_M := 25.0
const PROBE_S := 0.5
const STUCK_JUMP_S := 3.0
const STUCK_TELEPORT_S := 12.0
const HOP_M := 60.0
const HEADINGS := [0, 20, -20, 40, -40, 60, -60, 85, -85, 110, -110, 140, -140]
const Nav := preload("res://autotest/lib/nav.gd")
const PLAN_AHEAD_M := 300.0

var ctx
var inp
var teleports := 0
var jumps := 0
var legs: Array = []
var cells_visited := {}
var refocus := 0  # times the forward key had to be pressed again (released by a focus change)
var walked_m := 0.0
var hopped_m := 0.0
var leg_teleports := 0  # legs whose waypoint was not reached by walking in time (teleport to the waypoint)
var _deadline := 0
var plans := 0
var on_phase: Callable = Callable()  # called with "plan" before a (one-frame) path search and "" after it
var _last_trace := 0


func _init(p_ctx, p_inp) -> void:
	ctx = p_ctx
	inp = p_inp


static func cell_center(c: Vector2i, cell_size: float) -> Vector3:
	## centre of cell (x, y): cell x spans x*size..(x+1)*size, z spans -(y+1)*size..-y*size (docs: hzd index axes)
	return Vector3((c.x + 0.5) * cell_size, 0.0, -(c.y + 0.5) * cell_size)


func walk(waypoints: Array, leg_timeout_s: float = 300.0, on_cell: Callable = Callable()) -> void:
	inp.press("move_forward")
	var from: Vector3 = ctx.player_pos()
	for wp in waypoints:
		var t0 := Time.get_ticks_msec()
		var info := {"to": str((wp as Vector3).round()), "teleports": 0, "jumps": 0, "subs": 0, "reached_by_walking": true}
		_deadline = t0 + int(leg_timeout_s * 1000.0)
		# plan on the terrain in pieces of PLAN_AHEAD_M (cells further on may still be streaming in), follow the path
		while (Time.get_ticks_msec() - t0) / 1000.0 <= leg_timeout_s:
			var p: Vector3 = ctx.player_pos()
			var rest := Vector3(wp.x - p.x, 0.0, wp.z - p.z)
			if rest.length() < ARRIVE_M:
				break
			var target: Vector3 = wp if rest.length() <= PLAN_AHEAD_M else p + rest.normalized() * PLAN_AHEAD_M
			if on_phase.is_valid():
				on_phase.call("plan")
			await ctx.frames(1)
			var path: Array = Nav.plan(ctx, p, target)
			plans += 1
			await ctx.frames(1)
			if on_phase.is_valid():
				on_phase.call("")
			if path.size() < 2:
				path = [p, target]  # no terrain plan (data not loaded yet): head straight for the target
			for k in range(1, path.size()):
				await _go(path[k], info, on_cell, k == path.size() - 1)
				info.subs += 1
				if (Time.get_ticks_msec() - t0) / 1000.0 > leg_timeout_s:
					break
		var pe: Vector3 = ctx.player_pos()
		if Vector2(wp.x - pe.x, wp.z - pe.z).length() >= ARRIVE_M * 2.0:
			var gy: Variant = await ctx.ground_y(wp.x, wp.z)
			await ctx.call_api(ctx.game, "teleport", [Vector3(wp.x, float(gy) + 0.5 if gy != null else pe.y + 30.0, wp.z)])
			leg_teleports += 1
			info.reached_by_walking = false
			var tc: Variant = ctx.cell_of(wp)
			if tc != null and not cells_visited.has("%d_%d" % [tc.x, tc.y]):
				cells_visited["%d_%d" % [tc.x, tc.y]] = true
				if on_cell.is_valid():
					on_cell.call("%d_%d" % [tc.x, tc.y])
			ctx.note("route: leg time %d s used up %.0f m before %s - teleport to the waypoint" % [int(leg_timeout_s), Vector2(wp.x - pe.x, wp.z - pe.z).length(), str(wp.round())])
			await ctx.physics_frames(5)
		from = wp
		info.seconds = snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
		legs.append(info)
		ctx.note("route leg %d -> %s: %s s, jumps %d, teleports %d, cells visited %d, walked %.0f m" % [legs.size(), info.to, str(info.seconds), info.jumps, info.teleports, cells_visited.size(), walked_m])
	inp.release("move_forward")
	await ctx.frames(2)


func _go(goal: Vector3, info: Dictionary, on_cell: Callable, final: bool) -> void:
	var best := INF
	var best_t := Time.get_ticks_msec()
	var last_jump := 0
	var next_probe := 0
	var heading := 0.0  # offset from the goal bearing chosen by the probes
	var last_p: Vector3 = ctx.player_pos()
	var arrive := ARRIVE_M if final else 8.0
	while true:
		var p: Vector3 = ctx.player_pos()
		walked_m += Vector2(p.x - last_p.x, p.z - last_p.z).length()
		last_p = p
		var c: Variant = ctx.cell_of(p)
		if c != null:
			var key := "%d_%d" % [c.x, c.y]
			if not cells_visited.has(key):
				cells_visited[key] = true
				if on_cell.is_valid():
					on_cell.call(key)
		var d := Vector2(goal.x - p.x, goal.z - p.z).length()
		if d < arrive:
			return
		var now := Time.get_ticks_msec()
		if _deadline > 0 and now > _deadline:
			return
		if d < best - 1.0:
			best = d
			best_t = now
		# the engine releases held keys when the window loses focus; a player keeps holding W
		if not Input.is_action_pressed("move_forward"):
			inp.press("move_forward")
			refocus += 1
		if not final and (now - best_t) / 1000.0 > 6.0 and d < 30.0:
			return  # an intermediate path point that cannot be reached exactly: go on with the next one
		if (now - best_t) / 1000.0 > STUCK_TELEPORT_S:
			# blocked (dense structures / cliffs the terrain plan cannot see): a short hop towards the goal (setup
			# fallback, counted with its distance)
			var hop := Vector3(goal.x - p.x, 0.0, goal.z - p.z)
			var tgt: Vector3 = goal if hop.length() <= HOP_M else p + hop.normalized() * HOP_M
			var gy: Variant = await ctx.ground_y(tgt.x, tgt.z)
			await ctx.call_api(ctx.game, "teleport", [Vector3(tgt.x, float(gy) + 0.5 if gy != null else p.y + 30.0, tgt.z)])
			teleports += 1
			info.teleports += 1
			hopped_m += Vector2(tgt.x - p.x, tgt.z - p.z).length()
			ctx.note("route: no progress for %d s at %s - hop to %s" % [int(STUCK_TELEPORT_S), str(p.round()), str(tgt.round())])
			await ctx.physics_frames(5)
			last_p = ctx.player_pos()
			best = INF
			best_t = Time.get_ticks_msec()
			continue
		if (now - best_t) / 1000.0 > STUCK_JUMP_S and now - last_jump > 1200:
			last_jump = now
			jumps += 1
			info.jumps += 1
			await inp.tap("jump")
		if now >= next_probe:
			next_probe = now + int(PROBE_S * 1000.0)
			var pick: Vector2 = _choose_heading(p, goal, now - best_t > 1500, heading)
			heading = pick.x
		if now - _last_trace > 5000:
			_last_trace = now
			var pl: Node = ctx.player
			var vel: Variant = pl.get("velocity") if pl != null and "velocity" in pl else Vector3.ZERO
			ctx.note("route trace: pos %s goal dist %.0f heading %+.0f speed %.1f m/s" % [str(p.round()), d, rad_to_deg(heading), Vector2(vel.x, vel.z).length() if vel is Vector3 else 0.0])
		var cam: Camera3D = ctx.camera()
		if cam != null:
			var dir := Vector3(goal.x - p.x, 0.0, goal.z - p.z).normalized().rotated(Vector3.UP, heading)
			var aim := cam.global_position + dir * 30.0 + Vector3(0, -2.0, 0)
			var t: Vector2 = inp.yaw_pitch_to(cam.global_position, aim)
			var before: Vector2 = inp.yaw_pitch()
			var err: Vector2 = inp.look_step(t.x, t.y, 80.0)
			await ctx.frames(1)
			inp.learn_sensitivity(before, inp.yaw_pitch(), clampf(-err.x / inp.rad_per_px, -80.0, 80.0))
		else:
			await ctx.frames(1)


func _choose_heading(p: Vector3, goal: Vector3, stuck: bool, current: float) -> Vector2:
	## best open heading (offset from the goal bearing): a chest-height ray must not hit within BLOCK_M, the ground
	## ahead must not rise steeper than ~40 deg or drop into a hole; score prefers headings towards the goal
	var space: PhysicsDirectSpaceState3D = ctx.runner.get_viewport().get_world_3d().direct_space_state
	var ex: Array[RID] = ctx.player_rids()
	var base := Vector3(goal.x - p.x, 0.0, goal.z - p.z).normalized()
	var best_h := 0.0
	var best_s := -INF
	var cur_s := -INF
	var hs: Array = HEADINGS.duplicate()
	if not hs.has(int(round(rad_to_deg(current)))):
		hs.append(rad_to_deg(current))
	for hd in hs:
		var h := deg_to_rad(float(hd))
		var dir := base.rotated(Vector3.UP, h)
		var chest := p + Vector3(0, 1.0, 0)
		var q := PhysicsRayQueryParameters3D.create(chest, chest + dir * (9.0 if stuck else 6.0))
		q.exclude = ex
		var blocked: bool = not space.intersect_ray(q).is_empty()
		var climb := 0.0
		var drop := false
		for dist in [4.0, 8.0]:
			var gx: Vector3 = p + dir * dist
			var gq := PhysicsRayQueryParameters3D.create(gx + Vector3(0, 30, 0), gx + Vector3(0, -60, 0))
			gq.exclude = ex
			var hit: Dictionary = space.intersect_ray(gq)
			if hit.is_empty():
				drop = true
				continue
			climb = maxf(climb, (float(hit.position.y) - p.y) / dist)
			if float(hit.position.y) - p.y < -0.9 * dist:
				drop = true
		var s := cos(h) * 2.0
		if blocked:
			s -= 3.0
		if climb > 0.8:
			s -= 2.0 + climb
		if drop:
			s -= 1.5
		if absf(h - current) < 0.01:
			cur_s = s
		if s > best_s:
			best_s = s
			best_h = h
	# hysteresis: keep the current heading unless another one is clearly better (no left-right thrashing)
	if cur_s > -INF and best_s - cur_s < 0.6:
		return Vector2(current, cur_s)
	return Vector2(best_h, best_s)
