extends "res://autotest/lib/scenario.gd"
## r02clip (movie-maker child of r02, machine from env HZS_R02_MACHINE): three clips filmed side-on by a test camera
## at the open snow field, their drawn-frame ranges written to <out>/clips.json after each clip.
##   walk   - machine spawned with AI on, the player 200 m away (out of sight and hearing), 8 s
##   attack - invulnerable player 8 m in front of it, view turned onto it by mouse motion; from alert/attack on, 8 s
##   death  - AI off, health set to 1 (setup), one glock shot by the fire button; 1 s before to 6 s after the shot

const InputSim := preload("res://autotest/lib/inputsim.gd")
const HitCheck := preload("res://autotest/lib/hitcheck.gd")
const Combat := preload("res://autotest/lib/combat.gd")
const Sites := preload("res://autotest/lib/sites.gd")
const Movie := preload("res://autotest/lib/movie.gd")

const SITE := Vector3(2582.0, 178.0, 780.0)  # open snow field south of FE_Antelope_Scout (cell 5,-2), as t12 / t13
const FPS := 30
const FILM_M := 11.0

var clips := {}


func _init() -> void:
	timeout_s = 780.0


func _run(ctx):
	var mt := OS.get_environment("HZS_R02_MACHINE")
	data.machine = mt
	if not check("machine given (env HZS_R02_MACHINE)", mt != "", mt):
		return false
	if not check("world_ready", await ctx.need_world(500.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	p.set("invulnerable", true)
	var inp = InputSim.new(ctx)
	await inp.equip("glock")
	inp.capture_for_look()
	await ctx.call_api(g, "teleport", [SITE])
	var w: Variant = g.get("world") if "world" in g else null
	var c: Variant = ctx.cell_of(SITE)
	if w is Object and w.has_method("is_cell_loaded") and c != null:
		await ctx.wait_until(func(): return bool(w.call("is_cell_loaded", c)), 300.0)
	await ctx.wait(2.0)
	var gy: Variant = await ctx.ground_y(SITE.x, SITE.z)
	var center := Vector3(SITE.x, float(gy) if gy != null else SITE.y, SITE.z)
	var m: Variant = await ctx.call_api(g, "spawn_machine", [mt, center])
	if not check("spawn_machine(%s) works in this build" % mt, m is Node, str(m)):
		_save(ctx, "walk_why", "spawn_machine returned %s" % str(m))
		return false
	ctx.spawned.append(m)
	var mn := m as Node3D
	var cam := Movie.film_camera(ctx)
	# walk: the player far away, AI on
	var away := center + Vector3(0, 0, 200.0)
	var agy: Variant = await ctx.ground_y(away.x, away.z)
	away.y = float(agy) + 0.05 if agy != null else center.y + 5.0
	await ctx.call_api(g, "teleport", [away])
	ctx.set_ai(mn, true)
	await _film(ctx, cam, mn, 30)
	var p0 := mn.global_position
	var f0 := Movie.frame_now()
	await _film(ctx, cam, mn, 8 * FPS)
	clips.walk = [f0, Movie.frame_now()]
	data.walk_moved_m = snappedf(mn.global_position.distance_to(p0), 0.1)
	_save(ctx)
	# attack: invulnerable player 8 m in front, view on the machine
	var fwd := -mn.global_transform.basis.z
	await Sites.place_player_facing(ctx, mn.global_position, 8.0, fwd)
	await inp.aim_at_point(mn.global_position + Vector3(0, 1.0, 0))
	var waited := 0
	while waited < 10 * FPS and is_instance_valid(mn) and not ["alert", "attack"].has(str(mn.get("state"))):
		await _film(ctx, cam, mn, 1, _mid(ctx, mn))
		inp.look_step(InputSim.yaw_pitch_to(ctx.player_camera().global_position, mn.global_position + Vector3(0, 1.0, 0)).x, InputSim.yaw_pitch_to(ctx.player_camera().global_position, mn.global_position + Vector3(0, 1.0, 0)).y)
		waited += 1
	data.attack_state_at_start = str(mn.get("state")) if is_instance_valid(mn) else "freed"
	f0 = Movie.frame_now()
	var states := {}
	for i in 8 * FPS:
		if not is_instance_valid(mn):
			break
		states[str(mn.get("state"))] = true
		if "current_attack" in mn and str(mn.get("current_attack")) != "":
			states["attack:" + str(mn.get("current_attack"))] = true
		await _film(ctx, cam, mn, 1, _mid(ctx, mn))
	clips.attack = [f0, Movie.frame_now()]
	data.attack_states = states.keys()
	_save(ctx)
	# death: AI off, health 1, one shot by the fire button
	if not is_instance_valid(mn):
		_save(ctx, "death_why", "machine gone before the death clip")
		return false
	ctx.set_ai(mn, false)
	await _film(ctx, cam, mn, FPS)
	mn.set("health", 1.0)
	var bp: Vector3 = HitCheck.target_point(mn, "body")
	await inp.aim_at_point(bp)
	f0 = Movie.frame_now()
	await _film(ctx, cam, mn, FPS)
	var shot: Dictionary = await Combat.shoot(ctx, inp, mn)
	var dead := Combat.is_dead(mn)
	for i in 4:
		if dead:
			break
		await ctx.wait(Combat.shot_interval(ctx, "glock"))
		await inp.aim_at_point(HitCheck.target_point(mn, "body"))
		shot = await Combat.shoot(ctx, inp, mn)
		dead = Combat.is_dead(mn)
	var keep_pos := mn.global_position if is_instance_valid(mn) else cam.global_position
	for i in 6 * FPS:
		if is_instance_valid(mn):
			await _film(ctx, cam, mn, 1)
		else:
			await ctx.frames(1)
	clips.death = [f0, Movie.frame_now()]
	data.death = {"killed": dead, "last_shot": shot, "pos": str(keep_pos)}
	_save(ctx)
	check("walk, attack and death filmed", clips.has("walk") and clips.has("attack") and clips.has("death"), str(clips))
	check("%s killed by an input shot" % mt, dead, str(shot))
	note("walk: moved %s m; attack clip states %s" % [str(data.walk_moved_m), str(data.attack_states)])
	return true


func _film(ctx, cam: Camera3D, subject: Node3D, n: int, look: Variant = null) -> void:
	for i in n:
		Movie.side_on(cam, subject, FILM_M, look)
		await ctx.frames(1)


func _mid(ctx, m: Node3D) -> Vector3:
	return (m.global_position + ctx.player_pos()) * 0.5 + Vector3(0, 1.0, 0)


func _save(ctx, why_key: String = "", why: String = "") -> void:
	if why_key != "":
		clips[why_key] = why
	ctx.write_json(ctx.out_dir.path_join("clips.json"), clips)
