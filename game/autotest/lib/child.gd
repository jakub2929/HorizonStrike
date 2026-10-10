extends RefCounted
## One child game process for a scenario that needs its own process (t25 per preset, t26 restart, r05-r09 with their
## own --user-dir): the same executable, the parent's game args forwarded (minus the keys given here), the scenario
## run in-process in the child (env HZS_AUTOTEST_CHILD). The parent is quiet meanwhile (lib/proc.gd). Returns
## {pid, exit_code, hung, seconds, argv, result} with result = the child's results.json row for scenario_id (or null).

const Proc := preload("res://autotest/lib/proc.gd")
const CHILD_ENV := "HZS_AUTOTEST_CHILD"


static func run(ctx, scenario_id: String, out: String, engine_args: PackedStringArray, game_args: PackedStringArray,
		env: Dictionary, limit_s: float) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(out)
	var drop := ["--autotest", "--out"]
	for a in game_args:
		if a.begins_with("--"):
			drop.append(a)
	var argv := Proc.game_launch_prefix(engine_args)
	argv.append_array(ctx.args.forward(drop))
	argv.append_array(game_args)
	argv.append_array(PackedStringArray(["--autotest", scenario_id, "--out", out]))
	var t0 := int(Time.get_unix_time_from_system())
	OS.set_environment(CHILD_ENV, scenario_id)
	for k in env:
		OS.set_environment(k, str(env[k]))
	ctx.note("== child %s: %s %s" % [scenario_id, OS.get_executable_path(), " ".join(argv)])
	var pid := OS.create_process(OS.get_executable_path(), argv)
	OS.unset_environment(CHILD_ENV)
	for k in env:
		OS.unset_environment(k)
	var start := Time.get_ticks_msec()
	var last_note := start
	var quiet := Proc.quiet_parent(ctx.tree)
	while pid > 0 and OS.is_process_running(pid) and (Time.get_ticks_msec() - start) / 1000.0 < limit_s:
		await ctx.tree.create_timer(1.0, true, false, true).timeout
		if Time.get_ticks_msec() - last_note > 60000:
			last_note = Time.get_ticks_msec()
			ctx.note("child %s (pid %d) still running (%d s)" % [scenario_id, pid, (Time.get_ticks_msec() - start) / 1000])
	var hung := pid > 0 and OS.is_process_running(pid)
	if hung:
		ctx.note("child %s (pid %d) still running after %d s; killing that exact PID" % [scenario_id, pid, int(limit_s)])
		OS.kill(pid)
		await ctx.tree.create_timer(1.0, true, false, true).timeout
	Proc.restore_parent(ctx.tree, quiet)
	var r := {"pid": pid, "exit_code": OS.get_process_exit_code(pid) if pid > 0 else -1, "hung": hung,
		"seconds": snappedf((Time.get_ticks_msec() - start) / 1000.0, 0.1), "argv": " ".join(argv), "out": out, "result": null}
	var rp := out.path_join("results.json")
	var rows: Variant = load("res://autotest/lib/oracle.gd").read_json(rp)
	if FileAccess.file_exists(rp) and FileAccess.get_modified_time(rp) >= t0 and rows is Array:
		for row in rows:
			if row is Dictionary and row.get("id") == scenario_id:
				r.result = row
	return r


static func summary(r: Dictionary) -> String:
	## one line for checks: exit code, pass and the child's own summary
	var res: Variant = r.get("result")
	if not (res is Dictionary):
		return "no fresh result (exit %s, hung %s)" % [str(r.get("exit_code")), str(r.get("hung"))]
	return "exit %s, %s: %s" % [str(r.get("exit_code")), "PASS" if res.get("pass") else "FAIL", str(res.get("details", {}).get("summary", ""))]


static func passed(r: Dictionary) -> bool:
	var res: Variant = r.get("result")
	return res is Dictionary and bool(res.get("pass", false)) and not bool(r.get("hung", false))


static func data(r: Dictionary) -> Dictionary:
	var res: Variant = r.get("result")
	if res is Dictionary and res.get("details") is Dictionary:
		var d: Variant = res.details.get("data", {})
		return d if d is Dictionary else {}
	return {}
