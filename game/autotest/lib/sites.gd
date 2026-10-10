extends RefCounted
## Real machine sites and campfires from the converted cache (cell.json), and placing the player near them.

const SITE_CELLS := [Vector2i(5, -2), Vector2i(3, -2)]  # sheet t05/t06/s03: real Watcher / Grazer sites


## open snow field south of FE_Antelope_Scout (cell 5,-2): the fixed test field of t04 and t13
const TEST_FIELD := Vector3(2582.0, 178.0, 780.0)


static func go_test_field(ctx, ring_m: float) -> Dictionary:
	## setup for shooting tests, independent of where earlier scenarios left the player: the site cells exist (fresh
	## cache), the player is on TEST_FIELD's cell once it is loaded, then on the nearest ground point with a clear ring of
	## ring_m (ctx.clear_spot), standing still. {pos, clear, tried, cells}
	var g: Node = ctx.game
	var cells: Dictionary = await ensure_cells(ctx)
	var out := {"cells": cells}
	await ctx.call_api(g, "teleport", [TEST_FIELD])
	var c: Variant = ctx.cell_of(TEST_FIELD)
	var w: Variant = g.get("world") if "world" in g else null
	if w is Object and w.has_method("is_cell_loaded") and c != null:
		await ctx.wait_until(func(): return bool(w.call("is_cell_loaded", c)), 300.0)
	await ctx.wait(2.0)
	# the field's own herd (FE_Antelope_Scout) stays where it is: AI off while the scenario runs (ctx restores it)
	var frozen := 0
	for m in g.get("machines"):
		if is_instance_valid(m) and not ctx.spawned.has(m) and (m as Node3D).global_position.distance_to(TEST_FIELD) < 200.0:
			ctx.set_ai(m, false)
			frozen += 1
	out.frozen_world_machines = frozen
	var gy: Variant = await ctx.ground_y(TEST_FIELD.x, TEST_FIELD.z)
	var center := Vector3(TEST_FIELD.x, float(gy) if gy != null else TEST_FIELD.y, TEST_FIELD.z)
	var spot: Dictionary = await ctx.clear_spot(center, ring_m)
	out.pos = spot.pos
	out.clear = spot.clear
	out.tried = spot.tried
	await ctx.call_api(g, "teleport", [(spot.pos as Vector3) + Vector3(0, 0.05, 0)])
	var p: Node = ctx.player
	await ctx.physics_frames(3)
	await ctx.wait_until(func(): return p.get("_hold_until_ground") != true and p.call("is_on_floor"), 30.0)
	await ctx.wait(0.5)
	return out


static func ensure_cells(ctx, timeout_s: float = 240.0) -> Dictionary:
	## the site cells are converted on demand: on a fresh cache (first run, release suite) they are not on disk yet when a
	## site scenario starts near the start campfire. Setup: the player goes to each missing site cell (teleport) so the
	## game requests it, until its cell.json exists. Mock data has no such cells: nothing to do there.
	var out := {}
	if ctx.args.has("--mock-data"):
		return out
	var cs := float(ctx.oracle.f(ctx.oracle.system("streaming.cell_size_m")))
	for cell in SITE_CELLS:
		if not ctx.oracle.cell_json(cell).is_empty():
			continue
		var t0 := Time.get_ticks_msec()
		var c := preload("res://autotest/lib/route.gd").cell_center(cell, cs)
		var p: Node = ctx.player
		var was: Variant = p.get("invulnerable") if p != null and "invulnerable" in p else null
		if was != null:
			p.set("invulnerable", true)
		# below the terrain: the game holds the player until the cell's ground exists and lifts him onto it
		await ctx.call_api(ctx.game, "teleport", [c])
		var ok: bool = await ctx.wait_until(func(): return not ctx.oracle.cell_json(cell).is_empty(), timeout_s)
		var gy: Variant = null
		var deadline := Time.get_ticks_msec() + 60000
		while ok and gy == null and Time.get_ticks_msec() < deadline:
			gy = await ctx.ground_y(c.x, c.z, 3000.0)
			if gy == null:
				await ctx.wait(0.5)
		if gy != null:
			await ctx.call_api(ctx.game, "teleport", [Vector3(c.x, float(gy) + 0.3, c.z)])
			await ctx.wait(1.0)
		if was != null:
			p.set("invulnerable", was)
		out[str(cell)] = {"converted": ok, "seconds": snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)}
		ctx.note("site cell %s requested by going there: cell.json %s after %.1f s" % [str(cell), "present" if ok else "MISSING", (Time.get_ticks_msec() - t0) / 1000.0])
	return out


static func find_site(ctx, machine_type: String, min_count: int = 1, avoid_types: Array = [], avoid_m: float = 120.0) -> Dictionary:
	## a spawn of machine_type (count >= min_count) in the site cells, preferring sites whose original HZD machine is
	## this machine itself (e.g. a Grazer herd at an antelope site, not at a variant-B site); {} when the cache has none
	var own := str(MachinesSheet.ROWS.get(machine_type, {}).get("hzd_internal_name", ""))
	var best := {}
	for cell in SITE_CELLS:
		var cj: Dictionary = ctx.oracle.cell_json(cell)
		for s in cj.get("spawns", []):
			if s is Dictionary and str(s.get("type")) == machine_type and int(s.get("count", 1)) >= min_count:
				var pos: Vector3 = ctx.v3(s.get("pos"))
				if pos == Vector3.INF:
					continue
				var site := {"cell": cell, "pos": pos, "site": str(s.get("site")), "orig_type": str(s.get("orig_type")), "count": int(s.get("count", 1)), "radius": float(s.get("radius", 30.0))}
				var guarded := false
				for o in cj.get("spawns", []):
					if o is Dictionary and str(o.get("type")) in avoid_types and ctx.v3(o.get("pos")).distance_to(pos) <= avoid_m:
						guarded = true
				if guarded:
					continue
				if site.orig_type == own:
					return site
				if best.is_empty():
					best = site
	return best


static func go_near_site(ctx, site: Dictionary, machine_type: String, need: int, timeout_s: float = 240.0) -> Array:
	## teleports 40 m from the site, waits for its cell and for `need` machines of the type near the site
	var pos: Vector3 = site.pos
	var start: Vector3 = pos + Vector3(40.0, 2.0, 0.0)
	# the ground 40 m from the site can be far below the site: invulnerable while moving there (setup, not a fall
	# test), then put down on the loaded ground
	var p: Node = ctx.player
	var was: Variant = p.get("invulnerable") if p != null and "invulnerable" in p else null
	if was != null:
		p.set("invulnerable", true)
	await ctx.call_api(ctx.game, "teleport", [start])
	var ground := {"y": null}
	var deadline := Time.get_ticks_msec() + 120000
	while ground.y == null and Time.get_ticks_msec() < deadline:
		ground.y = await ctx.ground_y(start.x, start.z, start.y + 300.0)
		if ground.y == null:
			await ctx.wait(0.5)
	if ground.y != null:
		await ctx.call_api(ctx.game, "teleport", [Vector3(start.x, float(ground.y) + 0.3, start.z)])
	await ctx.wait(1.0)
	if was != null:
		p.set("invulnerable", was)
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
