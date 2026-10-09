extends RefCounted
## Process helpers: launching the game again as a child, netstat / tasklist parsing, independent disk usage.


const ENGINE_VALUE_ARGS := ["--resolution", "--write-movie", "--fixed-fps", "--position"]


static func game_launch_prefix(engine_args: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	## editor binary (dev): "--path <project>" + engine options + "--"; exported exe: engine options only (exactly as
	## Melty launches it plus those)
	var out := PackedStringArray()
	if not OS.has_feature("template"):
		out.append("--path")
		out.append(ProjectSettings.globalize_path("res://").trim_suffix("/"))
	if DisplayServer.get_name() == "headless":
		out.append("--headless")
	out.append_array(engine_args)
	if not OS.has_feature("template"):
		out.append("--")
	return out


static func system32(exe: String) -> String:
	var root := OS.get_environment("SystemRoot")
	if root == "":
		root = "C:/Windows"
	return root.path_join("System32").path_join(exe)


static func parse_netstat(text: String, pid: int) -> Array:
	## rows of `netstat -ano` owned by pid. Locale independent: a TCP row listens when its foreign port is 0
	## (the state column is translated on non-English Windows); every UDP row is an open endpoint.
	var rows := []
	for raw in text.split("\n"):
		var p := raw.strip_edges().split(" ", false)
		if p.size() < 4:
			continue
		var proto := p[0].to_upper()
		if not (proto.begins_with("TCP") or proto.begins_with("UDP")):
			continue
		var last := p[p.size() - 1]
		if not last.is_valid_int() or int(last) != pid:
			continue
		var local := p[1]
		var remote := p[2]
		var udp := proto.begins_with("UDP")
		var listening := udp or remote.ends_with(":0")
		rows.append({
			"proto": proto, "local": local, "remote": remote, "state": p[3] if not udp and p.size() >= 5 else "",
			"listening": listening, "loopback": is_loopback(local),
		})
	return rows


static func is_loopback(addr: String) -> bool:
	var host := addr
	var i := addr.rfind(":")
	if i > 0:
		host = addr.substr(0, i)
	host = host.trim_prefix("[").trim_suffix("]")
	return host == "::1" or host.begins_with("127.")


static func parse_tasklist_image(text: String, pid: int) -> String:
	## `tasklist /FI "PID eq N" /FO CSV /NH` -> image name or "" when the process does not exist
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if not line.begins_with("\""):
			continue
		var f := line.split("\",\"")
		if f.size() >= 2 and f[1].trim_suffix("\"") == str(pid):
			return f[0].trim_prefix("\"")
	return ""


static func dir_bytes(path: String) -> int:
	## total size of regular files under path; never descends into links / junctions (reparse points)
	var da := DirAccess.open(path)
	if da == null:
		return 0
	da.include_hidden = true
	var total := 0
	da.list_dir_begin()
	var n := da.get_next()
	while n != "":
		var full := path.path_join(n)
		if da.current_is_dir():
			if not da.is_link(full):
				total += dir_bytes(full)
		else:
			# files can vanish or be half-written while the game's mesh GC / converter run; never ask the engine
			# for the size of a path that may be gone (it logs an engine error), and skip *.tmp
			if not n.ends_with(".tmp") and FileAccess.file_exists(full):
				var f := FileAccess.open(full, FileAccess.READ)
				if f != null:
					total += f.get_length()
		n = da.get_next()
	da.list_dir_end()
	return total


static func cell_dirs(cache_dir: String) -> Array:
	## finished cells on disk (hzd/cells/<x>_<y>/cell.json present), read straight from the cache folder
	var out := []
	var base := cache_dir.path_join("hzd/cells")
	var da := DirAccess.open(base)
	if da == null:
		return out
	for d in da.get_directories():
		var parts := d.split("_")
		if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int() and FileAccess.file_exists(base.path_join(d).path_join("cell.json")):
			out.append(Vector2i(int(parts[0]), int(parts[1])))
	return out
