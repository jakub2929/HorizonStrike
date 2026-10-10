extends SceneTree
## Editor entry for dev/progress_input_driver.gd: boots the real main scene and adds the input driver.
##   godot --path game [--resolution WxH] --script res://dev/progress_input.gd -- --mock-data --user-dir <dir> [--prog-phase restart]


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	var driver: Node = load("res://dev/progress_input_driver.gd").new()
	driver.name = "ProgressInputDriver"
	root.add_child(driver)
