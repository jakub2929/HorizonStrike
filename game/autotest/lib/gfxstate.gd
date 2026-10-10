extends RefCounted
## Graphics settings as the ENGINE has them (t26): what a preset of systems graphics.presets / graphics.shadow_quality_steps
## must have set on the root viewport, the sun, the Environment and the scattered vegetation chunks, read back from
## the engine objects (never from GraphicsSettings' own fields). Plus menu helpers (Esc > Graphics by input).

const GS := preload("res://settings/graphics_settings.gd")
const Oracle := preload("res://autotest/lib/oracle.gd")
const Sheets := preload("res://core/sheets.gd")


static func engine_state(ctx) -> Dictionary:
	var root: Viewport = ctx.tree.root
	var d := {"scaling_3d_scale": snappedf(root.scaling_3d_scale, 0.001), "scaling_3d_mode": root.scaling_3d_mode,
		"mesh_lod_threshold": snappedf(root.mesh_lod_threshold, 0.001)}
	var sun := sun_node(ctx)
	if sun != null:
		d.sun_shadow = sun.shadow_enabled
		d.sun_shadow_mode = sun.directional_shadow_mode
		d.sun_shadow_max_distance = snappedf(sun.directional_shadow_max_distance, 0.01)
	var env := environment(ctx)
	if env != null:
		d.ssao = env.ssao_enabled
		d.ssr = env.ssr_enabled
		d.volumetric_fog = env.volumetric_fog_enabled
	# scattered vegetation chunks (GRAPHICS HOOK track_chunk): fade distance factor and visible share of thin channels
	var n := 0
	var dist_f := []
	var dens := []
	for mmi in ctx.tree.get_nodes_in_group(GS.VEG_GROUP):
		if not (mmi is MultiMeshInstance3D) or not is_instance_valid(mmi):
			continue
		n += 1
		var base := float(mmi.get_meta("gfx_vis_end", 0.0))
		if base > 0.0:
			dist_f.append(snappedf(mmi.visibility_range_end / base, 0.001))
		if bool(mmi.get_meta("gfx_thin", false)) and mmi.multimesh and int(mmi.get_meta("gfx_count", 0)) > 0:
			var vis: int = mmi.multimesh.visible_instance_count
			var total := int(mmi.get_meta("gfx_count", 0))
			dens.append([total, total if vis < 0 else vis])
	d.veg_chunks = n
	d.veg_distance_factors = _uniq(dist_f)
	d.veg_thin_counts = _uniq(dens)   # distinct [instances, visible instances] of thin-vegetation chunks
	d.max_fps = Engine.max_fps
	return d


static func _uniq(a: Array) -> Array:
	var out := []
	for v in a:
		if not out.has(v):
			out.append(v)
	out.sort()
	return out


static func sun_node(ctx) -> DirectionalLight3D:
	for n in ctx.tree.root.find_children("*", "DirectionalLight3D", true, false):
		if (n as Node).is_inside_tree():
			return n
	return null


static func environment(ctx) -> Environment:
	for n in ctx.tree.root.find_children("*", "WorldEnvironment", true, false):
		if (n as WorldEnvironment).environment != null:
			return (n as WorldEnvironment).environment
	return null


static func compare(ctx, preset: String, st: Dictionary) -> Array:
	## [ok, mismatches] of an engine_state against the sheet's preset row
	var p: Dictionary = GS.presets().get(preset, {})
	var bad := []
	if p.is_empty():
		return [false, ["no graphics.presets row %s" % preset]]
	var scale := float(p.get("render_scale", 1.0))
	if absf(float(st.get("scaling_3d_scale", -1.0)) - scale) > 0.001:
		bad.append("render scale %s != %s" % [str(st.get("scaling_3d_scale")), str(scale)])
	var want_mode := Viewport.SCALING_3D_MODE_FSR if bool(p.get("fsr", true)) and scale < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR
	if int(st.get("scaling_3d_mode", -1)) != want_mode:
		bad.append("scaling mode %s != %s" % [str(st.get("scaling_3d_mode")), str(want_mode)])
	var lod := Sheets.sys_num("render.lod_threshold_px", 12.0) / maxf(float(p.get("lod_bias", 1.0)), 0.01)
	if absf(float(st.get("mesh_lod_threshold", -1.0)) - lod) > 0.01:
		bad.append("mesh_lod_threshold %s != %s" % [str(st.get("mesh_lod_threshold")), str(snappedf(lod, 0.001))])
	var step: Dictionary = GS.shadow_steps().get(str(p.get("shadow_quality", "medium")), {})
	if st.has("sun_shadow"):
		if bool(st.sun_shadow) != bool(step.get("enabled", true)):
			bad.append("sun shadow %s != %s" % [str(st.sun_shadow), str(step.get("enabled"))])
		var modes := {1: DirectionalLight3D.SHADOW_ORTHOGONAL, 2: DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, 4: DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS}
		var want_sm: int = modes.get(int(step.get("splits", 2)), DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS)
		if int(st.sun_shadow_mode) != want_sm:
			bad.append("sun shadow mode %s != %s" % [str(st.sun_shadow_mode), str(want_sm)])
		if absf(float(st.sun_shadow_max_distance) - float(p.get("shadow_distance", 100.0))) > 0.01:
			bad.append("shadow distance %s != %s" % [str(st.sun_shadow_max_distance), str(p.get("shadow_distance"))])
	else:
		bad.append("no sun in the scene")
	if st.has("ssao"):
		for k in ["ssao", "ssr", "volumetric_fog"]:
			if bool(st[k]) != bool(p.get(k, false)):
				bad.append("%s %s != %s" % [k, str(st[k]), str(p.get(k))])
	else:
		bad.append("no WorldEnvironment")
	if int(st.get("veg_chunks", 0)) > 0:
		var vf: Array = st.get("veg_distance_factors", [])
		if not vf.all(func(x): return absf(float(x) - float(p.get("veg_distance", 1.0))) < 0.002):
			bad.append("vegetation fade factors %s != %s" % [str(vf), str(p.get("veg_distance"))])
		# thin vegetation: visible instances == round(instances x veg_density) in every chunk (small chunks round)
		var dens := float(p.get("veg_density", 1.0))
		var wrong: Array = (st.get("veg_thin_counts", []) as Array).filter(func(x): return int(x[1]) != (int(x[0]) if dens >= 0.999 else int(round(int(x[0]) * dens))))
		if not wrong.is_empty():
			bad.append("vegetation visible counts %s != round(count x %s)" % [str(wrong.slice(0, 6)), str(dens)])
	return [bad.is_empty(), bad]


static func file_preset(path: String) -> String:
	var d: Variant = Oracle.read_json(path)
	return str(d.get("preset", "")) if d is Dictionary else ""


# --- Esc > Graphics by input ---------------------------------------------------------------------------------------

static func control(ctx, node_name: String) -> Control:
	var c: Node = ctx.tree.root.find_child(node_name, true, false)
	return c as Control if c is Control else null


static func click_control(ctx, inp, node_name: String) -> bool:
	## a left click at the centre of the named control as drawn (canvas coordinates; InputSim converts to the window)
	var c := control(ctx, node_name)
	if c == null or not c.is_visible_in_tree():
		inp.sent.append("click %s: not visible" % node_name)
		return false
	await inp.click(c.get_global_rect().get_center())
	return true


static func open_graphics(ctx, inp) -> bool:
	## Esc (menu key) opens the pause menu, a click on Graphics opens the page
	var sm := control(ctx, "SettingsMenu")
	if sm == null or not sm.visible:
		await inp.tap("menu")
		await ctx.frames(2)
	sm = control(ctx, "SettingsMenu")
	if sm == null or not sm.visible:
		return false
	if not await click_control(ctx, inp, "GraphicsButton"):
		return false
	await ctx.frames(2)
	var gm := control(ctx, "GraphicsMenu")
	return gm != null and gm.visible


static func close_graphics(ctx, inp) -> bool:
	## Back, then Esc closes the pause menu; true when the game runs again
	await click_control(ctx, inp, "GraphicsBack")
	await ctx.frames(2)
	var sm := control(ctx, "SettingsMenu")
	if sm != null and sm.visible:
		await inp.tap("menu")
		await ctx.frames(2)
	return not ctx.tree.paused
