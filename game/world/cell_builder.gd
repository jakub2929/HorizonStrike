extends RefCounted
## Builds one world cell from hzd/cells/<x>_<y>/ (docs/ARCHITECTURE.md cell.json).
## prepare() runs on a worker thread (file IO, terrain arrays, vegetation scatter, glb parsing + texture decoding
## through the mesh library), instantiate() on the main thread (resources and nodes).
## Conventions: all positions in cell.json are world positions (Godot space); `origin` is the cell's min corner;
## height.r32 rows run along +Z, columns along +X, `res` = [columns, rows].
## Instances are drawn per mesh in spatial chunks (frustum culling + a visibility range that grows with the
## object's size; only big objects cast shadows); collision only for objects big enough to matter.

const Log := preload("res://core/log.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Campfire := preload("res://world/campfire.gd")
const TerrainMaterial := preload("res://world/terrain_material.gd")

const MAX_VISUAL_VERTS := 257
const MAX_COLLISION_VERTS := 1025
const MIN_COLLISION_SIZE_M := 1.0
const Sheets := preload("res://core/sheets.gd")

const LAYER_WORLD := 1


static func prepare(cell_dir: String, meshes: RefCounted) -> Dictionary:
	var out := {"ok": false, "dir": cell_dir}
	var tp := {}   # worker phase times in ms (profiling, H1)
	var tw := Time.get_ticks_usec()
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
	tp["read_json"] = (Time.get_ticks_usec() - tw) / 1000.0
	tw = Time.get_ticks_usec()
	# ---- terrain
	var terr: Dictionary = info.get("terrain", {}) if typeof(info.get("terrain")) == TYPE_DICTIONARY else {}
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
	tp["terrain"] = (Time.get_ticks_usec() - tw) / 1000.0
	tw = Time.get_ticks_usec()
	for key in ["albedo", "normal"]:
		var f := str(terr.get(key, ""))
		if f != "" and FileAccess.file_exists(cell_dir.path_join(f)):
			var img := Image.load_from_file(cell_dir.path_join(f))
			if img:
				img.generate_mipmaps()
				# runtime BC compression exists only in editor builds (release templates log an error)
				if key == "albedo" and not img.is_compressed() and OS.has_feature("editor"):
					img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
				out[key + "_img"] = img
	tp["terrain_tex"] = (Time.get_ticks_usec() - tw) / 1000.0
	tw = Time.get_ticks_usec()
	# ---- instances grouped by mesh
	var groups := {}
	var tints := {}      # mesh id -> Array[Color] parallel to groups[mid] (only for meshes with any tint)
	for inst in info.get("instances", []):
		var mid := str(inst.get("mesh", ""))
		var xf: Array = inst.get("xf", [])
		if mid == "" or xf.size() != 12:
			continue
		if not groups.has(mid):
			groups[mid] = []
		groups[mid].append(_xf(xf))
		var t: Variant = inst.get("tint")
		if t is Array and (t as Array).size() >= 3:
			if not tints.has(mid):
				var whites: Array = []
				whites.resize(groups[mid].size() - 1)
				whites.fill(Color.WHITE)
				tints[mid] = whites
			tints[mid].append(Color(float(t[0]), float(t[1]), float(t[2]), 1.0))
		elif tints.has(mid):
			tints[mid].append(Color.WHITE)
	out["instances"] = groups
	out["tints"] = tints
	tp["instances"] = (Time.get_ticks_usec() - tw) / 1000.0
	tw = Time.get_ticks_usec()
	# ---- vegetation scattered from the density map
	out["vegetation"] = _scatter(cell_dir, info, heights, w, h, origin, size)
	tp["scatter"] = (Time.get_ticks_usec() - tw) / 1000.0
	var ids := {}
	for mid in groups:
		ids[mid] = true
	for key in out["vegetation"]:
		if not str(key).begins_with("_"):
			ids[out["vegetation"][key]["mesh"]] = true
	out["mesh_ids"] = ids.keys()
	# parse meshes + decode their textures here, on the worker thread
	var ms: Dictionary = meshes.prepare(out["mesh_ids"])
	tp["mesh_parse"] = ms.get("parse_ms", 0.0)
	tp["mesh_lod"] = ms.get("lod_ms", 0.0)
	tp["tex_decode"] = ms.get("tex_ms", 0.0)
	out["t"] = tp
	out["ok"] = true
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
			var hl := heights[rr * w + maxi(cc - step, 0)]
			var hr := heights[rr * w + mini(cc + step, w - 1)]
			var hd := heights[maxi(rr - step, 0) * w + cc]
			var hu := heights[mini(rr + step, h - 1) * w + cc]
			normals[iz * nx + ix] = Vector3((hl - hr) / (2.0 * dx * step), 1.0, (hd - hu) / (2.0 * dz * step)).normalized()
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


## Vegetation from cell.json `vegetation` (format 3): {density, effect?, channels, species[]}. Per species:
## per_m2 (already includes the converter's density scale), expected, max_instances, cluster {count, radius_m},
## footprint_m (minimum spacing of clusters/plants), wander_m (position jitter), scale, scale_variance,
## max_slope_deg, effect_range [lo, hi] (only where the effect map - snow - is inside the range, so snow variants stay
## on snow). Every species is capped by max_instances; all species of a cell share streaming.vegetation_cell_cap.
static func _scatter(cell_dir: String, info: Dictionary, heights: PackedFloat32Array, w: int, h: int, origin: Vector3, size: float) -> Dictionary:
	var out := {}
	var veg = info.get("vegetation", {})
	if typeof(veg) != TYPE_DICTIONARY:
		return out
	var img := _load_map(cell_dir, str(veg.get("density", "")), Image.FORMAT_RGBA8)
	if img == null:
		return out
	out["_density"] = img
	var eff := _load_map(cell_dir, str(veg.get("effect", "")), Image.FORMAT_L8)
	var channels: Array = veg.get("channels", ["trees", "blockbush", "undergrowth", "stealthplants"])
	out["_channels"] = channels
	var iw := img.get_width()
	var ih := img.get_height()
	var mean := [0.0, 0.0, 0.0, 0.0]
	var n_s := 0
	for py in range(0, ih, 4):
		for px in range(0, iw, 4):
			var c := img.get_pixel(px, py)
			for k in 4:
				mean[k] += c[k]
			n_s += 1
	for k in 4:
		mean[k] /= maxf(n_s, 1)
	var game_scale := Sheets.sys_num("streaming.vegetation_density_scale", 1.0)
	var cell_cap := int(Sheets.sys_num("streaming.vegetation_cell_cap", 14000))
	var species: Array = []
	var total := 0.0
	for sp in veg.get("species", []):
		var ch := str(sp.get("channel", ""))
		var ci := channels.find(ch)
		var mid := str(sp.get("mesh", ""))
		var per_m2 := float(sp.get("per_m2", 0.0))
		if ci < 0 or ci > 3 or mid == "" or per_m2 <= 0.0:
			continue
		var expected := float(sp.get("expected", per_m2 * size * size * float(mean[ci]))) * game_scale * float(sp.get("density_scale", 1.0))
		if sp.has("max_instances"):
			expected = minf(expected, float(sp["max_instances"]))
		if expected < 1.0:
			continue
		species.append([sp, ci, expected])
		total += expected
	# trees get their own budget; every other species shares what is left of the cell budget
	var tree_total := 0.0
	for entry in species:
		if str(entry[0].get("channel", "")) == "trees":
			tree_total += float(entry[2])
	var tree_budget := minf(tree_total, Sheets.sys_num("streaming.vegetation_tree_cap", 1800.0))
	var tree_share := tree_budget / maxf(tree_total, 1.0)
	var share := minf(1.0, maxf(float(cell_cap) - tree_budget, 0.0) / maxf(total - tree_total, 1.0))
	var cell: Array = info.get("cell", [0, 0])
	var rng := RandomNumberGenerator.new()
	var dx := size / float(w - 1)
	for entry in species:
		var sp: Dictionary = entry[0]
		var ci: int = entry[1]
		var target := int(float(entry[2]) * (tree_share if str(sp.get("channel", "")) == "trees" else share))
		if target <= 0:
			continue
		var ch := str(sp.get("channel", ""))
		var mid := str(sp.get("mesh", ""))
		rng.seed = hash([int(cell[0]), int(cell[1]), mid])
		var max_slope := deg_to_rad(float(sp.get("max_slope_deg", 90.0)))
		var base_scale := float(sp.get("scale", 1.0))
		var var_scale := float(sp.get("scale_variance", 0.15))
		var wander := float(sp.get("wander_m", 0.0))
		var er: Array = sp.get("effect_range", [])
		var cl: Dictionary = sp.get("cluster", {}) if typeof(sp.get("cluster")) == TYPE_DICTIONARY else {}
		var per_cluster := maxi(int(cl.get("count", 1)), 1)
		var radius := float(cl.get("radius_m", 0.0))
		var centers := int(ceil(float(target) / per_cluster))
		# spacing between plants (single) or clusters; thinned species spread out instead of clumping
		var spacing := maxf(float(sp.get("footprint_m", 0.0)), maxf(radius * 2.0, sqrt(size * size / maxf(centers, 1.0)) * 0.5))
		var grid := {}
		var xfs: Array = []
		var attempts := centers * 8
		for i in attempts:
			if xfs.size() >= target:
				break
			var u := rng.randf()
			var v := rng.randf()
			if rng.randf() >= img.get_pixel(mini(int(u * iw), iw - 1), mini(int(v * ih), ih - 1))[ci]:
				continue
			var x := origin.x + u * size
			var z := origin.z + v * size
			if not _in_effect(eff, er, x, z, origin, size):
				continue
			var key := Vector2i(floori(x / spacing), floori(z / spacing))
			var close := false
			for gy in range(-1, 2):
				for gx in range(-1, 2):
					var other: Variant = grid.get(key + Vector2i(gx, gy))
					if other != null and Vector2(x, z).distance_to(other) < spacing:
						close = true
			if close:
				continue
			grid[key] = Vector2(x, z)
			for m in per_cluster:
				if xfs.size() >= target:
					break
				var px := x
				var pz := z
				if m > 0 or per_cluster > 1:
					var a := rng.randf() * TAU
					var r := sqrt(rng.randf()) * radius
					px += cos(a) * r
					pz += sin(a) * r
				if wander > 0.0:
					px += rng.randf_range(-wander, wander)
					pz += rng.randf_range(-wander, wander)
				px = clampf(px, origin.x, origin.x + size)
				pz = clampf(pz, origin.z, origin.z + size)
				if m > 0 and not _in_effect(eff, er, px, pz, origin, size):
					continue
				var y := sample_height(heights, w, h, origin, size, px, pz)
				if max_slope < PI * 0.49:
					var gxs := sample_height(heights, w, h, origin, size, px + dx, pz) - y
					var gzs := sample_height(heights, w, h, origin, size, px, pz + dx) - y
					if atan(Vector2(gxs, gzs).length() / dx) > max_slope:
						continue
				var s := base_scale * (1.0 + rng.randf_range(-var_scale, var_scale))
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
				xfs.append(Transform3D(basis, Vector3(px, y - 0.05, pz)))
		if not xfs.is_empty():
			out[ch + ":" + mid] = {"channel": ch, "mesh": mid, "xfs": xfs}
	return out


static func _load_map(cell_dir: String, file: String, fmt: int) -> Image:
	if file == "" or not FileAccess.file_exists(cell_dir.path_join(file)):
		return null
	var im := Image.load_from_file(cell_dir.path_join(file))
	if im == null:
		return null
	if im.is_compressed():
		im.decompress()
	im.convert(fmt)
	return im


## Effect map (e.g. snow) value at a position inside [lo, hi]; no range or no map = everywhere.
static func _in_effect(eff: Image, er: Array, x: float, z: float, origin: Vector3, size: float) -> bool:
	if er.size() < 2 or eff == null:
		return true
	var ew := eff.get_width()
	var eh := eff.get_height()
	var u := clampf((x - origin.x) / size, 0.0, 0.9999)
	var v := clampf((z - origin.z) / size, 0.0, 0.9999)
	var e := eff.get_pixel(int(u * ew), int(v * eh)).r
	return e >= float(er[0]) and e <= float(er[1])


## Main thread: builds the node tree for prepared data (meshes must already be loaded in `meshes`).
static func instantiate(data: Dictionary, meshes: RefCounted) -> Node3D:
	var info: Dictionary = data["info"]
	var cell: Array = info.get("cell", [0, 0])
	var root := Node3D.new()
	root.name = "Cell_%d_%d" % [int(cell[0]), int(cell[1])]
	var origin: Vector3 = data["origin"]
	var size: float = data["size"]
	var ph := {"terrain": 0.0, "terrain_collision": 0.0, "multimesh": 0.0, "collision": 0.0, "mesh_upload": 0.0}
	var tw := Time.get_ticks_usec()
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
	ph["terrain"] = (Time.get_ticks_usec() - tw) / 1000.0
	tw = Time.get_ticks_usec()
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
	ph["terrain_collision"] = (Time.get_ticks_usec() - tw) / 1000.0
	# static objects: shapes grouped into static bodies of SHAPES_PER_BODY (shape owners, no node per shape)
	var objects := Node3D.new()
	objects.name = "ObjectBodies"
	root.add_child(objects)
	var inst_root := Node3D.new()
	inst_root.name = "Instances"
	root.add_child(inst_root)
	var inst_data: Dictionary = data["instances"]
	var n_shapes := 0
	for mid in inst_data:
		tw = Time.get_ticks_usec()
		var e: Dictionary = meshes.get_entry(mid)
		ph["mesh_upload"] += (Time.get_ticks_usec() - tw) / 1000.0
		if e.is_empty():
			continue
		var xfs: Array = inst_data[mid]
		tw = Time.get_ticks_usec()
		_add_chunked(inst_root, mid, e, xfs, origin, (data.get("tints", {}) as Dictionary).get(mid, []))
		ph["multimesh"] += (Time.get_ticks_usec() - tw) / 1000.0
		tw = Time.get_ticks_usec()
		n_shapes += _add_collision(objects, meshes, mid, e, xfs)
		ph["collision"] += (Time.get_ticks_usec() - tw) / 1000.0
	# vegetation
	var veg_root := Node3D.new()
	veg_root.name = "Vegetation"
	root.add_child(veg_root)
	var veg: Dictionary = data["vegetation"]
	for key in veg:
		if str(key).begins_with("_"):
			continue
		var v: Dictionary = veg[key]
		tw = Time.get_ticks_usec()
		var ve: Dictionary = meshes.get_entry(str(v["mesh"]))
		ph["mesh_upload"] += (Time.get_ticks_usec() - tw) / 1000.0
		if ve.is_empty():
			continue
		tw = Time.get_ticks_usec()
		_add_chunked(veg_root, str(key), ve, v["xfs"], origin)
		ph["multimesh"] += (Time.get_ticks_usec() - tw) / 1000.0
		if v["channel"] == "trees":
			tw = Time.get_ticks_usec()
			n_shapes += _add_collision(objects, meshes, str(v["mesh"]), ve, v["xfs"])
			ph["collision"] += (Time.get_ticks_usec() - tw) / 1000.0
	root.set_meta("phases", ph)
	root.set_meta("collision_shapes", n_shapes)
	root.set_meta("collision_bodies", objects.get_child_count())
	# campfires
	for cf in info.get("campfires", []):
		var p: Array = cf.get("pos", [0, 0, 0])
		var node := Campfire.new()
		node.campfire_id = str(cf.get("id", ""))
		node.name = "Campfire_" + node.campfire_id.validate_node_name()
		node.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		node.rotation.y = deg_to_rad(float(cf.get("yaw_deg", 0.0)))
		root.add_child(node)
	return root


## Size class of a mesh -> [chunk size m, visibility range m, casts shadow]. Plants (alpha-tested) fade sooner.
static func _lod_class(aabb: AABB, scale: float, plant: bool) -> Array:
	var s := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * scale
	var k := 0.45 if plant else 1.0
	if s < 1.5:
		return [128.0, 45.0 if plant else 55.0, false]
	if s < 4.0:
		return [128.0, 130.0 * k, false]
	if s < 12.0:
		return [256.0, 300.0 * k, false]
	return [512.0, 600.0 if plant else 0.0, true]


static func _add_chunked(parent: Node3D, id: String, e: Dictionary, xfs: Array, origin: Vector3, tints: Array = []) -> void:
	var mesh: Mesh = e["mesh"]
	var aabb: AABB = e["aabb"]
	var scale := 1.0
	if not xfs.is_empty():
		scale = (xfs[0] as Transform3D).basis.get_scale().abs().x
	var cls := _lod_class(aabb, scale, bool(e.get("plant", false)))
	# huge alpha-tested meshes are distant impostors (e.g. combined forest billboards spanning hundreds of metres):
	# only drawn from afar, never up close
	var impostor := _is_impostor(e, scale)
	var chunk: float = cls[0]
	var buckets := {}
	var colors := {}
	var tinted := tints.size() == xfs.size() and not tints.is_empty()
	for i in xfs.size():
		var t: Transform3D = xfs[i]
		var key := Vector2i(floori((t.origin.x - origin.x) / chunk), floori((t.origin.z - origin.z) / chunk))
		if not buckets.has(key):
			buckets[key] = []
			colors[key] = []
		buckets[key].append(t)
		if tinted:
			colors[key].append(tints[i])
	for key in buckets:
		var k: Vector2i = key
		var center := origin + Vector3((k.x + 0.5) * chunk, 0.0, (k.y + 0.5) * chunk)
		var list: Array = buckets[key]
		center.y = (list[0] as Transform3D).origin.y
		var mmi := _multimesh(id, mesh, list, center, colors[key] if tinted else [])
		mmi.position = center
		if impostor:
			mmi.visibility_range_begin = maxf(220.0, maxf(aabb.size.x, aabb.size.z) * scale * 0.6)
			mmi.visibility_range_begin_margin = 20.0
		elif float(cls[1]) > 0.0:
			mmi.visibility_range_end = float(cls[1]) + chunk * 0.5
			mmi.visibility_range_end_margin = 15.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cls[2] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mmi)


## Collision for objects big enough to block a player; shapes are spread over several static bodies (one Jolt
## compound per body must stay small). Primitive shapes (tree trunks) drop the instance scale (Jolt only scales
## them uniformly); triangle meshes keep it.
static func _is_impostor(e: Dictionary, scale: float) -> bool:
	var aabb: AABB = e["aabb"]
	return bool(e.get("plant", false)) and maxf(aabb.size.x, aabb.size.z) * scale > 64.0


static func _add_collision(parent: Node3D, meshes: RefCounted, id: String, e: Dictionary, xfs: Array) -> int:
	var aabb: AABB = e["aabb"]
	var plant: bool = e.get("plant", false)
	if _is_impostor(e, 1.0):
		return 0
	if not plant and maxf(aabb.size.x, aabb.size.z) < MIN_COLLISION_SIZE_M and aabb.size.y < 0.8:
		return 0
	var sh: Shape3D = meshes.get_shape(id)
	if sh == null:
		return 0
	var off: Vector3 = meshes.shape_offset(id)
	var primitive := not (sh is ConcavePolygonShape3D)
	var n := 0
	for xf in xfs:
		var t: Transform3D = xf
		var body := _body_with_room(parent)
		var o := body.create_shape_owner(body)
		body.shape_owner_add_shape(o, sh)
		if primitive:
			body.shape_owner_set_transform(o, Transform3D(t.basis.orthonormalized(), t.origin + t.basis * off))
		else:
			body.shape_owner_set_transform(o, t * Transform3D(Basis(), off))
		n += 1
	return n


const SHAPES_PER_BODY := 256


static func _body_with_room(parent: Node3D) -> StaticBody3D:
	var last: StaticBody3D = parent.get_child(parent.get_child_count() - 1) if parent.get_child_count() > 0 else null
	if last and last.get_shape_owners().size() < SHAPES_PER_BODY:
		return last
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_WORLD
	body.collision_mask = 0
	parent.add_child(body)
	return body


static func _multimesh(id: String, mesh: Mesh, xfs: Array, center: Vector3, colors: Array = []) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var use_colors := colors.size() == xfs.size() and not colors.is_empty()
	mm.use_colors = use_colors
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	var stride := 16 if use_colors else 12
	var buf := PackedFloat32Array()
	buf.resize(xfs.size() * stride)
	var i := 0
	for n in xfs.size():
		var t: Transform3D = xfs[n]
		var b := t.basis
		var o := t.origin - center
		buf[i] = b.x.x
		buf[i + 1] = b.y.x
		buf[i + 2] = b.z.x
		buf[i + 3] = o.x
		buf[i + 4] = b.x.y
		buf[i + 5] = b.y.y
		buf[i + 6] = b.z.y
		buf[i + 7] = o.y
		buf[i + 8] = b.x.z
		buf[i + 9] = b.y.z
		buf[i + 10] = b.z.z
		buf[i + 11] = o.z
		if use_colors:
			var c: Color = colors[n]
			buf[i + 12] = c.r
			buf[i + 13] = c.g
			buf[i + 14] = c.b
			buf[i + 15] = 1.0
		i += stride
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "MM_" + id.validate_node_name()
	mmi.multimesh = mm
	return mmi
