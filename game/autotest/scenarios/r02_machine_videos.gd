extends "res://autotest/lib/scenario.gd"
## r02 Record: machine videos (walk, attack, death) for every machine of the machines sheet. One movie-maker child
## per machine (scenario r02clip, fixed 30 fps, 1280x720) films its three clips side-on and lists their frame ranges;
## the clips are cut into <out>/records/video/<machine>_<clip>.mp4 with ffmpeg. The raw AVIs stay in <out>/r02raw.

const Movie := preload("res://autotest/lib/movie.gd")
const CLIPS := ["walk", "attack", "death"]
const CHILD_LIMIT_S := 900.0


func _init() -> void:
	timeout_s = MachinesSheet.ROWS.size() * (CHILD_LIMIT_S + 120.0)


func _run(ctx):
	var video: String = ctx.out_dir.path_join("records/video")
	var raw: String = ctx.out_dir.path_join("r02raw")
	var made := []
	var bad := []
	var per := {}
	for mt in MachinesSheet.ROWS:
		var avi := raw.path_join("%s.avi" % mt)
		var rec: Dictionary = await Movie.record(ctx, "r02clip", avi, raw.path_join(mt), {"HZS_R02_MACHINE": mt}, CHILD_LIMIT_S)
		var info := {"child": rec.duplicate()}
		info.child.erase("result")
		info.child_pass = rec.result.get("pass") if rec.result is Dictionary else null
		info.child_summary = rec.result.get("details", {}).get("summary", "") if rec.result is Dictionary else ""
		for clip in CLIPS:
			var fr: Variant = rec.clips.get(clip)
			if not (fr is Array and (fr as Array).size() >= 2):
				bad.append("%s_%s: not recorded (%s)" % [mt, clip, str(rec.clips.get(clip + "_why", info.child_summary))])
				continue
			var c: Dictionary = await Movie.cut(ctx, avi, int(fr[0]), int(fr[1]), video.path_join("%s_%s.mp4" % [mt, clip]))
			info[clip] = c
			var secs := float(c.get("seconds", -1.0))
			if c.has("error") or secs < 5.0 or secs > 10.5 or bool(c.get("blank", true)):
				bad.append("%s_%s: %s" % [mt, clip, c.get("error", "%.1f s, luma stddev %s" % [secs, str(c.get("luma_stddev"))])])
			else:
				made.append("%s_%s.mp4" % [mt, clip])
		per[mt] = info
		ctx.note("r02 %s: %s" % [mt, str(per[mt].keys())])
	data.machines = per
	data.videos = made
	var want := MachinesSheet.ROWS.size() * CLIPS.size()
	check("%d videos of 5-10 s, converted to mp4, not blank" % want, made.size() == want, "%d/%d; %s" % [made.size(), want, "; ".join(bad)])
	return true
