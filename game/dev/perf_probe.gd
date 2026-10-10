extends Node
## Perf / memory probe (dev only, not exported; owner vykon). Self-contained so it can be attached to a RELEASE build
## (release templates ignore --script) through an override.cfg next to a copy of the exe:
##     [autoload]
##     PerfProbe="*E:/meshy_work/vykon/probe/perf_probe.gd"
## and is inactive unless the run gets `--perf-probe-out <dir>`. Works on 0.2 and later builds (every game field is
## read with get() and checked).
##
## Writes into <dir>:
##   frames_<pid>.csv     one row per frame: t_s, frame_ms, gpu_ms (all measured viewports), cpu_render_ms,
##                        process_ms, physics_ms, draw_calls, primitives, objects, cell, cells_loaded, building, heavy
##   mem_<pid>.csv        every 5 s: static memory, video/texture/buffer memory, object/resource/node counts, cells,
##                        mesh library counts
##   breakdown_<pid>.json heavy memory breakdown 20 s after world_ready and every --perf-probe-heavy-s (120) s:
##                        textures (RenderingServer.texture_debug_usage by owner), collision shapes, cell data,
##                        prepared cells, MultiMesh instances, machines, baseline before the world (engine+scripts)
## Frames that ran a heavy sample have heavy = 1 (exclude them from frame statistics).

const MIB := 1048576.0

var _out := ""
var _active := false
var _t0 := 0
var _frames: FileAccess
var _mem: FileAccess
var _breakdowns: Array = []
var _baseline := {}
var _ready_at := -1.0
var _next_heavy := -1.0
var _heavy_every := 120.0
var _next_mem := 0.0
var _vps: Array = []      # viewport RIDs with render time measuring on
var _vp_scan := 0.0
var _heavy_frame := false
var _lines := PackedStringArray()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000   # after the game's own _process
	_out = _arg("--perf-probe-out")
	if _out == "":
		return
	var h := _arg("--perf-probe-heavy-s")
	if h != "":
		_heavy_every = maxf(float(h), 10.0)
	_active = true
	_out = _out.replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(_out)
	var pid := OS.get_process_id()
	_frames = FileAccess.open(_out.path_join("frames_%d.csv" % pid), FileAccess.WRITE)
	_frames.store_line("t_s,frame_ms,gpu_ms,cpu_render_ms,process_ms,physics_ms,draw_calls,primitives,objects,cell,cells_loaded,building,heavy")
	_mem = FileAccess.open(_out.path_join("mem_%d.csv" % pid), FileAccess.WRITE)
	_mem.store_line("t_s,static_mib,static_peak_mib,video_mib,texture_mib,buffer_mib,objects,resources,nodes,orphans,cells_loaded,cells_far,cell_data,building,mesh_entries,mesh_textures,mesh_shapes,mesh_parsed,mesh_images,machines,converter_pid")
	_t0 = Time.get_ticks_usec()
	_baseline = {"static_mib": OS.get_static_memory_usage() / MIB, "objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT), "note": "autoloads + scripts + engine before the main scene"}
	print("perf probe: on, out %s" % _out)


static func _arg(flag: String) -> String:
	var list := PackedStringArray()
	list.append_array(OS.get_cmdline_args())
	list.append_array(OS.get_cmdline_user_args())
	var i := list.find(flag)
	if i >= 0 and i + 1 < list.size():
		return list[i + 1]
	return ""


func _t() -> float:
	return (Time.get_ticks_usec() - _t0) / 1000000.0


func _game() -> Node:
	return get_node_or_null("/root/Game")


func _world() -> Object:
	var g := _game()
	if g == null:
		return null
	var w: Variant = g.get("world")
	return w if w is Object and is_instance_valid(w) else null


func _process(delta: float) -> void:
	if not _active:
		return
	var t := _t()
	if t >= _vp_scan:
		_vp_scan = t + 10.0
		_scan_viewports()
	var gpu := 0.0
	var cpu := RenderingServer.get_frame_setup_time_cpu()
	for rid in _vps:
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var w := _world()
	var cell := ""
	var loaded := 0
	var building := 0
	if w:
		var l: Variant = w.get("loaded")
		loaded = (l as Dictionary).size() if l is Dictionary else 0
		var b: Variant = w.get("building")
		building = (b as Dictionary).size() if b is Dictionary else 0
		var g := _game()
		var p: Variant = g.get("player") if g else null
		if p is Node3D and is_instance_valid(p) and w.has_method("cell_of"):
			var c: Vector2i = w.cell_of((p as Node3D).global_position)
			cell = "%d_%d" % [c.x, c.y]
	_lines.append("%.3f,%.2f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%s,%d,%d,%d" % [t, delta * 1000.0, gpu, cpu,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), cell, loaded, building, 1 if _heavy_frame else 0])
	_heavy_frame = false
	if _lines.size() >= 600:
		_flush()
	var g2 := _game()
	if _ready_at < 0.0 and g2 and bool(g2.get("is_world_ready")):
		_ready_at = t
		_next_heavy = t + 20.0
		_breakdowns.append({"t_s": t, "event": "world_ready"})
	if t >= _next_mem:
		_next_mem = t + 5.0
		_mem_sample(t)
	if _next_heavy > 0.0 and t >= _next_heavy:
		_next_heavy = t + _heavy_every
		_heavy(t)


func _scan_viewports() -> void:
	_vps.clear()
	var vp_nodes: Array = [get_tree().root]
	vp_nodes.append_array(get_tree().root.find_children("*", "SubViewport", true, false))
	for v in vp_nodes:
		var rid: RID = (v as Viewport).get_viewport_rid()
		RenderingServer.viewport_set_measure_render_time(rid, true)
		_vps.append(rid)


func _flush() -> void:
	if _frames and not _lines.is_empty():
		_frames.store_string("\n".join(_lines) + "\n")
		_frames.flush()
	_lines.clear()


func _ml() -> Object:
	var w := _world()
	if w == null:
		return null
	var m: Variant = w.get("meshes")
	return m if m is Object else null


static func _dsize(v: Variant) -> int:
	return (v as Dictionary).size() if v is Dictionary else -1


func _mem_sample(t: float) -> void:
	var w := _world()
	var ml := _ml()
	var g := _game()
	var machines: Variant = g.get("machines") if g else null
	_mem.store_line("%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d" % [t,
		OS.get_static_memory_usage() / MIB, OS.get_static_memory_peak_usage() / MIB,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / MIB, Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / MIB,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / MIB,
		Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		_dsize(w.get("loaded")) if w else -1, _dsize(w.get("far")) if w else -1, _dsize(w.get("cell_data")) if w else -1,
		_dsize(w.get("building")) if w else -1,
		_dsize(ml.get("_entries")) if ml else -1, _dsize(ml.get("_textures")) if ml else -1, _dsize(ml.get("_shapes")) if ml else -1,
		_dsize(ml.get("_parsed")) if ml else -1, _dsize(ml.get("_images")) if ml else -1,
		(machines as Array).size() if machines is Array else -1, int(g.get("converter_pid")) if g and g.get("converter_pid") != null else 0])
	_mem.flush()


## Bytes of plain data inside a Variant (packed arrays, images, nested containers); objects other than Image count 0.
static func _data_bytes(v: Variant, depth: int = 0) -> int:
	if depth > 6:
		return 0
	match typeof(v):
		TYPE_PACKED_BYTE_ARRAY:
			return (v as PackedByteArray).size()
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_FLOAT32_ARRAY:
			return v.size() * 4
		TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return v.size() * 8
		TYPE_PACKED_VECTOR2_ARRAY:
			return v.size() * 8
		TYPE_PACKED_VECTOR3_ARRAY:
			return v.size() * 12
		TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return v.size() * 16
		TYPE_PACKED_STRING_ARRAY:
			return v.size() * 32
		TYPE_TRANSFORM3D:
			return 48
		TYPE_DICTIONARY:
			var n := 0
			for k in v:
				n += 48 + _data_bytes(v[k], depth + 1)
			return n
		TYPE_ARRAY:
			var n2 := 0
			for e in v:
				n2 += 16 + _data_bytes(e, depth + 1)
			return n2
		TYPE_OBJECT:
			if v is Image and is_instance_valid(v):
				return (v as Image).get_data_size()
	return 0


func _heavy(t: float) -> void:
	var t_start := Time.get_ticks_usec()
	_heavy_frame = true
	var b := {"t_s": t, "since_ready_s": t - _ready_at, "baseline": _baseline,
		"static_mib": OS.get_static_memory_usage() / MIB,
		"video_mib": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / MIB,
		"texture_mib": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / MIB,
		"buffer_mib": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / MIB}
	# textures: the mesh library's (world) textures estimated from size and format (full mip chain); the rest of
	# RENDER_TEXTURE_MEM_USED is everything else (terrain, machines, weapons, UI, render targets, shadow atlas)
	var ml := _ml()
	var tex_lib := 0.0
	var tex_n := 0
	var by_fmt := {}
	if ml:
		var tx: Variant = ml.get("_textures")
		if tx is Dictionary:
			for k in tx:
				var tex: Variant = tx[k]
				if tex is ImageTexture and is_instance_valid(tex):
					var it := tex as ImageTexture
					var bytes := it.get_width() * it.get_height() * _bpp(it.get_format()) * 4.0 / 3.0
					tex_lib += bytes
					tex_n += 1
					var f := "fmt%d" % it.get_format()
					by_fmt[f] = float(by_fmt.get(f, 0.0)) + bytes
	b["textures"] = {"mesh_library_count": tex_n, "mesh_library_mib_est": tex_lib / MIB,
		"other_mib": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / MIB - tex_lib / MIB,
		"mesh_library_by_format_mib": _mib_dict(by_fmt)}
	# mesh library: entries, shapes (collision faces kept in RAM), pending parsed data and decoded images
	if ml:
		var shapes: Variant = ml.get("_shapes")
		var faces := 0
		var nshape := 0
		if shapes is Dictionary:
			for k in shapes:
				var s: Variant = shapes[k]
				if s is ConcavePolygonShape3D:
					faces += (s as ConcavePolygonShape3D).get_faces().size()
					nshape += 1
		var parsed_b := 0
		var p: Variant = ml.get("_parsed")
		if p is Dictionary:
			for k in p:
				parsed_b += _data_bytes(p[k])
		var img_b := 0
		var im: Variant = ml.get("_images")
		if im is Dictionary:
			for k in im:
				img_b += _data_bytes(im[k])
		var entries: Variant = ml.get("_entries")
		var tris := 0
		if entries is Dictionary:
			for k in entries:
				tris += int((entries[k] as Dictionary).get("tris", 0)) if entries[k] is Dictionary else 0
		b["mesh_library"] = {"entries": _dsize(entries), "entry_tris": tris, "trimesh_shapes": nshape,
			"trimesh_faces_mib": faces * 12 / MIB, "parsed_pending": _dsize(p), "parsed_mib": parsed_b / MIB,
			"images_pending": _dsize(im), "images_mib": img_b / MIB, "materials": _dsize(ml.get("_materials"))}
	# world: per-cell data kept for queries, collision plans, prepared cells waiting, far cells, scene content
	var w := _world()
	if w:
		b["cell_data_mib"] = _data_bytes(w.get("cell_data")) / MIB
		b["collision_plans_mib"] = _data_bytes(w.get("_col")) / MIB
		var bd: Variant = w.get("building")
		var prep := 0
		if bd is Dictionary:
			for k in bd:
				var job: Variant = bd[k]
				if job is Dictionary:
					prep += _data_bytes((job as Dictionary).get("result"))
		b["prepared_cells_mib"] = prep / MIB
		b["site_records_mib"] = _data_bytes(w.get("site_records")) / MIB
		var mm_inst := 0
		var mm_n := 0
		var hm := 0
		var bodies := 0
		var shapes_scene := 0
		for n in (w as Node).find_children("*", "MultiMeshInstance3D", true, false):
			var mm := (n as MultiMeshInstance3D).multimesh
			if mm:
				mm_inst += mm.instance_count
				mm_n += 1
		for n in (w as Node).find_children("*", "CollisionShape3D", true, false):
			shapes_scene += 1
			var s2 := (n as CollisionShape3D).shape
			if s2 is HeightMapShape3D:
				hm += (s2 as HeightMapShape3D).map_data.size() * 4
		for n in (w as Node).find_children("*", "StaticBody3D", true, false):
			bodies += 1
		b["scene"] = {"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "multimeshes": mm_n,
			"multimesh_instances": mm_inst, "multimesh_buffers_mib": mm_inst * 64 / MIB, "static_bodies": bodies,
			"collision_shapes": shapes_scene, "heightmap_mib": hm / MIB,
			"cells_loaded": _dsize(w.get("loaded")), "cells_far": _dsize(w.get("far"))}
	var g := _game()
	var machines: Variant = g.get("machines") if g else null
	b["machines"] = (machines as Array).size() if machines is Array else -1
	b["objects"] = Performance.get_monitor(Performance.OBJECT_COUNT)
	b["resources"] = Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	b["heavy_ms"] = (Time.get_ticks_usec() - t_start) / 1000.0
	_breakdowns.append(b)
	_write_breakdowns()


## Bytes per pixel of the top mip level of an Image.Format (block formats averaged).
static func _bpp(f: int) -> float:
	match f:
		Image.FORMAT_DXT1, Image.FORMAT_RGTC_R:
			return 0.5
		Image.FORMAT_DXT3, Image.FORMAT_DXT5, Image.FORMAT_RGTC_RG, Image.FORMAT_BPTC_RGBA, Image.FORMAT_BPTC_RGBF, Image.FORMAT_BPTC_RGBFU:
			return 1.0
		Image.FORMAT_L8, Image.FORMAT_R8:
			return 1.0
		Image.FORMAT_LA8, Image.FORMAT_RG8:
			return 2.0
		Image.FORMAT_RGBH, Image.FORMAT_RGBAH:
			return 8.0
		Image.FORMAT_RF:
			return 4.0
		Image.FORMAT_RGBAF:
			return 16.0
	return 4.0


static func _mib_dict(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[k] = snappedf(d[k] / MIB, 0.1)
	return out


func _write_breakdowns() -> void:
	var f := FileAccess.open(_out.path_join("breakdown_%d.json" % OS.get_process_id()), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_breakdowns, " "))


func _exit_tree() -> void:
	if not _active:
		return
	_flush()
	if _mem:
		_mem.flush()
