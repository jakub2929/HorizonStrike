extends "res://autotest/lib/scenario.gd"
## r07 Record: 15-20 s fight with hit effects. One movie-maker child (r07clip, own --user-dir) fights 2 scrappers and
## a watcher by input; the clip is cut into <out>/records/video/combat.mp4. Raw AVI in <out>/r07raw.

const RecClip := preload("res://autotest/lib/recclip.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const Child := preload("res://autotest/lib/child.gd")
const CHILD_LIMIT_S := 900.0


func _init() -> void:
	timeout_s = CHILD_LIMIT_S + 180.0


func _run(ctx):
	var raw: String = ctx.out_dir.path_join("r07raw")
	var avi := raw.path_join("combat.avi")
	var r: Dictionary = await RecClip.record(ctx, "r07clip", avi, raw.path_join("child"),
		PackedStringArray(["--user-dir", ctx.out_dir.path_join("user_r07")]), {}, CHILD_LIMIT_S)
	var info := RecClip.info(r)
	var fr: Variant = r.clips.get("combat")
	if fr is Array and (fr as Array).size() >= 2:
		var c: Dictionary = await Movie.cut(ctx, avi, int(fr[0]), int(fr[1]), ctx.out_dir.path_join("records/video/combat.mp4"))
		info.mp4 = c
		var secs := float(c.get("seconds", -1.0))
		check("combat video 15-20 s, not blank", not c.has("error") and secs >= 15.0 and secs <= 20.0 and not bool(c.get("blank", true)),
			c.get("error", "%.2f s, luma %s" % [secs, str(c.get("luma_stddev"))]))
	else:
		check("combat clip recorded", false, str(r.clips.get("why", info.summary)))
	check("child: hitmarkers, numbers, sparks and player hits during the clip", Child.passed(r), info.summary)
	data.child = info
	return true
