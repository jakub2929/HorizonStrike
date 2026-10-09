extends RefCounted
## File helpers for the cache. Deleting is only allowed strictly inside a guard root and never descends into
## (or deletes through) links/junctions.


static func dir_bytes(dir: String) -> int:
	var total := 0
	var d := DirAccess.open(dir)
	if d == null:
		return 0
	d.include_hidden = true
	for f in d.get_files():
		var fa := FileAccess.open(dir.path_join(f), FileAccess.READ)
		if fa:
			total += fa.get_length()
	for sub in d.get_directories():
		var p := dir.path_join(sub)
		if d.is_link(sub):
			continue
		total += dir_bytes(p)
	return total


static func is_inside(path: String, root: String) -> bool:
	var p := path.replace("\\", "/").simplify_path().to_lower()
	var r := root.replace("\\", "/").simplify_path().to_lower().trim_suffix("/")
	return r != "" and p.begins_with(r + "/") and p.length() > r.length() + 1


## Removes `dir` recursively. Refuses anything outside `guard_root`; links are unlinked, never followed.
static func remove_tree(dir: String, guard_root: String) -> bool:
	if not is_inside(dir, guard_root):
		push_error("refusing to delete outside the cache: %s" % dir)
		return false
	var d := DirAccess.open(dir)
	if d == null:
		return false
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for sub in d.get_directories():
		var p := dir.path_join(sub)
		if d.is_link(sub):
			DirAccess.remove_absolute(p)
			continue
		remove_tree(p, guard_root)
	return DirAccess.remove_absolute(dir) == OK


static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func write_json_atomic(path: String, data: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, " "))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)


## Copies a file tree (files that already exist in `to` are kept). Never follows links. Returns bytes copied.
static func copy_tree(from: String, to: String) -> int:
	var d := DirAccess.open(from)
	if d == null:
		return 0
	DirAccess.make_dir_recursive_absolute(to)
	var total := 0
	for f in d.get_files():
		var dst := to.path_join(f)
		if FileAccess.file_exists(dst):
			continue
		if DirAccess.copy_absolute(from.path_join(f), dst) == OK:
			var fa := FileAccess.open(dst, FileAccess.READ)
			if fa:
				total += fa.get_length()
	for sub in d.get_directories():
		if d.is_link(sub):
			continue
		total += copy_tree(from.path_join(sub), to.path_join(sub))
	return total
