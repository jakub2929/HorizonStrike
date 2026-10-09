extends "res://autotest/lib/scenario.gd"
## s03 Screenshot: Grazer herd in the landscape, from a raised point 40-60 m from a real herd site (cells [5,-2] /
## [3,-2]). Checks: not blank, >= 3 Grazers inside the frustum and not occluded (ray test), real terrain in the
## cell (cell.json terrain.real), vegetation instances around the player.

const Frame := preload("res://autotest/lib/frame.gd")
const Sites := preload("res://autotest/lib/sites.gd")

const NEED := 3


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["machines", "player"], ["teleport", "aim_at"])):
		return false
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
		if "ai_enabled" in m:
			m.set("ai_enabled", false)
	var center := Vector3.ZERO
	for m in herd:
		center += (m as Node3D).global_position
	center /= herd.size()
	var view: Dictionary = await _raised_point(ctx, center, herd)
	data.view_point = {"pos": str(view.get("pos")), "height_above_herd_m": view.get("rise"), "distance_m": view.get("dist"), "members_visible_when_chosen": view.get("seen")}
	await ctx.call_api(g, "teleport", [view.pos])
	var marker := Node3D.new()
	marker.name = "AutotestHerdMarker"
	ctx.runner.add_child(marker)
	marker.global_position = center + Vector3(0, 1.0, 0)
	await ctx.call_api(g, "aim_at", [marker, "body"])
	await ctx.wait(2.0)
	await ctx.call_api(g, "aim_at", [marker, "body"])
	await ctx.physics_frames(2)
	var shot: Dictionary = await ctx.screenshot("herd_landscape.png")
	marker.queue_free()
	for m in herd:
		if is_instance_valid(m) and "ai_enabled" in m:
			m.set("ai_enabled", true)
	data.screenshot = shot
	check("file exists (fresh)", shot.get("exists", false) and shot.get("fresh", false), shot.get("path"))
	check("not blank (luma stddev > 10)", float(shot.get("luma_stddev", 0.0)) > 10.0, str(shot.get("luma_stddev")))

	var cam: Camera3D = ctx.camera()
	var world: World3D = ctx.runner.get_viewport().get_world_3d()
	var seen := []
	await ctx.physics_frames(1)
	for m in ctx.machines_of("grazer"):
		if str(m.get("state")) == "dead" or cam == null:
			continue
		var box := Frame.global_aabb(m)
		var c := box.get_center()
		if not cam.is_position_in_frustum(c):
			continue
		var los: Dictionary = Frame.line_of_sight(world, cam.global_position, c, m, ctx.player_rids())
		seen.append({"name": str(m.name), "frac_h": Frame.screen_box(cam, box).frac_h, "clear": los.clear, "by": los.by})
	data.grazers_in_frustum = seen
	var visible := seen.filter(func(s): return s.clear).size()
	check(">= %d grazers inside the frustum and not occluded" % NEED, visible >= NEED, "%d in frustum, %d unoccluded" % [seen.size(), visible])

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


func _raised_point(ctx, center: Vector3, herd: Array) -> Dictionary:
	## ground 40-60 m from the herd (loaded collision only) from which the most herd members are unoccluded (one ray
	## from eye height to each member's centre); ties go to the nearer ring, then the higher point
	var world: World3D = ctx.runner.get_viewport().get_world_3d()
	var best := {}
	for r in [40.0, 50.0, 60.0]:
		for i in 24:
			var d := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 24.0)
			var p: Vector3 = center + d * r
			var gy: Variant = await ctx.ground_y(p.x, p.z)
			if gy == null:
				continue
			p.y = float(gy) + 0.05
			var eye := p + Vector3(0, 1.6, 0)
			var seen := 0
			for m in herd:
				if not is_instance_valid(m):
					continue
				var los: Dictionary = Frame.line_of_sight(world, eye, Frame.global_aabb(m).get_center(), m, ctx.player_rids())
				if los.clear:
					seen += 1
			if seen > 0 and (best.is_empty() or seen > int(best.seen) or (seen == int(best.seen) and r == float(best.dist) and p.y > float(best.pos.y))):
				best = {"pos": p, "rise": snappedf(p.y - center.y, 0.1), "dist": r, "seen": seen}
	if best.is_empty():
		best = {"pos": center + Vector3(50.0, 10.0, 0.0), "rise": 10.0, "dist": 50.0, "seen": 0}
		note("no loaded ground with a view of the herd; used +50 m east, +10 m up")
	return best
