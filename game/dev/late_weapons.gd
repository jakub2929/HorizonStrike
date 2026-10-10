extends SceneTree
## Editor entry for dev/late_weapons_driver.gd: boots the real main scene and adds the input driver.
##   godot --path game [--resolution WxH] --script res://dev/late_weapons.gd -- --mock-data --mock-weapons-late --user-dir <dir>


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	var driver: Node = load("res://dev/late_weapons_driver.gd").new()
	driver.name = "LateWeaponsDriver"
	root.add_child(driver)
