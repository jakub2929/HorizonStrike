extends RefCounted
## --mock-data: synthetic placeholder content so the whole loop runs before real converted content exists.
## Everything here is invented (numbers from simple formulas, shapes from primitives, terrain from noise); nothing is
## read or copied from CS2 or HZD. Files are written into the mock cache with the same layout the converter uses,
## so the game exercises its real loading code.

const Sheets := preload("res://core/sheets.gd")
const FsUtil := preload("res://core/fsutil.gd")
const CELL_RES := 129
const VEG_RES := 64
const MESHES := ["mock_rock", "mock_tree", "mock_bush", "mock_ruin"]

# Placeholder stats per category: [damage, headshot_mult, armor_ratio, range_u, range_mod, full_auto, cycle,
# clip, reserve, reload_s, max_speed_u, inacc_stand, inacc_move, inacc_fire, spread, recoil_mag]
const TEMPLATES := {
	"knife": [40, 1.0, 1.7, 64, 1.0, false, 0.4, -1, 0, 0.0, 250, 0.0, 0.0, 0.0, 0.0, 0.0],
	"pistol": [30, 4.0, 0.9, 4096, 0.85, false, 0.15, 15, 120, 2.2, 240, 0.006, 0.02, 0.05, 0.002, 18.0],
	"smg": [28, 4.0, 0.6, 4096, 0.8, true, 0.08, 30, 120, 2.6, 240, 0.01, 0.03, 0.006, 0.003, 15.0],
	"rifle": [33, 4.0, 1.5, 8192, 0.97, true, 0.1, 30, 90, 2.4, 215, 0.005, 0.15, 0.008, 0.0006, 25.0],
	"sniper": [110, 4.0, 1.9, 8192, 0.99, false, 1.4, 5, 30, 3.6, 200, 0.1, 0.3, 0.1, 0.0002, 70.0],
	"shotgun": [26, 4.0, 1.0, 3000, 0.7, false, 0.9, 8, 32, 0.5, 220, 0.009, 0.03, 0.03, 0.04, 140.0],
	"grenade": [99, 1.0, 1.6, 350, 1.0, false, 1.0, 1, 0, 0.0, 245, 0.0, 0.0, 0.0, 0.0, 0.0],
	"equipment": [0, 0.0, 0.0, 0, 1.0, false, 0.0, 0, 0, 0.0, 250, 0.0, 0.0, 0.0, 0.0, 0.0],
}


static func weapons_json() -> Dictionary:
	var out := {"_errors": [], "_mock": true}
	for id in Sheets.weapon_ids():
		var row: Dictionary = Sheets.weapon_row(id)
		var cat := str(row.get("category", "pistol"))
		var t: Array = TEMPLATES.get(cat, TEMPLATES["pistol"])
		var idx := int(row.get("buy_wheel_index", -1))
		var r := {}
		r["price"] = 0 if idx < 0 else 200 + 300 * idx
		r["kill_award"] = null # mock leaves it unresolved: the game falls back to kill_award_class
		r["damage"] = t[0] if cat != "grenade" or id == "hegrenade" else 40
		r["bullets"] = 9 if cat == "shotgun" else 1
		r["headshot_mult"] = t[1]
		r["armor_ratio"] = t[2]
		r["penetration"] = 1.0
		r["range"] = t[3]
		r["range_modifier"] = t[4]
		r["full_auto"] = t[5]
		r["cycle_time"] = [t[6], t[6] * 2.5]
		r["clip_size"] = t[7]
		r["reserve_max"] = t[8]
		r["reserve_as_clips"] = false
		r["reload_time"] = t[9]
		r["reload_single_shells"] = cat == "shotgun"
		r["deploy_time"] = 0.8
		r["spread"] = [t[14], t[14] * 0.8]
		r["inaccuracy_stand"] = [t[11], t[11] * 0.5]
		r["inaccuracy_crouch"] = [t[11] * 0.7, t[11] * 0.4]
		r["inaccuracy_move"] = [t[12], t[12]]
		r["inaccuracy_jump"] = [0.3, 0.3]
		r["inaccuracy_land"] = [0.1, 0.1]
		r["inaccuracy_fire"] = [t[13], t[13]]
		r["recovery_time_stand"] = 0.35
		r["recovery_time_crouch"] = 0.3
		r["recoil_angle"] = [0.0, 0.0]
		r["recoil_angle_variance"] = [40.0, 40.0]
		r["recoil_magnitude"] = [t[15], t[15]]
		r["recoil_magnitude_variance"] = [2.0, 2.0]
		r["recoil_seed"] = 1000 + idx
		r["max_speed"] = [t[10], t[10] * 0.6]
		r["zoom_levels"] = 2 if cat == "sniper" else 0
		r["zoom_fov"] = 40 if cat == "sniper" else 0
		r["throw_velocity"] = 750.0 if cat == "grenade" else 0.0
		r["world_model"] = "mock"
		out[id] = r
	return out


# ------------------------------------------------------------------ world

static func make_noise() -> Array:
	var a := FastNoiseLite.new()
	a.seed = 1337
	a.frequency = 0.0016
	a.fractal_octaves = 4
	var b := FastNoiseLite.new()
	b.seed = 4242
	b.frequency = 0.012
	return [a, b]


static func height_at(noise: Array, x: float, z: float) -> float:
	var a: FastNoiseLite = noise[0]
	var b: FastNoiseLite = noise[1]
	return 60.0 + 28.0 * a.get_noise_2d(x, z) + 3.0 * b.get_noise_2d(x, z)


static func cell_origin(x: int, y: int, size: float) -> Vector3:
	return Vector3(x * size, 0.0, -(y + 1) * size)


static func index_json(size: float) -> Dictionary:
	var gmin: Array = Sheets.sys("streaming.grid_min")
	var gmax: Array = Sheets.sys("streaming.grid_max")
	var start: Array = Sheets.sys("streaming.start_cell")
	var cells: Array = []
	for y in range(int(gmin[1]), int(gmax[1]) + 1):
		for x in range(int(gmin[0]), int(gmax[0]) + 1):
			cells.append([x, y])
	var o := cell_origin(int(start[0]), int(start[1]), size)
	var noise := make_noise()
	var sx := o.x + size * 0.5
	var sz := o.z + size * 0.5
	var cf := campfire_pos(noise, int(start[0]), int(start[1]), size)
	return {"cell_size": size, "grid_min": gmin, "grid_max": gmax, "cells": cells, "start_cell": start,
		"start_pos": [cf.x + 3.0, height_at(noise, cf.x + 3.0, cf.z), cf.z], "start_campfire": campfire_id(int(start[0]), int(start[1])),
		"_mock": true, "_center": [sx, 0, sz]}


static func campfire_id(x: int, y: int) -> String:
	return "mock_campfire_%d_%d" % [x, y]


static func campfire_pos(noise: Array, x: int, y: int, size: float) -> Vector3:
	var o := cell_origin(x, y, size)
	var px := o.x + size * (0.45 + 0.1 * float(posmod(x * 7 + y * 3, 5)) / 5.0)
	var pz := o.z + size * (0.45 + 0.1 * float(posmod(x * 3 + y * 5, 5)) / 5.0)
	return Vector3(px, height_at(noise, px, pz), pz)


static func xf_array(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z]


## Writes hzd/cells/<x>_<y>/ (cell.json, height.r32, albedo.png, veg_density.png). Returns bytes written.
static func write_cell(cache_root: String, x: int, y: int, size: float, pad_bytes: int = 0) -> int:
	var dir := cache_root.path_join("hzd/cells/%d_%d" % [x, y])
	var tmp := dir + ".tmp"
	if DirAccess.dir_exists_absolute(tmp):
		FsUtil.remove_tree(tmp, cache_root)
	DirAccess.make_dir_recursive_absolute(tmp)
	var noise := make_noise()
	var o := cell_origin(x, y, size)
	var step := size / float(CELL_RES - 1)
	var heights := PackedFloat32Array()
	heights.resize(CELL_RES * CELL_RES)
	var hmin := INF
	var hmax := -INF
	for r in CELL_RES:
		for c in CELL_RES:
			var h := height_at(noise, o.x + c * step, o.z + r * step)
			heights[r * CELL_RES + c] = h
			hmin = minf(hmin, h)
			hmax = maxf(hmax, h)
	var f := FileAccess.open(tmp.path_join("height.r32"), FileAccess.WRITE)
	f.store_buffer(heights.to_byte_array())
	f.close()
	# albedo: grass/dirt by height, a little noise
	var img := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var b: FastNoiseLite = noise[1]
	for py in 256:
		for px in 256:
			var wx := o.x + px * size / 255.0
			var wz := o.z + py * size / 255.0
			var h := height_at(noise, wx, wz)
			var t := clampf((h - 45.0) / 40.0, 0.0, 1.0)
			var n := 0.08 * b.get_noise_2d(wx * 3.0, wz * 3.0)
			var grass := Color(0.30 + n, 0.42 + n, 0.20)
			var rock := Color(0.48 + n, 0.44 + n, 0.38 + n)
			img.set_pixel(px, py, grass.lerp(rock, t * t))
	img.save_png(tmp.path_join("albedo.png"))
	# vegetation density RGBA = trees, blockbush, undergrowth, stealthplants
	var veg := Image.create(VEG_RES, VEG_RES, false, Image.FORMAT_RGBA8)
	var a: FastNoiseLite = noise[0]
	for py in VEG_RES:
		for px in VEG_RES:
			var wx := o.x + px * size / float(VEG_RES - 1)
			var wz := o.z + py * size / float(VEG_RES - 1)
			var v := a.get_noise_2d(wx * 4.0, wz * 4.0)
			var w := b.get_noise_2d(wx * 2.0, wz * 2.0)
			veg.set_pixel(px, py, Color(clampf(v * 2.0, 0, 1), clampf(w * 2.0, 0, 1), clampf(0.5 + v, 0, 1), clampf(w * 3.0 - 0.5, 0, 1)))
	veg.save_png(tmp.path_join("veg_density.png"))
	# instances: a few rocks and ruins
	var instances: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(x, y))
	for i in 24:
		var px := o.x + rng.randf_range(10, size - 10)
		var pz := o.z + rng.randf_range(10, size - 10)
		var s := rng.randf_range(0.8, 3.0)
		var mesh := "mock_rock" if i % 6 != 0 else "mock_ruin"
		var t := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s)), Vector3(px, height_at(noise, px, pz) - 0.3, pz))
		instances.append({"mesh": mesh, "xf": xf_array(t)})
	var campfires: Array = []
	if posmod(x + y, 2) == 1 or (x == 4 and y == -3):
		var cp := campfire_pos(noise, x, y, size)
		campfires.append({"id": campfire_id(x, y), "pos": [cp.x, cp.y, cp.z]})
	var spawns: Array = []
	var kinds := [["scout", "recongroup", "watcher", 2], ["antelope", "resourcegatheringherd", "grazer", 5],
		["horse", "transportgroup", "strider", 3]]
	var nsites := 1 + posmod(x * 5 + y * 11, 2)
	for i in nsites:
		var k: Array = kinds[posmod(x + y * 2 + i, kinds.size())]
		if x == 4 and y == -3 and i == 0:
			k = kinds[0]
		var px := o.x + size * (0.2 + 0.6 * rng.randf())
		var pz := o.z + size * (0.2 + 0.6 * rng.randf())
		spawns.append({"site": "mock_site_%d_%d_%d" % [x, y, i], "orig_type": k[0], "group": k[1], "type": k[2],
			"count": k[3], "pos": [px, height_at(noise, px, pz), pz], "radius": 30})
	var cell := {"cell": [x, y], "origin": [o.x, 0.0, o.z], "size": size,
		"terrain": {"file": "height.r32", "res": [CELL_RES, CELL_RES], "min": hmin, "max": hmax, "real": false,
			"albedo": "albedo.png"},
		"instances": instances,
		"vegetation": {"density": "veg_density.png", "channels": ["trees", "blockbush", "undergrowth", "stealthplants"],
			"species": [{"channel": "trees", "mesh": "mock_tree", "per_m2": 0.0015},
				{"channel": "blockbush", "mesh": "mock_bush", "per_m2": 0.004}]},
		"campfires": campfires, "spawns": spawns, "meshes": MESHES.duplicate(), "_mock": true}
	var cf := FileAccess.open(tmp.path_join("cell.json"), FileAccess.WRITE)
	cf.store_string(JSON.stringify(cell, " "))
	cf.close()
	if pad_bytes > 0:
		var pf := FileAccess.open(tmp.path_join("mock_pad.dat"), FileAccess.WRITE)
		var chunk := PackedByteArray()
		chunk.resize(1 << 20)
		var left := pad_bytes
		while left > 0:
			var n := mini(left, chunk.size())
			pf.store_buffer(chunk.slice(0, n))
			left -= n
		pf.close()
	if DirAccess.dir_exists_absolute(dir):
		FsUtil.remove_tree(dir, cache_root)
	DirAccess.rename_absolute(tmp, dir)
	return FsUtil.dir_bytes(dir)


static func write_meshes(cache_root: String) -> int:
	var dir := cache_root.path_join("hzd/meshes")
	DirAccess.make_dir_recursive_absolute(dir)
	var total := 0
	for id in MESHES:
		var path := dir.path_join(id + ".glb")
		if FileAccess.file_exists(path):
			continue
		var root := Node3D.new()
		root.name = id
		match id:
			"mock_rock":
				_add_part(root, _sphere(1.0, 0.7), Transform3D(Basis().scaled(Vector3(1.4, 0.8, 1.1)), Vector3(0, 0.4, 0)), Color(0.45, 0.43, 0.4))
			"mock_tree":
				var trunk := CylinderMesh.new()
				trunk.top_radius = 0.18
				trunk.bottom_radius = 0.3
				trunk.height = 5.0
				_add_part(root, trunk, Transform3D(Basis(), Vector3(0, 2.5, 0)), Color(0.35, 0.25, 0.15))
				var crown := CylinderMesh.new()
				crown.top_radius = 0.0
				crown.bottom_radius = 2.2
				crown.height = 6.0
				_add_part(root, crown, Transform3D(Basis(), Vector3(0, 7.0, 0)), Color(0.16, 0.36, 0.18))
			"mock_bush":
				_add_part(root, _sphere(0.9, 0.7), Transform3D(Basis(), Vector3(0, 0.5, 0)), Color(0.22, 0.42, 0.16))
			"mock_ruin":
				var box := BoxMesh.new()
				box.size = Vector3(4, 3, 0.6)
				_add_part(root, box, Transform3D(Basis(), Vector3(0, 1.5, 0)), Color(0.55, 0.52, 0.5))
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_scene(root, state) == OK:
			doc.write_to_filesystem(state, path)
		root.free()
		if FileAccess.file_exists(path):
			total += FileAccess.get_file_as_bytes(path).size()
	return total


static func _sphere(r: float, h_scale: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = 2.0 * r * h_scale
	s.radial_segments = 12
	s.rings = 6
	return s


static func _add_part(root: Node3D, mesh: Mesh, xf: Transform3D, color: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.transform = xf
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mesh.surface_set_material(0, mat)
	root.add_child(mi)


## Placeholder machine meta (no model.glb: the game builds a code rig with the same procedural animation).
static func machine_meta(id: String) -> Dictionary:
	var h := Sheets.machine_num(id, "body_height_m", 2.4)
	var parts: Array = Sheets.machine(id, "weak_spot_parts") if Sheets.machine(id, "weak_spot_parts") is Array else []
	var ws: Array = []
	for p in parts:
		ws.append({"part": p, "bone": "mock_" + str(p)})
	return {"id": id, "mock": true, "height_m": h, "weak_spots": ws, "bones": [], "leg_chains": []}

