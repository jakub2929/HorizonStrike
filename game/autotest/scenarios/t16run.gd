extends "res://autotest/lib/scenario.gd"
## t16run (child part of t16): walk perf.stress_route_cells by input (forward key, mouse steering; legs bounded with a
## teleport to the waypoint) with player.speed_mult = perf.stress_speed_mult (setup); write RSS, VRAM and the game
## log's error count at the end.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Route := preload("res://autotest/lib/route.gd")
const Proc := preload("res://autotest/lib/proc.gd")
const LEG_MAX_S := 10.0  # 30 legs + boot must stay well inside the 10 min limit per run (sheet t16)
const LEG_NO_MULT_S := 8.0


func _init() -> void:
	timeout_s = 560.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	var o = ctx.oracle
	p.set("invulnerable", true)
	var mult := float(o.f(o.system("perf.stress_speed_mult")))
	# a leg is one cell (512 m): walked in ~512 / (6.35 m/s x mult) s; legs are bounded (teleport to the waypoint
	# after that) so 30 cells fit the child's watchdog; without speed_mult mostly teleports (the streaming still loads
	# every cell)
	var leg_s := LEG_NO_MULT_S
	if "speed_mult" in p:
		p.set("speed_mult", mult)
		data.speed_mult = mult
		leg_s = minf(LEG_MAX_S, 512.0 / (6.35 * maxf(mult, 1.0)) + 5.0)
	else:
		note("player.speed_mult missing in this build: normal speed, legs of %d s then a teleport to the waypoint" % int(LEG_NO_MULT_S))
	data.leg_s = snappedf(leg_s, 0.1)
	var inp = InputSim.new(ctx)
	inp.capture_for_look()
	await inp.equip("knife")
	var cs := float(o.f(o.system("streaming.cell_size_m")))
	var wps := []
	for c in o.system("perf.stress_route_cells"):
		wps.append(Route.cell_center(ctx.v2i(c), cs))
	var walker = Route.new(ctx, inp)
	await walker.walk(wps, leg_s)
	data.cells_visited = walker.cells_visited.keys()
	data.leg_teleports = walker.leg_teleports
	data.walked_m = snappedf(walker.walked_m, 1.0)
	data.vram_end_mb = snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1)
	var tl: Dictionary = await ctx.run_cmd(Proc.system32("tasklist.exe"), PackedStringArray(["/FI", "PID eq %d" % OS.get_process_id(), "/FO", "CSV", "/NH"]))
	data.rss_end_mb = _mem_mb(str(tl.get("out", "")))
	data.log_errors = _log_errors(ctx)
	check("route walked over the stress cells", walker.cells_visited.size() >= mini(10, wps.size()), str(walker.cells_visited.size()))
	return true


static func _mem_mb(csv: String) -> float:
	## tasklist "Mem Usage" column ("123,456 K", thousands separator depends on the locale)
	for raw in csv.split("\n"):
		var f := raw.strip_edges().split("\",\"")
		if f.size() >= 5:
			var digits := ""
			for ch in f[4]:
				if ch >= "0" and ch <= "9":
					digits += ch
			if digits != "":
				return snappedf(int(digits) / 1024.0, 0.1)
	return -1.0


static func _log_errors(ctx) -> int:
	## "[error]" lines of this process in the game log
	var path := OS.get_environment("LOCALAPPDATA").path_join("HorizonStrike/logs/latest.log")
	if ctx.game != null and "log_path" in ctx.game:
		path = str(ctx.game.get("log_path"))
	if not FileAccess.file_exists(path):
		return 0
	var tag := "[%d] [error]" % OS.get_process_id()
	return FileAccess.get_file_as_string(path).count(tag)
