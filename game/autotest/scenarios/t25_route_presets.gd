extends "res://autotest/lib/scenario.gd"
## t25 Route measurement for Low and High (BRIEF-0.3 Autotest 9): one child process per preset (scenario t25run with
## --gfx-preset <preset> --fps-limit 0, window perf.resolution, its own --user-dir), so the presets share no memory.
## The child walks perf.route_cells by input and checks its preset's limits; this parent collects both.

const Child := preload("res://autotest/lib/child.gd")
const PRESETS := ["low", "high"]
const CHILD_LIMIT_S := 3000.0


func _init() -> void:
	timeout_s = PRESETS.size() * (CHILD_LIMIT_S + 60.0)


func _run(ctx):
	var o = ctx.oracle
	var res: Array = o.system("perf.resolution")
	var per := {}
	for p in PRESETS:
		var out: String = ctx.out_dir.path_join("t25/%s" % p)
		var user: String = ctx.out_dir.path_join("t25/user_%s" % p)
		var r: Dictionary = await Child.run(ctx, "t25run", out,
			PackedStringArray(["--resolution", "%dx%d" % [int(res[0]), int(res[1])]]),
			PackedStringArray(["--user-dir", user, "--gfx-preset", p, "--fps-limit", "0"]), {}, CHILD_LIMIT_S)
		per[p] = {"child": {"pid": r.pid, "exit_code": r.exit_code, "hung": r.hung, "seconds": r.seconds, "out": out},
			"data": Child.data(r), "checks": r.result.get("details", {}).get("checks", []) if r.result is Dictionary else []}
		ctx.note("t25 %s: %s" % [p, Child.summary(r)])
		check("%s: child passed its limits" % p, Child.passed(r), Child.summary(r))
	data.presets = per
	var table := []
	for p in per:
		var d: Dictionary = per[p].data
		var rt: Dictionary = d.get("route", {})
		var g: Dictionary = d.get("gpu", {})
		var m: Dictionary = d.get("mem", {})
		table.append("%s: fps %s / 1%% low %s, GPU %s ms (p99 %s), CPU %s ms, game RAM peak %s MiB, VRAM peak %s MiB, converter peak %s / idle %s MiB" % [
			p, str(rt.get("fps_avg")), str(rt.get("fps_1pct_low")), str(g.get("gpu_ms_avg")), str(g.get("gpu_ms_p99")),
			str(g.get("cpu_ms_avg")), str(m.get("game_mb_peak")), str(m.get("vram_mb_peak")), str(m.get("converter_mb_peak")),
			str(d.get("converter_idle_mb"))])
	for line in table:
		note(line)
	return true
