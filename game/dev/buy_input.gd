extends SceneTree
## Editor entry for dev/buy_input_driver.gd: boots the real main scene and adds the input driver.
##   godot --path game [--resolution WxH] --script res://dev/buy_input.gd -- [--mock-data | --game ... --cache-dir ...]


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	var driver: Node = load("res://dev/buy_input_driver.gd").new()
	driver.name = "BuyInputDriver"
	root.add_child(driver)
