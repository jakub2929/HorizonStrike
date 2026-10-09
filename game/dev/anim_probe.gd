extends SceneTree
## Dev only: checks that the procedural animator really moves bones of a real machine skeleton.
##   godot --headless --path game --script res://dev/anim_probe.gd -- --mock-data --seed-cache <dev> --cache-dir <d>


func _initialize() -> void:
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _wait(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		await physics_frame


func _run() -> void:
	var game: Node = root.get_node("Game")
	while not game.is_world_ready:
		await process_frame
	game.world.spawner.set_process(false)
	var p: Node3D = game.player
	for type in ["watcher", "strider", "grazer"]:
		var m: Node = game.spawn_machine(type, p.global_position - p.global_transform.basis.z * 12.0 + Vector3(0, 1.5, 0))
		m.rig.animator.debug_measure = true
		await _wait(1.5)
		var sk: Skeleton3D = m.rig.skeleton
		var an: Node = m.rig.animator
		print("   inside modifier: bones moved %d" % an.debug_moved)
		var moved := 0
		var maxd := 0.0
		for i in sk.get_bone_count():
			var d := sk.get_bone_global_pose(i).origin.distance_to(sk.get_bone_global_rest(i).origin)
			if d > 0.01:
				moved += 1
			maxd = maxf(maxd, d)
		print("%s: active=%s influence=%.2f init=%s legs=%d tail=%d neck=%d bones moved %d/%d (max %.3f m) skeleton modifier_callback_mode=%d" % [type,
			an.active, an.influence, an._initialized, an._legs.size(), an._tail_bones.size(), an._neck_bones.size(), moved,
			sk.get_bone_count(), maxd, sk.modifier_callback_mode_process])
		for leg in an._legs:
			var ch: PackedInt32Array = leg["chain"]
			print("   leg %s knee=%s" % [sk.get_bone_name(ch[0]), sk.get_bone_name(ch[int(leg["knee"])])])
		m.queue_free()
		await _wait(0.3)
	quit(0)
