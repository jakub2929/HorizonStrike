extends RefCounted
## Real machine sites and campfires from the converted cache (cell.json), and placing the player near them.

const SITE_CELLS := [Vector2i(5, -2), Vector2i(3, -2)]  # sheet t05/t06/s03: real Watcher / Grazer sites


static func find_site(ctx, machine_type: String, min_count: int = 1) -> Dictionary:
	## first spawn of machine_type (count >= min_count) in the site cells; {} when the cache has none (mock data)
	for cell in SITE_CELLS:
		var cj: Dictionary = ctx.oracle.cell_json(cell)
		for s in cj.get("spawns", []):
			if s is Dictionary and str(s.get("type")) == machine_type and int(s.get("count", 1)) >= min_count:
				var pos: Vector3 = ctx.v3(s.get("pos"))
				if pos != Vector3.INF:
					return {"cell": cell, "pos": pos, "site": str(s.get("site")), "orig_type": str(s.get("orig_type")), "count": int(s.get("count", 1)), "radius": float(s.get("radius", 30.0))}
	return {}


static func go_near_site(ctx, site: Dictionary, machine_type: String, need: int, timeout_s: float = 240.0) -> Array:
	## teleports 40 m from the site, waits for its cell and for `need` machines of the type near the site
	var pos: Vector3 = site.pos
	var start: Vector3 = pos + Vector3(40.0, 2.0, 0.0)
	await ctx.call_api(ctx.game, "teleport", [start])
	var box := {"found": []}
	var radius: float = site.radius + 40.0
	var cond := func() -> bool:
		box.found = ctx.machines_of(machine_type).filter(func(m): return (m as Node3D).global_position.distance_to(pos) <= radius and str(m.get("state")) != "dead")
		return box.found.size() >= need
	await ctx.wait_until(cond, timeout_s)
	return box.found


static func place_player_facing(ctx, target: Vector3, dist_m: float, prefer_dir: Vector3 = Vector3.ZERO) -> Dictionary:
	## puts the player dist_m from target on the ground with a clear line of sight (tries 16 directions)
	var dirs := []
	if prefer_dir.length() > 0.01:
		var d := prefer_dir
		d.y = 0.0
		dirs.append(d.normalized())
	for i in 16:
		dirs.append(Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 16.0))
	var world: World3D = ctx.runner.get_viewport().get_world_3d()
	var best := {}
	for d in dirs:
		var p: Vector3 = target + d * dist_m
		var gy: Variant = await ctx.ground_y(p.x, p.z)
		if gy == null:
			continue
		p.y = float(gy) + 0.05
		var eye := p + Vector3(0, 1.6, 0)
		var q := PhysicsRayQueryParameters3D.create(eye, target + Vector3(0, 1.2, 0))
		q.exclude = ctx.player_rids()
		await ctx.physics_frames(1)
		var hit := world.direct_space_state.intersect_ray(q)
		var clear := hit.is_empty() or (hit.position as Vector3).distance_to(target) < 3.0
		if clear:
			best = {"pos": p, "dir": d, "los": true}
			break
		if best.is_empty():
			best = {"pos": p, "dir": d, "los": false}
	if best.is_empty():
		best = {"pos": target + (dirs[0] as Vector3) * dist_m, "dir": dirs[0], "los": false, "no_ground": true}
	await ctx.call_api(ctx.game, "teleport", [best.pos])
	await ctx.physics_frames(2)
	return best
