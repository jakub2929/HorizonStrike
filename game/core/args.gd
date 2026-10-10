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
var seed_cache := ""          ## --seed-cache <dir>: dev, with --mock-data copy real cs2/ + hzd/machines from <dir>
var mock_cell_mib := 0        ## --mock-cell-mib <n>: dev, pad every mock cell to ~n MiB (eviction tests)
var exit_after := -1.0        ## --exit-after <s>: dev, quit cleanly after s seconds
var screenshot_at := -1.0     ## --screenshot-at <s> <png>: dev, save a screenshot after s seconds
var screenshot_path := ""
var profile_cells := false    ## --profile-cells: dev, vsync off, walk perf.route_cells, write <logs>/cell_phases.csv
var quit_after_cells := 0     ## --quit-after-cells <n>: dev, quit after n inserted cells (with --profile-cells)
var no_converter_throttle := false   ## --no-converter-throttle: dev, keep the loading-screen converter workers in play
var user_dir := ""            ## --user-dir <dir>: settings.json, loadout.json, progression.json there (tests)
var cache_cap_mib := 0.0      ## --cache-cap-mib <n>: cache cap for this run only (settings.json is not changed)
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
			"--seed-cache":
				if has_value:
					a.seed_cache = nxt
					i += 1
			"--mock-cell-mib":
				if has_value:
					a.mock_cell_mib = int(nxt)
					i += 1
			"--exit-after":
				if has_value:
					a.exit_after = float(nxt)
					i += 1
			"--screenshot-at":
				if has_value and i + 2 < list.size():
					a.screenshot_at = float(nxt)
					a.screenshot_path = list[i + 2]
					i += 2
			"--profile-cells":
				a.profile_cells = true
			"--no-converter-throttle":
				a.no_converter_throttle = true
			"--quit-after-cells":
				if has_value:
					a.quit_after_cells = int(nxt)
					i += 1
			"--user-dir":
				if has_value:
					a.user_dir = nxt
					i += 1
			"--cache-cap-mib":
				if has_value:
					a.cache_cap_mib = float(nxt)
					i += 1
		i += 1
	return a


## True for runs driven by a program (autotest, dev --script tools, timed dev runs): no mouse capture.
func automated() -> bool:
	return autotest or all.has("--script") or exit_after > 0.0 or screenshot_at > 0.0 or profile_cells


func describe() -> String:
	return "game=%s hzd=%s cache=%s autotest=%s%s out=%s mock=%s converter=%s" % [
		game_dir, hzd_dir if hzd_given else "(auto)", cache_dir if cache_dir != "" else "(default)",
		autotest, "" if autotest_ids.is_empty() else "[" + ",".join(autotest_ids) + "]", out_dir, mock_data,
		converter_exe if converter_exe != "" else "(auto)"]
