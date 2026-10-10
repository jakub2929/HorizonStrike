extends "res://autotest/lib/scenario.gd"
## r07clip (movie-maker child of r07, own --user-dir): on the open snow field (r02 site) 2 scrappers and a watcher with
## AI on 25 m ahead; AK bought (setup), player invulnerable (hits still show the hurt effects). For 18 s: view onto
## the nearest machine's body or weak spot by Game.aim_at (setup, as lib/combat.gd), fire bursts with the mouse button, reload with the
## key. Clip range in <out>/clips.json; Game.fx_stats and player_hurt counted over the clip.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const HitCheck := preload("res://autotest/lib/hitcheck.gd")
const Combat := preload("res://autotest/lib/combat.gd")
const RecClip := preload("res://autotest/lib/recclip.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const SITE := Vector3(2582.0, 178.0, 780.0)  # open snow field south of FE_Antelope_Scout (cell 5,-2), as r02clip
const CLIP_S := 18.0
const BURST_S := 0.1    # fire button held per press (one AK shot)
const PAUSE_S := 0.5    # between presses: the fight lasts the whole clip

var clips := {}


func _init() -> void:
	timeout_s = 780.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return _why(ctx, "world not ready")
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["money"], ["teleport", "spawn_machine", "buy", "fx_stats"])):
		return _why(ctx, "Game API missing")
	p.set("invulnerable", true)
	await ctx.call_api(g, "teleport", [SITE])
	var w: Variant = g.get("world")
	var c: Variant = ctx.cell_of(SITE)
	if w is Object and c != null:
		await ctx.wait_until(func(): return bool(w.call("is_cell_loaded", c)), 300.0)
	await ctx.wait(2.0)
	g.set("money", 3500)
	check("AK bought (setup)", bool(g.call("buy", "ak47")))
	var inp = InputSim.new(ctx)
	inp.capture_for_look()
	check("1 takes the AK", await inp.equip("ak47"), str(p.get("current_weapon")))
	var base: Vector3 = ctx.forward()
	var ms: Array = await _wave(ctx, base)
	check("3 machines spawned", ms.size() == 3, str(ms.size()))
	if ms.is_empty():
		return _why(ctx, "no machine spawned")
	await inp.aim_at_point(HitCheck.target_point(ms[1], "body"), 0.01, 60)
	await ctx.wait(1.5)
	var hurt = ctx.record(g, "player_hurt")
	var fx0: Dictionary = g.call("fx_stats")
	var f0 := Movie.frame_now()
	# length counted in physics steps (game time): drawn frames do not advance in a headless check run
	var end_phys := Engine.get_physics_frames() + int(CLIP_S * int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))
	var n := 0
	var bursts := 0
	var waves := 1
	while Engine.get_physics_frames() < end_phys:
		var alive := ms.filter(func(m): return not Combat.is_dead(m))
		if alive.is_empty():
			# the wave is down (weak-spot shots kill fast): the next one 25 m ahead (setup) keeps the fight going
			await ctx.wait(1.0)
			ms = await _wave(ctx, base)
			waves += 1
			continue
		var cam_pos: Vector3 = ctx.player_camera().global_position
		alive.sort_custom(func(a, b): return cam_pos.distance_squared_to(a.global_position) < cam_pos.distance_squared_to(b.global_position))
		var m: Node = alive[0]
		var weak: Array = m.call("weak_spots") if m.has_method("weak_spots") else []
		var part: String = "body" if n % 4 != 3 or weak.is_empty() else str(weak[0])
		n += 1
		# view onto the target as lib/combat.gd kill() does (Game.aim_at points the camera; the shots are input)
		await ctx.call_api(g, "aim_at", [m, part])
		await ctx.physics_frames(1)
		var ammo: Variant = Combat.ammo_of(ctx, "ak47")
		if (ammo is Vector2i or ammo is Vector2) and int(ammo.x) == 0:
			await inp.tap("reload")
			await ctx.wait(2.6)
			continue
		inp.press("fire")
		await ctx.wait(BURST_S)
		inp.release("fire")
		bursts += 1
		await ctx.wait(PAUSE_S)
	clips.combat = [f0, Movie.frame_now()]
	RecClip.save_clips(ctx, clips)
	var fx1: Dictionary = g.call("fx_stats")
	var d := {}
	for k in ["hitmarkers", "numbers", "sparks", "indicators"]:
		d[k] = int(fx1.get(k, 0)) - int(fx0.get(k, 0))
	d.player_hurt = hurt.events.size()
	d.bursts = bursts
	d.waves = waves
	d.killed_last_wave = ms.filter(func(m): return Combat.is_dead(m)).size()
	data.fx = d
	check("hitmarkers > 0 and damage numbers > 0 during the clip", d.hitmarkers > 0 and d.numbers > 0, str(d))
	check("sparks > 0 during the clip", d.sparks > 0, str(d.sparks))
	check(">= 1 player hit during the clip", d.player_hurt >= 1, str(d.player_hurt))
	data.input_tail = inp.sent.slice(-10)
	return true


static func _wave(ctx, base: Vector3) -> Array:
	## 2 scrappers and a watcher 25 m ahead (sheet r07), AI on
	var out := []
	for e in [["scrapper", -18.0], ["watcher", 0.0], ["scrapper", 18.0]]:
		var m: Variant = await ctx.spawn_ahead(e[0], 25.0, e[1], true, base)
		if m is Node:
			out.append(m)
	return out


func _why(ctx, why: String) -> bool:
	clips.why = why
	RecClip.save_clips(ctx, clips)
	return false
