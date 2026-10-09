extends "res://autotest/lib/scenario.gd"
## t14 Terrain, rock and building materials have normal maps (state read only: no gameplay behaviour is under test).
## After the start 3x3 is loaded: every terrain mesh and every MultiMesh / mesh instance of the loaded cells is
## classified by the cell.json instance kind (terrain, rock, building, vegetation, prop) and its material is checked
## for a normal map (StandardMaterial3D normal_enabled + normal_texture, or a ShaderMaterial texture parameter whose
## name contains "normal"). Instances are matched to cell.json by mesh id (node meta "mesh_id" or a node name that
## contains the mesh id).

const KINDS := ["terrain", "rock", "building", "vegetation", "prop"]


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var w: Variant = g.get("world") if g != null and "world" in g else null
	var start: Variant = ctx.cell_of(ctx.player_pos())
	if w is Object and w.has_method("is_cell_loaded") and start != null:
		var want := []
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				want.append((start as Vector2i) + Vector2i(dx, dy))
		check("start 3x3 loaded", await ctx.wait_until(func(): return want.all(func(c): return bool(w.call("is_cell_loaded", c))), 900.0))
	# mesh id -> kind from the loaded cells' cell.json
	var kind_of := {}
	var kinds_present := false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cj: Dictionary = ctx.oracle.cell_json((start as Vector2i) + Vector2i(dx, dy))
			for inst in cj.get("instances", []):
				if inst is Dictionary and inst.has("kind"):
					kinds_present = true
					kind_of[str(inst.get("mesh"))] = str(inst.kind)
	check("cell.json instances carry a kind (contract addition)", kinds_present, "%d mesh ids with a kind" % kind_of.size())
	var stats := {}
	for k in KINDS + ["unknown"]:
		stats[k] = {"count": 0, "with_normal": 0, "missing": {}}
	var root: Node = w if w is Node else ctx.tree.root
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var gi := n as GeometryInstance3D
		if not gi.is_visible_in_tree():
			continue
		var kind := _kind(gi, kind_of)
		var count := 1
		var mesh: Mesh = null
		if gi is MultiMeshInstance3D:
			var mm := (gi as MultiMeshInstance3D).multimesh
			if mm == null:
				continue
			count = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
			mesh = mm.mesh
		elif gi is MeshInstance3D:
			mesh = (gi as MeshInstance3D).mesh
		else:
			continue
		if mesh == null or count <= 0:
			continue
		var ok := _has_normal(gi, mesh)
		var st: Dictionary = stats[kind]
		st.count += count
		if ok:
			st.with_normal += count
		else:
			var key := _mesh_id(gi) if _mesh_id(gi) != "" else str(gi.name)
			st.missing[key] = int(st.missing.get(key, 0)) + count
	var report := {}
	for k in stats:
		var st: Dictionary = stats[k]
		var miss: Array = st.missing.keys()
		miss.sort_custom(func(a, b): return st.missing[a] > st.missing[b])
		report[k] = {"count": st.count, "with_normal": st.with_normal, "ratio": snappedf(float(st.with_normal) / maxf(1.0, st.count), 0.001), "top_missing": miss.slice(0, 10).map(func(x): return "%s x%d" % [x, st.missing[x]])}
	data.materials = report
	check("terrain material of every loaded cell has a normal map", report.terrain.count > 0 and report.terrain.with_normal == report.terrain.count, "%d/%d" % [report.terrain.with_normal, report.terrain.count])
	for k in ["rock", "building"]:
		check(">= 95 %% of %s instances have a normal map" % k, report[k].count > 0 and report[k].ratio >= 0.95, "%d/%d (%.1f %%), top without: %s" % [report[k].with_normal, report[k].count, report[k].ratio * 100.0, str(report[k].top_missing)])
	note("vegetation: %d/%d with a normal map; unknown kind: %d instances" % [report.vegetation.with_normal, report.vegetation.count, report.unknown.count])
	return true


static func _mesh_id(gi: Node) -> String:
	if gi.has_meta("mesh_id"):
		return str(gi.get_meta("mesh_id"))
	return ""


static func _kind(gi: GeometryInstance3D, kind_of: Dictionary) -> String:
	if gi.has_meta("kind"):
		return str(gi.get_meta("kind"))
	var mid := _mesh_id(gi)
	if mid != "" and kind_of.has(mid):
		return kind_of[mid]
	var nm := str(gi.name).to_lower()
	if nm.contains("terrain"):
		return "terrain"
	for id in kind_of:
		if nm.contains(str(id).to_lower()):
			return kind_of[id]
	return "unknown"


static func _has_normal(gi: GeometryInstance3D, mesh: Mesh) -> bool:
	var mats := []
	if gi.material_override != null:
		mats.append(gi.material_override)
	else:
		for s in mesh.get_surface_count():
			var m: Material = null
			if gi is MeshInstance3D:
				m = (gi as MeshInstance3D).get_active_material(s)
			if m == null:
				m = mesh.surface_get_material(s)
			if m != null:
				mats.append(m)
	if mats.is_empty():
		return false
	for m in mats:
		if not _material_normal(m):
			return false
	return true


static func _material_normal(m: Material) -> bool:
	if m is BaseMaterial3D:
		var b := m as BaseMaterial3D
		return b.normal_enabled and b.normal_texture != null
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		if sm.shader == null:
			return false
		for u in sm.shader.get_shader_uniform_list():
			var nm := str(u.get("name", "")).to_lower()
			if nm.contains("normal") and sm.get_shader_parameter(u.name) is Texture:
				return true
		return false
	return false
