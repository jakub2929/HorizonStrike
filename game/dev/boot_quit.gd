extends SceneTree
## Dev only: boot the main scene, wait for world_ready (+ optional seconds), quit. Used to check clean shutdown.
##   godot --headless --path game --script res://dev/boot_quit.gd -- --mock-data [--stay 2]


func _initialize() -> void:
	root.add_child(load("res://main/main.tscn").instantiate())
	_run.call_deferred()


func _run() -> void:
	var game: Node = root.get_node("Game")
	var stay := 1.0
	var ua := OS.get_cmdline_user_args()
	var i := ua.find("--stay")
	if i >= 0 and i + 1 < ua.size():
		stay = float(ua[i + 1])
	var t0 := Time.get_ticks_msec()
	while not game.is_world_ready and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
	print("world_ready=%s" % game.is_world_ready)
	if ua.has("--probe-logger"):
		push_error("hzs logger probe")
	var t1 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t1 < int(stay * 1000):
		await process_frame
	print("BOOT_QUIT done")
	quit(0)
