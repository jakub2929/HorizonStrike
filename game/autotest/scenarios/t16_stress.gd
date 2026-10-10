extends "res://autotest/lib/scenario.gd"
## t16 Streaming stress: perf.stress_runs child processes in a row, each walks perf.stress_route_cells by input
## (scenario t16run, player.speed_mult = perf.stress_speed_mult as setup). Pass: every child exits 0 with a result
## file within 10 min, no engine errors in any run, RSS and VRAM at the end of each run within +15 % of run 1.

const Proc := preload("res://autotest/lib/proc.gd")
const CHILD_ENV := "HZS_AUTOTEST_CHILD"
const RUN_LIMIT_S := 600.0


func _init() -> void:
	timeout_s = 20.0 * (RUN_LIMIT_S + 60.0)


func _run(ctx):
	var o = ctx.oracle
	var runs: int = o.i(o.system("perf.stress_runs"))
	if OS.get_environment("HZS_T16_RUNS").is_valid_int():
		# dev only: a shorter series to validate the scenario itself (the result names the count it ran)
		runs = int(OS.get_environment("HZS_T16_RUNS"))
		note("HZS_T16_RUNS: %d runs instead of perf.stress_runs" % runs)
	var exe := OS.get_executable_path()
	var results := []
	for n in range(1, runs + 1):
		var out: String = ctx.out_dir.path_join("t16/run%d" % n)
		DirAccess.make_dir_recursive_absolute(out)
		var argv := Proc.game_launch_prefix()
		argv.append_array(ctx.args.forward(["--autotest", "--out"]))
		argv.append_array(PackedStringArray(["--autotest", "t16run", "--out", out]))
		var t0 := int(Time.get_unix_time_from_system())
		OS.set_environment(CHILD_ENV, "t16run")
		var pid := OS.create_process(exe, argv)
		OS.unset_environment(CHILD_ENV)
		var start := Time.get_ticks_msec()
		var quiet := Proc.quiet_parent(ctx.tree)
		while pid > 0 and OS.is_process_running(pid) and (Time.get_ticks_msec() - start) / 1000.0 < RUN_LIMIT_S:
			await ctx.tree.create_timer(1.0, true, false, true).timeout
		var hung := pid > 0 and OS.is_process_running(pid)
		if hung:
			OS.kill(pid)
			await ctx.tree.create_timer(1.0, true, false, true).timeout
		Proc.restore_parent(ctx.tree, quiet)
		var code := OS.get_process_exit_code(pid) if pid > 0 else -1
		var r := {"run": n, "pid": pid, "exit_code": code, "hung": hung, "seconds": snappedf((Time.get_ticks_msec() - start) / 1000.0, 0.1)}
		var rp := out.path_join("results.json")
		var rows: Variant = load("res://autotest/lib/oracle.gd").read_json(rp)
		if FileAccess.file_exists(rp) and FileAccess.get_modified_time(rp) >= t0 and rows is Array and not (rows as Array).is_empty():
			var d: Dictionary = rows[0].get("details", {})
			var dd: Dictionary = d.get("data", {})
			r.result = rows[0].get("pass")
			r.rss_end_mb = dd.get("rss_end_mb")
			r.vram_end_mb = dd.get("vram_end_mb")
			r.engine_errors = (d.get("engine_errors", []) as Array).size() + int(dd.get("log_errors", 0))
			r.cells = (dd.get("cells_visited", []) as Array).size()
		else:
			r.result = null
		results.append(r)
		ctx.note("t16 run %d/%d: exit %d, hung %s, cells %s, rss %s MB, vram %s MB, errors %s" % [n, runs, code, str(hung), str(r.get("cells")), str(r.get("rss_end_mb")), str(r.get("vram_end_mb")), str(r.get("engine_errors"))])
	data.runs = results
	var ok_exit := results.filter(func(r): return r.exit_code == 0 and r.result != null and not r.hung)
	check("%d/%d children exit 0 with a result file, none hung > %d s" % [ok_exit.size(), runs, int(RUN_LIMIT_S)], ok_exit.size() == runs, str(results.map(func(r): return [r.run, r.exit_code, r.hung])))
	var errs := results.filter(func(r): return int(r.get("engine_errors", 0) if r.get("engine_errors") != null else 0) > 0)
	check("0 engine errors in every run", errs.is_empty(), str(errs.map(func(r): return [r.run, r.engine_errors])))
	var base: Dictionary = results[0] if not results.is_empty() else {}
	var drift := []
	for r in results:
		for key in ["rss_end_mb", "vram_end_mb"]:
			if base.get(key) != null and r.get(key) != null and float(r[key]) > float(base[key]) * 1.15:
				drift.append("run %d %s %s > %s" % [r.run, key, str(r[key]), str(snappedf(float(base[key]) * 1.15, 0.1))])
	check("RSS and VRAM at the end of each run within +15 % of run 1", drift.is_empty() and base.get("rss_end_mb") != null, str(drift) if not drift.is_empty() else "run 1: rss %s MB, vram %s MB" % [str(base.get("rss_end_mb")), str(base.get("vram_end_mb"))])
	return true
