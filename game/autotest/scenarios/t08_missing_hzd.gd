extends "res://autotest/lib/scenario.gd"
## t08 Message when HZD is missing. Runs in a child process started with --hzd <out>/no_hzd_here: Game.hzd_missing,
## node MissingHzdScreen visible with a Label whose text == systems ui.missing_hzd_message, the log says so, and no
## HZD stage started. The parent adds "child exit code 0".

const HZD_STAGES := ["machines", "audio", "index", "start-area", "start_cell", "cell"]


func _init() -> void:
	timeout_s = 120.0


func _run(ctx):
	var hzd_arg: String = ctx.args.value("--hzd")
	data.hzd_arg = hzd_arg
	check("setup: --hzd points to a folder that does not exist", hzd_arg != "" and not DirAccess.dir_exists_absolute(hzd_arg), hzd_arg)
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["hzd_missing"])):
		return false
	var box := {"screen": null}
	var shown := func() -> bool:
		box.screen = ctx.tree.root.find_child("MissingHzdScreen", true, false)
		return box.screen is CanvasItem and (box.screen as CanvasItem).is_visible_in_tree()
	var found: bool = await ctx.wait_until(shown, 30.0)
	var screen: Node = box.screen
	check("Game.hzd_missing == true", g.get("hzd_missing") == true, str(g.get("hzd_missing")))
	check("node MissingHzdScreen visible within 30 s", found, "node %s" % ("found" if screen != null else "not found"))
	var want := str(ctx.oracle.system("ui.missing_hzd_message"))
	var texts := []
	if screen != null:
		for l in screen.find_children("*", "Label", true, false) + screen.find_children("*", "RichTextLabel", true, false):
			if (l as CanvasItem).is_visible_in_tree():
				texts.append(str(l.get("text")).strip_edges())
	data.label_texts = texts
	check("a Label shows systems ui.missing_hzd_message", texts.has(want), "labels: %s" % str(texts))
	if DisplayServer.get_name() != "headless":
		data.screenshot = await ctx.screenshot("missing_hzd.png")  # evidence only, not a criterion

	# log evidence (hra H2 acceptance): latest.log mentions the screen
	var log_path := _game_log(ctx)
	var log_text := FileAccess.get_file_as_string(log_path) if FileAccess.file_exists(log_path) else ""
	# the log is shared with the parent game; when lines carry the process id ("[<pid>]") keep only this process
	var tag := "[%d]" % OS.get_process_id()
	if log_text.contains(tag):
		log_text = "\n".join(PackedStringArray(Array(log_text.split("\n")).filter(func(l): return l.contains(tag))))
		data.game_log_filter = tag
	data.game_log = log_path
	check("game log says MissingHzdScreen shown", log_text.contains("MissingHzdScreen shown"), "%s (%d bytes)" % [log_path, log_text.length()])

	# no HZD stage: either no converter at all, or its log / the game log show no HZD stage or HZD file access
	var pid := int(g.get("converter_pid")) if "converter_pid" in g else 0
	data.converter_pid = pid
	var bad := []
	for line in log_text.split("\n"):
		var l := line.to_lower()
		if l.contains("progress") or l.contains("stage"):
			for st in HZD_STAGES:
				if l.contains("\"stage\":\"%s\"" % st) or l.contains("stage %s" % st) or l.contains("stage=%s" % st):
					bad.append(line.strip_edges())
	var conv_log := log_path.get_base_dir().path_join("converter.log")
	if pid > 0 and FileAccess.file_exists(conv_log) and FileAccess.get_modified_time(conv_log) >= ctx.run_start_unix - 5:
		var lines := FileAccess.get_file_as_string(conv_log).split("\n")
		for i in range(1, lines.size()):  # line 0 echoes the command line (hzd=<path>)
			var l := lines[i].to_lower()
			if l.contains("no_hzd_here") or l.contains("packed_dx12") or l.contains("oo2core"):
				bad.append(lines[i].strip_edges())
	data.hzd_stage_lines = bad.slice(0, 10)
	check("no HZD stage started", bad.is_empty(), "converter %s; %d suspicious log lines" % ["not started" if pid <= 0 else "pid %d" % pid, bad.size()])
	return true


static func _game_log(ctx) -> String:
	var g: Node = ctx.game
	if g != null and "log_path" in g and str(g.get("log_path")) != "":
		return str(g.get("log_path"))
	return OS.get_environment("LOCALAPPDATA").path_join("HorizonStrike/logs/latest.log")
