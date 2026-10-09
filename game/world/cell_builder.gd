extends RefCounted
## Builds one world cell from hzd/cells/<x>_<y>/ (docs/ARCHITECTURE.md cell.json).
## prepare() runs on a worker thread (file IO, terrain arrays, scatter, glTF), instantiate() on the main thread.
## Conventions: all positions in cell.json are world positions (Godot space); `origin` is the cell's min corner;
## height.r32 rows run along +Z, columns along +X, `res` = [columns, rows].

const Log := preload("res://core/log.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Campfire := preload("res://world/campfire.gd")
const TerrainMaterial := preload("res://world/terrain_material.gd")

const MAX_VISUAL_VERTS := 257
const MAX_COLLISION_VERTS := 1025
const SPECIES_CAP := {"trees": 2500, "blockbush": 5000, "undergrowth": 6000, "stealthplants": 6000}
const SPECIES_RANGE := {"trees": 900.0, "blockbush": 260.0, "undergrowth": 140.0, "stealthplants": 160.0}

const LAYER_WORLD := 1


static func prepare(cell_dir: String) -> Dictionary:
	var out := {"ok": false, "dir": cell_dir}
	var info = FsUtil.read_json(cell_dir.path_join("cell.json"))
	if typeof(info) != TYPE_DICTIONARY:
		out["error"] = "cell.json missing or invalid in %s" % cell_dir
		return out
	out["info"] = info
	var size := float(info.get("size", 512.0))
	var org: Array = info.get("origin", [0, 0, 0])
	var origin := Vector3(float(org[0]), float(org[1]), float(org[2]))
	out["origin"] = origin
	out["size"] = size
	# ---- terrain
	var terr: Dictionary = info.get("terrain", {})
	var res: Array = terr.get("res", [0, 0])
	var w := int(res[0])
	var h := int(res[1])
	var heights := PackedFloat32Array()
	var hpath := cell_dir.path_join(str(terr.get("file", "height.r32")))
	if w >= 2 and h >= 2 and FileAccess.file_exists(hpath):
		var bytes := FileAccess.get_file_as_bytes(hpath)
		if bytes.size() >= w * h * 4:
			heights = bytes.slice(0, w * h * 4).to_float32_array()
	if heights.is_empty():
		w = 2
		h = 2
		heights = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		out["terrain_missing"] = true
	# sanitize NaN/inf
	for i in heights.size():
		if is_nan(heights[i]) or is_inf(heights[i]):
			heights[i] = 0.0
	out["w"] = w
	out["h"] = h
	out["heights"] = heights
	out["real"] = bool(terr.get("real", false))
	out["terrain_arrays"] = _terrain_arrays(heights, w, h, origin, size)
	var col := _collision_heights(heights, w, h)
	out["col_heights"] = col[0]
	out["col_w"] = col[1]
	out["col_h"] = col[2]
	for key in ["albedo", "normal"]:
		var f := str(terr.get(key, ""))
		if f != "" and FileAccess.file_exists(cell_dir.path_join(f)):
			var img := Image.load_from_file(cell_dir.path_join(f))
			if img:
				img.generate_mipmaps()
				out[key + "_img"] = img
	# ---- instances grouped by mesh
	var groups := {}
	for inst in info.get("instances", []):
		var mid := str(inst.get("mesh", ""))
		var xf: Array = inst.get("xf", [])
		if mid == "" or xf.size() != 12:
			continue
		if not groups.has(mid):
			groups[mid] = []
		groups[mid].append(_xf(xf))
	out["instances"] = groups
	# ---- vegetation scattered from the density map
	out["vegetation"] = _scatter(cell_dir, info, heights, w, h, origin, size)
	var ids := {}
	for mid in groups:
		ids[mid] = true
	for key in out["vegetation"]:
		if not str(key).begins_with("_"):
			ids[out["vegetation"][key]["mesh"]] = true
	out["mesh_ids"] = ids.keys()
	return out


static func _xf(a: Array) -> Transform3D:
	var b := Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8]))
	return Transform3D(b, Vector3(a[9], a[10], a[11]))


static func sample_height(heights: PackedFloat32Array, w: int, h: int, origin: Vector3, size: float, x: float, z: float) -> float:
	var fx := clampf((x - origin.x) / size * (w - 1), 0.0, w - 1.0)
	var fz := clampf((z - origin.z) / size * (h - 1), 0.0, h - 1.0)
	var x0 := mini(int(fx), w - 2)
	var z0 := mini(int(fz), h - 2)
	var tx := fx - x0
	var tz := fz - z0
	var h00 := heights[z0 * w + x0]
	var h10 := heights[z0 * w + x0 + 1]
	var h01 := heights[(z0 + 1) * w + x0]
	var h11 := heights[(z0 + 1) * w + x0 + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Terrain surface arrays (pure data, safe on a worker thread).
static func _terrain_arrays(heights: PackedFloat32Array, w: int, h: int, origin: Vector3, size: float) -> Array:
	var step := maxi(1, int(ceil(float(maxi(w, h) - 1) / float(MAX_VISUAL_VERTS - 1))))
	var cols := PackedInt32Array()
	var c := 0
	while c < w - 1:
		cols.append(c)
		c += step
	cols.append(w - 1)
	var rows := PackedInt32Array()
	var r := 0
	while r < h - 1:
		rows.append(r)
		r += step
	rows.append(h - 1)
	var nx := cols.size()
	var nz := rows.size()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize(nx * nz)
	normals.resize(nx * nz)
	uvs.resize(nx * nz)
	var dx := size / float(w - 1)
	var dz := size / float(h - 1)
	for iz in nz:
		var rr := rows[iz]
		for ix in nx:
			var cc := cols[ix]
			var y := heights[rr * w + cc]
			verts[iz * nx + ix] = Vector3(origin.x + cc * dx, y, origin.z + rr * dz)
			var hl := heights[rr * w + maxi(cc - 1, 0)]
			var hr := heights[rr * w + mini(cc + 1, w - 1)]
			var hd := heights[maxi(rr - 1, 0) * w + cc]
			var hu := heights[mini(rr + 1, h - 1) * w + cc]
			normals[iz * nx + ix] = Vector3((hl - hr) / (2.0 * dx), 1.0, (hd - hu) / (2.0 * dz)).normalized()
			uvs[iz * nx + ix] = Vector2(float(cc) / (w - 1), float(rr) / (h - 1))
	var idx := PackedInt32Array()
	idx.resize((nx - 1) * (nz - 1) * 6)
	var k := 0
	for iz in nz - 1:
		for ix in nx - 1:
			var a := iz * nx + ix
			var b := a + 1
			var cidx := a + nx
			var d := cidx + 1
			idx[k] = a
			idx[k + 1] = b
			idx[k + 2] = cidx
			idx[k + 3] = b
			idx[k + 4] = d
			idx[k + 5] = cidx
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


## Heights for HeightMapShape3D, downsampled to at most MAX_COLLISION_VERTS per side. Returns [data, w, h].
static func _collision_heights(heights: PackedFloat32Array, w: int, h: int) -> Array:
	if w <= MAX_COLLISION_VERTS and h <= MAX_COLLISION_VERTS:
		return [heights, w, h]
	var step := int(ceil(float(maxi(w, h) - 1) / float(MAX_COLLISION_VERTS - 1)))
	var nw := (w - 1) / step + 1
	var nh := (h - 1) / step + 1
	var out := PackedFloat32Array()
	out.resize(nw * nh)
	for r in nh:
		for c in nw:
			out[r * nw + c] = heights[mini(r * step, h - 1) * w + mini(c * step, w - 1)]
	return [out, nw, nh]


static func _scatter(cell_dir: String, info: Dictionary, heights: PackedFloat32Array, w: int, h: int, origin: Vector3, size: float) -> Dictionary:
	var out := {}
	var veg = info.get("vegetation", {})
	if typeof(veg) != TYPE_DICTIONARY:
		return out
	var dpath := cell_dir.path_join(str(veg.get("density", "")))
	if not FileAccess.file_exists(dpath):
		return out
	var img := Image.load_from_file(dpath)
	if img == null:
		return out
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	out["_density"] = img
	var channels: Array = veg.get("channels", ["trees", "blockbush", "undergrowth", "stealthplants"])
	out["_channels"] = channels
	var iw := img.get_width()
	var ih := img.get_height()
	var cell: Array = info.get("cell", [0, 0])
	var rng := RandomNumberGenerator.new()
	for sp in veg.get("species", []):
		var ch := str(sp.get("channel", ""))
		var ci := channels.find(ch)
		var mid := str(sp.get("mesh", ""))
		var per_m2 := float(sp.get("per_m2", 0.0))
		if ci < 0 or ci > 3 or mid == "" or per_m2 <= 0.0:
			continue
		rng.seed = hash([int(cell[0]), int(cell[1]), mid])
		var cap := int(SPECIES_CAP.get(ch, 4000))
		var attempts := mini(int(per_m2 * size * size), cap * 3)
		var xfs: Array = []
		for i in attempts:
			if xfs.size() >= cap:
				break
			var u := rng.randf()
			var v := rng.randf()
			var px := mini(int(u * iw), iw - 1)
			var py := mini(int(v * ih), ih - 1)
			var dens: float = img.get_pixel(px, py)[ci]
			if rng.randf() >= dens:
				continue
			var x := origin.x + u * size
			var z := origin.z + v * size
			var y := sample_height(heights, w, h, origin, size, x, z)
			var s := rng.randf_range(0.75, 1.3)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			xfs.append(Transform3D(basis, Vector3(x, y - 0.05, z)))
		if not xfs.is_empty():
			out[ch + ":" + mid] = {"channel": ch, "mesh": mid, "xfs": xfs}
	return out


## Main thread: builds the node tree for prepared data (meshes must already be loaded in `meshes`).
static func instantiate(data: Dictionary, meshes: RefCounted) -> Node3D:
	var info: Dictionary = data["info"]
	var cell: Array = info.get("cell", [0, 0])
	var root := Node3D.new()
	root.name = "Cell_%d_%d" % [int(cell[0]), int(cell[1])]
	var origin: Vector3 = data["origin"]
	var size: float = data["size"]
	# terrain visual
	var tm := MeshInstance3D.new()
	tm.name = "Terrain"
	var tmesh := ArrayMesh.new()
	tmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data["terrain_arrays"])
	tm.mesh = tmesh
	var alb: Texture2D = ImageTexture.create_from_image(data["albedo_img"]) if data.has("albedo_img") else null
	var nrm: Texture2D = ImageTexture.create_from_image(data["normal_img"]) if data.has("normal_img") else null
	tm.material_override = TerrainMaterial.make(alb, nrm)
	root.add_child(tm)
	# terrain collision (HeightMapShape3D is centred on its node; uniform scale = grid spacing)
	var cw: int = data["col_w"]
	var chh: int = data["col_h"]
	var spacing := size / float(cw - 1)
	var col: PackedFloat32Array = data["col_heights"]
	var scaled := PackedFloat32Array()
	scaled.resize(col.size())
	for i in col.size():
		scaled[i] = col[i] / spacing
	var shape := HeightMapShape3D.new()
	shape.map_width = cw
	shape.map_depth = chh
	shape.map_data = scaled
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = shape
	# (square grids assumed: the Z extent uses the X spacing)
	cs.transform = Transform3D(Basis().scaled(Vector3(spacing, spacing, spacing)), origin + Vector3((cw - 1) * spacing * 0.5, 0.0, (chh - 1) * spacing * 0.5))
	body.add_child(cs)
	root.add_child(body)
	# instances: one MultiMesh per mesh + collision
	var inst_root := Node3D.new()
	inst_root.name = "Instances"
	root.add_child(inst_root)
	var inst_body := StaticBody3D.new()
	inst_body.name = "InstanceBodies"
	inst_body.collision_layer = LAYER_WORLD
	inst_body.collision_mask = 0
	root.add_child(inst_body)
	var inst_data: Dictionary = data["instances"]
	for mid in inst_data:
		var e: Dictionary = meshes.get_entry(mid)
		if e.is_empty():
			continue
		var xfs: Array = inst_data[mid]
		inst_root.add_child(_multimesh(mid, e["mesh"], xfs, 0.0))
		var sh: Shape3D = meshes.get_shape(mid)
		if sh:
			for xf in xfs:
				var c := CollisionShape3D.new()
				c.shape = sh
				c.transform = xf
				inst_body.add_child(c)
	# vegetation
	var veg_root := Node3D.new()
	veg_root.name = "Vegetation"
	root.add_child(veg_root)
	var veg: Dictionary = data["vegetation"]
	var tree_body := StaticBody3D.new()
	tree_body.name = "TreeBodies"
	tree_body.collision_layer = LAYER_WORLD
	tree_body.collision_mask = 0
	root.add_child(tree_body)
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.3
	trunk.height = 4.0
	for key in veg:
		if str(key).begins_with("_"):
			continue
		var v: Dictionary = veg[key]
		var ve: Dictionary = meshes.get_entry(str(v["mesh"]))
		if ve.is_empty():
			continue
		var mmi := _multimesh(str(key), ve["mesh"], v["xfs"], float(SPECIES_RANGE.get(v["channel"], 300.0)))
		mmi.set_meta("channel", v["channel"])
		veg_root.add_child(mmi)
		if v["channel"] == "trees":
			for xf in v["xfs"]:
				var c := CollisionShape3D.new()
				c.shape = trunk
				c.transform = Transform3D(Basis(), (xf as Transform3D).origin + Vector3(0, 2.0, 0))
				tree_body.add_child(c)
	# campfires
	for cf in info.get("campfires", []):
		var p: Array = cf.get("pos", [0, 0, 0])
		var node := Campfire.new()
		node.campfire_id = str(cf.get("id", ""))
		node.name = "Campfire_" + node.campfire_id.validate_node_name()
		node.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		root.add_child(node)
	return root


static func _multimesh(id: String, mesh: Mesh, xfs: Array, range_end: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	var buf := PackedFloat32Array()
	buf.resize(xfs.size() * 12)
	var i := 0
	for xf in xfs:
		var t: Transform3D = xf
		var b := t.basis
		buf[i] = b.x.x
		buf[i + 1] = b.y.x
		buf[i + 2] = b.z.x
		buf[i + 3] = t.origin.x
		buf[i + 4] = b.x.y
		buf[i + 5] = b.y.y
		buf[i + 6] = b.z.y
		buf[i + 7] = t.origin.y
		buf[i + 8] = b.x.z
		buf[i + 9] = b.y.z
		buf[i + 10] = b.z.z
		buf[i + 11] = t.origin.z
		i += 12
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "MM_" + id.validate_node_name()
	mmi.multimesh = mm
	if range_end > 0.0:
		mmi.visibility_range_end = range_end
		mmi.visibility_range_end_margin = 10.0
	return mmi
