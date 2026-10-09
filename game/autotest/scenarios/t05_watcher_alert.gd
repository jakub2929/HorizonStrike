extends "res://autotest/lib/scenario.gd"
## t05 Watcher: suspicious -> alert -> attack, at a real Watcher site (cells [5,-2] / [3,-2]); hosts s02 (screenshot
## at the first alert). The player stands 35 m away facing the Watcher, invulnerable (damage is still observed).

const Frame := preload("res://autotest/lib/frame.gd")
const Sites := preload("res://autotest/lib/sites.gd")
const Scn := preload("res://autotest/lib/scenario.gd")

const START_M := 35.0
const CLOSE_M := 10.0
const WATCH_S := 25.0
const WALK_AFTER_S := 15.0
const S02_MIN_FRAC := 0.15

var s02 = null
var s02_retake := false


func _init() -> void:
	timeout_s = 1800.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "machines"], ["teleport", "aim_at", "spawn_machine"], ["machine_state_changed"]) + ctx.missing_api(p, ["health", "invulnerable"])):
		return false
	if ctx.wanted.has("s02"):
		s02 = Scn.new()
	var w: Node = await _find_watcher(ctx)
	if not check("a watcher to test", w != null):
		return false
	if not api_check(ctx.missing_api(w, ["state", "suspicion", "ai_enabled"])):
		return false
	w.set("ai_enabled", true)
	p.set("invulnerable", true)
	var placed: Dictionary = await Sites.place_player_facing(ctx, (w as Node3D).global_position, START_M, ctx.player_pos() - (w as Node3D).global_position)
	data.placement = {"distance_m": START_M, "line_of_sight": placed.get("los"), "pos": str(placed.get("pos"))}
	await ctx.call_api(g, "aim_at", [w, "body"])

	var rec = ctx.record(g, "machine_state_changed")
	var dmg_rec = ctx.record(g, "player_damaged")
	var hud_rec = ctx.record(g, "hud_message")
	var health0 := float(p.get("health"))
	var initial := str(w.get("state"))
	var polled: Array = [initial]
	var proj_max := 0
	var walked := false
	var t0 := Time.get_ticks_msec()
	var attack_t := -1.0
	var hit_seen := false
	var next_aim := 0.5
	while (Time.get_ticks_msec() - t0) / 1000.0 < WATCH_S:
		await ctx.frames(1)
		var t := (Time.get_ticks_msec() - t0) / 1000.0
		var st := str(w.get("state"))
		if st != polled[polled.size() - 1]:
			polled.append(st)
			ctx.note("t05 %.1f s: watcher %s (suspicion %s, %.1f m)" % [t, st, str(w.get("suspicion")), ctx.player_pos().distance_to((w as Node3D).global_position)])
		if st == "alert" and s02 != null and not data.has("s02_first_alert"):
			data.s02_first_alert = true
			await _capture_s02(ctx, w, "first alert in t05")
		if st == "attack" and attack_t < 0.0:
			attack_t = t
		proj_max = maxi(proj_max, _projectiles(ctx))
		if float(p.get("health")) < health0 or not ctx.hit_evidence(dmg_rec, hud_rec).is_empty():
			hit_seen = true
		if not walked and t >= WALK_AFTER_S and attack_t < 0.0:
			walked = true
			var to_w: Vector3 = (w as Node3D).global_position - ctx.player_pos()
			await Sites.place_player_facing(ctx, (w as Node3D).global_position, CLOSE_M, -to_w)
			ctx.note("t05: no attack after %d s, moved to %d m" % [int(WALK_AFTER_S), int(CLOSE_M)])
		if t >= next_aim:
			next_aim = t + 0.5
			await ctx.call_api(g, "aim_at", [w, "body"])
		if attack_t >= 0.0 and (hit_seen or proj_max > 0) and t > attack_t + 1.0:
			break

	var states: Array = [initial]
	for e in rec.events:
		if e.args[0] == w:
			states.append(str(e.args[2]))
	data.initial_state = initial
	data.states_signal = states
	data.states_polled = polled
	data.walked_to_10m = walked
	data.attack_after_s = attack_t
	data.projectiles_seen = proj_max
	data.player_hits = ctx.hit_evidence(dmg_rec, hud_rec)
	data.player_health = [health0, float(p.get("health"))]
	data.suspicion_threshold = ctx.oracle.machine("watcher", "suspicious_threshold")
	check("ordered states contain (idle|patrol) -> suspicious -> alert -> attack", _ordered(states), str(states))
	check("machine_state_changed agrees with the polled states", polled.all(func(s): return states.has(s)), "signal %s, polled %s" % [str(states), str(polled)])
	check("an attack hit the player or spawned a projectile within %d s" % int(WATCH_S), attack_t >= 0.0 and (hit_seen or proj_max > 0), "attack at %s s, hit %s, projectiles %d" % [str(attack_t), str(hit_seen), proj_max])
	if not g.has_signal("player_damaged"):
		note("Game signal player_damaged missing: a hit on the invulnerable player is only visible as a health drop")

	if s02 != null and (s02_retake or not s02.finished):
		await _s02_retake(ctx, g)
	w.set("ai_enabled", false)
	p.set("invulnerable", false)
	return true


func _find_watcher(ctx) -> Node:
	var site: Dictionary = Sites.find_site(ctx, "watcher")
	data.site = site.duplicate()
	if not site.is_empty():
		data.site.pos = str(site.pos)
		var found: Array = await Sites.go_near_site(ctx, site, "watcher", 1)
		check("watcher present at the real site %s in cell %s" % [site.site, str(site.cell)], not found.is_empty(), "%d found" % found.size())
		if found.is_empty():
			return null
		found.sort_custom(func(a, b): return (a as Node3D).global_position.distance_to(site.pos) < (b as Node3D).global_position.distance_to(site.pos))
		return found[0]
	note("no watcher site in cache cells %s (mock data?) - spawned one %d m ahead" % [str(Sites.SITE_CELLS), int(START_M)])
	data.site = {"spawned": true}
	return await ctx.spawn_ahead("watcher", START_M, 0.0, true)


static func _ordered(states: Array) -> bool:
	var want := [["idle", "patrol"], ["suspicious"], ["alert"], ["attack"]]
	var k := 0
	for s in states:
		if k < want.size() and want[k].has(s):
			k += 1
	return k == want.size()


static func _projectiles(ctx) -> int:
	var n := 0
	for grp in ["machine_projectiles", "projectiles"]:
		n += ctx.tree.get_nodes_in_group(grp).size()
	return n


func _capture_s02(ctx, w: Node, how: String) -> void:
	var state_at := str(w.get("state"))
	var shot: Dictionary = await ctx.screenshot("watcher_alert.png")
	var cam: Camera3D = ctx.camera()
	var box := Frame.global_aabb(w)
	var sb: Dictionary = Frame.screen_box(cam, box) if cam != null else {}
	s02.checks.clear()
	s02.data = {"capture": how, "screenshot": shot, "screen_box": sb, "state_at_capture": state_at}
	s02.check("file exists (fresh)", shot.get("exists", false) and shot.get("fresh", false), shot.get("path"))
	s02.check("not blank (luma stddev > 10)", float(shot.get("luma_stddev", 0.0)) > 10.0, str(shot.get("luma_stddev")))
	s02.check("watcher screen box height >= %d%% of the frame" % int(S02_MIN_FRAC * 100), float(sb.get("frac_h", 0.0)) >= S02_MIN_FRAC and sb.get("center_in_frustum", false), "%s at %s m" % [str(sb.get("frac_h")), str(sb.get("distance_m"))])
	s02.check("watcher state == alert at capture", state_at == "alert", state_at)
	s02.finished = true
	ctx.extra_results["s02"] = s02.result()
	s02_retake = not s02.passed() and how == "first alert in t05"
	if s02_retake:
		ctx.note("s02: first-alert capture does not meet the criteria (frac_h %s); retake after t05" % str(sb.get("frac_h")))


func _s02_retake(ctx, g: Node) -> void:
	## the first alert happened too far away for a readable frame: a fresh Watcher 9 m ahead, AI on, until alert
	var w2: Node = await ctx.spawn_ahead("watcher", 9.0, 0.0, true)
	if w2 == null:
		return
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline and str(w2.get("state")) != "alert":
		await ctx.call_api(g, "aim_at", [w2, "body"])
		await ctx.frames(1)
	if str(w2.get("state")) == "alert":
		await _capture_s02(ctx, w2, "retake: watcher spawned 9 m ahead")
	else:
		s02.note("retake: watcher did not reach alert within 20 s (state %s)" % str(w2.get("state")))
		s02.finished = true
		ctx.extra_results["s02"] = s02.result()
	w2.set("ai_enabled", false)
