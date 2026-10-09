extends SceneTree
## Dev only: loads every GDScript of the project (autoloads registered, unlike --check-only) and reports the ones
## that fail to compile.  godot --headless --path game --script res://dev/check_scripts.gd


func _initialize() -> void:
	var files: PackedStringArray = []
	_collect("res://", files)
	var bad := 0
	for f in files:
		printraw("load %s\n" % f)
		var s: Script = ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_REUSE)
		if s == null or not s.can_instantiate() and not f.ends_with("smoke.gd"):
			print("BAD ", f)
			bad += 1
	print("checked %d scripts, %d bad" % [files.size(), bad])
	quit(1 if bad > 0 else 0)


func _collect(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if sub.begins_with("."):
			continue
		_collect(dir.path_join(sub), out)
