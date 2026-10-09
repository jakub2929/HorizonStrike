extends Node3D
## Shader / pipeline precompile while the loading screen is still up (0.2 H8, render.shader_precompile).
## Godot compiles a material's shader variant and its pipelines (vertex format, instancing, shadow pass, visibility
## fade) the first time it is drawn; in play that was a 4 s first frame and 50-80 ms hitches when new cells came in.
## Here, in front of the player's camera but under the loading screen, it draws once:
##  - every feature variant world/mesh_library.gd can make (albedo texture, alpha scissor / depth pre-pass, culling,
##    normal map, ORM roughness/metallic, AO) on a quad with and without tangents, as MultiMesh with and without
##    instance colours, with and without visibility-range fade, shadows on;
##  - every world material made so far, the terrain material variants, one machine of each type and every weapon
##    view model.
## Then it waits until frames are fast again (or a time cap) and emits `finished`.

signal finished

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const MeshLib := preload("res://world/mesh_library.gd")
const TerrainMaterial := preload("res://world/terrain_material.gd")

const MAX_S := 30.0
const FAST_MS := 40.0

var camera: Camera3D
var meshes: RefCounted
var spawner: Node
var viewmodel: Node
var loading: Node

var _stage: Node3D
var _machines: Array = []
var _weapons: Array = []
var _phase := 0
var _t0 := 0
var _fast := 0
var _frames := 0
var _last_us := 0
var _draws := 0
var _variants: Array = []   # handed to the mesh library to stay alive (see MeshLib.keep_alive)


func start() -> void:
	_t0 = Time.get_ticks_msec()
	_stage = Node3D.new()
	_stage.name = "PrecompileStage"
	add_child(_stage)
	_stage.global_transform = camera.global_transform.translated_local(Vector3(0, 0, -3.0))
	_build_world_variants()
	_build_real_materials()
	_build_terrain_variants()
	if spawner and spawner.has_method("warm_up_visible"):
		_machines = spawner.warm_up_visible(camera.global_transform.translated_local(Vector3(0, -1.0, -8.0)).origin)
	for id in Sheets.weapon_ids():
		_weapons.append(id)
	Log.info("precompile: %d draws, %d machines, %d weapon models" % [_draws, _machines.size(), _weapons.size()])


func _process(_delta: float) -> void:
	if _stage == null:
		return
	var now := Time.get_ticks_usec()
	var dt := (now - _last_us) / 1000.0 if _last_us > 0 else 999.0
	_last_us = now
	_frames += 1
	# weapon view models one per frame (each is a glTF load), drawn in the view model viewport
	if not _weapons.is_empty():
		var id: String = _weapons.pop_front()
		if viewmodel and viewmodel.has_method("preload_model"):
			viewmodel.preload_model(id)
		if loading and loading.has_method("set_stage"):
			loading.set_stage("shaders", Sheets.weapon_ids().size() - _weapons.size(), Sheets.weapon_ids().size())
		_fast = 0
		return
	_fast = _fast + 1 if dt < FAST_MS else 0
	var elapsed := (Time.get_ticks_msec() - _t0) / 1000.0
	if (_frames > 10 and _fast >= 5) or elapsed > MAX_S:
		Log.info("precompile: done in %.1f s (%d frames, last frame %.1f ms%s); pipelines %s" % [elapsed, _frames, dt, ", time cap" if elapsed > MAX_S else "",
			load("res://world/cell_profiler.gd").pipelines()])
		_finish()


func _finish() -> void:
	# freed a few nodes per frame by the world (828 instances and 6 skinned machines at once were a 0.5 s frame)
	var w: Node = get_parent()
	for m in _machines:
		if is_instance_valid(m):
			if w and w.has_method("bury"):
				Game.unregister_machine(m)
				w.bury(m, true)
			else:
				m.queue_free()
	_machines.clear()
	if viewmodel and viewmodel.has_method("end_preload"):
		viewmodel.end_preload()
	_stage = null
	if meshes and meshes.has_method("keep_alive"):
		meshes.keep_alive(_variants)
	finished.emit()
	# this node with its stage goes the same way
	if w and w.has_method("bury"):
		w.bury(self)
	else:
		queue_free()


# ------------------------------------------------------------------ stage content

var _quad_plain: ArrayMesh
var _quad_tangent: ArrayMesh
var _dummy: ImageTexture


## A quad with exactly the vertex layout world meshes get (glb_reader arrays: positions, normals, UVs, 32-bit
## indices, MikkTSpace tangents when normal-mapped, LOD index lists), so the surface pipelines compiled here are the
## ones real surfaces use.
func _quad(tangents: bool) -> ArrayMesh:
	var s := 0.03
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-s, -s, 0), Vector3(s, -s, 0), Vector3(s, s, 0), Vector3(-s, s, 0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	if tangents:
		var st := SurfaceTool.new()
		st.create_from_arrays(arrays, Mesh.PRIMITIVE_TRIANGLES)
		st.generate_tangents()
		st.index()
		arrays = st.commit_to_arrays()
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {0.5: PackedInt32Array([0, 1, 2])})
	return m


func _tex(_name: String) -> Texture2D:
	return _dummy


var _slot := 0


func _place(node: GeometryInstance3D) -> void:
	var cols := 24
	node.position = Vector3((_slot % cols - cols * 0.5) * 0.08, (_slot / cols - 8) * 0.08, 0.0)
	_slot += 1
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_stage.add_child(node)
	_draws += 1


func _mm(mesh: Mesh, mat: Material, colors: bool, fade: bool) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D())
	if colors:
		mm.set_instance_color(0, Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	if fade:
		mmi.visibility_range_end = 100.0
		mmi.visibility_range_end_margin = 15.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_place(mmi)


## Every combination of the features MeshLib.build_material() switches on.
func _build_world_variants() -> void:
	var img := Image.create(4, 4, true, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	_dummy = ImageTexture.create_from_image(img)
	_quad_plain = _quad(false)
	_quad_tangent = _quad(true)
	for image in ["", "x"]:
		for alpha in ["none", "scissor", "blend"]:
			for ds in [false, true]:
				for normal in ["", "x"]:
					for orm in ["", "x"]:
						for occ in ["", "x"]:
							var m := {"image": image, "color": Color.WHITE, "alpha": alpha != "none", "blend": alpha == "blend",
								"cutoff": 0.5, "double_sided": ds, "roughness": 1.0, "metallic": 1.0,
								"normal": normal, "orm": orm, "occlusion": occ}
							var mat := MeshLib.build_material(m, _tex)
							_variants.append(mat)
							var mesh: Mesh = _quad_tangent if normal != "" else _quad_plain
							for colors in [false, true]:
								for fade in [false, true]:
									_mm(mesh, mat, colors, fade)


func _build_real_materials() -> void:
	if meshes == null:
		return
	for mat in meshes.all_materials():
		var mesh: Mesh = _quad_tangent if (mat as BaseMaterial3D).normal_enabled else _quad_plain
		_mm(mesh, mat, false, true)
		_mm(mesh, mat, true, false)


func _build_terrain_variants() -> void:
	var wq := MeshInstance3D.new()
	wq.mesh = _quad_plain
	wq.material_override = load("res://world/water_material.gd").get_material()
	_place(wq)
	for alb in [null, _dummy]:
		for nrm in [null, _dummy]:
			for world_n in [false, true]:
				var mi := MeshInstance3D.new()
				mi.mesh = _quad_tangent
				mi.material_override = TerrainMaterial.make(alb, nrm, world_n)
				_place(mi)
