extends "res://autotest/lib/scenario.gd"
## r09 Record: screenshots from the same poses (systems perf.shot_poses) in Low, Medium and High. One child per preset
## (r09shot with --gfx-preset <preset>, own --user-dir), so every texture loads at that preset from the start; the
## PNGs are copied into <out>/records/presets/<pose>_<preset>.png.

const Child := preload("res://autotest/lib/child.gd")
const Frame := preload("res://autotest/lib/frame.gd")
const PRESETS := ["low", "medium", "high"]
const CHILD_LIMIT_S := 1500.0


func _init() -> void:
	timeout_s = PRESETS.size() * (CHILD_LIMIT_S + 60.0)


func _run(ctx):
	var poses: Variant = ctx.oracle.system("perf.shot_poses")
	if not check("perf.shot_poses filled (systems sheet)", poses is Dictionary and not (poses as Dictionary).is_empty(), str(poses)):
		return false
	var dst_dir: String = ctx.out_dir.path_join("records/presets")
	DirAccess.make_dir_recursive_absolute(dst_dir)
	var per := {}
	var files := []
	for pr in PRESETS:
		var out: String = ctx.out_dir.path_join("r09/%s" % pr)
		var r: Dictionary = await Child.run(ctx, "r09shot", out, PackedStringArray(),
			PackedStringArray(["--user-dir", ctx.out_dir.path_join("user_r09_%s" % pr), "--gfx-preset", pr]), {}, CHILD_LIMIT_S)
		per[pr] = {"pid": r.pid, "exit_code": r.exit_code, "hung": r.hung, "seconds": r.seconds, "summary": Child.summary(r), "data": Child.data(r)}
		check("%s: child shot every pose" % pr, Child.passed(r), Child.summary(r))
		for pose in (poses as Dictionary):
			var f := "%s_%s.png" % [pose, pr]
			var src := out.path_join(f)
			var dst := dst_dir.path_join(f)
			var ok := FileAccess.file_exists(src) and DirAccess.copy_absolute(src, dst) == OK
			var a := Frame.analyze_png(dst, ctx.run_start_unix)
			check("%s copied, not blank" % f, ok and float(a.get("luma_stddev", 0.0)) > 10.0, str(a.get("luma_stddev")))
			if ok:
				files.append({"path": dst, "bytes": FileAccess.get_file_as_bytes(dst).size()})
	data.presets = per
	data.files = files
	return true
