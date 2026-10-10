extends "res://autotest/lib/scenario.gd"
## t20 Kill gives the right XP; level-up gives a point. Progression reset (setup), then by input (fire button, knife
## stab = right mouse button; Game.aim_at only points the camera, setup):
##   body kill of a Watcher with the Glock        -> xp += machines.xp_reward
##   weak-spot killing shot on a Grazer            -> xp += xp_reward x (1 + xp.weak_spot_kill_bonus_pct / 100)
##   silent strike: knife stab into an unaware Broadhead from behind -> xp += xp_reward x (1 + xp.silent_strike_bonus_pct / 100)
##   xp = one below the next level (setup), body kill of a Watcher -> level + 1, points + xp.points_per_level, HUD
##   LevelUpNotice visible
## Expected XP from the sheets (rounded like a whole-number XP counter), the kill flags from machine_killed.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Combat := preload("res://autotest/lib/combat.gd")
const HitCheck := preload("res://autotest/lib/hitcheck.gd")


func _init() -> void:
	timeout_s = 900.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player", "progression", "machines"], ["spawn_machine", "aim_at", "set_progression", "teleport"], ["machine_killed", "level_up"])):
		return false
	var o = ctx.oracle
	var p: Node = ctx.player
	var inp = InputSim.new(ctx)
	# aiming is mouse motion: --headless has no mouse capture, so this test needs a window run
	if not check("window run (aiming by mouse motion needs a captured mouse)", not InputSim.headless_look()):
		return false
	p.set("invulnerable", true)
	g.call("set_progression", {"xp": 0, "level": 0, "points": 0, "upgrades": {"damage": 0, "max_health": 0, "bhop": 0}})
	await ctx.frames(2)
	data.progression_start = g.get("progression")
	var kills = ctx.record(g, "machine_killed")
	var ups = ctx.record(g, "level_up")
	var weak_pct: float = o.f(o.system("xp.weak_spot_kill_bonus_pct"))
	var silent_pct: float = o.f(o.system("xp.silent_strike_bonus_pct"))
	var base_dir: Vector3 = ctx.forward()
	inp.capture_for_look()

	# 1. body kill (Glock, body only)
	await inp.equip("glock")
	var r1: Dictionary = await _kill_case(ctx, inp, kills, "watcher", "body", "glock", 6.0, base_dir)
	var want1: int = _xp(o, "watcher", false, false)
	data.body_kill = r1
	check("body kill: xp += machines.xp_reward (watcher %d)" % want1, r1.killed and not r1.weak and not r1.silent and r1.xp == want1, str(r1))

	# 2. weak-spot killing shot (Grazer)
	var weak_part := ""
	var mg: Node = await ctx.spawn_ahead("grazer", 9.0, 0.0, false, base_dir)
	if mg != null and mg.has_method("weak_spots") and not mg.call("weak_spots").is_empty():
		weak_part = str(mg.call("weak_spots")[0])
	ctx.despawn(mg)
	await ctx.wait(0.3)
	var r2: Dictionary = await _kill_case(ctx, inp, kills, "grazer", weak_part, "glock", 9.0, base_dir)
	var want2: int = _xp(o, "grazer", true, false)
	data.weak_kill = r2
	check("weak kill: xp += xp_reward x (1 + %s %%) (grazer %d)" % [str(weak_pct), want2], r2.killed and r2.weak and r2.xp == want2, str(r2))

	# 3. silent strike: knife stab (right mouse button) from behind an unaware broadhead
	await inp.equip("knife")
	var r3: Dictionary = await _silent_case(ctx, inp, kills, base_dir)
	var want3: int = _xp(o, "broadhead", bool(r3.get("weak", false)), true)
	data.silent_strike = r3
	check("silent strike: xp += xp_reward x (1 + %s %%) (broadhead %d)" % [str(silent_pct), want3], r3.killed and r3.silent and r3.xp == want3, str(r3))

	# 4. level-up: xp one below the next level (setup), one body kill
	var prog: Dictionary = g.get("progression")
	var lvl0 := int(prog.level)
	var next_total := _total_for(o, lvl0 + 1)
	g.call("set_progression", {"xp": next_total - 1})
	await ctx.frames(2)
	prog = g.get("progression")
	var pts0 := int(prog.points)
	var n_up: int = ups.events.size()
	await inp.equip("glock")
	var r4: Dictionary = await _kill_case(ctx, inp, kills, "watcher", "body", "glock", 6.0, base_dir)
	await ctx.frames(2)
	prog = g.get("progression")
	var notice: Control = inp.find_control("LevelUpNotice")
	var notice_vis: bool = notice != null and notice.is_visible_in_tree() and notice.modulate.a > 0.05
	var ppl: int = o.i(o.system("xp.points_per_level"))
	data.level_up = {"kill": r4, "xp_set": next_total - 1, "level": [lvl0, int(prog.level)], "points": [pts0, int(prog.points)], "level_up_signals": ups.events.slice(n_up).map(func(e): return [e.args[0], e.args[1]]), "notice_visible": notice_vis, "notice_text": str(notice.get("text")) if notice != null and "text" in notice else ""}
	check("crossing the level threshold (%d xp): level + 1, points + %d, level_up signal" % [next_total, ppl], r4.killed and int(prog.level) == lvl0 + 1 and int(prog.points) == pts0 + ppl and ups.events.size() > n_up, str(data.level_up))
	check("HUD level-up notice visible", notice_vis, str(data.level_up.notice_text))
	data.progression_end = prog
	return true


static func _xp(o, machine_type: String, weak: bool, silent: bool) -> int:
	var base: float = o.f(o.machine(machine_type, "xp_reward"))
	var pct := 0.0
	if weak:
		pct += o.f(o.system("xp.weak_spot_kill_bonus_pct"))
	if silent:
		pct += o.f(o.system("xp.silent_strike_bonus_pct"))
	return int(round(base * (1.0 + pct / 100.0)))


static func _total_for(o, level: int) -> int:
	## xp.level_curve arithmetic: level L -> L+1 costs first + step x (L - 1)... the cost of reaching level l is
	## first + step x (l - 1); total = sum over 1..level
	var c: Dictionary = o.system("xp.level_curve")
	var t := 0
	for l in range(1, level + 1):
		t += int(c.get("first", 0)) + int(c.get("step", 0)) * (l - 1)
	return t


func _kill_case(ctx, inp, kills, machine_type: String, part: String, weapon: String, dist: float, base_dir: Vector3) -> Dictionary:
	var g: Node = ctx.game
	var m: Node = await ctx.spawn_ahead(machine_type, dist, 0.0, false, base_dir)
	if m == null:
		return {"killed": false, "why": "spawn failed"}
	await ctx.wait(0.8)
	var xp0 := int(g.get("progression").xp)
	var n0: int = kills.events.size()
	var res: Dictionary
	if part == "body":
		# body: a body point whose shot line first meets a non-weak body hitbox (from the front a watcher's eye sits in
		# front of its body; lib/hitcheck.gd aim_body), turned onto by relative mouse motion; one press per shot
		res = {"shots": 0, "hits": 0, "aim_failed": 0}
		var interval: float = Combat.shot_interval(ctx, weapon)
		var t_end := Time.get_ticks_msec() + 40000
		while not Combat.is_dead(m) and int(res.shots) < 60 and Time.get_ticks_msec() < t_end:
			var a: Dictionary = await HitCheck.aim_body(ctx, inp, m)
			if not a.get("ok", false):
				res.aim_failed = int(res.aim_failed) + 1
				res.last_aim = str(a.get("by", a.get("why", "")))
				if int(res.aim_failed) >= 10:
					break
				await ctx.wait(0.2)
				continue
			var s: Dictionary = await Combat.shoot(ctx, inp, m)
			res.shots = int(res.shots) + 1
			res.hits = int(res.hits) + (1 if s.hit else 0)
			var ammo: Variant = Combat.ammo_of(ctx, weapon)
			if (ammo is Vector2i or ammo is Vector2) and int(ammo.x) == 0:
				await inp.tap("reload")
				await ctx.wait(3.0)
			await ctx.wait(interval)
	else:
		res = await Combat.kill(ctx, m, weapon, part, 60, 40.0)
	await ctx.wait_until(func(): return kills.events.size() > n0, 2.0)
	await ctx.frames(2)
	var ev: Array = kills.events.slice(n0)
	var out := {"machine": machine_type, "part": part, "weapon": weapon, "killed": not ev.is_empty(), "shots": res.get("shots"), "hits": res.get("hits"),
		"xp": int(g.get("progression").xp) - xp0}
	if res.has("aim_failed"):
		out.aim_failed = res.aim_failed
		if res.has("last_aim"):
			out.last_aim = res.last_aim
	if not ev.is_empty():
		out.signal = ev[0].args
		out.weak = bool(ev[0].args[2])
		out.silent = bool(ev[0].args[3])
	else:
		out.weak = false
		out.silent = false
	ctx.despawn(m)
	return out


func _silent_case(ctx, inp, kills, base_dir: Vector3) -> Dictionary:
	var g: Node = ctx.game
	var m: Node = await ctx.spawn_ahead("broadhead", 8.0, 0.0, false, base_dir)
	if m == null:
		return {"killed": false, "silent": false, "why": "spawn failed"}
	await ctx.wait(1.0)
	var state0 := str(m.get("state"))
	# setup: stand 1.1 m behind it (opposite its forward), at ground height
	var fwd: Vector3 = m.call("forward") if m.has_method("forward") else -(m as Node3D).global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var behind: Vector3 = (m as Node3D).global_position - fwd * 1.1
	var gy: Variant = await ctx.ground_y(behind.x, behind.z, behind.y + 50.0)
	behind.y = (float(gy) if gy != null else behind.y) + 0.05
	# the broadhead's own bounds: stand outside them
	var bx: AABB = load("res://autotest/lib/frame.gd").global_aabb(m)
	var half := maxf(bx.size.x, bx.size.z) * 0.5
	behind = (m as Node3D).global_position - fwd * (half + 0.5)
	behind.y = (float(gy) if gy != null else behind.y) + 0.05
	await ctx.call_api(g, "teleport", [behind])
	await ctx.wait(0.5)
	var xp0 := int(g.get("progression").xp)
	var n0: int = kills.events.size()
	var stabs := 0
	var reach: float = float(ctx.oracle.f(ctx.oracle.system("combat.knife_reach_m")))
	while stabs < 4 and kills.events.size() == n0 and is_instance_valid(m) and str(m.get("state")) != "dead":
		# the rear of its body at the body aim height (a plain body stab: the sheet's silent-strike XP has no weak bonus)
		var rear: Vector3 = (m as Node3D).global_position - fwd * half * 0.6
		rear.y = HitCheck.target_point(m, "body").y
		await inp.aim_at_point(rear, 0.002, 120)
		var h0 := float(m.get("health"))
		await inp.tap("alt_fire")
		stabs += 1
		await ctx.physics_frames(3)
		if is_instance_valid(m) and float(m.get("health")) >= h0:
			# out of reach: one step closer (setup)
			var to: Vector3 = (m as Node3D).global_position - ctx.player_pos()
			to.y = 0.0
			await ctx.call_api(g, "teleport", [ctx.player_pos() + to.normalized() * minf(0.4, maxf(to.length() - reach * 0.5, 0.0))])
		await ctx.wait(float(ctx.oracle.f(ctx.oracle.system("combat.knife_secondary_interval_s"))) + 0.1)
	await ctx.wait_until(func(): return kills.events.size() > n0, 2.0)
	var ev: Array = kills.events.slice(n0)
	var out := {"machine": "broadhead", "state_before": state0, "stabs": stabs, "stab_key": inp.describe("alt_fire"), "killed": not ev.is_empty(), "xp": int(g.get("progression").xp) - xp0}
	out.silent = not ev.is_empty() and bool(ev[0].args[3])
	out.weak = not ev.is_empty() and bool(ev[0].args[2])
	if not ev.is_empty():
		out.signal = ev[0].args
	ctx.despawn(m)
	return out
