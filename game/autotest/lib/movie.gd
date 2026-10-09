extends RefCounted
## Movie-maker recordings (r02, r03). The parent starts a child with --write-movie <avi> --fixed-fps 30; the child's
## recording scenario writes the drawn-frame range of each clip to <child out>/clips.json (the movie covers the whole
## process, boot included). After the child exits the parent cuts each clip out of the AVI into an MP4 with ffmpeg
## (dev tool: env HZS_FFMPEG or ffmpeg on PATH) and checks a few frames of it are not blank.

const Proc := preload("res://autotest/lib/proc.gd")
const Frame := preload("res://autotest/lib/frame.gd")
const CHILD_ENV := "HZS_AUTOTEST_CHILD"
const FPS := 30
const RESOLUTION := "1280x720"


static func ffmpeg() -> String:
	var e := OS.get_environment("HZS_FFMPEG")
	return e if e != "" else "ffmpeg"


static func record(ctx, scenario_id: String, avi: String, out: String, env: Dictionary, limit_s: float) -> Dictionary:
	## one child process with the movie maker on; returns {pid, exit_code, hung, seconds, clips, result}
	DirAccess.make_dir_recursive_absolute(out)
	DirAccess.make_dir_recursive_absolute(avi.get_base_dir())
	var argv := Proc.game_launch_prefix(PackedStringArray(["--write-movie", avi, "--fixed-fps", str(FPS), "--resolution", RESOLUTION]))
	argv.append_array(ctx.args.forward(["--autotest", "--out"]))
	argv.append_array(PackedStringArray(["--autotest", scenario_id, "--out", out]))
	var t0 := int(Time.get_unix_time_from_system())
	OS.set_environment(CHILD_ENV, scenario_id)
	for k in env:
		OS.set_environment(k, str(env[k]))
	ctx.note("== movie child %s: %s %s" % [scenario_id, OS.get_executable_path(), " ".join(argv)])
	var pid := OS.create_process(OS.get_executable_path(), argv)
	OS.unset_environment(CHILD_ENV)
	for k in env:
		OS.unset_environment(k)
	var start := Time.get_ticks_msec()
	var quiet := Proc.quiet_parent(ctx.tree)
	while pid > 0 and OS.is_process_running(pid) and (Time.get_ticks_msec() - start) / 1000.0 < limit_s:
		await ctx.tree.create_timer(1.0, true, false, true).timeout
	var hung := pid > 0 and OS.is_process_running(pid)
	if hung:
		ctx.note("movie child %d still running after %d s; killing that exact PID" % [pid, int(limit_s)])
		OS.kill(pid)
		await ctx.tree.create_timer(1.0, true, false, true).timeout
	Proc.restore_parent(ctx.tree, quiet)
	var r := {"pid": pid, "exit_code": OS.get_process_exit_code(pid) if pid > 0 else -1, "hung": hung, "seconds": snappedf((Time.get_ticks_msec() - start) / 1000.0, 0.1), "avi": avi}
	var cp := out.path_join("clips.json")
	var clips: Variant = load("res://autotest/lib/oracle.gd").read_json(cp)
	r.clips = clips if clips is Dictionary and FileAccess.get_modified_time(cp) >= t0 else {}
	var rows: Variant = load("res://autotest/lib/oracle.gd").read_json(out.path_join("results.json"))
	r.result = rows[0] if rows is Array and not (rows as Array).is_empty() else null
	return r


static func cut(ctx, avi: String, f0: int, f1: int, mp4: String) -> Dictionary:
	## frames [f0, f1) of the AVI -> H.264 MP4; then its duration and three frames (10 / 50 / 90 %) for blankness
	var r := {"path": mp4, "frames": [f0, f1]}
	if not FileAccess.file_exists(avi):
		r.error = "no AVI " + avi
		return r
	DirAccess.make_dir_recursive_absolute(mp4.get_base_dir())
	var ss := float(f0) / FPS
	var dur := float(f1 - f0) / FPS
	var res: Dictionary = await ctx.run_cmd(ffmpeg(), PackedStringArray(["-y", "-v", "error", "-ss", "%.3f" % ss, "-i", avi, "-t", "%.3f" % dur,
		"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22", "-preset", "veryfast", "-c:a", "aac", "-movflags", "+faststart", mp4]))
	r.ffmpeg_code = res.code
	if res.code != 0 or not FileAccess.file_exists(mp4):
		r.error = "ffmpeg exit %d: %s" % [res.code, str(res.out).substr(0, 400)]
		return r
	r.bytes = FileAccess.get_file_as_bytes(mp4).size()
	r.seconds = await duration(ctx, mp4)
	var stds := []
	for frac in [0.1, 0.5, 0.9]:
		var png := mp4.get_basename() + "_%d.png" % int(frac * 100)
		var t: float = maxf(0.0, float(r.seconds) * frac) if float(r.seconds) > 0.0 else dur * frac
		await ctx.run_cmd(ffmpeg(), PackedStringArray(["-y", "-v", "error", "-ss", "%.3f" % t, "-i", mp4, "-frames:v", "1", png]))
		var a := Frame.analyze_png(png, 0)
		stds.append(snappedf(float(a.get("luma_stddev", 0.0)), 0.1))
		if FileAccess.file_exists(png):
			# probe frames are scratch: moved next to the AVIs (never deleted)
			var keep := avi.get_base_dir().path_join(png.get_file())
			if FileAccess.file_exists(keep):
				DirAccess.rename_absolute(keep, keep + ".%d.old" % Time.get_ticks_msec())
			DirAccess.rename_absolute(png, keep)
	r.luma_stddev = stds
	r.blank = stds.filter(func(s): return float(s) > 10.0).size() < 2
	return r


static func duration(ctx, path: String) -> float:
	## "Duration: hh:mm:ss.cc" from ffmpeg -i (exit code 1: no output file is expected)
	var res: Dictionary = await ctx.run_cmd(ffmpeg(), PackedStringArray(["-hide_banner", "-i", path]))
	var s := str(res.out)
	var i := s.find("Duration: ")
	if i < 0:
		return -1.0
	var hms := s.substr(i + 10, 11).split(":")
	if hms.size() < 3:
		return -1.0
	return float(hms[0]) * 3600.0 + float(hms[1]) * 60.0 + float(hms[2])


# --- child side ---------------------------------------------------------------------------------------------------

static func frame_now() -> int:
	return Engine.get_frames_drawn()


static func film_camera(ctx) -> Camera3D:
	## a test camera for side-on recordings (the player's own camera keeps driving aim and shots); HUD hidden
	var cam := Camera3D.new()
	cam.name = "AutotestFilmCamera"
	cam.fov = 60.0
	cam.near = 0.05
	cam.far = 4000.0
	ctx.tree.root.add_child(cam)
	cam.current = true
	var hud: Variant = ctx.game.get("hud") if ctx.game != null and "hud" in ctx.game else null
	if hud is CanvasItem:
		(hud as CanvasItem).visible = false
	# every overlay layer too: the first-person weapon is drawn by its own SubViewport on a CanvasLayer and would
	# otherwise sit in front of the side-on camera
	for n in ctx.tree.root.find_children("*", "CanvasLayer", true, false):
		(n as CanvasLayer).visible = false
	return cam


static func side_on(cam: Camera3D, subject: Node3D, dist_m: float, look_at_pos: Variant = null) -> void:
	## camera dist_m to the subject's right, 2 m up, looking at it (or at look_at_pos)
	if not is_instance_valid(subject):
		return
	var right := subject.global_transform.basis.x.normalized()
	right.y = 0.0
	if right.length() < 0.1:
		right = Vector3.RIGHT
	right = right.normalized()
	var target: Vector3 = look_at_pos if look_at_pos is Vector3 else subject.global_position + Vector3(0, 1.0, 0)
	var space := subject.get_world_3d().direct_space_state
	# side (right / left / the two diagonals behind) re-chosen once a second: first one with a clear view
	var f := Engine.get_frames_drawn()
	if not cam.has_meta("side") or f >= int(cam.get_meta("next_check", 0)):
		cam.set_meta("next_check", f + FPS)
		var back := right.cross(Vector3.UP).normalized()
		var sides := [right, -right, (right + back).normalized(), (-right + back).normalized()]
		var keep: Vector3 = cam.get_meta("side") if cam.has_meta("side") else right
		var chosen: Vector3 = keep
		for s in [keep] + sides:
			var pos := _cam_pos(space, subject.global_position + (s as Vector3) * dist_m)
			var q := PhysicsRayQueryParameters3D.create(pos, target)
			var hit := space.intersect_ray(q)
			if hit.is_empty() or (hit.position as Vector3).distance_to(target) < 2.5:
				chosen = s
				break
		cam.set_meta("side", chosen)
	cam.global_position = _cam_pos(space, subject.global_position + (cam.get_meta("side") as Vector3) * dist_m)
	if cam.global_position.distance_to(target) > 0.1:
		cam.look_at(target, Vector3.UP)


static func _cam_pos(space: PhysicsDirectSpaceState3D, p: Vector3) -> Vector3:
	## 2 m above the subject's height, at least 1.6 m above the ground under the camera
	var out := p + Vector3(0, 2.0, 0)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 300.0, 0), p - Vector3(0, 300.0, 0)))
	if not hit.is_empty():
		out.y = maxf(out.y, (hit.position as Vector3).y + 1.6)
	return out
