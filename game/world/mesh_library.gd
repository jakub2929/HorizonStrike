extends RefCounted
## Shared static meshes hzd/meshes/<meshid>.glb loaded at runtime with GLTFDocument (main thread only: glTF scene
## generation creates RenderingServer resources; world.gd loads them with a per-frame time budget).
## A glb may hold several nodes/parts; they are merged into one ArrayMesh (node transforms baked) so a single
## MultiMesh can draw every instance. When LOD nodes exist (name contains "lod<N>", N > 0) only LOD 0 is kept.

const Log := preload("res://core/log.gd")

var dir := ""
var _entries := {}      # id -> {mesh: ArrayMesh, faces: PackedVector3Array, aabb: AABB} ({} = failed)
var _shapes := {}       # id -> Shape3D (main thread only)
var _mutex := Mutex.new()
var _lod_re := RegEx.create_from_string("(?i)lod_?(\\d+)")


func _init(meshes_dir: String) -> void:
	dir = meshes_dir


## Returns {} when the mesh cannot be loaded.
func get_entry(id: String) -> Dictionary:
	_mutex.lock()
	if _entries.has(id):
		var e: Dictionary = _entries[id]
		_mutex.unlock()
		return e
	_mutex.unlock()
	var entry := _load(id)
	_mutex.lock()
	_entries[id] = entry
	_mutex.unlock()
	return entry


func forget(id: String) -> void:
	_mutex.lock()
	_entries.erase(id)
	_shapes.erase(id)
	_mutex.unlock()


func loaded_ids() -> Array:
	_mutex.lock()
	var k := _entries.keys()
	_mutex.unlock()
	return k


## Collision shape for a mesh (main thread). Trimesh for normal meshes, convex hull for very large ones.
func get_shape(id: String) -> Shape3D:
	if _shapes.has(id):
		return _shapes[id]
	var e := get_entry(id)
	var shape: Shape3D = null
	if not e.is_empty():
		var faces: PackedVector3Array = e["faces"]
		if faces.size() > 0 and faces.size() <= 180000:
			var s := ConcavePolygonShape3D.new()
			s.set_faces(faces)
			shape = s
		elif faces.size() > 0:
			var m: ArrayMesh = e["mesh"]
			shape = m.create_convex_shape(true, true)
	_shapes[id] = shape
	return shape


func _load(id: String) -> Dictionary:
	var path := dir.path_join(id + ".glb")
	if not FileAccess.file_exists(path):
		Log.warn("mesh missing: %s" % path)
		return {}
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		Log.warn("glTF load failed (%d): %s" % [err, path])
		return {}
	var scene := doc.generate_scene(state)
	if scene == null:
		return {}
	var merged := ArrayMesh.new()
	_collect(scene, Transform3D.IDENTITY, merged, true)
	scene.free()
	if merged.get_surface_count() == 0:
		Log.warn("glTF has no mesh: %s" % path)
		return {}
	return {"mesh": merged, "faces": merged.get_faces(), "aabb": merged.get_aabb()}


func _collect(node: Node, parent_xf: Transform3D, merged: ArrayMesh, is_root: bool) -> void:
	var xf := parent_xf
	if node is Node3D and not is_root:
		xf = parent_xf * (node as Node3D).transform
	var m := _lod_re.search(String(node.name))
	if m and int(m.get_string(1)) > 0:
		return
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				if not xf.is_equal_approx(Transform3D.IDENTITY):
					_transform_arrays(arrays, xf)
				var mat: Material = mi.get_surface_override_material(s)
				if mat == null:
					mat = mesh.surface_get_material(s)
				var prim := Mesh.PRIMITIVE_TRIANGLES
				if mesh is ArrayMesh:
					prim = (mesh as ArrayMesh).surface_get_primitive_type(s)
				merged.add_surface_from_arrays(prim, arrays)
				if mat:
					merged.surface_set_material(merged.get_surface_count() - 1, mat)
	for c in node.get_children():
		_collect(c, xf, merged, false)


static func _transform_arrays(arrays: Array, xf: Transform3D) -> void:
	if arrays.size() <= Mesh.ARRAY_INDEX or arrays[Mesh.ARRAY_VERTEX] == null:
		return
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in v.size():
		v[i] = xf * v[i]
	arrays[Mesh.ARRAY_VERTEX] = v
	var nb := xf.basis.inverse().transposed()
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in n.size():
			n[i] = (nb * n[i]).normalized()
		arrays[Mesh.ARRAY_NORMAL] = n
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		for i in range(0, t.size(), 4):
			var tv := (xf.basis * Vector3(t[i], t[i + 1], t[i + 2])).normalized()
			t[i] = tv.x
			t[i + 1] = tv.y
			t[i + 2] = tv.z
		arrays[Mesh.ARRAY_TANGENT] = t
