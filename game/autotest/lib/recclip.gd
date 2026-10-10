extends RefCounted
## Movie-maker child with its own game args (r06-r08): lib/child.gd with --write-movie <avi> --fixed-fps 30
## --resolution 1280x720 (lib/movie.gd FPS / RESOLUTION), then the clip ranges the child wrote to <out>/clips.json.
## Cutting stays lib/movie.gd (Movie.cut).

const Child := preload("res://autotest/lib/child.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const Oracle := preload("res://autotest/lib/oracle.gd")


static func record(ctx, scenario_id: String, avi: String, out: String, game_args: PackedStringArray, env: Dictionary, limit_s: float) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(avi.get_base_dir())
	var t0 := int(Time.get_unix_time_from_system())
	var r: Dictionary = await Child.run(ctx, scenario_id, out,
		PackedStringArray(["--write-movie", avi, "--fixed-fps", str(Movie.FPS), "--resolution", Movie.RESOLUTION]), game_args, env, limit_s)
	r.avi = avi
	var cp := out.path_join("clips.json")
	var clips: Variant = Oracle.read_json(cp)
	r.clips = clips if clips is Dictionary and FileAccess.get_modified_time(cp) >= t0 else {}
	return r


static func info(r: Dictionary) -> Dictionary:
	## the child part of a record result for details (no full result row)
	return {"pid": r.get("pid"), "exit_code": r.get("exit_code"), "hung": r.get("hung"), "seconds": r.get("seconds"),
		"avi": r.get("avi"), "clips": r.get("clips"), "summary": Child.summary(r), "data": Child.data(r)}


static func save_clips(ctx, clips: Dictionary) -> void:
	## child side: the drawn-frame ranges so far
	ctx.write_json(ctx.out_dir.path_join("clips.json"), clips)
