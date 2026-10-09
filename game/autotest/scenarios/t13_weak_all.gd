extends "res://autotest/lib/scenario.gd"
## t13 Weak spot beats body for every machine (machines sheet rows), real shots through input from 8 directions.
## Per machine: AI off, spawned on open flat ground; the player (Desert Eagle, taken with its slot key) stands at
## 0, 45 ... 315 deg on a 10 m ring. At each position the camera is turned onto a weak point by relative mouse motion;
## a ray first checks that the FIRST thing a bullet meets is that weak spot (lib/hitcheck.gd; else the direction is
## blocked); then the fire button. A shot that misses or lands on the body is retried (3 shots max). Health is set
## very high before each shot (setup) so damage is not capped; one body shot from the same position for comparison.
##   weak = deagle.damage * headshot_mult * falloff (weak spots ignore armor); details: N/8 directions per machine.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const HitCheck := preload("res://autotest/lib/hitcheck.gd")
const Combat := preload("res://autotest/lib/combat.gd")
const Frame := preload("res://autotest/lib/frame.gd")

const WEAPON := "deagle"
const RING_M := 10.0
const SITE := Vector3(2582.0, 178.0, 780.0)  # open snow field south of FE_Antelope_Scout (cell 5,-2)
const BIG_HP := 100000.0


func _init() -> void:
	timeout_s = 3000.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "money"], ["spawn_machine", "teleport", "buy"]) + ctx.missing_api(p, ["inventory", "invulnerable"])):
		return false
	var o = ctx.oracle
	p.set("invulnerable", true)
	var inp = InputSim.new(ctx)
	# setup: own a Desert Eagle (bought through the API: buying is not under test here), take it with its slot key
	if not Array(p.get("inventory")).has(WEAPON):
		g.set("money", o.i(o.weapon(WEAPON, "price")))
		await ctx.call_api(g, "buy", [WEAPON])
	if not check("%s taken with its slot key" % WEAPON, await inp.equip(WEAPON), str(p.get("current_weapon"))):
		return false
	inp.capture_for_look()
	await ctx.call_api(g, "teleport", [SITE])
	var c: Variant = ctx.cell_of(SITE)
	var w: Variant = g.get("world") if "world" in g else null
	if w is Object and w.has_method("is_cell_loaded") and c != null:
		await ctx.wait_until(func(): return bool(w.call("is_cell_loaded", c)), 300.0)
	await ctx.wait(2.0)
	var gy: Variant = await ctx.ground_y(SITE.x, SITE.z)
	var center := Vector3(SITE.x, float(gy) if gy != null else SITE.y, SITE.z)
	var per := {}
	for mt in MachinesSheet.ROWS:
		per[mt] = await _machine(ctx, inp, g, o, mt, center)
	data.machines = per
	return true


func _machine(ctx, inp, g: Node, o, mt: String, center: Vector3) -> Dictionary:
	var info := {"directions": [], "hittable": 0}
	var m: Variant = await ctx.call_api(g, "spawn_machine", [mt, center])
	if not (m is Node):
		check("%s: spawn_machine works in this build" % mt, false, str(m))
		return info
	ctx.spawned.append(m)
	if "ai_enabled" in m:
		m.set("ai_enabled", false)
	await ctx.physics_frames(5)
	var weak_parts: Array = Array(await ctx.call_api(m, "weak_spots"))
	info.weak_spots = weak_parts
	if not check("%s: reports weak spots" % mt, not weak_parts.is_empty(), str(weak_parts)):
		return info
	var armor0: float = float(m.get("armor")) if "armor" in m else 0.0
	var dmg: float = o.num(o.weapon(WEAPON, "damage"))
	var hs: float = o.num(o.weapon(WEAPON, "headshot_mult"))
	var rm: float = o.num(o.weapon(WEAPON, "range_modifier"))
	var step: float = o.f(o.system("combat.range_step_u"))
	var u2m: float = o.f(o.system("combat.units_to_m"))
	var f := func(dist_m: float) -> float: return pow(rm, (dist_m / u2m) / step)
	var good := 0
	var formula_ok := 0
	var formula_bad := []
	for k in 8:
		var ang := deg_to_rad(45.0 * k)
		var pos: Vector3 = (m as Node3D).global_position + Vector3(sin(ang), 0.0, cos(ang)) * RING_M
		var gy: Variant = await ctx.ground_y(pos.x, pos.z)
		pos.y = float(gy) + 0.05 if gy != null else pos.y
		await ctx.call_api(g, "teleport", [pos])
		await ctx.physics_frames(4)
		var d := {"deg": 45 * k}
		# which weak point (of which part) is the first hit from here
		var target := {}
		for part in weak_parts:
			var pts: Array = []
			if m.has_method("weak_points"):
				pts = Array(m.call("weak_points", part))
			if pts.is_empty():
				pts = [HitCheck.target_point(m, part)]
			for pt in pts:
				var aim: Dictionary = await inp.aim_at_point(pt)
				await ctx.physics_frames(2)
				var fh: Dictionary = HitCheck.first_hit(ctx, m, pt, part)
				d.first_hit = fh.by
				if aim.get("ok", false) and fh.clear:
					target = {"part": part, "point": pt}
					break
			if not target.is_empty():
				break
		if target.is_empty():
			d.blocked = true
			info.directions.append(d)
			continue
		d.part = target.part
		var cam: Camera3D = ctx.camera()
		var dist: float = cam.global_position.distance_to(target.point) if cam != null else RING_M
		var exp_w: float = dmg * hs * f.call(dist)
		var tol: float = absf(dmg * hs * (f.call(maxf(0.0, dist - 0.75)) - f.call(dist + 0.75))) * 0.5 + 0.05
		# weak shot; a miss or a spread hit on the body (well below the weak value) is retried, 3 shots max
		var shot := {}
		var spread := []
		for attempt in 3:
			m.set("health", BIG_HP)
			if "armor" in m:
				m.set("armor", armor0)
			await inp.aim_at_point(target.point)
			shot = await Combat.shoot(ctx, inp, m)
			if shot.hit and float(shot.damage) >= 0.6 * exp_w:
				break
			spread.append(snappedf(float(shot.get("damage", 0.0)), 0.01))
			await ctx.wait(Combat.shot_interval(ctx, WEAPON))
		d.spread_shots = spread
		d.weak_damage = snappedf(float(shot.get("damage", 0.0)), 0.01)
		d.weak_expected = snappedf(exp_w, 0.01)
		d.tolerance = snappedf(tol, 0.01)
		# body shot from the same position
		await ctx.wait(Combat.shot_interval(ctx, WEAPON))
		m.set("health", BIG_HP)
		if "armor" in m:
			m.set("armor", armor0)
		var bp: Vector3 = HitCheck.target_point(m, "body")
		await inp.aim_at_point(bp)
		var body: Dictionary = await Combat.shoot(ctx, inp, m)
		d.body_damage = snappedf(float(body.get("damage", 0.0)), 0.01)
		var weak_ok: bool = float(d.weak_damage) > float(d.body_damage) and float(d.weak_damage) > 0.0
		if weak_ok:
			good += 1
		if absf(float(d.weak_damage) - exp_w) <= tol:
			formula_ok += 1
		else:
			formula_bad.append("%d deg: %s vs %s" % [45 * k, str(d.weak_damage), str(d.weak_expected)])
		info.directions.append(d)
		await ctx.wait(Combat.shot_interval(ctx, WEAPON))
	info.hittable = good
	note("%s: weak spot first hit and beating the body from %d/8 directions" % [mt, good])
	check("%s: >= 1 direction where the weak spot is the first hit and weak > body (%d/8)" % [mt, good], good >= 1, str(info.directions.map(func(x): return [x.deg, x.get("part", "blocked"), x.get("weak_damage", "-"), x.get("body_damage", "-")])))
	check("%s: weak damage == deagle.damage * headshot_mult * falloff on every hit direction" % mt, formula_bad.is_empty() and formula_ok >= 1, "; ".join(formula_bad) if not formula_bad.is_empty() else "%d ok" % formula_ok)
	return info
