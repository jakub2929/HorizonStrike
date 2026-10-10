extends "res://autotest/lib/scenario.gd"
## t22 BHOP levels 0, 1, 5 (upgrades.bhop set per case = setup). On flat open ground with the knife out, all by input:
## W held up to run speed, then a jump (space) and air strafes synced with the mouse (A or D held, the view turned with
## relative mouse motion so it follows the horizontal velocity: the air acceleration stays perpendicular, the CS
## speed gain); one strafe key per level (D, A, D: the player circles on the spot instead of drifting off it at 12+ m/s).
## The jump key is pressed on the first frame the player
## stands again after a landing (inside movement.bhop_window_ms) and released once airborne. N + 2 jumps per level;
## horizontal speed (player.horizontal_speed) logged at every landing and take-off. Never sets a velocity.
## Pass: level 0 take-off == the friction rule (one grounded frame of CS friction + ground acceleration, then the clamp
## to run speed x movement.bhop_clip_speed_mult; +-2 %); level N jumps 1..N take-off >= 99 % of landing; jump N+1
## take-off <= run speed x bhop_clip_speed_mult (+1 %) with a landing above 1.1 x run speed; every air phase gains speed.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const LEVELS := [0, 1, 5]
const FLAT_RADIUS_M := 12.0


func _init() -> void:
	timeout_s = 900.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "progression", "machines"], ["set_progression", "teleport"]) + ctx.missing_api(p, ["horizontal_speed", "velocity"], ["is_on_floor"])):
		return false
	var o = ctx.oracle
	var inp = InputSim.new(ctx)
	# the air strafe under test is mouse motion: --headless has no mouse capture, so the game ignores it there
	if not check("window run (mouse look needs a captured mouse; --headless cannot test the air strafe)", not InputSim.headless_look()):
		return false
	# setup: uncapped frame rate (input is read between physics steps), invulnerable, machines nearby frozen
	var gs: Node = ctx.tree.root.get_node_or_null("GraphicsSettings")
	var gfx0 := {}
	if gs != null:
		gfx0 = {"fps_limit": gs.get("fps_limit"), "vsync": gs.get("vsync")}
		gs.call("set_value", "fps_limit", 0)
		gs.call("set_value", "vsync", false)
	data.graphics_before = gfx0
	p.set("invulnerable", true)
	for m in g.get("machines"):
		if is_instance_valid(m) and (m as Node3D).global_position.distance_to(ctx.player_pos()) < 250.0:
			ctx.set_ai(m, false)
	var u: float = o.f(o.system("combat.units_to_m"))
	var run_speed: float = o.num(o.weapon("knife", "max_speed")) * u
	var cap: float = run_speed * o.f(o.system("movement.bhop_clip_speed_mult"))
	var window_ms: float = o.f(o.system("movement.bhop_window_ms"))
	data.numbers = {"run_speed": snappedf(run_speed, 0.001), "cap": snappedf(cap, 0.001), "window_ms": window_ms, "physics_hz": Engine.physics_ticks_per_second,
		"friction": o.f(o.system("movement.friction")), "stop_speed_u": o.f(o.system("movement.stop_speed_u")), "accelerate": o.f(o.system("movement.accelerate"))}
	inp.capture_for_look()
	if not check("knife out (slot key)", await inp.equip("knife"), str(p.get("current_weapon"))):
		return false
	# open ground where the player really stands and runs (setup check by input: 1 s of W moves him > 2 m)
	var spot := {}
	var skip := []
	var tries := []
	for attempt in 10:
		var s: Dictionary = await _flat_spot(ctx, FLAT_RADIUS_M, skip)
		if not s.ok:
			tries.append(s)
			break
		var v: Dictionary = await _verify_spot(ctx, inp, s)
		tries.append(v)
		if v.ok:
			spot = s
			break
		skip.append(s.pos)
	if spot.is_empty():
		var poses: Variant = o.system("perf.shot_poses")
		if poses is Dictionary and (poses as Dictionary).has("valley"):
			var vp: Array = poses.valley.pos
			await ctx.call_api(g, "teleport", [Vector3(float(vp[0]), float(vp[1]), float(vp[2]))])
			await ctx.wait_until(func(): return p.call("is_on_floor"), 60.0)
			await ctx.wait(3.0)
			tries.append("no spot near the start: searching around perf.shot_poses.valley")
			skip = []
			for attempt in 10:
				var s: Dictionary = await _flat_spot(ctx, FLAT_RADIUS_M, skip)
				if not s.ok:
					tries.append(s)
					break
				var v: Dictionary = await _verify_spot(ctx, inp, s)
				tries.append(v)
				if v.ok:
					spot = s
					break
				skip.append(s.pos)
	data.spot_tries = tries
	if not check("open ground (%d m around: steps <= 0.8 m per 3 m, free at 0.5 / 0.9 / 1.7 m) where the player runs and jumps (input check)" % int(FLAT_RADIUS_M), not spot.is_empty(), str(tries)):
		return false
	data.spot = {"pos": str(spot.pos), "tried": spot.get("tried")}
	for level in LEVELS:
		g.call("set_progression", {"upgrades": {"bhop": level}})
		await ctx.call_api(g, "teleport", [spot.pos + Vector3(0, 0.1, 0)])
		await ctx.physics_frames(4)
		await ctx.wait_until(func(): return p.call("is_on_floor") and float(p.get("horizontal_speed")) < 0.2, 5.0)
		await ctx.wait(1.0)
		var rows: Array = await _chain(ctx, inp, level + 2, run_speed, "move_left" if LEVELS.find(level) % 2 == 1 else "move_right")
		var res := _judge(level, rows, run_speed, cap, window_ms, o)
		data["level_%d" % level] = {"rows": rows, "judged": res, "trace": trace}
		for c in res:
			check("level %d: %s" % [level, c.check], c.ok, c.info)
		ctx.note("t22 level %d: %s" % [level, ", ".join(rows.map(func(r): return "%d: %.2f->%.2f (%d ms)" % [r.jump, r.landing, r.takeoff, r.ms_after_landing])) ])
		await ctx.wait(1.0)
	if gs != null and not gfx0.is_empty():
		gs.call("set_value", "fps_limit", gfx0.fps_limit)
		gs.call("set_value", "vsync", gfx0.vsync)
	g.call("set_progression", {"upgrades": {"bhop": 0}})
	return true


var trace: Array = []  # first two air phases per level: [jump, physics frame, position, velocity, on floor]


func _chain(ctx, inp, jumps: int, run_speed: float, strafe_key: String) -> Array:
	## W up to run speed, jump 0, then `jumps` landings each followed by a timed jump; air strafes between
	var p: Node = ctx.player
	var rows := []
	trace = []
	inp.press("move_forward")
	await ctx.wait_until(func(): return float(p.get("horizontal_speed")) >= run_speed * 0.97, 3.0)
	var keys := [strafe_key]
	inp.press(strafe_key)
	inp.release("move_forward")
	var takeoff_prev: float = await _jump(ctx, inp)
	rows.append({"jump": 0, "landing": snappedf(float(p.get("horizontal_speed")), 0.001), "takeoff": snappedf(takeoff_prev, 0.001), "ms_after_landing": -1, "ground_steps": -1})
	for j in range(1, jumps + 1):
		# air phase: keep the view on the velocity (synced strafe), until the player stands again
		var t_air := Time.get_ticks_msec()
		var corrections := 0
		var last_pf := -1
		while Time.get_ticks_msec() - t_air < 3000:
			await ctx.frames(1)
			if j <= 2 and Engine.get_physics_frames() != last_pf and trace.size() < 160:
				last_pf = Engine.get_physics_frames()
				var v: Vector3 = p.get("velocity")
				trace.append([j, last_pf, str((p as Node3D).global_position.snappedf(0.01)), str(v.snappedf(0.01)), p.call("is_on_floor")])
			if p.call("is_on_floor") and Time.get_ticks_msec() - t_air > 80:
				break
			var e: float = inp.strafe_look()
			if absf(e) > 0.0005:
				corrections += 1
		var landing := float(p.get("horizontal_speed"))
		var t_land := Time.get_ticks_msec()
		var f_land := Engine.get_physics_frames()
		inp.strafe_look()
		var takeoff: float = await _jump(ctx, inp)
		rows.append({"jump": j, "landing": snappedf(landing, 0.001), "takeoff": snappedf(takeoff, 0.001), "air_gain": snappedf(landing - takeoff_prev, 0.001),
			"ms_after_landing": Time.get_ticks_msec() - t_land, "ground_steps": Engine.get_physics_frames() - f_land, "strafe_corrections": corrections})
		takeoff_prev = takeoff
	# land and stop
	for k in keys:
		inp.release(k)
	await ctx.wait_until(func(): return p.call("is_on_floor"), 3.0)
	return rows


func _jump(ctx, inp) -> float:
	## space down until the player leaves the ground (a few physics steps at most), then up; the take-off speed
	var p: Node = ctx.player
	inp.press("jump")
	var f0 := Engine.get_physics_frames()
	while Engine.get_physics_frames() - f0 < 12:
		await ctx.frames(1)
		if not p.call("is_on_floor"):
			break
	inp.release("jump")
	return float(p.get("horizontal_speed"))


func _judge(level: int, rows: Array, run_speed: float, cap: float, window_ms: float, o) -> Array:
	var out := []
	var jumps := rows.filter(func(r): return r.jump >= 1)
	var timed := jumps.filter(func(r): return r.ms_after_landing <= window_ms and r.ground_steps <= 2)
	out.append({"check": "every jump pressed inside movement.bhop_window_ms (%d ms) after its landing (%d/%d)" % [int(window_ms), timed.size(), jumps.size()], "ok": timed.size() == jumps.size(),
		"info": str(jumps.map(func(r): return [r.jump, r.ms_after_landing, r.ground_steps]))})
	var gain := jumps.filter(func(r): return r.air_gain > 0.05)
	out.append({"check": "air strafe adds speed in every air phase (%d/%d)" % [gain.size(), jumps.size()], "ok": gain.size() == jumps.size(),
		"info": str(jumps.map(func(r): return r.air_gain))})
	if level == 0:
		var bad := []
		for r in jumps:
			var want := _friction_rule(r.landing, maxi(int(r.ground_steps), 1), run_speed, cap, o)
			r["expected_takeoff"] = snappedf(want, 0.001)
			if absf(r.takeoff - want) > want * 0.02:
				bad.append([r.jump, r.landing, r.takeoff, snappedf(want, 0.001)])
		out.append({"check": "take-off after each landing == friction rule + clamp (+-2 %)", "ok": bad.is_empty() and not jumps.is_empty(), "info": str(bad) if not bad.is_empty() else str(jumps.map(func(r): return [r.landing, r.takeoff, r.expected_takeoff]))})
		var fast := jumps.filter(func(r): return r.landing > run_speed * 1.1)
		out.append({"check": "landing speeds above 1.1 x run speed (the clip is visible)", "ok": fast.size() == jumps.size(), "info": str(jumps.map(func(r): return r.landing))})
		return out
	var keep := jumps.filter(func(r): return r.jump <= level)
	var kept := keep.filter(func(r): return r.takeoff >= r.landing * 0.99)
	out.append({"check": "jumps 1..%d keep speed (take-off >= 99 %% of landing) (%d/%d)" % [level, kept.size(), keep.size()], "ok": kept.size() == level and keep.size() == level,
		"info": str(keep.map(func(r): return [r.jump, r.landing, r.takeoff]))})
	var clip := jumps.filter(func(r): return r.jump == level + 1)
	var c_ok: bool = clip.size() == 1 and clip[0].takeoff <= cap * 1.01 and clip[0].landing > run_speed * 1.1
	out.append({"check": "jump %d clips: take-off <= %.2f m/s (+1 %%) after a landing > 1.1 x run speed (%.2f)" % [level + 1, cap, run_speed * 1.1], "ok": c_ok,
		"info": str(clip.map(func(r): return [r.jump, r.landing, r.takeoff]))})
	return out


static func _friction_rule(landing: float, steps: int, run_speed: float, cap: float, o) -> float:
	## CS ground movement on the grounded frames before the take-off (sheet movement.*): friction (speed - max(speed,
	## stop speed) x friction x dt) and the ground acceleration of the held strafe key (perpendicular to the velocity,
	## accelerate x dt x run speed), then the clamp to run speed x bhop_clip_speed_mult
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var u: float = o.f(o.system("combat.units_to_m"))
	var stop: float = o.f(o.system("movement.stop_speed_u")) * u
	var fr: float = o.f(o.system("movement.friction"))
	var acc: float = o.f(o.system("movement.accelerate"))
	var s := landing
	for i in steps:
		s = maxf(s - maxf(s, stop) * fr * dt, 0.0)
		s = sqrt(s * s + pow(minf(acc * dt * run_speed, run_speed), 2.0))
	return minf(s, cap)


func _flat_spot(ctx, radius: float, skip: Array = []) -> Dictionary:
	## nearest candidate to the player (rings 16 m apart) whose ground has headroom and where, in 16 directions out to
	## `radius`, the ground has no step over 0.8 m per 3 m and nothing stands 0.5 / 0.9 / 1.7 m above it; the caller
	## verifies by input that the player really runs and jumps there (HZD rocks and settlement meshes overlap the
	## terrain, so a geometric check alone is not enough)
	var space: PhysicsDirectSpaceState3D = ctx.runner.get_viewport().get_world_3d().direct_space_state
	var ex: Array[RID] = ctx.player_rids()
	var base: Vector3 = ctx.player_pos()
	if ctx.player is CollisionObject3D:
		mask = (ctx.player as CollisionObject3D).collision_mask
	var tried := 0
	var why := {"no_ground": 0, "blocked": 0}
	var blockers := {}
	await ctx.physics_frames(1)
	for ring in range(0, 14):
		var r := ring * 16.0
		var n := 1 if ring == 0 else 6 * ring
		for k in n:
			var a := TAU * k / n
			var c := base + Vector3(sin(a), 0.0, cos(a)) * r
			if skip.any(func(q): return Vector2(q.x - c.x, q.z - c.z).length() < 20.0):
				continue
			var cy: Variant = _ground(space, ex, c)
			if cy == null:
				why.no_ground += 1
				continue
			tried += 1
			c.y = float(cy)
			var ok := true
			# 16 directions, ground sampled every 3 m out to `radius`: no step over 0.8 m between samples (no ledge,
			# pit or steep rise) and nothing on the segments 0.5 / 0.9 / 1.7 m above that ground (trunks, rocks, walls)
			for j in 16:
				var b := TAU * j / 16.0
				var dir := Vector3(sin(b), 0.0, cos(b))
				var prev := c
				var dd := 3.0
				while dd <= radius + 0.01 and ok:
					var q: Vector3 = c + dir * dd
					var gq: Variant = _ground(space, ex, Vector3(q.x, prev.y, q.z), 3.3, false)
					if gq == null or absf(float(gq) - prev.y) > 0.8:
						ok = false
						why["ledge"] = int(why.get("ledge", 0)) + 1
						break
					q.y = float(gq)
					for hgt in [0.5, 0.9, 1.7]:   # 0.5: above the 0.46 m step height
						var ray := PhysicsRayQueryParameters3D.create(prev + Vector3(0, hgt, 0), q + Vector3(0, hgt, 0))
						ray.exclude = ex
						ray.collision_mask = mask
						var hit := space.intersect_ray(ray)
						if not hit.is_empty():
							ok = false
							why.blocked += 1
							var col: Variant = hit.get("collider")
							var key: String = (col as Node).name.left(24) if col is Node else str(col)
							blockers[key] = int(blockers.get(key, 0)) + 1
							break
					prev = q
					dd += 3.0
				if not ok:
					break
			if ok:
				return {"ok": true, "pos": c, "tried": tried}
	var top_blockers := blockers.keys()
	top_blockers.sort_custom(func(x, y): return blockers[x] > blockers[y])
	return {"ok": false, "pos": base, "tried": tried, "why": why, "blockers": top_blockers.slice(0, 6).map(func(x): return [x, blockers[x]])}


static var mask := 0xFFFFFFFF  # the player's collision mask: what the player stands on and runs into


static func _ground(space: PhysicsDirectSpaceState3D, ex: Array[RID], at: Vector3, from_above: float = 60.0, headroom: bool = true) -> Variant:
	## ground height: the first surface from `from_above` m above `at` down with 3.5 m of headroom (a jump lifts the
	## 1.83 m hull 1.4 m); null otherwise. HZD rocks and settlement meshes overlap the terrain, so whether the player
	## really stands, runs and jumps there is verified by input afterwards
	var q := PhysicsRayQueryParameters3D.create(Vector3(at.x, at.y + from_above, at.z), Vector3(at.x, at.y - 120.0, at.z))
	q.exclude = ex
	q.collision_mask = mask
	var h := space.intersect_ray(q)
	if h.is_empty():
		return null
	var y := float(h.position.y)
	if not headroom:
		return y
	var up := PhysicsRayQueryParameters3D.create(Vector3(at.x, y + 0.1, at.z), Vector3(at.x, y + 3.5, at.z))
	up.exclude = ex
	up.collision_mask = mask
	if not space.intersect_ray(up).is_empty():
		return null
	return y


func _verify_spot(ctx, inp, s: Dictionary) -> Dictionary:
	## setup check by input: on the spot 1 s of W moves the player > 2 m and a jump lifts him > 0.8 m (a player stuck
	## in a mesh lying over the terrain does neither)
	var g: Node = ctx.game
	var p: Node = ctx.player
	await ctx.call_api(g, "teleport", [s.pos + Vector3(0, 0.1, 0)])
	await ctx.physics_frames(4)
	await ctx.wait_until(func(): return p.call("is_on_floor"), 5.0)
	await ctx.wait(0.8)
	var at: Vector3 = ctx.player_pos()
	inp.press("move_forward")
	await ctx.wait(1.0)
	inp.release("move_forward")
	var moved: float = Vector2(ctx.player_pos().x - at.x, ctx.player_pos().z - at.z).length()
	await ctx.wait(0.5)
	var y0: float = ctx.player_pos().y
	inp.press("jump")
	var peak := y0
	var t_j := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_j < 1200:
		await ctx.frames(1)
		peak = maxf(peak, ctx.player_pos().y)
	inp.release("jump")
	return {"ok": moved > 2.0 and peak - y0 > 0.8, "pos": str(s.pos), "stands_at_y": snappedf(at.y, 0.01), "w_1s_moved_m": snappedf(moved, 0.01),
		"jump_height_m": snappedf(peak - y0, 0.01), "tried": s.tried}
