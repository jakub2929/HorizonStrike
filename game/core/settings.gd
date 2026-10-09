extends RefCounted
## %LOCALAPPDATA%/HorizonStrike/settings.json (hooks cache.settings): {cache_cap_bytes, mouse_sensitivity, volume}.

const GIB := 1073741824.0

static var data := {}
static var _path := ""


static func load_from(path: String, default_cap_gib: float) -> void:
	_path = path
	data = {"cache_cap_bytes": int(default_cap_gib * GIB), "mouse_sensitivity": 1.0, "volume": 0.8}
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			for k in parsed:
				data[k] = parsed[k]
	data["cache_cap_bytes"] = int(data["cache_cap_bytes"])


static func save() -> void:
	if _path == "":
		return
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "  "))


static func get_value(key: String, default_value: Variant = null) -> Variant:
	return data.get(key, default_value)


static func set_value(key: String, value: Variant) -> void:
	data[key] = value
	save()
