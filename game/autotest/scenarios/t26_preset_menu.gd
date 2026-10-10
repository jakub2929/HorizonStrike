extends "res://autotest/lib/scenario.gd"
## t26 Preset switch in Esc > Graphics (BRIEF-0.3 Autotest 10): child A (t26a) clicks the presets with real input and
## checks after each click that the engine state follows at once; child B (t26b) starts with the same --user-dir and
## checks the last clicked preset is active from the start. graphics.json must be written only in that user dir.

const Child := preload("res://autotest/lib/child.gd")
const GfxState := preload("res://autotest/lib/gfxstate.gd")
const CHILD_LIMIT_S := 900.0


func _init() -> void:
	timeout_s = 2.0 * (CHILD_LIMIT_S + 60.0)


func _run(ctx):
	var user: String = ctx.out_dir.path_join("t26/user")
	var gfile := user.path_join(str(ctx.oracle.system("graphics.settings_file")))
	if FileAccess.file_exists(gfile):
		# a previous run's profile: kept, a fresh folder is used (never deleted)
		user = "%s_%d" % [user, int(Time.get_unix_time_from_system())]
		gfile = user.path_join(gfile.get_file())
	var app_file := OS.get_environment("LOCALAPPDATA").replace("\\", "/").path_join("HorizonStrike").path_join(gfile.get_file())
	var app_mtime0 := FileAccess.get_modified_time(app_file) if FileAccess.file_exists(app_file) else -1
	data.user_dir = user
	var a: Dictionary = await Child.run(ctx, "t26a", ctx.out_dir.path_join("t26/a"), PackedStringArray(),
		PackedStringArray(["--user-dir", user]), {}, CHILD_LIMIT_S)
	var ad := Child.data(a)
	data.a = {"child": _info(a), "data": ad}
	check("A: preset clicks applied at once (child t26a)", Child.passed(a), Child.summary(a))
	var final := str(ad.get("final_preset", ""))
	check("A: graphics.json in --user-dir holds the last clicked preset %s" % final, final != "" and GfxState.file_preset(gfile) == final, "%s: %s" % [gfile, GfxState.file_preset(gfile)])
	var b: Dictionary = await Child.run(ctx, "t26b", ctx.out_dir.path_join("t26/b"), PackedStringArray(),
		PackedStringArray(["--user-dir", user]), {"HZS_T26_EXPECT": final}, CHILD_LIMIT_S)
	data.b = {"child": _info(b), "data": Child.data(b)}
	check("B: after the restart %s is active and applied (child t26b)" % final, Child.passed(b), Child.summary(b))
	var app_mtime1 := FileAccess.get_modified_time(app_file) if FileAccess.file_exists(app_file) else -1
	check("%%LOCALAPPDATA%%/HorizonStrike/%s untouched (graphics.json follows --user-dir)" % gfile.get_file(), app_mtime0 == app_mtime1,
		"mtime %d -> %d" % [app_mtime0, app_mtime1])
	return true


static func _info(r: Dictionary) -> Dictionary:
	return {"pid": r.pid, "exit_code": r.exit_code, "hung": r.hung, "seconds": r.seconds, "out": r.out}
