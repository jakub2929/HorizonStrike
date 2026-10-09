extends RefCounted
## Finds the player's Horizon Zero Dawn Complete Edition install (hooks steam.root, steam.libraryfolders,
## steam.hzd_manifest, hzd.install). Only reads Steam's text files and checks that two files exist.

const APP_ID := "1151640"
const REQUIRED := ["Packed_DX12/Initial.bin", "oo2core_3_win64.dll"]
const STEAM_FALLBACK := "C:/Program Files (x86)/Steam"
const Paths := preload("res://core/paths.gd")


## Returns {found: bool, dir: String, source: String, reason: String, build: String}.
static func detect(override_given: bool, override_dir: String) -> Dictionary:
	if override_given:
		var d := Paths.norm(override_dir)
		var why := check_install(d)
		return {"found": why == "", "dir": d, "source": "--hzd", "reason": why, "build": ""}
	var steam := steam_root()
	var vdf_path := steam.path_join("steamapps/libraryfolders.vdf")
	var libs: Array[String] = []
	var vdf := read_text(vdf_path)
	if vdf != "":
		var kv := parse_kv1(vdf)
		var folders: Dictionary = kv.get("libraryfolders", {})
		for k in folders:
			var entry = folders[k]
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var lib := Paths.norm(str(entry.get("path", "")).replace("\\\\", "/"))
			if lib == "":
				continue
			var apps: Dictionary = entry.get("apps", {})
			if apps.has(APP_ID):
				libs.push_front(lib)
			else:
				libs.append(lib)
	if libs.is_empty():
		libs.append(steam)
	var last_reason := "no Steam library lists app %s (%s)" % [APP_ID, vdf_path]
	for lib in libs:
		var acf := read_text(lib.path_join("steamapps/appmanifest_%s.acf" % APP_ID))
		if acf == "":
			continue
		var st: Dictionary = parse_kv1(acf).get("AppState", {})
		var installdir := str(st.get("installdir", "Horizon Zero Dawn"))
		var dir := lib.path_join("steamapps/common").path_join(installdir)
		var why := check_install(dir)
		if why == "":
			return {"found": true, "dir": dir, "source": "steam", "reason": "", "build": str(st.get("buildid", ""))}
		last_reason = why
	return {"found": false, "dir": "", "source": "steam", "reason": last_reason, "build": ""}


static func check_install(dir: String) -> String:
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return "folder does not exist: %s" % dir
	for rel in REQUIRED:
		if not FileAccess.file_exists(dir.path_join(rel)):
			return "missing %s in %s" % [rel, dir]
	return ""


## Steam install folder from HKCU\Software\Valve\Steam\SteamPath (reg.exe query), fallback Program Files.
static func steam_root() -> String:
	var out: Array = []
	var code := OS.execute("reg", ["query", "HKCU\\Software\\Valve\\Steam", "/v", "SteamPath"], out, true)
	if code == 0 and not out.is_empty():
		for line in str(out[0]).split("\n"):
			var l := line.strip_edges()
			if l.begins_with("SteamPath"):
				var idx := l.find("REG_SZ")
				if idx >= 0:
					var p := Paths.norm(l.substr(idx + 6).strip_edges())
					if p != "" and DirAccess.dir_exists_absolute(p):
						return p
	return STEAM_FALLBACK


static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## Minimal Valve KeyValues (text) parser: quoted keys/values and braces -> nested Dictionary.
static func parse_kv1(text: String) -> Dictionary:
	var tokens := PackedStringArray()
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == "\"":
			var j := i + 1
			var s := ""
			while j < n and text[j] != "\"":
				if text[j] == "\\" and j + 1 < n:
					s += text[j + 1]
					j += 2
					continue
				s += text[j]
				j += 1
			tokens.append("s:" + s)
			i = j + 1
		elif c == "{" or c == "}":
			tokens.append(c)
			i += 1
		elif c == "/" and i + 1 < n and text[i + 1] == "/":
			while i < n and text[i] != "\n":
				i += 1
		else:
			i += 1
	var pos := [0]
	return _kv_block(tokens, pos)


static func _kv_block(tokens: PackedStringArray, pos: Array) -> Dictionary:
	var d := {}
	while pos[0] < tokens.size():
		var t := tokens[pos[0]]
		if t == "}":
			pos[0] += 1
			return d
		if not t.begins_with("s:"):
			pos[0] += 1
			continue
		var key := t.substr(2)
		pos[0] += 1
		if pos[0] >= tokens.size():
			break
		var v := tokens[pos[0]]
		if v == "{":
			pos[0] += 1
			d[key] = _kv_block(tokens, pos)
		elif v.begins_with("s:"):
			d[key] = v.substr(2)
			pos[0] += 1
	return d
