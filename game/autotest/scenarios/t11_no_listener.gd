extends "res://autotest/lib/scenario.gd"
## t11 Converter listens on no non-loopback address (D12: stdio only). While the converter runs, `netstat -ano`
## is sampled three times; every TCP listener / UDP endpoint owned by Game.converter_pid must be 127.0.0.1 or ::1.

const Proc := preload("res://autotest/lib/proc.gd")
const SAMPLES := 3


func _init() -> void:
	timeout_s = 300.0


func _run(ctx):
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["converter_pid"])):
		return false
	var started: bool = await ctx.wait_until(func(): return int(g.get("converter_pid")) > 0, 120.0)
	var pid := int(g.get("converter_pid"))
	data.converter_pid = pid
	if not check("converter running (Game.converter_pid > 0 within 120 s)", started, str(pid)):
		return false
	var tl: Dictionary = await ctx.run_cmd(Proc.system32("tasklist.exe"), PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"]))
	var image := Proc.parse_tasklist_image(str(tl.out), pid)
	data.converter_image = image
	check("converter_pid is a running converter process (hzsconv.exe or dotnet.exe)", image.to_lower() in ["hzsconv.exe", "dotnet.exe"], image if image != "" else "no such process")
	var rows := []
	var lines := 0
	for i in SAMPLES:
		var ns: Dictionary = await ctx.run_cmd(Proc.system32("netstat.exe"), PackedStringArray(["-ano"]))
		var text := str(ns.out)
		lines += text.count("\n")
		for r in Proc.parse_netstat(text, pid):
			if not rows.has(r):
				rows.append(r)
		if i < SAMPLES - 1:
			await ctx.wait(1.0)
	var alive: Dictionary = await ctx.run_cmd(Proc.system32("tasklist.exe"), PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"]))
	data.netstat_lines_scanned = lines
	data.rows_owned_by_converter = rows
	check("netstat produced output", lines > 10, "%d lines" % lines)
	check("converter still running after the samples", Proc.parse_tasklist_image(str(alive.out), pid) != "")
	var bad := rows.filter(func(r): return r.listening and not r.loopback)
	check("no LISTENING/UDP endpoint of the converter outside 127.0.0.1 / ::1", bad.is_empty(), "%d listeners (%d non-loopback): %s" % [rows.filter(func(r): return r.listening).size(), bad.size(), str(bad)])
	return true
