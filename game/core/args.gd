extends RefCounted
## Command line (docs/ARCHITECTURE.md, hooks hzs.args). Arguments are accepted before and after `--`.

var game_dir := ""            ## --game <dir>: CS2 install (from Melty)
var hzd_dir := ""             ## --hzd <dir>: HZD install override (missing dir = "HZD not installed")
var hzd_given := false
var cache_dir := ""           ## --cache-dir <dir>
var autotest := false         ## --autotest [ids]
var autotest_ids := PackedStringArray()
var out_dir := ""             ## --out <dir>
var mock_data := false        ## --mock-data: synthetic content (dev/test only)
var converter_exe := ""       ## --converter <exe>: dev override of the converter path
var all := PackedStringArray()


static func from_os() -> RefCounted:
	var list := PackedStringArray()
	list.append_array(OS.get_cmdline_args())
	list.append_array(OS.get_cmdline_user_args())
	return parse(list)


static func parse(list: PackedStringArray) -> RefCounted:
	var a = load("res://core/args.gd").new()
	a.all = list
	var i := 0
	while i < list.size():
		var t := list[i]
		var nxt := list[i + 1] if i + 1 < list.size() else ""
		var has_value := nxt != "" and not nxt.begins_with("--")
		match t:
			"--game":
				if has_value:
					a.game_dir = nxt
					i += 1
			"--hzd":
				a.hzd_given = true
				if has_value:
					a.hzd_dir = nxt
					i += 1
			"--cache-dir":
				if has_value:
					a.cache_dir = nxt
					i += 1
			"--out":
				if has_value:
					a.out_dir = nxt
					i += 1
			"--converter":
				if has_value:
					a.converter_exe = nxt
					i += 1
			"--autotest":
				a.autotest = true
				if has_value:
					for id in nxt.split(",", false):
						a.autotest_ids.append(id.strip_edges())
					i += 1
			"--mock-data":
				a.mock_data = true
		i += 1
	return a


func describe() -> String:
	return "game=%s hzd=%s cache=%s autotest=%s%s out=%s mock=%s converter=%s" % [
		game_dir, hzd_dir if hzd_given else "(auto)", cache_dir if cache_dir != "" else "(default)",
		autotest, "" if autotest_ids.is_empty() else "[" + ",".join(autotest_ids) + "]", out_dir, mock_data,
		converter_exe if converter_exe != "" else "(auto)"]
