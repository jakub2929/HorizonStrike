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
			var inside := inside_shapes(n as CollisionObject3D, hit2.position)
			label += "; next: %s at %.2f m further, %s it" % [(n2 as Node).name, (hit2.position as Vector3).distance_to(hit.position), "inside" if inside else "behind"]
			ok = inside
	return {"clear": ok, "by": label}


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
