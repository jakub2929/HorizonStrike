extends "res://autotest/lib/scenario.gd"
## r03 Record: 25 s walk across two cell borders. A movie-maker child (scenario r03walk, fixed 30 fps, 1280x720)
## walks by held W + mouse steering across a corner of the first perf.route_cells cell; the clip is cut into
## <out>/records/video/cell_crossing.mp4 with ffmpeg. The raw AVI stays in <out>/r03raw.

const Movie := preload("res://autotest/lib/movie.gd")
const CHILD_LIMIT_S := 900.0


func _init() -> void:
	timeout_s = CHILD_LIMIT_S + 180.0


func _run(ctx):
	var raw: String = ctx.out_dir.path_join("r03raw")
	var avi := raw.path_join("cell_crossing.avi")
	var rec: Dictionary = await Movie.record(ctx, "r03walk", avi, raw.path_join("walk"), {}, CHILD_LIMIT_S)
	var info := rec.duplicate()
	info.erase("result")
	var cd: Dictionary = rec.result.get("details", {}).get("data", {}) if rec.result is Dictionary else {}
	data.child = info
	data.walk = cd
	var fr: Variant = rec.clips.get("walk")
	if not check("walk filmed (child clips.json)", fr is Array and (fr as Array).size() >= 2, "%s; child exit %d" % [str(rec.clips), int(rec.exit_code)]):
		return false
	var c: Dictionary = await Movie.cut(ctx, avi, int(fr[0]), int(fr[1]), ctx.out_dir.path_join("records/video/cell_crossing.mp4"))
	data.video = c
	var secs := float(c.get("seconds", -1.0))
	check("one video 20-30 s long", not c.has("error") and secs >= 20.0 and secs <= 30.0, c.get("error", "%.1f s" % secs))
	check("video not blank (luma stddev > 10 in >= 2 of 3 frames)", not bool(c.get("blank", true)), str(c.get("luma_stddev")))
	check("2 cell borders crossed while filming", int(cd.get("crossings", 0)) >= 2, str(cd.get("cells", [])))
	return true
