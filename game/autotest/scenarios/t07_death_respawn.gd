extends "res://autotest/lib/scenario.gd"
## t07 Death: weapons lost, knife + Glock back, money kept, respawn at the last campfire.
## Campfire A (start) then campfire B in another cell becomes last_campfire_id; buy ak47 + hegrenade + kevlar;
## money 5000; 60 m away; Game.kill_player() (normal damage path); wait for player_respawned.


func _init() -> void:
	timeout_s = 1800.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "money", "last_campfire_id", "machines"], ["teleport", "campfires_near", "buy", "kill_player"], ["player_died", "player_respawned"]) + ctx.missing_api(p, ["inventory", "health", "armor"])):
		return false
	var o = ctx.oracle
	var start_id := _start_campfire_id(ctx)
	var fires: Array = _norm(ctx, await ctx.call_api(g, "campfires_near", [ctx.player_pos(), 6000.0]))
	data.campfires_found = fires.size()
	if not check("campfires_near returns >= 2 campfires", fires.size() >= 2, str(fires.slice(0, 5))):
		return false
	var a: Dictionary = {}
	for f in fires:
		if f.id == start_id:
			a = f
	if a.is_empty():
		note("start campfire %s not among campfires_near; using the nearest" % start_id)
		a = fires[0]
	var b: Dictionary = {}
	var best := INF
	for f in fires:
		if f.id != a.id and f.cell != a.cell:
			var d: float = (f.pos as Vector3).distance_to(a.pos)
			if d < best:
				best = d
				b = f
	if b.is_empty():
		note("no campfire in another cell; using another campfire in the same cell")
		for f in fires:
			if f.id != a.id:
				b = f
				break
	data.campfire_a = {"id": a.id, "pos": str(a.pos), "cell": str(a.cell)}
	data.campfire_b = {"id": b.id, "pos": str(b.pos), "cell": str(b.cell)}

	for f in [a, b]:
		await ctx.call_api(g, "teleport", [(f.pos as Vector3) + Vector3(1.5, 0.5, 0.0)])
		var got: bool = await ctx.wait_until(func(): return str(g.get("last_campfire_id")) == f.id, 300.0)
		check("walking next to campfire %s makes it last_campfire_id" % f.id, got, "last_campfire_id %s" % str(g.get("last_campfire_id")))

	# loadout to lose: ak47, hegrenade, kevlar through the normal buy path
	var want := {"ak47": true, "hegrenade": true, "kevlar": true}
	var inv: Array = Array(p.get("inventory"))
	if inv.has("ak47"):
		want.erase("ak47")
	if inv.has("hegrenade"):
		want.erase("hegrenade")
	if float(p.get("armor")) >= o.f(o.weapon("kevlar", "armor_points")):
		want.erase("kevlar")
	var cost := 0
	for id in want:
		cost += o.i(o.weapon(id, "price"))
	g.set("money", cost)
	await ctx.frames(1)
	for id in want:
		check("setup: buy(%s)" % id, (await ctx.call_api(g, "buy", [id])) == true)
	inv = Array(p.get("inventory"))
	data.before_death = {"inventory": inv, "armor": p.get("armor"), "health": p.get("health")}
	check("setup: carrying ak47 + hegrenade with armor > 0", inv.has("ak47") and inv.has("hegrenade") and float(p.get("armor")) > 0.0, str(data.before_death))
	g.set("money", 5000)
	var away: Vector3 = (b.pos as Vector3) + Vector3(60.0, 0.0, 0.0)
	var gy: Variant = await ctx.ground_y(away.x, away.z)
	away.y = float(gy) + 0.1 if gy != null else (b.pos as Vector3).y + 1.0
	await ctx.call_api(g, "teleport", [away])
	await ctx.physics_frames(3)
	data.death_pos = str(ctx.player_pos())

	var died = ctx.record(g, "player_died")
	var resp = ctx.record(g, "player_respawned")
	await ctx.call_api(g, "kill_player")
	var delay: float = o.f(o.system("respawn.delay_s"))
	var ok: bool = await ctx.wait_until(func(): return not resp.events.is_empty(), delay + 20.0)
	await ctx.physics_frames(3)
	check("player_died then player_respawned", not died.events.is_empty() and ok and died.events[0].t <= resp.events[0].t, "died %d, respawned %d" % [died.events.size(), resp.events.size()])
	if not ok:
		return false
	var cf_id := str(resp.events[0].args[0])
	var inv2: Array = Array(p.get("inventory")).map(func(x): return str(x))
	var start_inv: Array = o.start_loadout()
	var s1 := inv2.duplicate()
	s1.sort()
	var s2 := start_inv.duplicate()
	s2.sort()
	var dist: float = ctx.player_pos().distance_to(b.pos)
	var radius: float = o.f(o.system("respawn.campfire_activate_radius_m"))
	var hp: float = o.f(o.system("respawn.health"))
	data.after_respawn = {"campfire_id": cf_id, "inventory": inv2, "armor": p.get("armor"), "money": g.get("money"), "health": p.get("health"), "distance_to_b_m": snappedf(dist, 0.01), "respawn_delay_s": snappedf(resp.events[0].t - died.events[0].t, 0.01)}
	check("player_respawned campfire_id == B (%s)" % b.id, cf_id == b.id, cf_id)
	check("inventory == start loadout %s" % str(start_inv), s1 == s2, str(inv2))
	check("armor == 0", float(p.get("armor")) == 0.0, str(p.get("armor")))
	check("money == 5000 (kept)", int(g.get("money")) == 5000, str(g.get("money")))
	check("distance(player, B) <= respawn.campfire_activate_radius_m (%s)" % str(radius), dist <= radius, "%.2f m" % dist)
	check("health == respawn.health (%s)" % str(hp), is_equal_approx(float(p.get("health")), hp), str(p.get("health")))
	var near: float = o.f(o.system("spawning.activation_radius_m"))
	var busy := []
	for m in g.get("machines"):
		if is_instance_valid(m) and str(m.get("state")) in ["alert", "attack"] and (m as Node3D).global_position.distance_to(b.pos) <= near:
			busy.append("%s %s %.0f m" % [m.get("machine_type"), m.get("state"), (m as Node3D).global_position.distance_to(b.pos)])
	check("no machine in alert or attack within %d m of the respawn" % int(near), busy.is_empty(), str(busy))
	return true


func _start_campfire_id(ctx) -> String:
	var idx: Dictionary = ctx.oracle.index_json()
	if str(idx.get("start_campfire", "")) != "":
		return str(idx.start_campfire)
	return str(ctx.oracle.system("respawn.start_campfire"))


func _norm(ctx, raw: Variant) -> Array:
	## campfires_near items as {id, pos, cell}; accepts dictionaries or nodes
	var out := []
	if not (raw is Array):
		return out
	for c in raw:
		var id := ""
		var pos := Vector3.INF
		var cell: Variant = null
		if c is Dictionary:
			id = str(c.get("id", ""))
			pos = ctx.v3(c.get("pos"))
			cell = c.get("cell")
		elif c is Node3D:
			id = str(c.get("campfire_id")) if "campfire_id" in c else str(c.get("id")) if "id" in c else str(c.name)
			pos = (c as Node3D).global_position
			cell = c.get("cell") if "cell" in c else null
		if id == "" or pos == Vector3.INF:
			continue
		if cell == null:
			cell = ctx.cell_of(pos)
		out.append({"id": id, "pos": pos, "cell": ctx.v2i(cell) if cell != null else Vector2i(int(floor(pos.x / 512.0)), int(floor(-pos.z / 512.0)))})
	out.sort_custom(func(x, y): return (x.pos as Vector3).distance_to(ctx.player_pos()) < (y.pos as Vector3).distance_to(ctx.player_pos()))
	return out
