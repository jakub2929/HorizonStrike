extends SceneTree
## Dev check of the graphics settings (owner vykon), not exported:
##   godot [--headless] --path game --script res://dev/perf_settings_check.gd -- --mock-data --cache-dir <dir>
##         --user-dir <dir> [--expect-saved]
## Boots the main scene, opens the Esc menu (setup), then drives the Graphics page with real mouse clicks
## (Input.parse_input_event on the buttons' centres) and checks that every change is applied at once (root viewport,
## Engine, Environment, sun, vegetation chunks) and written to <user-dir>/graphics.json. With --expect-saved a second
## run checks the values written by the first one survived the restart.

var _fails: PackedStringArray = []
var _gs: Node
var _cursor := Vector2.ZERO


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_fails.append(what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _click_named(node_name: String) -> bool:
	var c := root.find_child(node_name, true, false) as Control
	if c == null or not c.is_visible_in_tree():
		print("  (no visible control %s)" % node_name)
		return false
	var pos: Vector2 = root.get_final_transform() * (c.get_global_rect().get_center())
	var mv := InputEventMouseMotion.new()
	mv.position = pos
	mv.global_position = pos
	mv.relative = pos - _cursor
	Input.parse_input_event(mv)
	_cursor = pos
	await _frames(2)
	for pressed in [true, false]:
		# hover again right before press and release: a stray OS mouse move over the window in between resets the
		# button's hover state and the release then does not count as a click
		var hv := InputEventMouseMotion.new()
		hv.position = pos
		hv.global_position = pos
		hv.button_mask = 0 if pressed else MOUSE_BUTTON_MASK_LEFT
		Input.parse_input_event(hv)
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = pos
		e.global_position = pos
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		Input.parse_input_event(e)
		await _frames(2)
	return true


func _run() -> void:
	var game: Node = root.get_node("Game")
	_gs = root.get_node("GraphicsSettings")
	var user_dir := ""
	var args := OS.get_cmdline_user_args()
	var i := args.find("--user-dir")
	if i >= 0:
		user_dir = args[i + 1]
	var t0 := Time.get_ticks_msec()
	while not game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	_check(game.is_world_ready, "world_ready")
	await _frames(30)
	var file: String = _gs.get_script().settings_path()
	if args.has("--expect-saved"):
		_check(_gs.preset == "custom", "restart: preset custom (got %s)" % _gs.preset)
		_check(is_equal_approx(_gs.veg_density, 0.25), "restart: veg density 0.25 (got %s)" % _gs.veg_density)
		_check(_gs.fps_limit == 30, "restart: fps limit 30 (got %d)" % _gs.fps_limit)
		_check(_gs.shadow_quality == "low", "restart: shadow quality low (got %s)" % _gs.shadow_quality)
		_check(is_equal_approx(root.scaling_3d_scale, 0.67), "restart: render scale applied 0.67 (got %.2f)" % root.scaling_3d_scale)
		_finish()
		return
	var veg := get_nodes_in_group("gfx_vegetation")
	print("  vegetation chunks tracked: %d" % veg.size())
	# setup: open the Esc menu (automated runs ignore Esc)
	var sm: Node = null
	for n in game.main.get_children():
		if n.has_method("open") and n.has_method("is_open") and n.get_node_or_null("SettingsMenu") != null:
			sm = n
	_check(sm != null, "Esc menu found")
	if sm == null:
		_finish()
		return
	sm.open()
	await _frames(3)
	_check(await _click_named("GraphicsButton"), "click Graphics in the Esc menu")
	await _frames(3)
	var gm := root.find_child("GraphicsMenu", true, false) as Control
	_check(gm != null and gm.visible, "Graphics page visible")
	if user_dir != "" and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(user_dir.path_join("graphics_menu.png"))
	_check(await _click_named("PresetLow"), "click PresetLow")
	await _frames(2)
	_check(_gs.preset == "low", "preset low (got %s)" % _gs.preset)
	_check(is_equal_approx(root.scaling_3d_scale, 0.67), "render scale 0.67 on the root viewport (got %.2f)" % root.scaling_3d_scale)
	_check(root.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR, "FSR scaling mode")
	_check(is_equal_approx(root.mesh_lod_threshold, 24.0), "lod threshold 24 px (got %.1f)" % root.mesh_lod_threshold)
	var sun := game.main.get_node_or_null("Sun") as DirectionalLight3D
	_check(sun != null and is_equal_approx(sun.directional_shadow_max_distance, 50.0) and sun.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL,
		"sun shadow 50 m orthogonal (got %s)" % (str(sun.directional_shadow_max_distance) if sun else "no sun"))
	_check(await _click_named("PresetHigh"), "click PresetHigh")
	await _frames(2)
	_check(_gs.preset == "high" and is_equal_approx(root.scaling_3d_scale, 1.0) and root.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR,
		"preset high: scale 1.0 bilinear")
	var ss := root.find_child("Ssao", true, false) as CheckButton
	print("  ssao rect %s pressed %s win %s" % [ss.get_global_rect(), ss.button_pressed, root.size])
	_check(await _click_named("Ssao"), "click SSAO")
	await _frames(2)
	print("  ssao after click pressed %s gs %s" % [ss.button_pressed, _gs.ssao])
	var env: Environment = null
	for we in game.main.get_children():
		if we is WorldEnvironment:
			env = (we as WorldEnvironment).environment
	_check(_gs.ssao and env != null and env.ssao_enabled, "SSAO on in the Environment")
	_check(_gs.preset == "custom", "manual change -> custom")
	await _click_named("Ssao")
	await _frames(2)
	_check(_gs.preset == "high", "back to high after SSAO off")
	_check(await _click_named("VegDensity_25"), "click VegDensity_25")
	await _frames(2)
	var thinned := 0
	var trees_full := 0
	for n in get_nodes_in_group("gfx_vegetation"):
		var mmi := n as MultiMeshInstance3D
		if bool(mmi.get_meta("gfx_thin")):
			if mmi.multimesh.visible_instance_count == int(round(int(mmi.get_meta("gfx_count")) * 0.25)):
				thinned += 1
		elif mmi.multimesh.visible_instance_count == -1:
			trees_full += 1
	print("  thinned %d, trees full %d of %d" % [thinned, trees_full, get_nodes_in_group("gfx_vegetation").size()])
	_check(thinned + trees_full == get_nodes_in_group("gfx_vegetation").size(), "density 25 %% applied to every loaded vegetation chunk")
	await _click_named("VegDistance_50")
	await _frames(2)
	var dist_ok := true
	for n in get_nodes_in_group("gfx_vegetation"):
		var mmi := n as MultiMeshInstance3D
		var e0 := float(mmi.get_meta("gfx_vis_end"))
		dist_ok = dist_ok and (e0 <= 0.0 or is_equal_approx(mmi.visibility_range_end, e0 * 0.5))
	_check(dist_ok, "vegetation distance 50 % applied to loaded chunks")
	await _click_named("FpsLimit_30")
	await _frames(2)
	_check(_gs.fps_limit == 30, "fps limit 30 (Engine.max_fps %d; headless keeps 0)" % Engine.max_fps)
	await _click_named("ShadowQuality_low")
	await _frames(2)
	_check(_gs.shadow_quality == "low", "shadow quality low")
	# render scale slider: drag from its current value to the left end with the mouse
	var sl := root.find_child("RenderScale", true, false) as HSlider
	if sl:
		var r := sl.get_global_rect()
		var p0: Vector2 = root.get_final_transform() * Vector2(r.position.x + 2.0 + (r.size.x - 4.0) * 0.34, r.get_center().y)
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_LEFT
			e.pressed = pressed
			e.position = p0
			e.global_position = p0
			e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			Input.parse_input_event(e)
			await _frames(2)
	print("  render scale after slider click: %.2f" % _gs.render_scale)
	_check(_gs.render_scale < 0.9 and is_equal_approx(root.scaling_3d_scale, _gs.render_scale), "slider changes render scale")
	# exact value for the restart check
	_gs.set_value("render_scale", 0.67)
	_check(await _click_named("GraphicsBack"), "click Back")
	await _frames(2)
	_check(gm != null and not gm.visible, "Graphics page closed")
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(file)) if FileAccess.file_exists(file) else null
	_check(saved is Dictionary and str(saved.get("preset")) == "custom" and is_equal_approx(float(saved.get("veg_density", 0)), 0.25),
		"saved %s: %s" % [file, str(saved).left(300)])
	_finish()


func _finish() -> void:
	print("PERF_SETTINGS_CHECK %s (%d failed)" % ["OK" if _fails.is_empty() else "FAIL", _fails.size()])
	quit(0 if _fails.is_empty() else 1)
