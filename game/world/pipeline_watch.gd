extends Node
## Names what Godot still compiles in play (0.2): after the precompile (world/precompile.gd) every new mesh / surface /
## draw pipeline is a material x vertex format x instancing combination the precompile did not draw. When the
## counters grow, geometry and lights added in the last RECENT_MS are described as keys (see key_of) and every key
## the precompile did not draw is logged once: `pipeline watch: +<counts> new key: <key> (<node path>)`.
## With --profile-cells and nothing recent to blame, the whole scene is scanned once per event.

const Log := preload("res://core/log.gd")

const RECENT_MS := 500
const MONITORS := [Performance.PIPELINE_COMPILATIONS_MESH, Performance.PIPELINE_COMPILATIONS_SURFACE,
	Performance.PIPELINE_COMPILATIONS_DRAW, Performance.PIPELINE_COMPILATIONS_SPECIALIZATION]
const MONITOR_NAMES := ["mesh", "surface", "draw", "specialization"]
## BaseMaterial3D properties that pick its shader variant (read with get(), absent ones are skipped)
const MAT_PROPS := ["transparency", "blend_mode", "cull_mode", "depth_draw_mode", "depth_test", "shading_mode",
	"diffuse_mode", "specular_mode", "billboard_mode", "texture_filter", "alpha_antialiasing_mode", "distance_fade_mode",
	"roughness_texture_channel", "metallic_texture_channel", "ao_texture_channel", "emission_operator",
	"detail_blend_mode", "detail_uv_layer", "stencil_mode"]

static var precompiled := {}      # key -> true, filled by world/precompile.gd before its stage goes

var profile := false
var _active := false
var _recent: Array = []           # [ticks_msec, instance id] of geometry / lights added lately
var _counts: Array = []
var _logged := {}


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


## From the precompile's finish on, new compilations count.
func start() -> void:
	_active = true
	_counts = _read()
	Log.info("pipeline watch: on (%d precompiled keys)" % precompiled.size())


func _on_node_added(n: Node) -> void:
	if _active and (n is GeometryInstance3D or n is Light3D):
		_recent.append([Time.get_ticks_msec(), n.get_instance_id()])


func _process(_delta: float) -> void:
	if not _active:
		return
	var now := Time.get_ticks_msec()
	while not _recent.is_empty() and now - int(_recent[0][0]) > RECENT_MS:
		_recent.pop_front()
	var c := _read()
	var grew := false
	for i in c.size():
		if c[i] > _counts[i] and i != 3:   # specialization runs in the background; it is reported, not a trigger
			grew = true
	if not grew:
		_counts = c
		return
	var delta := PackedStringArray()
	for i in c.size():
		if c[i] != _counts[i]:
			delta.append("%s +%d" % [MONITOR_NAMES[i], c[i] - _counts[i]])
	_counts = c
	var found := 0
	var seen := 0
	for e in _recent:
		var n := instance_from_id(int(e[1])) as Node
		if n == null or not is_instance_valid(n) or not n.is_inside_tree():
			continue
		seen += 1
		found += _report(n, ", ".join(delta))
	if found == 0 and profile:
		for n in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
			found += _report(n, ", ".join(delta))
	if found == 0:
		Log.info("pipeline watch: %s, no new key (%d nodes added in the last %d ms)" % [", ".join(delta), seen, RECENT_MS])


func _report(n: Node, delta: String) -> int:
	var found := 0
	for k in keys_of(n):
		if precompiled.has(k) or _logged.has(k):
			continue
		_logged[k] = true
		found += 1
		Log.info("pipeline watch: %s new key: %s (%s)" % [delta, k, n.get_path()])
	return found


func _read() -> Array:
	var out := []
	for m in MONITORS:
		out.append(int(Performance.get_monitor(m)))
	return out


## Every node below (and including) root -> keys into `precompiled`.
static func register(root: Node) -> void:
	if root == null:
		return
	for k in keys_of(root):
		precompiled[k] = true
	for n in root.find_children("*", "", true, false):
		for k in keys_of(n):
			precompiled[k] = true


## One key per drawn surface: instancing, vertex format, visibility fade, material variant.
static func keys_of(n: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if n is Light3D:
		var l := n as Light3D
		out.append("light %s shadow %d" % [l.get_class(), int(l.shadow_enabled)])
		return out
	if not n is GeometryInstance3D:
		return out
	var gi := n as GeometryInstance3D
	var mesh: Mesh
	var inst := ""
	if gi is MultiMeshInstance3D:
		var mm := (gi as MultiMeshInstance3D).multimesh
		if mm == null:
			return out
		mesh = mm.mesh
		inst = "multimesh%s%s" % [" colors" if mm.use_colors else "", " custom" if mm.use_custom_data else ""]
	elif gi is MeshInstance3D:
		mesh = (gi as MeshInstance3D).mesh
		inst = "mesh"
	else:
		out.append("%s %s" % [gi.get_class(), material_key(gi.material_override)])
		return out
	if mesh == null:
		return out
	# shadow casting is left out: the precompile draws everything with shadows on, and a surface without shadows only
	# uses a subset of those passes
	var common := "%s fade %d" % [inst, gi.visibility_range_fade_mode]
	for s in mesh.get_surface_count():
		var mat: Material = gi.material_override
		if mat == null and gi is MeshInstance3D and s < (gi as MeshInstance3D).get_surface_override_material_count():
			mat = (gi as MeshInstance3D).get_surface_override_material(s)
		if mat == null:
			mat = mesh.surface_get_material(s)
		var fmt := (mesh as ArrayMesh).surface_get_format(s) if mesh is ArrayMesh else -1
		out.append("%s | format %x | %s" % [common, fmt, material_key(mat)])
	if gi.material_overlay:
		out.append("%s | overlay %s" % [common, material_key(gi.material_overlay)])
	return out


static func material_key(mat: Material) -> String:
	if mat == null:
		return "no material"
	if mat is ShaderMaterial:
		var sh := (mat as ShaderMaterial).shader
		if sh == null:
			return "shader none"
		return "shader %s#%d" % [sh.resource_path.get_file(), sh.get_instance_id()]
	if mat is BaseMaterial3D:
		var b := mat as BaseMaterial3D
		var parts := PackedStringArray([b.get_class()])
		for p in MAT_PROPS:
			var v: Variant = b.get(p)
			if v != null:
				parts.append("%s=%s" % [p, v])
		var f := ""
		for i in BaseMaterial3D.FEATURE_MAX:
			f += "1" if b.get_feature(i) else "0"
		var fl := ""
		for i in BaseMaterial3D.FLAG_MAX:
			fl += "1" if b.get_flag(i) else "0"
		parts.append("features " + f)
		parts.append("flags " + fl)
		if b.next_pass:
			parts.append("next_pass " + material_key(b.next_pass))
		return " ".join(parts)
	return mat.get_class()
