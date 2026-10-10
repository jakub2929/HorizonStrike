extends SceneTree
## Dev only (owner vykon): the main scene with dev/gpu_ablation.gd attached (see there).
##   godot --path game --resolution 1920x1080 --script res://dev/gpu_ablation_run.gd -- --gpu-ablation-out <dir> <game args>


func _initialize() -> void:
	var ab: Node = load("res://dev/gpu_ablation.gd").new()
	ab.name = "GpuAblation"
	root.add_child(ab)
	root.add_child(load("res://main/main.tscn").instantiate())
