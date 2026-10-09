extends RefCounted
## Inserts one prepared cell into the scene in small main-thread steps (0.2 H2, streaming.main_thread_budget_ms):
## empty root -> terrain visual -> terrain collision tiles (nearest to the player first) -> MultiMesh chunks (nearest
## first) -> campfires. Every step is one resource/node; step() runs steps until the frame's deadline. Object collision
## is not built here: world.gd adds it per bucket only near the player (streaming.collision_radius_m).

const CellBuilder := preload("res://world/cell_builder.gd")

var cell: Vector2i
var data: Dictionary
var meshes: RefCounted
var parent: Node3D
var root: Node3D
var ground_ready := false
var done := false
## main-thread ms per phase (profiling): mesh_upload, tex_upload, terrain, terrain_collision, multimesh, add_child
var phases := {"mesh_upload": 0.0, "tex_upload": 0.0, "terrain": 0.0, "terrain_collision": 0.0, "multimesh": 0.0, "add_child": 0.0}
var steps_done := 0
var last_steps := ""          # what the last step() call ran (only with trace: slow frame diagnosis)
var trace := false
var _steps: Array = []
var _tiles_left := 0


func _init(c: Vector2i, d: Dictionary, lib: RefCounted, world_node: Node3D, player_pos: Vector3) -> void:
	cell = c
	data = d
	meshes = lib
	parent = world_node
	_steps.append(["root", null])
	_steps.append(["terrain", null])
	var p2 := Vector2(player_pos.x, player_pos.z)
	# nearest first; sorting [distance, index] pairs natively (a sort_custom lambda over thousands of chunks was slow)
	var tiles: Array = d.get("tcol_tiles", [])
	var order: Array = []
	for i in tiles.size():
		order.append([p2.distance_squared_to(_xz((tiles[i]["xf"] as Transform3D).origin)), i])
	order.sort()
	for o in order:
		_steps.append(["tile", tiles[o[1]]])
	_tiles_left = tiles.size()
	if tiles.is_empty():
		ground_ready = true
	var chunks: Array = d.get("chunks", [])
	order = []
	for i in chunks.size():
		order.append([p2.distance_squared_to(_xz(chunks[i]["center"])), i])
	order.sort()
	for o in order:
		_steps.append(["chunk", chunks[o[1]]])
	_steps.append(["campfires", null])


static func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


## Runs steps until `deadline_usec` (at least one step per call). Returns true when the cell is complete.
func step(deadline_usec: int) -> bool:
	var first := true
	last_steps = ""
	while steps_done < _steps.size():
		if not first and Time.get_ticks_usec() >= deadline_usec:
			return false
		first = false
		var t0 := Time.get_ticks_usec()
		var kind := str(_steps[steps_done][0])
		var complete := _run(_steps[steps_done])
		var t1 := Time.get_ticks_usec()
		if trace and t1 - t0 > 1000:
			last_steps += "%s%s %.1f " % [kind, "" if complete else "+", (t1 - t0) / 1000.0]
		if complete:
			steps_done += 1
	done = true
	return true


## One step; false = it did a sub-step (a texture or mesh upload for a chunk) and the same step runs again.
func _run(s: Array) -> bool:
	var t0 := Time.get_ticks_usec()
	match str(s[0]):
		"root":
			root = CellBuilder.make_root(data)
			parent.add_child(root)
			phases["add_child"] += _ms(t0)
		"terrain":
			var tex0: float = meshes.stat_tex_upload_ms
			var tm := CellBuilder.make_terrain(data)
			var t1 := Time.get_ticks_usec()
			root.add_child(tm)
			phases["add_child"] += _ms(t1)
			phases["terrain"] += (t1 - t0) / 1000.0
			phases["tex_upload"] += meshes.stat_tex_upload_ms - tex0
		"tile":
			var body := CellBuilder.make_terrain_tile(s[1])
			root.get_node("TerrainBodies").add_child(body)
			phases["terrain_collision"] += _ms(t0)
			_tiles_left -= 1
			if _tiles_left <= 0:
				ground_ready = true
		"chunk":
			var mid := str(s[1]["mesh"])
			if not meshes.is_built(mid):
				# the chunk's mesh is not on the GPU yet: its textures one per step, then the mesh itself
				var texs: Array = meshes.pending_textures(mid)
				var x1: float = meshes.stat_tex_upload_ms
				if not texs.is_empty():
					meshes.upload_texture(str(texs[0]))
					phases["tex_upload"] += meshes.stat_tex_upload_ms - x1
					return false
				meshes.build_step(mid)      # one surface per step
				phases["mesh_upload"] += _ms(t0)
				return false
			var m0: float = meshes.stat_mesh_ms
			var x0: float = meshes.stat_tex_upload_ms
			var mmi := CellBuilder.make_chunk(s[1], meshes)
			var up: float = meshes.stat_mesh_ms - m0
			var tx: float = meshes.stat_tex_upload_ms - x0
			if mmi:
				var spec: Dictionary = s[1]
				var holder: Node = root.get_node("Instances" if str(spec["name"]) == str(spec["mesh"]) else "Vegetation")
				holder.add_child(mmi)
			phases["mesh_upload"] += maxf(up - tx, 0.0)
			phases["tex_upload"] += tx
			phases["multimesh"] += maxf(_ms(t0) - up, 0.0)
		"campfires":
			for cf in data["info"].get("campfires", []):
				root.add_child(CellBuilder.make_campfire(cf))
			phases["add_child"] += _ms(t0)
	return true


static func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0
