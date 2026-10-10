extends Node
## Dev only (owner vykon, not exported): where the GPU time of a frame goes, by ablation. After world_ready and the
## start 3x3, at each pose (the start view turned to 4 headings + systems perf.shot_poses) the root viewport's
## measured GPU time is averaged with everything on, then with one item switched off at a time (sun shadows, full-cell
## instances, vegetation (all / trees / thin), terrain, far cells, campfire lights, sky, fog, FXAA, FSR, render scale
## 0.5 / 1.0, coarser LODs). Godot 4.7 exposes no per-pass GPU timestamps to scripts (only viewport begin/end), so
## the cost of an item = baseline - time without it.
##   godot --path game --resolution 1920x1080 --script res://dev/gpu_ablation_run.gd -- --gpu-ablation-out <dir>
##     --gfx-preset low --fps-limit 0 <game args>
## Writes <dir>/ablation.json and prints one line per pose.

const MEASURE_S := 2.5
const SETTLE_S := 0.6

var _out := ""
var _game: Node
var _rid: RID
var _results := {}
var _set := "general"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var a := OS.get_cmdline_user_args()
	var i := a.find("--gpu-ablation-out")
	_out = a[i + 1] if i >= 0 and i + 1 < a.size() else ""
	var j := a.find("--gpu-ablation-set")
	_set = a[j + 1] if j >= 0 and j + 1 < a.size() else "general"
	if _out == "":
		return
	_run.call_deferred()


func _wait(s: float) -> void:
	await get_tree().create_timer(s, true, false, true).timeout


func _gpu(seconds: float) -> Dictionary:
	var sum := 0.0
	var n := 0
	var t0 := Time.get_ticks_msec()
	var f0 := Engine.get_frames_drawn()
	while (Time.get_ticks_msec() - t0) / 1000.0 < seconds:
		await get_tree().process_frame
		sum += RenderingServer.viewport_get_measured_render_time_gpu(_rid)
		n += 1
	var fps := (Engine.get_frames_drawn() - f0) / maxf((Time.get_ticks_msec() - t0) / 1000.0, 0.001)
	return {"gpu_ms": snappedf(sum / maxi(n, 1), 0.01), "fps": snappedf(fps, 0.1),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))}


func _cells() -> Array:
	var w: Node = _game.world
	return w.get_children().filter(func(c): return str(c.name).begins_with("Cell_")) if w else []


func _set_vis(nodes: Array, on: bool) -> void:
	for n in nodes:
		if is_instance_valid(n) and n is Node3D:
			(n as Node3D).visible = on


func _children_named(name: String) -> Array:
	var out := []
	for c in _cells():
		var n: Node = c.get_node_or_null(name)
		if n:
			out.append(n)
	return out


func _veg(trees: Variant) -> Array:
	## vegetation MultiMeshes (GraphicsSettings group): trees = not thin; null = all
	return get_tree().get_nodes_in_group("gfx_vegetation").filter(func(n): return trees == null or bool(n.get_meta("gfx_thin", false)) != bool(trees))


func _inst_mmis() -> Array:
	var out := []
	for n in _children_named("Instances"):
		out.append_array(n.find_children("*", "MultiMeshInstance3D", true, false))
	return out


func _set_cast(nodes: Array, on: bool) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _set_lod(nodes: Array, bias: float) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.lod_bias = bias


func _instance_toggles() -> Array:
	## where inside "instances" the time goes: by cell, by size class (cell_builder._lod_class: vis_end 0 = >= 12 m,
	## always drawn), by distance, shadow casting
	var t := []
	var pc: Vector2i = _game.world.cell_of(_game.player.global_position)
	var cam := get_viewport().get_camera_3d().global_position
	var mine := func(n): return str(n.get_parent().get_parent().name) == "Cell_%d_%d" % [pc.x, pc.y]
	t.append(["inst_player_cell", func(on): _set_vis(_inst_mmis().filter(mine), on)])
	t.append(["inst_other_cells", func(on): _set_vis(_inst_mmis().filter(func(n): return not mine.call(n)), on)])
	t.append(["inst_big_always", func(on): _set_vis(_inst_mmis().filter(func(n): return n.visibility_range_end <= 0.0 and n.visibility_range_begin <= 0.0), on)])
	t.append(["inst_ranged", func(on): _set_vis(_inst_mmis().filter(func(n): return n.visibility_range_end > 0.0), on)])
	t.append(["inst_impostor", func(on): _set_vis(_inst_mmis().filter(func(n): return n.visibility_range_begin > 0.0), on)])
	t.append(["inst_beyond_300m", func(on): _set_vis(_inst_mmis().filter(func(n): return n.global_position.distance_to(cam) > 300.0), on)])
	t.append(["inst_beyond_600m", func(on): _set_vis(_inst_mmis().filter(func(n): return n.global_position.distance_to(cam) > 600.0), on)])
	var casters := _inst_mmis().filter(func(n): return n.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	t.append(["inst_no_shadow_cast", func(on): _set_cast(casters, on)])
	t.append(["inst_lod_bias_0.25", func(on): _set_lod(_inst_mmis(), 1.0 if on else 0.25)])
	var counts := {"mmis": 0, "instances": 0, "big_always": 0, "big_instances": 0}
	for n in _inst_mmis():
		counts.mmis += 1
		counts.instances += n.multimesh.instance_count
		if n.visibility_range_end <= 0.0 and n.visibility_range_begin <= 0.0:
			counts.big_always += 1
			counts.big_instances += n.multimesh.instance_count
	t.append(["_counts", counts])
	return t


func _sun() -> DirectionalLight3D:
	## the scene's sun (main.gd names it "Sun"; the knife preview viewport has its own light)
	for n in get_tree().root.find_children("Sun", "DirectionalLight3D", true, false):
		return n
	return null


func _inst_range(f: float) -> void:
	## distance-culled instance chunks (cell_builder size classes < 12 m) at f x their range
	for n in _inst_mmis():
		if n.visibility_range_end > 0.0:
			if not n.has_meta("abl_end"):
				n.set_meta("abl_end", n.visibility_range_end)
			n.visibility_range_end = float(n.get_meta("abl_end")) * f


func _config_toggles() -> Array:
	## candidate Low settings, each measured against the current preset (on = back to the preset)
	var root := get_tree().root
	var sun := _sun()
	var lod0 := root.mesh_lod_threshold
	var t := []
	t.append(["sun_shadows_off", func(on): sun.shadow_enabled = on])
	t.append(["lod_bias_0.25", func(on): root.mesh_lod_threshold = lod0 if on else lod0 * 2.0])
	t.append(["lod_bias_0.125", func(on): root.mesh_lod_threshold = lod0 if on else lod0 * 4.0])
	t.append(["inst_range_0.7", func(on): _inst_range(1.0 if on else 0.7)])
	t.append(["inst_range_0.5", func(on): _inst_range(1.0 if on else 0.5)])
	t.append(["combo_lod0.25_range0.7", func(on): _combo(on, lod0, 2.0, 0.7, true)])
	t.append(["combo_lod0.25_range0.7_noshadow", func(on): _combo(on, lod0, 2.0, 0.7, false)])
	t.append(["combo_lod0.25_range0.7_scale0.5", func(on): _combo(on, lod0, 2.0, 0.7, true, 0.5)])
	return t


func _combo(on: bool, lod0: float, lod_mult: float, rng: float, shadows: bool, scale: float = -1.0) -> void:
	var root := get_tree().root
	root.mesh_lod_threshold = lod0 if on else lod0 * lod_mult
	_inst_range(1.0 if on else rng)
	var sun := _sun()
	if sun:
		sun.shadow_enabled = true if on else shadows
	if scale > 0.0:
		if not root.has_meta("abl_scale"):
			root.set_meta("abl_scale", root.scaling_3d_scale)
		root.scaling_3d_scale = float(root.get_meta("abl_scale")) if on else scale


func _toggles() -> Array:
	if _set == "instances":
		return _instance_toggles()
	if _set == "configs":
		return _config_toggles()
	var root := get_tree().root
	var sun := _sun()
	var env: Environment = null
	for n in root.find_children("*", "WorldEnvironment", true, false):
		env = (n as WorldEnvironment).environment
	var t := []
	t.append(["sun_shadows", func(on): sun.shadow_enabled = on])
	t.append(["instances", func(on): _set_vis(_children_named("Instances"), on)])
	t.append(["vegetation_all", func(on): _set_vis(_children_named("Vegetation"), on)])
	t.append(["veg_trees", func(on): _set_vis(_veg(true), on)])
	t.append(["veg_thin", func(on): _set_vis(_veg(false), on)])
	t.append(["terrain", func(on): _set_vis(_children_named("Terrain"), on)])
	t.append(["far_cells", func(on): _set_vis((_game.world.far as Dictionary).values(), on)])
	t.append(["machines", func(on): _set_vis(_game.machines, on)])
	t.append(["omni_lights", func(on): _set_vis(root.find_children("*", "OmniLight3D", true, false), on)])
	t.append(["sky_bg", func(on): env.background_mode = Environment.BG_SKY if on else Environment.BG_COLOR])
	t.append(["fog", func(on): env.fog_enabled = on])
	t.append(["fxaa", func(on): root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if on else Viewport.SCREEN_SPACE_AA_DISABLED])
	var mode0 := root.scaling_3d_mode
	var scale0 := root.scaling_3d_scale
	var lod0 := root.mesh_lod_threshold
	t.append(["fsr_to_bilinear", func(on): root.scaling_3d_mode = mode0 if on else Viewport.SCALING_3D_MODE_BILINEAR])
	t.append(["scale_0.5", func(on): root.scaling_3d_scale = scale0 if on else 0.5])
	t.append(["scale_1.0", func(on): root.scaling_3d_scale = scale0 if on else 1.0])
	t.append(["lod_x2", func(on): root.mesh_lod_threshold = lod0 if on else lod0 * 2.0])
	return t


func _pose_run(label: String) -> void:
	var base: Dictionary = await _gpu(MEASURE_S)
	var row := {"baseline": base}
	for e in _toggles():
		if e[0] == "_counts":
			row["counts"] = e[1]
			continue
		e[1].call(false)
		await _wait(SETTLE_S)
		var r: Dictionary = await _gpu(MEASURE_S)
		e[1].call(true)
		r["saves_ms"] = snappedf(base.gpu_ms - r.gpu_ms, 0.01)
		row[e[0]] = r
		await _wait(0.3)
	row["baseline_end"] = await _gpu(MEASURE_S)
	_results[label] = row
	var parts := PackedStringArray()
	for k in row:
		if row[k] is Dictionary and row[k].has("saves_ms"):
			parts.append("%s %+.2f" % [k, -float(row[k].saves_ms)])
	print("ABLATION %s: base %.2f ms (%.0f fps, %d draws) | %s %s" % [label, base.gpu_ms, base.fps, base.draw_calls, ", ".join(parts), str(row.get("counts", ""))])
	_save()


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(_out)
	var f := FileAccess.open(_out.path_join("ablation.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"preset": GraphicsSettings.preset, "settings": GraphicsSettings.describe(),
			"gpu": RenderingServer.get_video_adapter_name(), "poses": _results}, " "))


func _aim(yaw_deg: float, pitch_deg: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	var m := Node3D.new()
	add_child(m)
	m.global_position = cam.global_position + Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) * 100.0
	_game.aim_at(m, "body")
	await _wait(0.3)
	_game.aim_at(m, "body")
	m.queue_free()


func _wait_3x3() -> void:
	var w: Node = _game.world
	var c: Vector2i = w.cell_of(_game.player.global_position)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 240000:
		var all := true
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				all = all and w.is_cell_loaded(c + Vector2i(dx, dy))
		if all:
			return
		await _wait(0.5)


func _run() -> void:
	_game = get_tree().root.get_node("Game")
	while not _game.is_world_ready:
		await get_tree().process_frame
	_rid = get_tree().root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)
	GraphicsSettings.set_value("vsync", false)
	_game.player.invulnerable = true
	await _wait_3x3()
	await _wait(8.0)
	for h in [0, 90, 180, 270]:
		await _aim(float(h), -3.0)
		await _wait(1.0)
		await _pose_run("start_yaw%d" % h)
	var poses: Dictionary = load("res://core/sheets.gd").sys("perf.shot_poses")
	for name in poses:
		var p: Dictionary = poses[name]
		var pos := Vector3(p.pos[0], p.pos[1], p.pos[2])
		_game.teleport(pos)
		await _wait(1.0)
		await _wait_3x3()
		await _wait(4.0)
		_game.teleport(pos)
		await _wait(2.0)
		await _aim(float(p.get("yaw_deg", 0.0)), float(p.get("pitch_deg", 0.0)))
		await _wait(1.0)
		await _pose_run(name)
	print("ABLATION DONE %s" % _out.path_join("ablation.json"))
	_game.quit(0)
