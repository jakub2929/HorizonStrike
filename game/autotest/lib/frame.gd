extends RefCounted
## Screenshot and camera checks: blank-frame detection, screen-space bounding boxes, frustum and occlusion tests.


static func analyze_png(path: String, since_unix: int) -> Dictionary:
	var r := {"path": path, "exists": FileAccess.file_exists(path)}
	if not r.exists:
		return r
	r.mtime = FileAccess.get_modified_time(path)
	r.fresh = int(r.mtime) >= since_unix
	var img := Image.load_from_file(path)
	r.loaded = img != null and not img.is_empty()
	if not r.loaded:
		return r
	r.width = img.get_width()
	r.height = img.get_height()
	var s := luma_stats(img)
	r.luma_mean = snappedf(s.x, 0.01)
	r.luma_stddev = snappedf(s.y, 0.01)
	return r


static func luma_stats(src: Image) -> Vector2:
	## mean and standard deviation of the luminance (0..255) on a downscaled copy
	var img := src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	var w := mini(img.get_width(), 320)
	var h := maxi(1, int(round(float(img.get_height()) * w / maxf(1.0, img.get_width()))))
	img.resize(w, h, Image.INTERPOLATE_BILINEAR)
	var data := img.get_data()
	var n := w * h
	var sum := 0.0
	var sum2 := 0.0
	for i in n:
		var l := 0.2126 * data[i * 3] + 0.7152 * data[i * 3 + 1] + 0.0722 * data[i * 3 + 2]
		sum += l
		sum2 += l * l
	var mean := sum / n
	return Vector2(mean, sqrt(maxf(0.0, sum2 / n - mean * mean)))


static func global_aabb(node: Node) -> AABB:
	## merged world-space AABB of the visible meshes (GeometryInstance3D, no lights) under `node` (size 0 if none)
	var nodes: Array = node.find_children("*", "GeometryInstance3D", true, false)
	if node is GeometryInstance3D:
		nodes.append(node)
	var have := false
	var box := AABB()
	for vi in nodes:
		if not (vi as GeometryInstance3D).is_visible_in_tree():
			continue
		var a: AABB = vi.global_transform * vi.get_aabb()
		box = a if not have else box.merge(a)
		have = true
	if not have and node is Node3D:
		box = AABB(node.global_position, Vector3.ZERO)
	return box


static func screen_box(cam: Camera3D, box: AABB) -> Dictionary:
	## projected bounding rect of `box`, clipped to the viewport; frac_h = rect height / viewport height
	var vp := cam.get_viewport().get_visible_rect()
	var rect := Rect2()
	var have := false
	var behind := 0
	for i in 8:
		var p := box.get_endpoint(i)
		if cam.is_position_behind(p):
			behind += 1
			continue
		var s := cam.unproject_position(p)
		rect = Rect2(s, Vector2.ZERO) if not have else rect.expand(s)
		have = true
	var clipped := rect.intersection(vp) if have else Rect2()
	var center := box.get_center()
	return {
		"rect": [snappedf(clipped.position.x, 0.1), snappedf(clipped.position.y, 0.1), snappedf(clipped.size.x, 0.1), snappedf(clipped.size.y, 0.1)],
		"frac_h": snappedf(clipped.size.y / maxf(1.0, vp.size.y), 0.001),
		"center_in_frustum": cam.is_position_in_frustum(center),
		"corners_behind": behind,
		"distance_m": snappedf(cam.global_position.distance_to(center), 0.01),
	}


static func line_of_sight(world: World3D, from: Vector3, to: Vector3, target: Node, exclude: Array[RID]) -> Dictionary:
	## ray from -> to; clear when nothing is hit or the first hit belongs to `target`
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = exclude
	q.collide_with_areas = false
	var hit := world.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {"clear": true, "by": ""}
	var col: Variant = hit.get("collider")
	if col is Node and (col == target or target.is_ancestor_of(col)):
		return {"clear": true, "by": str(col.name)}
	var by := str(col.name) if col is Node else str(col)
	return {"clear": false, "by": by, "at": var_to_str(hit.get("position"))}
