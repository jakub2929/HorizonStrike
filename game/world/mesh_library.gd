extends RefCounted
## Shared static meshes hzd/meshes/<meshid>.glb with external textures hzd/textures/<hash>.png.
## prepare() runs on a worker thread: parses the glb (world/glb_reader.gd) and decodes + mipmaps + S3TC-compresses
## every texture once per hash. get_entry() runs on the main thread and only turns the prepared data into
## ArrayMesh/ImageTexture/material resources (RenderingServer objects are created on the main thread only).
## Files the reader cannot handle fall back to GLTFDocument on the main thread.

const Log := preload("res://core/log.gd")
const GlbReader := preload("res://world/glb_reader.gd")

const MAX_TRIMESH_FACES := 90000   # 30k triangles
const LOD_MIN_TRIS := 300

var dir := ""
var tex_dir := ""
var _parsed := {}      # id -> reader output ({} = failed)            (worker + main, mutex)
var _images := {}      # texture name -> Image (null while decoding)   (worker + main, mutex)
var _entries := {}     # id -> {mesh, aabb, plant, tris, faces}        (main)
var _textures := {}    # texture name -> ImageTexture                  (main)
var _materials := {}   # key -> Material                               (main)
var _shapes := {}      # id -> Shape3D or null                         (main)
var _mutex := Mutex.new()


func _init(meshes_dir: String) -> void:
	dir = meshes_dir
	tex_dir = meshes_dir.get_base_dir().path_join("textures")


# ------------------------------------------------------------------ worker thread

func prepare(ids: Array) -> void:
	for raw_id in ids:
		var id := str(raw_id)
		_mutex.lock()
		var done := _parsed.has(id) or _entries.has(id)
		if not done:
			_parsed[id] = null   # reserved
		_mutex.unlock()
		if done:
			continue
		var p := GlbReader.read(dir.path_join(id + ".glb"), false)
		if not p.is_empty():
			if _wants_trimesh(p):
				p["faces"] = _faces(p)
			_generate_lods(p)
		_mutex.lock()
		_parsed[id] = p
		_mutex.unlock()
		if p.is_empty():
			continue
		for m in p["materials"]:
			if str(m["image"]) != "":
				_decode(str(m["image"]))


## Solid meshes big enough to block the player get a triangle-mesh collider (faces built here, on the worker).
static func _wants_trimesh(p: Dictionary) -> bool:
	if p["alpha"] or int(p["tris"]) * 3 > MAX_TRIMESH_FACES:
		return false
	var a: AABB = p["aabb"]
	return maxf(a.size.x, a.size.z) >= 0.8 or a.size.y >= 0.8


static func _faces(p: Dictionary) -> PackedVector3Array:
	var faces := PackedVector3Array()
	faces.resize(int(p["tris"]) * 3)
	var k := 0
	for s in p["surfaces"]:
		var pos: PackedVector3Array = s["arrays"][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = s["arrays"][Mesh.ARRAY_INDEX]
		for i in idx.size():
			faces[k] = pos[idx[i]]
			k += 1
	faces.resize(k)
	return faces


## Automatic LODs (meshoptimizer through ImporterMesh, CPU only) -> per surface {screen size: indices}.
func _generate_lods(p: Dictionary) -> void:
	if int(p["tris"]) < LOD_MIN_TRIS:
		return
	var im := ImporterMesh.new()
	for s in p["surfaces"]:
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, s["arrays"])
	im.generate_lods(60.0, 25.0, [])
	for si in im.get_surface_count():
		var lods := {}
		for li in im.get_surface_lod_count(si):
			lods[im.get_surface_lod_size(si, li)] = im.get_surface_lod_indices(si, li)
		p["surfaces"][si]["lods"] = lods


func _decode(tex_name: String) -> void:
	_mutex.lock()
	var skip := _images.has(tex_name) or _textures.has(tex_name)
	if not skip:
		_images[tex_name] = null
	_mutex.unlock()
	if skip:
		return
	var img := _load_image(tex_name)
	_mutex.lock()
	_images[tex_name] = img
	_mutex.unlock()


func _load_image(tex_name: String) -> Image:
	var path := tex_dir.path_join(tex_name + ".png")
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	if not img.is_compressed():
		img.generate_mipmaps()
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	return img


# ------------------------------------------------------------------ main thread

## Returns {} when the mesh cannot be loaded.
func get_entry(id: String) -> Dictionary:
	if _entries.has(id):
		return _entries[id]
	_mutex.lock()
	var p = _parsed.get(id)
	var reserved := _parsed.has(id)
	_mutex.unlock()
	if p == null:
		if reserved:
			return {}   # a worker is still parsing it; callers only ask after prepare() finished
		prepare([id])
		_mutex.lock()
		p = _parsed.get(id)
		_mutex.unlock()
	var entry: Dictionary = {}
	if typeof(p) == TYPE_DICTIONARY and not (p as Dictionary).is_empty():
		entry = _build(p)
	if entry.is_empty():
		entry = _load_gltf(id)
	_mutex.lock()
	_parsed.erase(id)
	_mutex.unlock()
	_entries[id] = entry
	return entry


func _build(p: Dictionary) -> Dictionary:
	var mesh := ArrayMesh.new()
	var mats: Array = p["materials"]
	for s in p["surfaces"]:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s["arrays"], [], s.get("lods", {}))
		var mi := int(s["material"])
		if mi >= 0 and mi < mats.size():
			mesh.surface_set_material(mesh.get_surface_count() - 1, _material(mats[mi]))
	if mesh.get_surface_count() == 0:
		return {}
	return {"mesh": mesh, "aabb": p["aabb"], "plant": p["alpha"], "tris": p["tris"], "faces": p.get("faces", PackedVector3Array())}


func _material(m: Dictionary) -> Material:
	var key := "%s|%s|%s|%s|%s" % [m["image"], m["color"], m["alpha"], m["double_sided"], m["cutoff"]]
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = m["color"]
	if str(m["image"]) != "":
		mat.albedo_texture = _texture(str(m["image"]))
	if m["alpha"]:
		if m["blend"]:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = float(m["cutoff"])
	if m["double_sided"]:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = float(m["roughness"])
	mat.metallic = float(m["metallic"])
	_materials[key] = mat
	return mat


func _texture(tex_name: String) -> Texture2D:
	if _textures.has(tex_name):
		return _textures[tex_name]
	_mutex.lock()
	var img = _images.get(tex_name)
	_mutex.unlock()
	if img == null:
		img = _load_image(tex_name)
	var tex: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	_textures[tex_name] = tex
	_mutex.lock()
	_images.erase(tex_name)
	_mutex.unlock()
	return tex


## True while a worker reserved the mesh but has not finished parsing it.
func is_pending(id: String) -> bool:
	_mutex.lock()
	var p: bool = _parsed.has(id) and _parsed[id] == null
	_mutex.unlock()
	return p


func forget(id: String) -> void:
	_entries.erase(id)
	_shapes.erase(id)
	_mutex.lock()
	_parsed.erase(id)
	_mutex.unlock()


func loaded_ids() -> Array:
	return _entries.keys()


## Collision shape of a mesh (main thread): plants (alpha-tested foliage) get only a trunk when they are tree-sized,
## solid meshes get a trimesh (or a convex hull when very large). null = no collision.
func get_shape(id: String) -> Shape3D:
	if _shapes.has(id):
		return _shapes[id]
	var e := get_entry(id)
	var shape: Shape3D = null
	if not e.is_empty():
		var aabb: AABB = e["aabb"]
		if e.get("plant", false):
			if aabb.size.y > 2.5:
				var cyl := CylinderShape3D.new()
				cyl.radius = clampf(minf(aabb.size.x, aabb.size.z) * 0.06, 0.12, 0.6)
				cyl.height = minf(aabb.size.y, 6.0)
				shape = cyl
		elif (e.get("faces", PackedVector3Array()) as PackedVector3Array).size() > 0:
			var s := ConcavePolygonShape3D.new()
			s.set_faces(e["faces"])
			shape = s
		e.erase("faces")
	_shapes[id] = shape
	return shape


## Shape-local offset of a plant trunk (cylinders are centred).
func shape_offset(id: String) -> Vector3:
	var e := get_entry(id)
	if e.is_empty() or not e.get("plant", false):
		return Vector3.ZERO
	var aabb: AABB = e["aabb"]
	return Vector3(aabb.get_center().x, aabb.position.y + minf(aabb.size.y, 6.0) * 0.5, aabb.get_center().z)


# ------------------------------------------------------------------ fallback

func _load_gltf(id: String) -> Dictionary:
	var path := dir.path_join(id + ".glb")
	if not FileAccess.file_exists(path):
		Log.warn("mesh missing: %s" % path)
		return {}
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		Log.warn("glTF load failed: %s" % path)
		return {}
	var scene := doc.generate_scene(state)
	if scene == null:
		return {}
	var merged := ArrayMesh.new()
	_collect(scene, Transform3D.IDENTITY, merged, true)
	scene.free()
	if merged.get_surface_count() == 0:
		return {}
	return {"mesh": merged, "aabb": merged.get_aabb(), "plant": false, "tris": merged.get_faces().size() / 3}


func _collect(node: Node, parent_xf: Transform3D, merged: ArrayMesh, is_root: bool) -> void:
	var xf := parent_xf
	if node is Node3D and not is_root:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh:
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				if arrays[Mesh.ARRAY_VERTEX] == null:
					continue
				if not xf.is_equal_approx(Transform3D.IDENTITY):
					var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					for i in v.size():
						v[i] = xf * v[i]
					arrays[Mesh.ARRAY_VERTEX] = v
				var mat: Material = mi.get_surface_override_material(s)
				if mat == null:
					mat = mesh.surface_get_material(s)
				merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				if mat:
					merged.surface_set_material(merged.get_surface_count() - 1, mat)
	for c in node.get_children():
		_collect(c, xf, merged, false)
