extends RefCounted
## Weak-spot hit checks shared by t04 and t13: the point to aim at for a part, and whether the FIRST thing a bullet
## meets on the way from the camera is that part's hitbox (game rule: a weak hitbox inside an enclosing body box
## counts, one behind it does not).

const Frame := preload("res://autotest/lib/frame.gd")


static func target_point(m: Node, part: String) -> Vector3:
	## body: lower body (centre lowered by 10 % of the height) - from the front the eye sits in front of the body's
	## aim point; weak spots: the machine's own aim point for that part
	if part == "body" or not m.has_method("aim_point"):
		var bx: AABB = Frame.global_aabb(m)
		return bx.get_center() + Vector3(0, -0.1 * bx.size.y, 0)
	return m.call("aim_point", part)


static func first_hit(ctx, m: Node, to: Vector3, part: String = "body") -> Dictionary:
	## ray camera -> to, as a bullet travels (hitbox areas and world bodies; the target's own movement body is not a
	## bullet target). Clear only when the FIRST thing hit is the wanted hitbox of m: for a weak spot the hitbox of that
	## part, for "body" any non-weak hitbox of m. `by` names the first hit either way.
	var cam: Camera3D = ctx.player_camera()
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
	var owner_m: Variant = (n.get_meta("machine") if n.has_meta("machine") else null)
	var mine: bool = owner_m == m or n == m or m.is_ancestor_of(n)
	var hit_part := str(n.get_meta("part", ""))
	var hit_weak: bool = bool(n.get_meta("weak", false))
	var who: String = (owner_m as Node).name if owner_m is Node else ("a node under the target" if mine else "no machine")
	var label := "%s (part '%s'%s of %s)" % [n.name, hit_part, ", weak" if hit_weak else "", who]
	var ok: bool = mine and (hit_part == part if part != "body" else (hit_part != "" and not hit_weak))
	var dist: float = cam.global_position.distance_to(hit.position)
	if ok and part == "body":
		# the game's trace (player/weapons.gd) gives the hit to a weak spot of the same machine when it lies within
		# WEAK_SLACK_M behind the body surface or inside one of its body boxes: a body shot must have neither on its line
		var w := weak_behind(ctx, m, q.from, q.to, hit.position)
		if w != "":
			ok = false
			label += "; " + w
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
		if n2 is Node and str((n2 as Node).get_meta("part", "")) == part and (n2 as Node).has_meta("machine") and (n2 as Node).get_meta("machine") == m:
			var inside := inside_shapes(n as CollisionObject3D, hit2.position)
			label += "; next: %s at %.2f m further, %s it" % [(n2 as Node).name, (hit2.position as Vector3).distance_to(hit.position), "inside" if inside else "behind"]
			ok = inside
	return {"clear": ok, "by": label, "dist": dist, "pos": hit.position}


const WEAK_SLACK_M := 0.15  # player/weapons.gd WEAK_SLACK_M: a weak spot this close behind a body surface takes the hit


static func weak_behind(ctx, m: Node, from: Vector3, to: Vector3, body_hit: Vector3) -> String:
	## "" when no weak hitbox of m takes a shot that first meets m's body at body_hit (game rule above), else which one
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	var ex: Array[RID] = ctx.player_rids()
	for i in 32:
		q.exclude = ex
		var h: Dictionary = ctx.runner.get_viewport().get_world_3d().direct_space_state.intersect_ray(q)
		if h.is_empty():
			return ""
		var n: Variant = h.get("collider")
		if not (n is CollisionObject3D):
			return ""
		var node := n as Node
		if node.has_meta("machine") and node.get_meta("machine") == m and bool(node.get_meta("weak", false)):
			var d_body := from.distance_to(body_hit)
			var d_weak := from.distance_to(h.position)
			if d_weak <= d_body + WEAK_SLACK_M:
				return "weak %s %.2f m behind the body surface" % [node.get_meta("part", ""), d_weak - d_body]
			for co in m.find_children("*", "CollisionObject3D", true, false):
				if (co as Node).has_meta("part") and not bool((co as Node).get_meta("weak", false)) and inside_shapes(co as CollisionObject3D, h.position):
					return "weak %s inside body box %s" % [node.get_meta("part", ""), (co as Node).name]
			return ""
		ex.append((n as CollisionObject3D).get_rid())
	return ""


static func steady(ctx, timeout_s: float = 15.0) -> Dictionary:
	## setup wait before a measured shot: the player stands on loaded ground (not held after a teleport, not in the air,
	## not moving) and the landing penalty has decayed - CS inaccuracy adds inaccuracy_jump (0.088 rad Glock: 74 cm at
	## 8 m) while airborne and inaccuracy_move while moving, which puts a body-aimed bullet on a weak spot
	var p: Node = ctx.player
	var t0 := Time.get_ticks_msec()
	var still := func() -> bool:
		return p != null and p.get("_hold_until_ground") != true and p.call("is_on_floor") and float(p.get("horizontal_speed")) < 0.05
	var ok: bool = await ctx.wait_until(still, timeout_s)
	if ok:
		await ctx.wait(0.4)   # land penalty decays at 3/s (player.gd)
	return {"ok": ok, "seconds": snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.01)}


static func damage_mult(ctx) -> float:
	## the player's damage upgrade (0.3: upgrades.damage, applied before armour and weak-spot multipliers) as it stands in
	## the profile this run uses - expected damage values include it instead of rewriting the player's progression
	var g: Node = ctx.game
	var prog: Variant = g.get("progression") if g != null and "progression" in g else null
	if not (prog is Dictionary):
		return 1.0
	var lvl := int((prog.get("upgrades", {}) as Dictionary).get("damage", 0)) if prog.get("upgrades") is Dictionary else 0
	var row: Variant = ctx.oracle.system("upgrades.damage") if SystemsSheet.ROWS.has("upgrades.damage") else null
	var pct := float(row.get("pct_per_level", 0)) if row is Dictionary else 0.0
	return 1.0 + pct / 100.0 * lvl


static func spread_margin(ctx, dist: float) -> float:
	## how far a bullet of the weapon in hand can land from the aimed line at dist, standing still (CS: inaccuracy_stand
	## (crouch when crouched) + spread, radians, primary mode) + 2 cm aim tolerance; knives and grenades: 3 cm
	var p: Node = ctx.player
	var id := str(p.get("current_weapon")) if p != null else ""
	var o = ctx.oracle
	var row: Dictionary = WeaponsSheet.ROWS.get(id, {})
	if id == "" or str(row.get("category", "")) in ["knife", "grenade", "equipment"]:
		return 0.03
	var crouched: bool = p != null and bool(p.get("crouched"))
	var inacc: float = o.num(o.weapon(id, "inaccuracy_crouch" if crouched else "inaccuracy_stand"), 0)
	var spread: float = o.num(o.weapon(id, "spread"), 0)
	if is_nan(inacc):
		inacc = 0.01
	if is_nan(spread):
		spread = 0.0
	return (inacc + spread) * dist + 0.02


static func aim_body(ctx, inp, m: Node, max_dist: float = INF, margin_m: float = -1.0) -> Dictionary:
	## turns the camera (relative mouse motion) onto a point of m's body that a shot from the camera meets first as a
	## non-weak body hitbox (no weak spot taking it by the game's rule), within max_dist (knife reach), also margin_m
	## up/down/left/right of it (default: spread_margin of the weapon in hand at that distance); waits first until the
	## player stands still (steady); checked again along the camera's real view line after aiming.
	## {ok, point, dist, margin_m, by, tried, steady}
	var st: Dictionary = await steady(ctx)
	var cam: Camera3D = ctx.player_camera()
	if cam == null or not is_instance_valid(m):
		return {"ok": false, "why": "no camera / machine"}
	var cands := []
	for pt in body_points(m):
		var r: Dictionary = first_hit(ctx, m, pt, "body")
		if not r.clear or float(r.dist) > max_dist:
			continue
		var margin: float = margin_m if margin_m >= 0.0 else spread_margin(ctx, float(r.dist))
		var d: Vector3 = (pt - cam.global_position).normalized()
		var right := d.cross(Vector3.UP).normalized()
		var up := right.cross(d).normalized()
		var all_clear := true
		for off in [right, -right, up, -up, (right + up).normalized(), (right - up).normalized(), (-right + up).normalized(), (-right - up).normalized()]:
			var r2: Dictionary = first_hit(ctx, m, pt + off * margin, "body")
			if not r2.clear or float(r2.dist) > max_dist:
				all_clear = false
				break
		if all_clear:
			cands.append({"pt": pt, "dist": float(r.dist), "margin": margin})
	cands.sort_custom(func(x, y): return x.dist < y.dist)
	var last := {}
	for c in cands.slice(0, 6):
		var aim: Dictionary = await inp.aim_at_point(c.pt, 0.0015, 160)
		await ctx.physics_frames(1)
		var fwd := -cam.global_transform.basis.z
		var check: Dictionary = first_hit(ctx, m, cam.global_position + fwd * cam.global_position.distance_to(c.pt), "body")
		last = {"ok": bool(check.clear) and float(check.get("dist", INF)) <= max_dist and bool(aim.get("ok", false)), "point": c.pt,
			"dist": snappedf(float(check.get("dist", -1.0)), 0.01), "margin_m": snappedf(float(c.margin), 0.001), "by": check.by, "aim": aim,
			"tried": cands.size(), "steady": st}
		if last.ok:
			return last
	if last.is_empty():
		return {"ok": false, "why": "no body point with a clear first hit within %.2f m and the spread margin (%d points)" % [max_dist, body_points(m).size()], "steady": st}
	return last


static func body_points(m: Node) -> Array:
	## aim points for a body shot: the default body point, then the centre of every body (non-weak) hitbox shape
	var out := [target_point(m, "body")]
	for co in m.find_children("*", "CollisionObject3D", true, false):
		var n := co as Node
		if not n.has_meta("part") or bool(n.get_meta("weak", false)):
			continue
		for c in n.get_children():
			if c is CollisionShape3D:
				out.append((c as CollisionShape3D).global_position)
	return out


static func weak_distance(ctx, m: Node, to: Vector3, part: String) -> float:
	## camera -> the first hitbox area of m's part along the ray to `to` (where the game measures the falloff when the
	## weak spot wins); -1 when the ray never meets it
	var cam: Camera3D = ctx.player_camera()
	if cam == null:
		return -1.0
	var space: PhysicsDirectSpaceState3D = ctx.runner.get_viewport().get_world_3d().direct_space_state
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, to + (to - from).normalized() * 2.0)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	var ex: Array[RID] = []
	for i in 24:
		q.exclude = ex
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			return -1.0
		var n: Variant = hit.get("collider")
		if n is Node and (n as Node).has_meta("machine") and (n as Node).get_meta("machine") == m and str((n as Node).get_meta("part", "")) == part:
			return from.distance_to(hit.position)
		if not (n is CollisionObject3D):
			return -1.0
		ex.append((n as CollisionObject3D).get_rid())
	return -1.0


static func inside_shapes(co: CollisionObject3D, p: Vector3) -> bool:
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
