extends "res://autotest/lib/scenario.gd"
## s03 Screenshot: Grazer herd in the landscape, from a point 40-60 m from a real herd site (cells [5,-2] / [3,-2]),
## the first candidate view verified from the camera. Checks: not blank, >= 3 Grazers inside the frustum and not occluded (ray test), real terrain in the
## cell (cell.json terrain.real), vegetation instances around the player.

const Frame := preload("res://autotest/lib/frame.gd")
const Sites := preload("res://autotest/lib/sites.gd")

const NEED := 3
const MAX_TRIES := 10


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["machines", "player"], ["teleport", "aim_at"])):
		return false
	await Sites.ensure_cells(ctx)   # fresh cache: the site cell converts when the player goes there
	var site: Dictionary = Sites.find_site(ctx, "grazer", NEED, ["watcher"])
	if site.is_empty():
		site = Sites.find_site(ctx, "grazer", NEED)
	var herd := []
	var cell := Vector2i.ZERO
	if not site.is_empty():
		cell = site.cell
		data.site = {"cell": str(site.cell), "site": site.site, "orig_type": site.orig_type, "count": site.count}
		herd = await Sites.go_near_site(ctx, site, "grazer", NEED)
		check("grazer herd present at the real site %s" % site.site, herd.size() >= NEED, "%d found" % herd.size())
	else:
		note("no grazer herd site in the cache (mock data?) - spawned %d grazers" % NEED)
		data.site = {"spawned": true}
		for i in NEED:
			var m: Node = await ctx.spawn_ahead("grazer", 50.0 + 4.0 * i, -8.0 + 8.0 * i, true)
			if m != null:
				herd.append(m)
	if herd.size() < NEED:
		return false
	# a screenshot, not an AI test: the herd holds still so the chosen view still shows it at capture time
	for m in herd:
		ctx.set_ai(m, false)
	var center := Vector3.ZERO
	for m in herd:
		center += (m as Node3D).global_position
	center /= herd.size()
	# candidate view points (rings 40/50/60 m x 16 directions on loaded ground), best first by the herd members a ray
	# from eye height reaches; each one is then verified from the real camera with the same check as below, and the
	# screenshot is taken at the first that shows >= NEED unoccluded grazers (composition used to be flaky: one
	# grazer behind vegetation). None verified -> the best one is captured and the check fails.
	var cands: Array = await _candidates(ctx, center, herd)
	data.candidates = cands.size()
	var marker := Node3D.new()
	marker.name = "AutotestHerdMarker"
	ctx.runner.add_child(marker)
	marker.global_position = center + Vector3(0, 1.0, 0)
	var tried := []
	var chosen: Dictionary = {}
	for c in cands.slice(0, MAX_TRIES):
		await ctx.call_api(g, "teleport", [c.pos])
		await ctx.call_api(g, "aim_at", [marker, "body"])
		await ctx.wait(1.0)
		await ctx.call_api(g, "aim_at", [marker, "body"])
		await ctx.physics_frames(2)
		var v: Dictionary = _visibility(ctx)
		tried.append({"pos": str(c.pos), "dist": c.dist, "rise": c.rise, "estimate": c.seen, "verified": v.visible})
		if v.visible >= NEED:
			chosen = c
			break
	data.view_tries = tried
	if chosen.is_empty() and not cands.is_empty():
		note("no candidate view verified >= %d unoccluded grazers; capturing from the best estimate" % NEED)
		chosen = cands[0]
		await ctx.call_api(g, "teleport", [chosen.pos])
		await ctx.call_api(g, "aim_at", [marker, "body"])
		await ctx.wait(1.0)
	await ctx.call_api(g, "aim_at", [marker, "body"])
	await ctx.physics_frames(2)
	data.view_point = {"pos": str(chosen.get("pos")), "height_above_herd_m": chosen.get("rise"), "distance_m": chosen.get("dist"), "members_visible_estimate": chosen.get("seen")}
	var shot: Dictionary = await ctx.screenshot("herd_landscape.png")
	# the check is evaluated for the frame that was saved (camera and herd unchanged: herd AI is off)
	var vis: Dictionary = _visibility(ctx)
	marker.queue_free()
	data.screenshot = shot
	check("file exists (fresh)", shot.get("exists", false) and shot.get("fresh", false), shot.get("path"))
	check("not blank (luma stddev > 10)", float(shot.get("luma_stddev", 0.0)) > 10.0, str(shot.get("luma_stddev")))
	data.grazers_in_frustum = vis.seen
	check(">= %d grazers inside the frustum and not occluded" % NEED, vis.visible >= NEED, "%d in frustum, %d unoccluded (view %d of %d tried)" % [vis.seen.size(), vis.visible, tried.size(), mini(cands.size(), MAX_TRIES)])

	var pcv: Variant = ctx.cell_of(ctx.player_pos())
	var pc: Vector2i = pcv if pcv != null else cell
	var cj: Dictionary = ctx.oracle.cell_json(pc)
	data.player_cell = "%d_%d" % [pc.x, pc.y]
	data.terrain = cj.get("terrain", {})
	check("cell.json terrain.real == true in the player's cell", cj.get("terrain", {}).get("real", false) == true, str(cj.get("terrain", {}).get("real")) if not cj.is_empty() else "no cell.json for %s" % data.player_cell)
	var veg := 0
	for mm in ctx.tree.root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := mm as MultiMeshInstance3D
		if mmi.multimesh == null or not mmi.is_visible_in_tree():
			continue
		var area := AABB(ctx.player_pos() - Vector3(300, 2000, 300), Vector3(600, 4000, 600))
		if not (mmi.global_transform * mmi.get_aabb()).intersects(area):
			continue
		var n := mmi.multimesh.visible_instance_count
		veg += n if n >= 0 else mmi.multimesh.instance_count
	data.vegetation_instances_near = veg
	check("vegetation instances > 0 within 300 m of the player", veg > 0, str(veg))
	return true


func _candidates(ctx, center: Vector3, herd: Array) -> Array:
	## ground points 40-60 m from the herd (loaded collision only) with the number of herd members reachable by a ray
	## from eye height; sorted: more members, nearer ring, higher ground
	var world: World3D = ctx.runner.get_viewport().get_world_3d()
	var out := []
	for r in [40.0, 50.0, 60.0]:
		for i in 16:
			var d := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 16.0)
			var p: Vector3 = center + d * r
			var gy: Variant = await ctx.ground_y(p.x, p.z)
			if gy == null:
				continue
			p.y = float(gy) + 0.05
			var eye := p + Vector3(0, 1.6, 0)
			var seen := 0
			for m in herd:
				if is_instance_valid(m) and Frame.line_of_sight(world, eye, Frame.global_aabb(m).get_center(), m, ctx.player_rids()).clear:
					seen += 1
			if seen > 0:
				out.append({"pos": p, "rise": snappedf(p.y - center.y, 0.1), "dist": r, "seen": seen})
	var better := func(a, b) -> bool:
		if a.seen != b.seen:
			return a.seen > b.seen
		if a.dist != b.dist:
			return a.dist < b.dist
		return a.pos.y > b.pos.y
	out.sort_custom(better)
	return out


func _visibility(ctx) -> Dictionary:
	## grazers whose centre is inside the camera frustum, and how many of them a ray from the camera reaches
	var cam: Camera3D = ctx.camera()
	var world: World3D = ctx.runner.get_viewport().get_world_3d()
	var seen := []
	if cam != null:
		for m in ctx.machines_of("grazer"):
			if str(m.get("state")) == "dead":
				continue
			var box := Frame.global_aabb(m)
			var c := box.get_center()
			if not cam.is_position_in_frustum(c):
				continue
			var los: Dictionary = Frame.line_of_sight(world, cam.global_position, c, m, ctx.player_rids())
			seen.append({"name": str(m.name), "frac_h": Frame.screen_box(cam, box).frac_h, "clear": los.clear, "by": los.by})
	return {"seen": seen, "visible": seen.filter(func(x): return x.clear).size()}
