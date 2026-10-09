extends "res://autotest/lib/scenario.gd"
## t04 Weak spot deals more than body. Glock at two AI-disabled Watchers 10 m ahead (full health and armor):
##   weak = damage * headshot_mult * falloff            (D4, weak spots ignore armor)
##   body = damage * armor_ratio * armor_ratio_scale * falloff   (CS armor rule while the machine has armor)
##   falloff = range_modifier ^ (distance_u / combat.range_step_u)   (systems sheet; = 1 at 0 m)
## Every machine type must report >= 1 weak spot.

const Combat := preload("res://autotest/lib/combat.gd")
const DIST_M := 10.0


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player"], ["equip", "spawn_machine", "aim_at", "fire"])):
		return false
	var o = ctx.oracle
	await Combat.equip(ctx, "glock")
	var base: Vector3 = ctx.forward()
	var a: Node = await ctx.spawn_ahead("watcher", DIST_M, -6.0, false, base)
	var b: Node = await ctx.spawn_ahead("watcher", DIST_M, 6.0, false, base)
	if not check("spawn two watchers", a != null and b != null):
		return false
	if not api_check(ctx.missing_api(a, ["health", "state"], ["weak_spots"])):
		return false
	await ctx.physics_frames(3)
	var full: float = o.f(o.machine("watcher", "health"))
	check("setup: watchers at full health %s" % str(full), is_equal_approx(float(a.get("health")), full) and is_equal_approx(float(b.get("health")), full), "A %s B %s" % [str(a.get("health")), str(b.get("health"))])
	if "armor" in a:
		data.armor_before = [a.get("armor"), b.get("armor")]

	var weak_names: Array = Array(await ctx.call_api(b, "weak_spots"))
	var sheet_parts: Array = o.machine("watcher", "weak_spot_parts")
	var weak := ""
	for s in sheet_parts:
		if weak_names.has(s):
			weak = s
			break
	if weak == "" and not weak_names.is_empty():
		weak = str(weak_names[0])
	data.watcher_weak_spots = weak_names

	var shot_a := await _shot(ctx, a, "body")
	await ctx.wait(Combat.shot_interval(ctx, "glock"))
	var shot_b := await _shot(ctx, b, weak)
	data.body_shot = shot_a
	data.weak_shot = shot_b

	var dmg: float = o.num(o.weapon("glock", "damage"))
	var hs: float = o.num(o.weapon("glock", "headshot_mult"))
	var ar: float = o.num(o.weapon("glock", "armor_ratio"))
	var ars: float = o.f(o.system("combat.armor_ratio_scale"))
	var rm: float = o.num(o.weapon("glock", "range_modifier"))
	var step: float = o.f(o.system("combat.range_step_u"))
	var u2m: float = o.f(o.system("combat.units_to_m"))
	data.naive = {"weak": dmg * hs, "body": dmg * ar * ars, "note": "sheet numbers without range falloff (0 m)"}
	var ok_a := check("body shot hits A on body", shot_a.hit == true and shot_a.target_ok and str(shot_a.part) == "body", str(shot_a))
	var ok_b := check("weak shot hits B on %s" % weak, shot_b.hit == true and shot_b.target_ok and str(shot_b.part) == weak, str(shot_b))
	if not (ok_a and ok_b):
		return false
	var body := float(shot_a.damage)
	var wk := float(shot_b.damage)
	check("weak damage > body damage", wk > body, "%s > %s" % [str(wk), str(body)])
	var exp_w := _expect(dmg * hs, rm, step, u2m, shot_b)
	var exp_b := _expect(dmg * ar * ars, rm, step, u2m, shot_a)
	data.expected = {"weak": exp_w, "body": exp_b}
	check("weak == glock.damage * headshot_mult * falloff (%s)" % str(exp_w.value), absf(wk - exp_w.value) <= exp_w.tol, "weak %s, tolerance %s" % [str(wk), str(exp_w.tol)])
	check("body == glock.damage * armor_ratio * armor_ratio_scale * falloff (%s) while armor > 0" % str(exp_b.value), absf(body - exp_b.value) <= exp_b.tol, "body %s, tolerance %s" % [str(body), str(exp_b.tol)])
	check("A lost exactly the reported body damage", absf(shot_a.health_lost - body) <= 0.01, "health lost %s" % str(shot_a.health_lost))
	check("B lost exactly the reported weak damage", absf(shot_b.health_lost - minf(wk, shot_b.health_before)) <= 0.01, "health lost %s" % str(shot_b.health_lost))

	var per_type := {"watcher": weak_names}
	for t in ["strider", "grazer"]:
		var m: Node = await ctx.spawn_ahead(t, 14.0, 30.0 if t == "strider" else -30.0, false, base)
		per_type[t] = Array(await ctx.call_api(m, "weak_spots")) if m != null else []
	data.weak_spots = per_type
	for t in per_type:
		var ws: Array = per_type[t]
		var sheet: Array = o.machine(t, "weak_spot_parts")
		check("%s reports >= 1 weak spot (sheet: %s)" % [t, str(sheet)], not ws.is_empty() and sheet.all(func(s): return ws.has(s)), str(ws))
	return true


func _shot(ctx, m: Node, part: String) -> Dictionary:
	var before := float(m.get("health"))
	await ctx.call_api(ctx.game, "aim_at", [m, part])
	await ctx.physics_frames(2)
	var cam: Camera3D = ctx.camera()
	var cam_pos: Vector3 = cam.global_position if cam != null else ctx.player_pos()
	var r: Variant = await ctx.call_api(ctx.game, "fire")
	await ctx.physics_frames(2)
	var d: Dictionary = r if r is Dictionary else {}
	var after := float(m.get("health")) if is_instance_valid(m) else 0.0
	var dist := -1.0
	var exact := false
	if d.get("distance") != null:
		dist = float(d.distance)
		exact = true
	elif d.get("point") is Vector3:
		dist = cam_pos.distance_to(d.point)
		exact = true
	else:
		dist = cam_pos.distance_to((m as Node3D).global_position)
	return {"hit": d.get("hit"), "part": d.get("part"), "damage": d.get("damage"), "target_ok": d.get("target") == m,
		"health_before": before, "health_lost": before - after, "distance_m": snappedf(dist, 0.01), "distance_exact": exact}


func _expect(base: float, rm: float, step: float, u2m: float, shot: Dictionary) -> Dictionary:
	## expected damage at the shot distance; without an exact hit distance allow +-1.5 m around the estimate
	var d: float = shot.distance_m
	var f := func(m: float) -> float: return base * pow(rm, (m / u2m) / step)
	var v: float = f.call(d)
	var tol := 0.05
	if not shot.distance_exact:
		tol = maxf(absf(f.call(maxf(0.0, d - 1.5)) - v), absf(f.call(d + 1.5) - v)) + 0.05
	return {"value": snappedf(v, 0.01), "tol": snappedf(tol, 0.01), "distance_m": d}
