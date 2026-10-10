extends "res://autotest/lib/scenario.gd"
## r06 Record: inspect videos 3-5 s of Karambit, M9 Bayonet and Butterfly. One movie-maker child per knife (r06clip,
## env HZS_R06_KNIFE, own --user-dir) chooses the knife in the Esc menu, draws it and presses F; the clip is cut into
## <out>/records/video/inspect_<knife>.mp4. Raw AVIs stay in <out>/r06raw.

const RecClip := preload("res://autotest/lib/recclip.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const Child := preload("res://autotest/lib/child.gd")
const KNIVES := ["knife_karambit", "knife_m9_bayonet", "knife_butterfly"]
const CHILD_LIMIT_S := 900.0


func _init() -> void:
	timeout_s = KNIVES.size() * (CHILD_LIMIT_S + 120.0)


func _run(ctx):
	var video: String = ctx.out_dir.path_join("records/video")
	var raw: String = ctx.out_dir.path_join("r06raw")
	var per := {}
	var made := []
	for k in KNIVES:
		var avi := raw.path_join("inspect_%s.avi" % k)
		var r: Dictionary = await RecClip.record(ctx, "r06clip", avi, raw.path_join(k),
			PackedStringArray(["--user-dir", ctx.out_dir.path_join("user_r06_%s" % k)]), {"HZS_R06_KNIFE": k}, CHILD_LIMIT_S)
		var info := RecClip.info(r)
		var fr: Variant = r.clips.get("inspect")
		if fr is Array and (fr as Array).size() >= 2:
			var c: Dictionary = await Movie.cut(ctx, avi, int(fr[0]), int(fr[1]), video.path_join("inspect_%s.mp4" % k))
			info.mp4 = c
			var secs := float(c.get("seconds", -1.0))
			var ok: bool = not c.has("error") and secs >= 3.0 and secs <= 5.0 and not bool(c.get("blank", true))
			check("%s: inspect video 3-5 s, not blank" % k, ok, c.get("error", "%.2f s, luma %s" % [secs, str(c.get("luma_stddev"))]))
			if ok:
				made.append(c.path)
		else:
			check("%s: inspect clip recorded" % k, false, str(r.clips.get("why", info.summary)))
		check("%s: child chose the knife and inspect played" % k, Child.passed(r), info.summary)
		per[k] = info
	data.knives = per
	data.videos = made
	return true
