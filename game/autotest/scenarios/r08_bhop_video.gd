extends "res://autotest/lib/scenario.gd"
## r08 Record: bhop level 0 vs level 5 side by side. One movie-maker child per level (r08clip, env HZS_R08_LEVEL, own
## --user-dir) runs the same start pose and input script for 10 s; both clips are cut into
## <out>/records/video/bhop_l<n>.mp4 and stacked side by side (ffmpeg hstack, labelled) into bhop_l0_vs_l5.mp4.

const RecClip := preload("res://autotest/lib/recclip.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const Child := preload("res://autotest/lib/child.gd")
const Frame := preload("res://autotest/lib/frame.gd")
const LEVELS := [0, 5]
const CHILD_LIMIT_S := 900.0


func _init() -> void:
	timeout_s = LEVELS.size() * (CHILD_LIMIT_S + 120.0) + 120.0


func _run(ctx):
	var raw: String = ctx.out_dir.path_join("r08raw")
	var video: String = ctx.out_dir.path_join("records/video")
	var mp4s := []
	var per := {}
	for lv in LEVELS:
		var avi := raw.path_join("bhop_l%d.avi" % lv)
		var r: Dictionary = await RecClip.record(ctx, "r08clip", avi, raw.path_join("l%d" % lv),
			PackedStringArray(["--user-dir", ctx.out_dir.path_join("user_r08_l%d" % lv)]), {"HZS_R08_LEVEL": lv}, CHILD_LIMIT_S)
		var info := RecClip.info(r)
		var fr: Variant = r.clips.get("bhop")
		if fr is Array and (fr as Array).size() >= 2:
			var c: Dictionary = await Movie.cut(ctx, avi, int(fr[0]), int(fr[1]), video.path_join("bhop_l%d.mp4" % lv))
			info.mp4 = c
			var secs := float(c.get("seconds", -1.0))
			var ok: bool = not c.has("error") and absf(secs - 10.0) <= 0.5 and not bool(c.get("blank", true))
			check("level %d: 10 s clip, not blank" % lv, ok, c.get("error", "%.2f s, luma %s" % [secs, str(c.get("luma_stddev"))]))
			if ok:
				mp4s.append(c.path)
		else:
			check("level %d: clip recorded" % lv, false, str(r.clips.get("why", info.summary)))
		check("level %d: child jumped by input" % lv, Child.passed(r), info.summary)
		per["l%d" % lv] = info
	data.levels = per
	if mp4s.size() != 2:
		check("side-by-side video", false, "needs both clips")
		return true
	var out := video.path_join("bhop_l0_vs_l5.mp4")
	var font := "C\\:/Windows/Fonts/arial.ttf"
	var label := "drawtext=fontfile='%s':text='%s':x=24:y=24:fontsize=40:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=8"
	var filt := "[0:v]%s[a];[1:v]%s[b];[a][b]hstack=inputs=2[v]" % [label % [font, "BHOP level 0"], label % [font, "BHOP level 5"]]
	var args := PackedStringArray(["-y", "-v", "error", "-i", mp4s[0], "-i", mp4s[1], "-filter_complex", filt, "-map", "[v]",
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22", "-preset", "veryfast", "-movflags", "+faststart", out])
	var res: Dictionary = await ctx.run_cmd(Movie.ffmpeg(), args)
	var labelled: bool = res.code == 0
	if not labelled:
		# no drawtext (font / filter missing in this ffmpeg build): plain hstack
		note("ffmpeg drawtext failed (%s); side by side without labels (left level 0, right level 5)" % str(res.out).substr(0, 200))
		res = await ctx.run_cmd(Movie.ffmpeg(), PackedStringArray(["-y", "-v", "error", "-i", mp4s[0], "-i", mp4s[1], "-filter_complex",
			"[0:v][1:v]hstack=inputs=2[v]", "-map", "[v]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22", "-preset", "veryfast", "-movflags", "+faststart", out]))
	var secs: float = await Movie.duration(ctx, out) if res.code == 0 else -1.0
	data.side_by_side = {"path": out, "ffmpeg_code": res.code, "labelled": labelled, "seconds": secs,
		"bytes": FileAccess.get_file_as_bytes(out).size() if FileAccess.file_exists(out) else 0}
	check("bhop_l0_vs_l5.mp4 10 s (+-0.5) side by side", res.code == 0 and absf(secs - 10.0) <= 0.5, "%s, %.2f s" % [out, secs])
	return true
