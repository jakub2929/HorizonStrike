extends "res://autotest/lib/scenario.gd"
## t06 Herd flees on alert: a Grazer herd (>= herd_size_min) 30 m away, AI on, player crouched and undetected;
## one Glock shot into the air (noise radius weapons.glock.suspicion_radius_m). Within 3 s every member flees,
## after 10 s the mean distance grew by >= 30 m, and no Grazer damaged the player.

const Combat := preload("res://autotest/lib/combat.gd")
const InputSim := preload("res://autotest/lib/inputsim.gd")
const Sites := preload("res://autotest/lib/sites.gd")

const DIST_M := 30.0
const FLEE_WITHIN_S := 3.0
const WAIT_S := 10.0
const GROW_M := 30.0


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "machines"], ["teleport", "aim_at", "fire", "equip", "spawn_machine"]) + ctx.missing_api(p, ["health"])):
		return false
	var o = ctx.oracle
	var need: int = o.i(o.machine("grazer", "herd_size_min"))
	var herd: Array = await _find_herd(ctx, need)
	if not check("herd of >= %d grazers" % need, herd.size() >= need, "%d" % herd.size()):
		return false
	for m in herd:
		if "ai_enabled" in m:
			ctx.set_ai(m, true)
	var calm := ["idle", "patrol", "graze", "scavenge"]
	if not herd.all(func(m): return calm.has(str(m.get("state")))):
		# the herd is still disturbed (an earlier scenario): step 150 m away and give it up to 90 s to calm down
		var away: Vector3 = _centroid(herd) + Vector3(150.0, 0.0, 0.0)
		var gy: Variant = await ctx.ground_y(away.x, away.z)
		away.y = float(gy) + 0.3 if gy != null else away.y + 30.0
		await ctx.call_api(g, "teleport", [away])
		var calmed: bool = await ctx.wait_until(func(): return herd.all(func(m): return is_instance_valid(m) and calm.has(str(m.get("state")))), 90.0)
		note("herd was disturbed at arrival; calm after waiting: %s" % str(calmed))
	var sus_thr: float = o.f(o.machine("grazer", "suspicious_threshold"))
	# crouch before approaching; if a grazer still notices the player while being placed (sight is probabilistic at
	# this distance), back off, let the herd calm down and place again (up to 3 attempts)
	await _crouch(ctx, p, true)
	check("glock taken with its slot key", await Combat.equip(ctx, "glock"), "current %s" % str(p.get("current_weapon")))
	var placed: Dictionary = {}
	for attempt in 3:
		var center := _centroid(herd)
		placed = await Sites.place_player_facing(ctx, center, DIST_M, ctx.player_pos() - center)
		await _crouch(ctx, p, true)
		await ctx.wait(0.5)
		if herd.all(func(m): return calm.has(str(m.get("state"))) and float(m.get("suspicion")) < sus_thr):
			break
		note("attempt %d: herd noticed the player during setup; backing off" % (attempt + 1))
		var back: Vector3 = _centroid(herd) + (ctx.player_pos() - _centroid(herd)).normalized() * 150.0
		var by: Variant = await ctx.ground_y(back.x, back.z)
		back.y = float(by) + 0.3 if by != null else back.y + 30.0
		await ctx.call_api(g, "teleport", [back])
		await ctx.wait_until(func(): return herd.all(func(m): return is_instance_valid(m) and calm.has(str(m.get("state"))) and float(m.get("suspicion")) < sus_thr * 0.5), 90.0)
	data.placement = {"distance_m": DIST_M, "line_of_sight": placed.get("los")}

	var before := herd.map(func(m): return {"state": str(m.get("state")), "suspicion": m.get("suspicion")})
	data.herd_before = before
	check("setup: herd undetected (calm states, suspicion < %s)" % str(sus_thr), herd.all(func(m): return calm.has(str(m.get("state"))) and float(m.get("suspicion")) < sus_thr), str(before))
	var d0 := _mean_dist(ctx, herd)
	var health0 := float(p.get("health"))
	var dmg_rec = ctx.record(g, "player_damaged")
	var hud_rec = ctx.record(g, "hud_message")
	var died_rec = ctx.record(g, "player_died")

	# expected suspicion from the shot at the herd distance (systems suspicion.shot_gain_*), for the details
	var radius: float = o.f(o.weapon("glock", "suspicion_radius_m"))
	var gc: float = o.f(o.system("suspicion.shot_gain_center"))
	var ge: float = o.f(o.system("suspicion.shot_gain_edge"))
	data.design_shot_gain_at_herd = snappedf(gc - (gc - ge) * clampf(d0 / radius, 0.0, 1.0), 0.001) if d0 <= radius else 0.0
	data.alert_threshold = o.machine("grazer", "alert_threshold")

	var marker := Node3D.new()
	marker.name = "AutotestSkyMarker"
	ctx.runner.add_child(marker)
	marker.global_position = ctx.player_pos() + Vector3(0, 60, 0) + ctx.forward() * 5.0
	await ctx.call_api(g, "aim_at", [marker, "body"])
	await ctx.physics_frames(2)
	var ammo0: Variant = Combat.ammo_of(ctx, "glock")
	await _inp(ctx).tap("fire")
	await ctx.physics_frames(2)
	var ammo1: Variant = Combat.ammo_of(ctx, "glock")
	marker.queue_free()
	data.shot = {"fire_key": _inp(ctx).describe("fire"), "ammo": [str(ammo0), str(ammo1)]}
	check("fire button fired the Glock into the air (one round used)", ammo0 is Vector2i and ammo1 is Vector2i and (ammo1 as Vector2i).x == (ammo0 as Vector2i).x - 1, "ammo %s -> %s" % [str(ammo0), str(ammo1)])
	var t_shot := Time.get_ticks_msec()
	var fled_at := {}
	while (Time.get_ticks_msec() - t_shot) / 1000.0 < WAIT_S:
		await ctx.frames(1)
		var t := (Time.get_ticks_msec() - t_shot) / 1000.0
		for i in herd.size():
			if not fled_at.has(i) and is_instance_valid(herd[i]) and str(herd[i].get("state")) == "flee":
				fled_at[i] = snappedf(t, 0.01)
	var d1 := _mean_dist(ctx, herd)
	data.fled_at_s = fled_at
	data.states_after = herd.map(func(m): return str(m.get("state")) if is_instance_valid(m) else "freed")
	data.mean_distance_m = [snappedf(d0, 0.1), snappedf(d1, 0.1)]
	var all_fast := fled_at.size() == herd.size() and fled_at.values().all(func(t): return t <= FLEE_WITHIN_S)
	check("within %d s every herd member state == flee" % int(FLEE_WITHIN_S), all_fast, "%d/%d fled, times %s" % [fled_at.size(), herd.size(), str(fled_at.values())])
	check("after %d s the mean distance grew by >= %d m" % [int(WAIT_S), int(GROW_M)], d1 - d0 >= GROW_M, "%.1f -> %.1f m" % [d0, d1])
	var hits: Array = ctx.hit_evidence(dmg_rec, hud_rec)
	var grazer_hits := hits.filter(func(h): return str(h).to_lower().contains("grazer"))
	data.player_hits = hits
	check("no grazer damaged the player", grazer_hits.is_empty(), "grazer hits %s; all hits %s; health %s -> %s" % [str(grazer_hits), str(hits), str(health0), str(p.get("health"))])
	check("player alive through the scenario (distances are meaningful)", not died_rec_has_events(died_rec), "player_died %d" % died_rec.events.size())
	await _crouch(ctx, p, false)
	return true


func _find_herd(ctx, need: int) -> Array:
	# a herd without guards nearby: a Watcher guarding the herd would alert it and attack the player (setup noise)
	var site: Dictionary = Sites.find_site(ctx, "grazer", need, ["watcher"])
	if site.is_empty():
		site = Sites.find_site(ctx, "grazer", need)
	if not site.is_empty():
		data.site = {"cell": str(site.cell), "site": site.site, "orig_type": site.orig_type, "count": site.count}
		var found: Array = await Sites.go_near_site(ctx, site, "grazer", need)
		check("grazer herd present at the real site %s" % site.site, found.size() >= need, "%d found" % found.size())
		return found
	note("no grazer herd site in cache cells %s (mock data?) - spawned %d grazers" % [str(Sites.SITE_CELLS), need])
	data.site = {"spawned": true}
	var out := []
	for i in need:
		var m: Node = await ctx.spawn_ahead("grazer", DIST_M + 3.0 * i, -10.0 + 10.0 * i, true)
		if m != null:
			out.append(m)
	return out


var _inp_obj = null


func _inp(ctx):
	if _inp_obj == null:
		_inp_obj = InputSim.new(ctx)
	return _inp_obj


func _crouch(ctx, p: Node, on: bool) -> void:
	## the player's crouch key, held down while crouched (simulated input event), released afterwards
	var inp = _inp(ctx)
	if inp.binding("crouch") == null:
		data.crouch = "unavailable"
		if on:
			note("the game binds no crouch key - stood instead")
	else:
		if on:
			inp.press("crouch")
		else:
			inp.release("crouch")
		data.crouch = "crouch key %s held" % inp.describe("crouch")
	await ctx.physics_frames(3)
	if on:
		for k in ["crouched", "crouching"]:
			if k in p:
				check("setup: player crouched (%s)" % data.crouch, p.get(k) == true, "player.%s = %s" % [k, str(p.get(k))])
				break


static func _centroid(ms: Array) -> Vector3:
	var c := Vector3.ZERO
	for m in ms:
		c += (m as Node3D).global_position
	return c / maxf(1.0, ms.size())


static func _mean_dist(ctx, ms: Array) -> float:
	var pp: Vector3 = ctx.player_pos()
	var s := 0.0
	var n := 0
	for m in ms:
		if is_instance_valid(m):
			s += (m as Node3D).global_position.distance_to(pp)
			n += 1
	return s / maxf(1.0, n)


static func died_rec_has_events(rec) -> bool:
	return not rec.events.is_empty()
