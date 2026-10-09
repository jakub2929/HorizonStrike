extends "res://autotest/lib/scenario.gd"
## r01 Record: before/after screenshots from fixed poses (systems perf.shot_poses: {name: {pos [x,y,z] feet in Godot
## space, yaw_deg (0 = -Z, positive to the left), pitch_deg}}). The same scenario runs with the 0.1.1 baseline build
## (records-0.2/before) and the 0.2 build (records/after). Camera placement is setup (teleport + aim at a point); the
## shot uses Game.screenshot. A blank frame is retried once through an offscreen SubViewport render.

const Frame := preload("res://autotest/lib/frame.gd")
const ORDER := ["mothers_heart", "valley", "rocks_close"]


func _init() -> void:
	timeout_s = 2400.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player"], ["teleport", "aim_at", "screenshot"])):
		return false
	var poses: Variant = ctx.oracle.system("perf.shot_poses")
	if not check("perf.shot_poses filled (systems sheet)", poses is Dictionary and not (poses as Dictionary).is_empty(), str(poses)):
		return false
	if "invulnerable" in p:
		p.set("invulnerable", true)
	var shots := {}
	var names: Array = ORDER.duplicate()
	for k in (poses as Dictionary).keys():
		if not names.has(k):
			names.append(k)  # extra poses (scouting) are shot too
	for name in names:
		if not (poses as Dictionary).has(name):
			check("pose %s defined" % name, false)
			continue
		shots[name] = await _shot(ctx, g, name, poses[name])
	data.shots = shots
	return true


func _shot(ctx, g: Node, name: String, pose: Dictionary) -> Dictionary:
	var pos: Vector3 = ctx.v3(pose.get("pos"))
	var yaw := deg_to_rad(float(pose.get("yaw_deg", 0.0)))
	var pitch := deg_to_rad(float(pose.get("pitch_deg", 0.0)))
	await ctx.call_api(g, "teleport", [pos])
	var loaded: bool = await _wait_3x3(ctx, pos, 600.0)
	await ctx.wait(2.0)
	var eye: Vector3 = ctx.camera().global_position if ctx.camera() != null else pos + Vector3(0, 1.6, 0)
	var dir := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var marker := Node3D.new()
	marker.name = "AutotestPoseMarker"
	ctx.runner.add_child(marker)
	marker.global_position = eye + dir * 100.0
	await ctx.call_api(g, "aim_at", [marker, "body"])
	await ctx.wait(0.5)
	await ctx.call_api(g, "aim_at", [marker, "body"])
	await ctx.physics_frames(2)
	marker.queue_free()
	var shot: Dictionary = await ctx.screenshot("%s.png" % name)
	var blank := float(shot.get("luma_stddev", 0.0)) <= 10.0
	if blank:
		note("%s: screenshot blank (stddev %s) - retried with an offscreen SubViewport render" % [name, str(shot.get("luma_stddev"))])
		shot = await _offscreen(ctx, name)
		shot.via = "offscreen SubViewport (main viewport frame was blank)"
	var cam: Camera3D = ctx.camera()
	var info := {"pose": pose, "cells_3x3_loaded": loaded, "screenshot": shot,
		"camera": str(cam.global_position.round()) if cam != null else ""}
	check("%s: 3x3 around the pose loaded" % name, loaded)
	check("%s: PNG exists (fresh)" % name, shot.get("exists", false) and shot.get("fresh", false), shot.get("path"))
	check("%s: not blank (luma stddev > 10)" % name, float(shot.get("luma_stddev", 0.0)) > 10.0, str(shot.get("luma_stddev")))
	return info


static func _wait_3x3(ctx, pos: Vector3, timeout_s: float) -> bool:
	var c: Variant = ctx.cell_of(pos)
	if c == null:
		await ctx.wait(10.0)
		return false
	var w: Variant = ctx.game.get("world") if "world" in ctx.game else null
	if not (w is Object and w.has_method("is_cell_loaded")):
		await ctx.wait(10.0)
		return false
	var want := []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			want.append((c as Vector2i) + Vector2i(dx, dy))
	return await ctx.wait_until(func(): return want.all(func(x): return bool(w.call("is_cell_loaded", x))), timeout_s)


static func _offscreen(ctx, name: String) -> Dictionary:
	## render the same camera into an offscreen SubViewport (fallback when the window frame was blank)
	var cam: Camera3D = ctx.camera()
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.world_3d = ctx.runner.get_viewport().world_3d
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var c2 := Camera3D.new()
	vp.add_child(c2)
	ctx.runner.add_child(vp)
	if cam != null:
		c2.global_transform = cam.global_transform
		c2.fov = cam.fov
		c2.far = cam.far
	c2.current = true
	for i in 4:
		await RenderingServer.frame_post_draw
	var path: String = ctx.out_dir.path_join("%s.png" % name)
	var img := vp.get_texture().get_image()
	if img != null:
		img.save_png(path)
	vp.queue_free()
	return Frame.analyze_png(path, ctx.run_start_unix)
