extends SceneTree
## Dev check (owner vykon): GraphicsSettings reading a hand-edited / broken graphics.json (no main scene).
##   godot --headless --path game --script res://dev/perf_settings_edge.gd -- --user-dir <dir>
## Prints the values it ended up with as JSON plus the file written back.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gs: Node = root.get_node("GraphicsSettings")
	var d := {"preset": gs.preset, "fps_limit": gs.fps_limit, "vsync": gs.vsync}
	for k in gs.OPTION_KEYS:
		d[k] = gs.get(k)
	print("EDGE values ", JSON.stringify(d))
	var p: String = gs.get_script().settings_path()
	print("EDGE file ", FileAccess.get_file_as_string(p).replace("\n", " "))
	quit(0)
