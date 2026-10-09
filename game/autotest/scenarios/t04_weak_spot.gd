extends "res://autotest/lib/scenario.gd"
## t04 Weak spot deals more than body. Glock at two AI-disabled Watchers 10 m ahead (full health and armor):
##   weak = damage * headshot_mult * falloff            (D4, weak spots ignore armor)
##   body = damage * armor_ratio * armor_ratio_scale * falloff   (CS armor rule while the machine has armor)
##   falloff = range_modifier ^ (distance_u / combat.range_step_u)   (systems sheet; = 1 at 0 m)
## Every machine type must report >= 1 weak spot. The Glock is taken with its slot key and fired with the fire button
## (simulated input); Game.aim_at points the camera. Damage = the target's health loss. A Watcher has 90 HP, so the
## weak shot on it is capped by its health; the exact weak-spot number is measured on a Grazer's weak spot (150 HP).

const Combat := preload("res://autotest/lib/combat.gd")
const InputSim := preload("res://autotest/lib/inputsim.gd")
const Frame := preload("res://autotest/lib/frame.gd")
const DIST_M := 10.0


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player"], ["spawn_machine", "aim_at"])):
		return false
	var o = ctx.oracle
	if not check("glock taken with its slot key (%s)" % InputSim.new(ctx).describe(InputSim.slot_action("glock")), await Combat.equip(ctx, "glock"), "current %s" % str(ctx.player.get("current_weapon"))):
		return false
	var base: Vector3 = ctx.forward()
	var a: Node = await ctx.spawn_ahead("watcher", DIST_M, -6.0, false, base)
	var b: Node = await ctx.spawn_ahead("watcher", DIST_M, 6.0, false, base)
	if not check("spawn two watchers", a != null and b != null):
		return false
	if not api_check(ctx.missing_api(a, ["health", "state"], ["weak_spots"])):
		return false
	await ctx.physics_frames(3)
	var fh: Dictionary = o.machine_health("watcher")
	var full: float = fh.value
	data.full_health = fh
	check("setup: watchers at full health %s (%s)" % [str(full), fh.source], is_equal_approx(float(a.get("health")), full) and is_equal_approx(float(b.get("health")), full), "A %s B %s" % [str(a.get("health")), str(b.get("health"))])
	if "armor" in a:
		data.armor_before = [a.get("armor"), b.get("armor")]

	var weak_names: Array = Array(await ctx.call_api(b, "weak_spots"))
	var sheet_parts: Array = o.machine("watcher", "weak_spot_parts")
	var weak := ""
	for s in sheet_parts:
		if weak_names.has(s):
			weak = s
			break
	if weak == "" and not weak_names.is_empty():
		weak = str(weak_names[0])
	data.watcher_weak_spots = weak_names

	var c: Node = await ctx.spawn_ahead("grazer", DIST_M, 20.0, false, base)
	var c_weak := ""
	if c != null:
		var cw: Array = Array(await ctx.call_api(c, "weak_spots"))
		var cs: Array = o.machine("grazer", "weak_spot_parts")
		for s in cs:
			if cw.has(s):
				c_weak = s
		if c_weak == "" and not cw.is_empty():
			c_weak = str(cw[0])
	var shot_a := await _shot(ctx, a, "body")
	await ctx.wait(Combat.shot_interval(ctx, "glock"))
	var weak_min: float = 0.5 * o.num(o.weapon("glock", "damage")) * o.num(o.weapon("glock", "headshot_mult"))
	var shot_b := await _shot(ctx, b, weak, weak_min)
	await ctx.wait(Combat.shot_interval(ctx, "glock"))
	var shot_c := await _shot(ctx, c, c_weak, weak_min) if c != null and c_weak != "" else {}
	data.body_shot = shot_a
	data.weak_shot = shot_b
	data.weak_shot_grazer = shot_c

	var dmg: float = o.num(o.weapon("glock", "damage"))
	var hs: float = o.num(o.weapon("glock", "headshot_mult"))
	var ar: float = o.num(o.weapon("glock", "armor_ratio"))
	var ars: float = o.f(o.system("combat.armor_ratio_scale"))
	var rm: float = o.num(o.weapon("glock", "range_modifier"))
	var step: float = o.f(o.system("combat.range_step_u"))
	var u2m: float = o.f(o.system("combat.units_to_m"))
	data.naive = {"weak": dmg * hs, "body": dmg * ar * ars, "note": "sheet numbers without range falloff (0 m)"}
	for e in [["A body", shot_a], ["B " + weak, shot_b], ["Grazer " + c_weak, shot_c]]:
		var sh: Dictionary = e[1]
		if not sh.is_empty():
			check("line of sight %s: the first hit along the shot is that hitbox (after %d moves)" % [e[0], sh.blocked_by_before_moving.size()], sh.line_of_sight == true, "first hit: %s; earlier blockers: %s" % [sh.first_hit, str(sh.blocked_by_before_moving)])
	var ok_a := check("fire button: body shot hits A", shot_a.hit == true, str(shot_a))
	var ok_b := check("fire button: weak shot (%s) hits B" % weak, shot_b.hit == true, str(shot_b))
	if not (ok_a and ok_b):
		return false
	var body := float(shot_a.damage)
	var wk := float(shot_b.damage)
	check("weak damage > body damage", wk > body, "%s > %s" % [str(wk), str(body)])
	var exp_w := _expect(dmg * hs, rm, step, u2m, shot_b)
	var exp_b := _expect(dmg * ar * ars, rm, step, u2m, shot_a)
	data.expected = {"weak": exp_w, "body": exp_b}
	check("body == glock.damage * armor_ratio * armor_ratio_scale * falloff (%s) while armor > 0" % str(exp_b.value), absf(body - exp_b.value) <= exp_b.tol, "body %s, tolerance %s" % [str(body), str(exp_b.tol)])
	if is_equal_approx(wk, float(shot_b.health_before)):
		# one weak shot took all of B's health: consistent only if the formula deals at least that much
		check("weak shot on B (%s HP) kills it: formula %s >= %s" % [str(shot_b.health_before), str(exp_w.value), str(shot_b.health_before)], exp_w.value + exp_w.tol >= wk, "capped by health")
	else:
		check("weak == glock.damage * headshot_mult * falloff (%s)" % str(exp_w.value), absf(wk - exp_w.value) <= exp_w.tol, "weak %s, tolerance %s" % [str(wk), str(exp_w.tol)])
	if check("fire button: weak shot (%s) hits the Grazer" % c_weak, not shot_c.is_empty() and shot_c.hit == true, str(shot_c)):
		var exp_c := _expect(dmg * hs, rm, step, u2m, shot_c)
		data.expected.weak_grazer = exp_c
		check("weak (Grazer, not capped) == glock.damage * headshot_mult * falloff (%s)" % str(exp_c.value), absf(float(shot_c.damage) - exp_c.value) <= exp_c.tol, "weak %s, tolerance %s" % [str(shot_c.damage), str(exp_c.tol)])

	var per_type := {"watcher": weak_names}
	for t in ["strider", "grazer"]:
		var m: Node = c if t == "grazer" and c != null else await ctx.spawn_ahead(t, 14.0, 30.0 if t == "strider" else -30.0, false, base)
		per_type[t] = Array(await ctx.call_api(m, "weak_spots")) if m != null else []
	data.weak_spots = per_type
	for t in per_type:
		var ws: Array = per_type[t]
		var sheet: Array = o.machine(t, "weak_spot_parts")
		check("%s reports >= 1 weak spot (sheet: %s)" % [t, str(sheet)], not ws.is_empty() and sheet.all(func(s): return ws.has(s)), str(ws))
	return true


func _shot(ctx, m: Node, part: String, min_damage: float = 0.0) -> Dictionary:
	var before := float(m.get("health"))
	# line of sight from the camera to the point we shoot at; when something else is in the way (a tree, another
	# machine) the player moves around the target at the same distance (8 directions) before firing
	var los := {}
	var moves := []
	var base_off: Vector3 = ctx.player_pos() - (m as Node3D).global_position
	base_off.y = 0.0
	for attempt in 9:
		await _aim(ctx, m, part)
		await ctx.physics_frames(2)
		los = _los(ctx, m, _target_point(m, part), part)
		if los.clear:
			break
		moves.append(los.by)
		if attempt == 8:
			break
		var center: Vector3 = (m as Node3D).global_position
		var np := center + base_off.rotated(Vector3.UP, deg_to_rad(45.0 * (attempt + 1)))
		var gy: Variant = await ctx.ground_y(np.x, np.z, center.y + 100.0)
		np.y = float(gy) + 0.1 if gy != null else ctx.player_pos().y
		await ctx.call_api(ctx.game, "teleport", [np])
		await ctx.physics_frames(3)
	await ctx.physics_frames(2)
	var cam: Camera3D = ctx.camera()
	var cam_pos: Vector3 = cam.global_position if cam != null else ctx.player_pos()
	# CS inaccuracy (spread + first-shot inaccuracy) at 10 m can put a bullet beside a small weak spot: a shot that
	# misses, or (aimed at a weak spot) does less than min_damage = body-level damage, is retried - 3 shots at most,
	# waiting for the accuracy to recover; earlier shots are recorded, the measured damage is the last shot's
	var inp = InputSim.new(ctx)
	var d: Dictionary = {}
	var misses := []
	for attempt in 3:
		d = await Combat.shoot(ctx, inp, m)
		if not d.fired or (d.hit and float(d.damage) >= min_damage):
			break
		misses.append(snappedf(float(d.damage), 0.01))
		if is_instance_valid(m) and float(m.get("health")) <= 0.0:
			break
		await ctx.wait(Combat.shot_interval(ctx, "glock"))
		await _aim(ctx, m, part)
		await ctx.physics_frames(2)
	var miss_by := ""
	if not d.hit:
		# report what the shot line meets now (the bullet itself has CS inaccuracy)
		miss_by = str(_los(ctx, m, _target_point(m, part), part).by)
	var after := float(m.get("health")) if is_instance_valid(m) else 0.0
	var dist: float = cam_pos.distance_to(_target_point(m, part)) if is_instance_valid(m) else -1.0
	var how := "camera to the aimed point"
	# without the exact hit distance the hit lies somewhere on the machine: its AABB gives the distance range
	var box: AABB = Frame.global_aabb(m) if is_instance_valid(m) else AABB()
	var dmin := INF
	var dmax := 0.0
	for i in 8:
		var dd := cam_pos.distance_to(box.get_endpoint(i))
		dmin = minf(dmin, dd)
		dmax = maxf(dmax, dd)
	return {"hit": d.hit, "fired": d.fired, "ammo": d.ammo, "damage": float(d.damage), "earlier_shots_damage": misses,
		"health_before": float(d.health_before), "health_lost": before - after, "distance_m": snappedf(dist, 0.01), "distance_from": how,
		"aabb_distance_m": [snappedf(dmin, 0.01), snappedf(dmax, 0.01)],
		"line_of_sight": los.clear, "first_hit": los.by, "blocked_by_before_moving": moves, "miss_blocked_by": miss_by}


func _expect(base: float, rm: float, step: float, u2m: float, shot: Dictionary) -> Dictionary:
	## expected damage at the shot distance; without the exact hit distance allow a band around the estimate
	## (+-0.75 m around the aimed hitbox centre, +-1.5 m around the machine origin)
	var d: float = shot.distance_m
	var f := func(m: float) -> float: return base * pow(rm, (m / u2m) / step)
	var v: float = f.call(d)
	var tol := 0.05
	if shot.distance_from != "fire().distance" and shot.distance_from != "fire().point":
		var near: float = shot.aabb_distance_m[0]
		var far: float = shot.aabb_distance_m[1]
		tol = maxf(absf(f.call(minf(near, d)) - v), absf(f.call(maxf(far, d)) - v)) + 0.05
	return {"value": snappedf(v, 0.01), "tol": snappedf(tol, 0.01), "distance_m": d}


static func _target_point(m: Node, part: String) -> Vector3:
	## body: lower body (centre lowered by 10 % of the height) - from the front the eye sits in front of the body's
	## aim point; weak spots: the machine's own aim point for that part
	if part == "body" or not m.has_method("aim_point"):
		var bx: AABB = Frame.global_aabb(m)
		return bx.get_center() + Vector3(0, -0.1 * bx.size.y, 0)
	return m.call("aim_point", part)


func _aim(ctx, m: Node, part: String) -> void:
	if part == "body":
		var marker := Node3D.new()
		marker.name = "AutotestBodyMarker"
		ctx.runner.add_child(marker)
		marker.global_position = _target_point(m, part)
		await ctx.call_api(ctx.game, "aim_at", [marker, "body"])
		marker.queue_free()
	else:
		await ctx.call_api(ctx.game, "aim_at", [m, part])


static func _los(ctx, m: Node, to: Vector3, part: String = "body") -> Dictionary:
	## ray camera -> to, as a bullet travels (hitbox areas and world bodies; the target's own movement body is not a
	## bullet target). Clear only when the FIRST thing hit is the wanted hitbox of m: for a weak spot the hitbox of that
	## part, for "body" any non-weak hitbox of m. `by` names the first hit either way.
	var cam: Camera3D = ctx.camera()
	if cam == null:
		return {"clear": false, "by": "no camera"}
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, to + (to - cam.global_position).normalized() * 0.5)
	var ex: Array[RID] = ctx.player_rids()
	# machines' movement/blocking bodies (their root body, TrunkBody, ...) are not bullet targets: only their hitboxes
	# (nodes with a "part") are; exclude the rest for every machine, as the bullet trace does
	for mm in ctx.game.get("machines") if ctx.game != null and "machines" in ctx.game else []:
		if not is_instance_valid(mm):
			continue
		if mm is CollisionObject3D:
			ex.append((mm as CollisionObject3D).get_rid())
		for co in (mm as Node).find_children("*", "CollisionObject3D", true, false):
			if not (co as Node).has_meta("part"):
				ex.append((co as CollisionObject3D).get_rid())
	q.exclude = ex
	q.collide_with_areas = true
	var hit: Dictionary = ctx.runner.get_viewport().get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"clear": false, "by": "nothing (no hitbox up to 0.5 m behind the aim point)"}
	var col: Variant = hit.get("collider")
	if not (col is Node):
		return {"clear": false, "by": str(col)}
	var n := col as Node
	var owner_m: Variant = n.get_meta("machine", null)
	var mine: bool = owner_m == m or n == m or m.is_ancestor_of(n)
	var hit_part := str(n.get_meta("part", ""))
	var hit_weak: bool = bool(n.get_meta("weak", false))
	var who: String = (owner_m as Node).name if owner_m is Node else ("a node under the target" if mine else "no machine")
	var label := "%s (part '%s'%s of %s)" % [n.name, hit_part, ", weak" if hit_weak else "", who]
	var ok: bool = mine and (hit_part == part if part != "body" else (hit_part != "" and not hit_weak))
	if not ok and mine and part != "body" and hit_part != "" and not hit_weak and n is CollisionObject3D:
		# first hit is a body box of the target: the weak spot counts only if its hitbox lies INSIDE that box where the
		# ray meets it (the game's rule: weak wins inside an enclosing body box), not behind it
		var ex2: Array[RID] = q.exclude.duplicate()
		for co in m.find_children("*", "CollisionObject3D", true, false):
			if (co as Node).has_meta("part") and not bool((co as Node).get_meta("weak", false)):
				ex2.append((co as CollisionObject3D).get_rid())
		var q2 := PhysicsRayQueryParameters3D.create(q.from, q.to)
		q2.exclude = ex2
		q2.collide_with_areas = true
		var hit2: Dictionary = ctx.runner.get_viewport().get_world_3d().direct_space_state.intersect_ray(q2)
		var n2: Variant = hit2.get("collider")
		if n2 is Node and str((n2 as Node).get_meta("part", "")) == part and (n2 as Node).get_meta("machine", null) == m:
			var inside := _inside_shapes(n as CollisionObject3D, hit2.position)
			label += "; next: %s at %.2f m further, %s it" % [(n2 as Node).name, (hit2.position as Vector3).distance_to(hit.position), "inside" if inside else "behind"]
			ok = inside
	return {"clear": ok, "by": label}


static func _inside_shapes(co: CollisionObject3D, p: Vector3) -> bool:
	## is p inside one of the box/sphere/capsule shapes of co (hitboxes are simple shapes)
	for c in co.get_children():
		if not (c is CollisionShape3D) or (c as CollisionShape3D).shape == null:
			continue
		var cs := c as CollisionShape3D
		var lp: Vector3 = cs.global_transform.affine_inverse() * p
		var sh := cs.shape
		if sh is BoxShape3D:
			var h: Vector3 = (sh as BoxShape3D).size * 0.5 + Vector3(0.01, 0.01, 0.01)
			if absf(lp.x) <= h.x and absf(lp.y) <= h.y and absf(lp.z) <= h.z:
				return true
		elif sh is SphereShape3D:
			if lp.length() <= (sh as SphereShape3D).radius + 0.01:
				return true
		elif sh is CapsuleShape3D:
			var cap := sh as CapsuleShape3D
			var half := maxf(0.0, cap.height * 0.5 - cap.radius)
			var on_axis := Vector3(0, clampf(lp.y, -half, half), 0)
			if lp.distance_to(on_axis) <= cap.radius + 0.01:
				return true
	return false
