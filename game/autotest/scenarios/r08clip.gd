extends "res://autotest/lib/scenario.gd"
## r08clip (movie-maker child of r08, bhop level from env HZS_R08_LEVEL set by Game.set_progression as setup, own
## --user-dir): the same start pose and input script for every level. Knife out (3), W held to run speed, then a jump
## chain for 10 s: space on the first physics frame the player is grounded after a landing, in the air A or D held with
## mouse motion turning the same way (air strafe), the side alternating per jump. Take-off speeds are logged.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const RecClip := preload("res://autotest/lib/recclip.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const SITE := Vector3(2582.0, 178.0, 780.0)  # open snow field south of FE_Antelope_Scout (cell 5,-2), as r02clip
const YAW_DEG := 0.0                          # start view: -Z
const CLIP_S := 10.0
const TURN_DEG_S := 100.0                     # air strafe turn rate

var clips := {}


func _init() -> void:
	timeout_s = 780.0


func _run(ctx):
	var lv_s := OS.get_environment("HZS_R08_LEVEL")
	if not check("level given (env HZS_R08_LEVEL)", lv_s.is_valid_int(), lv_s):
		return _why(ctx, "no level")
	var level := int(lv_s)
	data.level = level
	if not check("world_ready", await ctx.need_world(1400.0)):
		return _why(ctx, "world not ready")
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, [], ["teleport", "set_progression"]) + ctx.missing_api(p, ["horizontal_speed"])):
		return _why(ctx, "API missing")
	g.call("set_progression", {"upgrades": {"bhop": level}})
	p.set("invulnerable", true)
	await ctx.call_api(g, "teleport", [SITE])
	var w: Variant = g.get("world")
	var c: Variant = ctx.cell_of(SITE)
	if w is Object and c != null:
		await ctx.wait_until(func(): return bool(w.call("is_cell_loaded", c)), 300.0)
	await ctx.wait(2.0)
	await ctx.call_api(g, "teleport", [SITE])   # again once the ground collides (as r01)
	await ctx.wait(1.5)
	var inp = InputSim.new(ctx)
	inp.capture_for_look()
	check("3 takes the knife", await inp.equip("knife"), str(p.get("current_weapon")))
	# same start view for every level (mouse motion, closed loop)
	for i in 120:
		var e: Vector2 = inp.look_step(deg_to_rad(YAW_DEG), deg_to_rad(-4.0))
		await ctx.frames(1)
		if absf(e.x) < 0.003 and absf(e.y) < 0.003:
			break
	data.start = {"pos": str(ctx.player_pos().round()), "yaw_pitch": str(inp.yaw_pitch())}
	var f0 := Movie.frame_now()
	var end_frame := f0 + int(CLIP_S * Movie.FPS)
	var jumps := []
	inp.press("move_forward")
	await ctx.wait(0.7)
	var side := -1
	var px_per_phys: float = deg_to_rad(TURN_DEG_S) / 60.0 / maxf(inp.rad_per_px, 0.0001)
	# first jump from running
	await _jump(ctx, inp)
	inp.release("move_forward")
	while Movie.frame_now() < end_frame:
		# air: wait to leave the ground, then strafe until the landing
		var key := "move_left" if side < 0 else "move_right"
		inp.press(key)
		var guard := 0
		while p.is_on_floor() and guard < 20 and Movie.frame_now() < end_frame:
			await ctx.physics_frames(1)
			guard += 1
		var takeoff: float = p.horizontal_speed
		guard = 0
		while not p.is_on_floor() and guard < 240 and Movie.frame_now() < end_frame:
			inp.look(side * px_per_phys, 0.0)
			await ctx.physics_frames(1)
			guard += 1
		inp.release(key)
		var landing: float = p.horizontal_speed
		jumps.append([snappedf(takeoff, 0.01), snappedf(landing, 0.01)])
		if Movie.frame_now() >= end_frame:
			break
		await _jump(ctx, inp)
		side = -side
	clips.bhop = [f0, Movie.frame_now()]
	RecClip.save_clips(ctx, clips)
	for a in ["move_forward", "move_left", "move_right", "jump"]:
		inp.release(a)
	data.jumps_takeoff_landing = jumps
	note("level %d: take-off / landing m/s per jump %s" % [level, str(jumps)])
	check(">= 5 jumps in %d s" % int(CLIP_S), jumps.size() >= 5, str(jumps.size()))
	return true


func _jump(ctx, inp) -> void:
	## space down for one physics frame (the game reads the press on its next physics step)
	inp.press("jump")
	await ctx.physics_frames(1)
	inp.release("jump")


func _why(ctx, why: String) -> bool:
	clips.why = why
	RecClip.save_clips(ctx, clips)
	return false
