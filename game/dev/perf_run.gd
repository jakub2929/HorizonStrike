extends SceneTree
## Dev only (owner vykon): runs the main scene with the perf probe attached (editor builds; release builds attach
## dev/perf_probe.gd through override.cfg instead).
##   godot --path game --script res://dev/perf_run.gd -- --perf-probe-out <dir> [--exit-after <s>] <game args>
## With --profile-cells the game walks perf.route_cells itself (world/cell_profiler.gd).


func _initialize() -> void:
	var probe: Node = load("res://dev/perf_probe.gd").new()
	probe.name = "PerfProbe"
	root.add_child(probe)
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
