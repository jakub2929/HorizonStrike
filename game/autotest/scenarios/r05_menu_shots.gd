extends "res://autotest/lib/scenario.gd"
## r05 Record: knife menu and upgrades menu screenshots. One child (r05shots, own --user-dir) opens both menus with
## real input and saves them; the PNGs are copied into <out>/records/.

const Child := preload("res://autotest/lib/child.gd")
const Frame := preload("res://autotest/lib/frame.gd")
const SHOTS := ["knife_menu.png", "upgrades_menu.png"]


func _init() -> void:
	timeout_s = 960.0


func _run(ctx):
	var out: String = ctx.out_dir.path_join("r05")
	var r: Dictionary = await Child.run(ctx, "r05shots", out, PackedStringArray(),
		PackedStringArray(["--user-dir", ctx.out_dir.path_join("user_r05")]), {}, 900.0)
	data.child = {"pid": r.pid, "exit_code": r.exit_code, "hung": r.hung, "seconds": r.seconds, "data": Child.data(r)}
	check("child r05shots ran its steps", Child.passed(r), Child.summary(r))
	var rec: String = ctx.out_dir.path_join("records")
	DirAccess.make_dir_recursive_absolute(rec)
	var files := {}
	for f in SHOTS:
		var src := out.path_join(f)
		var dst := rec.path_join(f)
		var ok := FileAccess.file_exists(src) and DirAccess.copy_absolute(src, dst) == OK
		var a := Frame.analyze_png(dst, ctx.run_start_unix)
		files[f] = {"path": dst, "copied": ok, "bytes": FileAccess.get_file_as_bytes(dst).size() if ok else 0, "analysis": a}
		check("%s in records, not blank" % f, ok and float(a.get("luma_stddev", 0.0)) > 10.0, str(a.get("luma_stddev")))
	data.files = files
	return true
