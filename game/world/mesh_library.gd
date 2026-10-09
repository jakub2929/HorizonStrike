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
const COLLISION_TRIS := 800         # collision triangles per mesh: the finest generated LOD under this count is used

var dir := ""
var tex_dir := ""
var _parsed := {}      # id -> reader output ({} = failed)            (worker + main, mutex)
var _images := {}      # texture name -> Image (null while decoding)   (worker + main, mutex)
var _entries := {}     # id -> {mesh, aabb, plant, tris, faces}        (main)
var _textures := {}    # texture name -> ImageTexture                  (main)
var _materials := {}   # key -> Material                               (main)
var _shapes := {}      # id -> Shape3D or null                         (main)
# Workers must never read the main-thread dictionaries above (a main-thread insert can rehash them under a reading
# worker): they ask these mutex-guarded sets instead.
var _built := {}       # ids that have an entry in _entries              (worker + main, mutex)
var _tex_built := {}   # texture names that have a _textures entry        (worker + main, mutex)
var _info := {}        # id -> {aabb, plant, shape: "tri"|"cyl"|""} known after parsing (worker + main, mutex)
var _mutex := Mutex.new()
# main-thread time counters (profiling, H1): callers read the difference around their work
var stat_mesh_ms := 0.0      # ArrayMesh/material building in get_entry
var stat_tex_upload_ms := 0.0   # ImageTexture.create_from_image (GPU upload) in _texture
var _partial := {}     # id -> {mesh: ArrayMesh, next: surface index} meshes being built a surface per step (main)


func _init(meshes_dir: String) -> void:
	dir = meshes_dir
	tex_dir = meshes_dir.get_base_dir().path_join("textures")


# ------------------------------------------------------------------ worker thread

## Returns worker time per phase in ms {parse_ms, lod_ms, tex_ms} for the meshes this call actually prepared.
func prepare(ids: Array) -> Dictionary:
	var st := {"parse_ms": 0.0, "lod_ms": 0.0, "tex_ms": 0.0}
	for raw_id in ids:
		var id := str(raw_id)
		_mutex.lock()
		var done := _parsed.has(id) or _built.has(id)
		if not done:
			_parsed[id] = null   # reserved
		_mutex.unlock()
		if done:
			continue
		var t0 := Time.get_ticks_usec()
		var p := GlbReader.read(dir.path_join(id + ".glb"), false)
		var t1 := Time.get_ticks_usec()
		if not p.is_empty():
			_add_tangents(p)
			_generate_lods(p)
			if _wants_trimesh(p):
				p["faces"] = _faces(p)
		st["parse_ms"] += (t1 - t0) / 1000.0
		st["lod_ms"] += (Time.get_ticks_usec() - t1) / 1000.0
		_mutex.lock()
		_parsed[id] = p
		if not p.is_empty():
			_info[id] = _info_of(p, p.has("faces"))
		_mutex.unlock()
		if p.is_empty():
			continue
		var t2 := Time.get_ticks_usec()
		for m in p["materials"]:
			for n in _map_names(m):
				_decode(n)
		st["tex_ms"] += (Time.get_ticks_usec() - t2) / 1000.0
	return st


## Solid meshes big enough to block the player get a triangle-mesh collider (faces built here, on the worker).
static func _wants_trimesh(p: Dictionary) -> bool:
	if p["alpha"] or int(p["tris"]) * 3 > MAX_TRIMESH_FACES:
		return false
	var a: AABB = p["aabb"]
	return maxf(a.size.x, a.size.z) >= 0.8 or a.size.y >= 0.8


## Collision triangles: per surface the finest generated LOD that keeps the whole mesh near COLLISION_TRIS (a
## simplified hull of the visual mesh: building a physics trimesh costs time on the main thread per triangle).
static func _faces(p: Dictionary) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var total := maxi(int(p["tris"]), 1)
	for s in p["surfaces"]:
		var pos: PackedVector3Array = s["arrays"][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = s["arrays"][Mesh.ARRAY_INDEX]
		var share := maxi(int(float(COLLISION_TRIS) * float(idx.size() / 3) / float(total)), 12)
		var lods: Dictionary = s.get("lods", {})
		if idx.size() / 3 > share:
			for key in lods:
				var li: PackedInt32Array = lods[key]
				if li.size() / 3 <= share and (idx.size() / 3 > share or li.size() > idx.size()):
					idx = li
		var k := faces.size()
		faces.resize(k + idx.size())
		for i in idx.size():
			faces[k + i] = pos[idx[i]]
	return faces


## Normal maps need tangents; the converter's glb has POSITION/NORMAL/TEXCOORD_0 only, so surfaces whose material
## has a normal map get MikkTSpace tangents here (SurfaceTool, CPU only, worker thread).
static func _add_tangents(p: Dictionary) -> void:
	var mats: Array = p["materials"]
	for s in p["surfaces"]:
		var mi := int(s["material"])
		if mi < 0 or mi >= mats.size() or str(mats[mi].get("normal", "")) == "":
			continue
		var arrays: Array = s["arrays"]
		if arrays[Mesh.ARRAY_NORMAL] == null or arrays[Mesh.ARRAY_TEX_UV] == null:
			continue
		var st := SurfaceTool.new()
		st.create_from_arrays(arrays, Mesh.PRIMITIVE_TRIANGLES)
		st.generate_tangents()
		st.index()
		var out := st.commit_to_arrays()
		if out.size() == Mesh.ARRAY_MAX and out[Mesh.ARRAY_TANGENT] != null:
			s["arrays"] = out


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
	var skip := _images.has(tex_name) or _tex_built.has(tex_name)
	if not skip:
		_images[tex_name] = null
	_mutex.unlock()
	if skip:
		return
	var img := _load_image(tex_name)
	_mutex.lock()
	_images[tex_name] = img
	_mutex.unlock()


## Texture names a material uses (colour, normal, ORM, occlusion), without duplicates.
static func _map_names(m: Dictionary) -> Array:
	var out: Array = []
	for k in ["image", "normal", "orm", "occlusion"]:
		var n := str(m.get(k, ""))
		if n != "" and not out.has(n):
			out.append(n)
	return out


## Cache texture: <name>.dds (converter BC1/BC5/BC7 with mips, used as is) or <name>.png (older caches).
func _load_image(tex_name: String) -> Image:
	var dds := tex_dir.path_join(tex_name + ".dds")
	if FileAccess.file_exists(dds):
		return load_dds(dds)
	var path := tex_dir.path_join(tex_name + ".png")
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	if not img.is_compressed():
		img.generate_mipmaps()
		# runtime BC compression exists only in editor builds (release templates log an error)
		if OS.has_feature("editor"):
			img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	return img


## DDS file -> Image (block-compressed formats stay compressed; the full mip chain comes from the file). null on error.
static func load_dds(path: String) -> Image:
	var img := Image.new()
	if img.load_dds_from_buffer(FileAccess.get_file_as_bytes(path)) != OK or img.is_empty():
		Log.warn("texture not loadable: %s" % path)
		return null
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
	var t0 := Time.get_ticks_usec()
	if typeof(p) == TYPE_DICTIONARY and not (p as Dictionary).is_empty():
		entry = _build(p, id)
	if entry.is_empty():
		entry = _load_gltf(id)
	var dt := (Time.get_ticks_usec() - t0) / 1000.0
	stat_mesh_ms += dt
	if dt > 20.0:
		Log.info("mesh %s built in %.1f ms (%s, %d tris, %d surfaces)" % [id, dt, "glb reader" if typeof(p) == TYPE_DICTIONARY and not (p as Dictionary).is_empty() else "GLTFDocument fallback",
			int(entry.get("tris", 0)), (entry["mesh"] as Mesh).get_surface_count() if entry.has("mesh") else 0])
	_entries[id] = entry
	_mutex.lock()
	_parsed.erase(id)
	_built[id] = true
	if not _info.has(id) and not entry.is_empty():
		_info[id] = _info_of({"aabb": entry["aabb"], "alpha": entry["plant"]}, (entry.get("faces", PackedVector3Array()) as PackedVector3Array).size() > 0)
	_mutex.unlock()
	return entry


## Main thread, budgeted callers: adds ONE surface of a parsed mesh (GPU upload of its buffers); true when the mesh is
## complete (then get_entry() returns it without further work).
func build_step(id: String) -> bool:
	if _entries.has(id):
		return true
	_mutex.lock()
	var p = _parsed.get(id)
	_mutex.unlock()
	if typeof(p) != TYPE_DICTIONARY or (p as Dictionary).is_empty():
		get_entry(id)
		return true
	var st: Dictionary = _partial.get(id, {})
	if st.is_empty():
		st = {"mesh": ArrayMesh.new(), "next": 0}
		_partial[id] = st
	var surfs: Array = p["surfaces"]
	if int(st["next"]) < surfs.size():
		var t0 := Time.get_ticks_usec()
		_add_surface(st["mesh"], surfs[int(st["next"])], p["materials"])
		st["next"] = int(st["next"]) + 1
		stat_mesh_ms += (Time.get_ticks_usec() - t0) / 1000.0
		if int(st["next"]) < surfs.size():
			return false
	get_entry(id)
	return true


func _add_surface(mesh: ArrayMesh, s: Dictionary, mats: Array) -> void:
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s["arrays"], [], s.get("lods", {}))
	var mi := int(s["material"])
	if mi >= 0 and mi < mats.size():
		mesh.surface_set_material(mesh.get_surface_count() - 1, _material(mats[mi]))


func _build(p: Dictionary, id: String) -> Dictionary:
	# continue a mesh build_step() started (its first surfaces are on the GPU already)
	var st: Dictionary = _partial.get(id, {"mesh": ArrayMesh.new(), "next": 0})
	_partial.erase(id)
	var mesh: ArrayMesh = st["mesh"]
	var surfs: Array = p["surfaces"]
	for i in range(int(st["next"]), surfs.size()):
		_add_surface(mesh, surfs[i], p["materials"])
	if mesh.get_surface_count() == 0:
		return {}
	return {"mesh": mesh, "aabb": p["aabb"], "plant": p["alpha"], "tris": p["tris"], "faces": p.get("faces", PackedVector3Array())}


func _material(m: Dictionary) -> Material:
	var key := "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [m["image"], m["color"], m["alpha"], m["double_sided"], m["cutoff"],
		m.get("normal", ""), m.get("orm", ""), m.get("occlusion", ""), m["roughness"], m["metallic"]]
	if _materials.has(key):
		return _materials[key]
	var mat := build_material(m, _texture)
	_materials[key] = mat
	return mat


## The one place world materials are made (also used by world/precompile.gd for every feature variant, so the
## shader variants compiled on the loading screen are exactly the ones the cells use). tex(name) -> Texture2D.
static func build_material(m: Dictionary, tex: Callable) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = m["color"]
	# per-instance tint (cell.json instances[].tint) arrives as the MultiMesh instance colour; meshes carry no vertex
	# colours, so untinted instances multiply by white
	mat.vertex_color_use_as_albedo = true
	if str(m["image"]) != "":
		mat.albedo_texture = tex.call(str(m["image"]))
	# alpha only where the glTF material says so (alphaMode MASK/BLEND, alphaCutoff, doubleSided)
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
	var nrm := str(m.get("normal", ""))
	if nrm != "":
		var nt: Texture2D = tex.call(nrm)
		if nt:
			mat.normal_enabled = true
			mat.normal_texture = nt
	var orm := str(m.get("orm", ""))
	if orm != "":
		var ot: Texture2D = tex.call(orm)
		if ot:
			# glTF metallicRoughness: G = roughness, B = metallic (factors multiply)
			mat.roughness_texture = ot
			mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			mat.metallic_texture = ot
			mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	var occ := str(m.get("occlusion", ""))
	if occ != "":
		var at: Texture2D = tex.call(occ)
		if at:
			mat.ao_enabled = true
			mat.ao_texture = at
			mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	return mat


## Main thread: every world material made so far (precompile draws them once).
func all_materials() -> Array:
	return _materials.values()


## Materials kept alive for the whole session: StandardMaterial3D shares one compiled shader per feature set and
## drops it when the last material of that set is freed, so the precompile variants must outlive the loading screen
## or the first real material of a set compiles again (a 20 ms surface_set_material).
var _kept: Array = []


func keep_alive(mats: Array) -> void:
	_kept.append_array(mats)


func _texture(tex_name: String) -> Texture2D:
	if _textures.has(tex_name):
		return _textures[tex_name]
	_mutex.lock()
	var img = _images.get(tex_name)
	_mutex.unlock()
	if img == null:
		img = _load_image(tex_name)
	var t0 := Time.get_ticks_usec()
	var tex: Texture2D = ImageTexture.create_from_image(img) if img != null else null
	stat_tex_upload_ms += (Time.get_ticks_usec() - t0) / 1000.0
	_textures[tex_name] = tex
	_mutex.lock()
	_images.erase(tex_name)
	_tex_built[tex_name] = true
	_mutex.unlock()
	return tex


## True while a worker reserved the mesh but has not finished parsing it.
func is_pending(id: String) -> bool:
	_mutex.lock()
	var p: bool = _parsed.has(id) and _parsed[id] == null
	_mutex.unlock()
	return p


## Main thread: true when get_entry(id) has already been built (no upload left for this mesh).
func is_built(id: String) -> bool:
	return _entries.has(id)


## Main thread: textures of a parsed, not yet built mesh that are not on the GPU yet (one upload step each).
func pending_textures(id: String) -> Array:
	var out: Array = []
	if _entries.has(id):
		return out
	_mutex.lock()
	var p = _parsed.get(id)
	_mutex.unlock()
	if typeof(p) != TYPE_DICTIONARY or (p as Dictionary).is_empty():
		return out
	for m in p["materials"]:
		for n in _map_names(m):
			if not _textures.has(n) and not out.has(n):
				out.append(n)
	return out


## Main thread: upload one texture (GPU) ahead of the mesh that uses it.
func upload_texture(tex_name: String) -> void:
	_texture(tex_name)


## Main thread: true when the collision shape of a mesh exists (or is known to be none).
func has_shape(id: String) -> bool:
	return _shapes.has(id)


## Worker: waits (bounded) until no id of the list is still being parsed by another worker.
func wait_parsed(ids: Array, timeout_ms: int = 20000) -> void:
	var t0 := Time.get_ticks_msec()
	for raw_id in ids:
		while is_pending(str(raw_id)) and Time.get_ticks_msec() - t0 < timeout_ms:
			OS.delay_msec(2)


## What a cell worker needs to plan chunks and collision without touching main-thread resources: AABB, plant flag
## and the collision shape kind (same rules as get_shape). {} = unknown / not loadable.
func info(id: String) -> Dictionary:
	_mutex.lock()
	var d: Dictionary = _info.get(id, {})
	_mutex.unlock()
	return d


static func _info_of(p: Dictionary, faces: bool) -> Dictionary:
	var aabb: AABB = p["aabb"]
	var plant: bool = p["alpha"]
	var shape := ""
	if plant:
		shape = "cyl" if aabb.size.y > 2.5 else ""
	elif faces:
		shape = "tri"
	return {"aabb": aabb, "plant": plant, "shape": shape}


func forget(id: String) -> void:
	_entries.erase(id)
	_shapes.erase(id)
	_partial.erase(id)
	_mutex.lock()
	_parsed.erase(id)
	_built.erase(id)
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
