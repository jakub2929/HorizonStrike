extends SceneTree
## Editor entry for dev/bhop_input_driver.gd: boots the real main scene and adds the input driver.
##   godot --path game [--resolution WxH] --script res://dev/bhop_input.gd -- --mock-data --user-dir <dir>


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	var driver: Node = load("res://dev/bhop_input_driver.gd").new()
	driver.name = "BhopInputDriver"
	root.add_child(driver)
