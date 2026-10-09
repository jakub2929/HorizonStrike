extends RefCounted
## Game command line (docs/ARCHITECTURE.md): args are accepted before and after "--".

const VALUE_KEYS := ["--game", "--hzd", "--cache-dir", "--out"]
const FLAG_KEYS := ["--mock-data"]

var argv := PackedStringArray()


func _init(p_argv: PackedStringArray = PackedStringArray()) -> void:
	if p_argv.is_empty():
		argv.append_array(OS.get_cmdline_args())
		argv.append_array(OS.get_cmdline_user_args())
	else:
		argv = p_argv


func value(key: String, default_value: String = "") -> String:
	var i := argv.find(key)
	if i >= 0 and i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
		return argv[i + 1]
	return default_value


func has(key: String) -> bool:
	return argv.has(key)


## Ids after --autotest (comma separated); empty = all scenarios.
func autotest_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var i := argv.find("--autotest")
	if i >= 0 and i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
		for s in argv[i + 1].split(",", false):
			var id := s.strip_edges().to_lower()
			if id != "" and not out.has(id):
				out.append(id)
	return out


## Known game args of this process, for a child process; keys in `drop` are left out.
func forward(drop: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for k in VALUE_KEYS:
		if k in drop:
			continue
		var v := value(k)
		if v != "":
			out.append(k)
			out.append(v)
	for f in FLAG_KEYS:
		if not (f in drop) and has(f):
			out.append(f)
	return out
