extends "res://autotest/lib/scenario.gd"
## t12 New machines: suspicious -> alert -> attack for Sawtooth, Scrapper and Broadhead (sheet t12).
## Setup per machine (Game API): open snow field, machine spawned with AI on (Broadhead: two of them 6 m apart, the
## second one must leave graze when the first is attacked), player invulnerable 35 m away (Sawtooth 45 m), facing it.
## Behaviour by input only: held W towards the machine until it is suspicious, the view kept on it by mouse motion;
## if there is no alert 10 s after that, one glock shot into the air (look up + fire button); alert but no attack
## 8 s later (a defend_charge herd only charges a threat inside fight_back_radius_m): held W towards it again.
## machine_state_changed, machine.current_attack and machine projectiles are logged for 30 s per machine.
## States: stalk (Sawtooth) is a sub-state of alert (game: alert -> stalk -> attack), scavenge (Scrapper) is calm.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const Sites := preload("res://autotest/lib/sites.gd")

const SITE := Vector3(2582.0, 178.0, 780.0)  # open snow field south of FE_Antelope_Scout (cell 5,-2), as t13
const WATCH_S := 30.0
const WALK_MAX_S := 20.0
const SHOT_AFTER_S := 10.0
const MACHINES := {"sawtooth": 45.0, "scrapper": 35.0, "broadhead": 35.0}
const CALM := ["idle", "patrol", "graze", "scavenge"]
const WARY := ["suspicious"]
const ALERT := ["alert", "stalk"]
const HOT := ["alert", "stalk", "attack"]
const APPROACH_AFTER_S := 8.0


func _init() -> void:
	timeout_s = 1800.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player"], ["spawn_machine", "teleport"], ["machine_state_changed"]) + ctx.missing_api(p, ["invulnerable"])):
		return false
	p.set("invulnerable", true)
	var inp = InputSim.new(ctx)
	if not check("glock taken with its slot key", await inp.equip("glock"), str(p.get("current_weapon"))):
		return false
	inp.capture_for_look()
	await ctx.call_api(g, "teleport", [SITE])
	var w: Variant = g.get("world") if "world" in g else null
	var c: Variant = ctx.cell_of(SITE)
	if w is Object and w.has_method("is_cell_loaded") and c != null:
		await ctx.wait_until(func(): return bool(w.call("is_cell_loaded", c)), 300.0)
	await ctx.wait(2.0)
	var gy: Variant = await ctx.ground_y(SITE.x, SITE.z)
	var center := Vector3(SITE.x, float(gy) if gy != null else SITE.y, SITE.z)
	var per := {}
	for mt in MACHINES:
		per[mt] = await _machine(ctx, inp, g, mt, center)
	data.machines = per
	return true


func _machine(ctx, inp, g: Node, mt: String, center: Vector3) -> Dictionary:
	var info := {}
	var m: Variant = await ctx.call_api(g, "spawn_machine", [mt, center])
	if not (m is Node):
		check("%s: spawn_machine works in this build" % mt, false, str(m))
		return info
	ctx.spawned.append(m)
	var mates := []
	if mt == "broadhead":
		var m2: Variant = await ctx.call_api(g, "spawn_machine", [mt, center + Vector3(6.0, 0.0, 0.0)])
		if m2 is Node:
			ctx.spawned.append(m2)
			mates.append(m2)
	for x in [m] + mates:
		ctx.set_ai(x, true)
	if not api_check(ctx.missing_api(m, ["state"])):
		return info
	if not ("current_attack" in m):
		note("%s: machine.current_attack missing (needs_api): attack kind read from the state and projectiles only" % mt)
	await ctx.wait(2.0)  # settle into its calm behaviour
	var mpos: Vector3 = (m as Node3D).global_position
	var placed: Dictionary = await Sites.place_player_facing(ctx, mpos, MACHINES[mt], ctx.player_pos() - mpos)
	info.start = {"distance_m": MACHINES[mt], "line_of_sight": placed.get("los")}
	await inp.aim_at_point(_chest(m))
	var rec = ctx.record(g, "machine_state_changed")
	var initial := str(m.get("state"))
	var polled := [[0.0, initial]]
	var mate_states := {}
	var attacks := []
	var projectiles := []
	var seen_proj := {}
	var walking := false
	var wary_t := -1.0
	var shot_t := -1.0
	var alert_t := -1.0
	var approach := false
	var t0 := Time.get_ticks_msec()
	var next_aim := 0.0
	while (Time.get_ticks_msec() - t0) / 1000.0 < WATCH_S and is_instance_valid(m):
		var t := (Time.get_ticks_msec() - t0) / 1000.0
		var st := str(m.get("state"))
		if st != polled[polled.size() - 1][1]:
			polled.append([snappedf(t, 0.1), st])
			ctx.note("t12 %s %.1f s: %s (%.1f m)" % [mt, t, st, ctx.player_pos().distance_to((m as Node3D).global_position)])
		if wary_t < 0.0 and (WARY.has(st) or HOT.has(st)):
			wary_t = t
		if alert_t < 0.0 and HOT.has(st):
			alert_t = t
		if not approach and alert_t >= 0.0 and t > alert_t + APPROACH_AFTER_S and not _seen(polled, ["attack"]):
			approach = true
			ctx.note("t12 %s: alert but no attack %d s later, walking towards it again" % [mt, int(APPROACH_AFTER_S)])
		if approach and _seen(polled, ["attack"]):
			approach = false
		# held W towards the machine until it is suspicious (again after an alert without attack)
		if (wary_t < 0.0 and t < WALK_MAX_S) or (approach and ctx.player_pos().distance_to((m as Node3D).global_position) > 6.0):
			if not walking or not Input.is_action_pressed("move_forward"):
				inp.press("move_forward")
				walking = true
		elif walking:
			inp.release("move_forward")
			walking = false
		# no alert 10 s after suspicious: one glock shot into the air
		if shot_t < 0.0 and wary_t >= 0.0 and t > wary_t + SHOT_AFTER_S and not HOT.has(st) and not _seen(polled, HOT):
			var yp: Vector2 = inp.yaw_pitch()
			for i in 30:
				inp.look_step(yp.x, deg_to_rad(60.0))
				await ctx.frames(1)
			await inp.tap("fire")
			shot_t = t
			ctx.note("t12 %s: no alert %d s after suspicious, one shot into the air" % [mt, int(SHOT_AFTER_S)])
		elif t >= next_aim:
			next_aim = t + 0.25
			var yp2: Vector2 = InputSim.yaw_pitch_to(ctx.camera().global_position if ctx.camera() != null else ctx.player_pos(), _chest(m))
			inp.look_step(yp2.x, yp2.y)
		if "current_attack" in m:
			var a := str(m.get("current_attack"))
			if a != "" and (attacks.is_empty() or attacks[attacks.size() - 1][1] != a):
				attacks.append([snappedf(t, 0.1), a])
		for n in _projectile_nodes(ctx):
			if not seen_proj.has(n.get_instance_id()):
				seen_proj[n.get_instance_id()] = true
				projectiles.append([snappedf(t, 0.1), _proj_kind(n, m)])
		for x in mates:
			if is_instance_valid(x):
				var ms := str(x.get("state"))
				var arr: Array = mate_states.get(x.get_instance_id(), [])
				if arr.is_empty() or arr[arr.size() - 1][1] != ms:
					arr.append([snappedf(t, 0.1), ms])
				mate_states[x.get_instance_id()] = arr
		await ctx.frames(1)
	if walking:
		inp.release("move_forward")
	var states: Array = [initial]
	for e in rec.events:
		if e.args[0] == m:
			states.append(str(e.args[2]))
	info.initial_state = initial
	info.states_signal = states
	info.state_times = polled
	info.attacks = attacks
	info.projectiles = projectiles
	info.shot_into_air_s = shot_t
	info.approached_after_alert = alert_t >= 0.0 and approach
	info.mates = mate_states.values()
	var seq: Array = states if states.size() > 1 else polled.map(func(x): return x[1])
	check("%s: states (idle|patrol|graze|scavenge) -> suspicious -> alert (or stalk) -> attack" % mt, _ordered(seq), str(polled))
	check("%s: does not flee (flee_on_alert false)" % mt, not seq.has("flee"), str(seq))
	match mt:
		"sawtooth":
			var ch := attacks.filter(func(a): return str(a[1]).contains("pounce") or str(a[1]).contains("charge"))
			check("sawtooth: a pounce or charge starts within %d s" % int(WATCH_S), not ch.is_empty(), str(attacks))
		"scrapper":
			var lb := projectiles.filter(func(x): return str(x[1]).contains("laser"))
			check("scrapper: a laser_burst projectile is spawned within %d s" % int(WATCH_S), not lb.is_empty(), "projectiles %s, attacks %s" % [str(projectiles), str(attacks)])
		"broadhead":
			var ch2 := attacks.filter(func(a): return str(a[1]).contains("charge"))
			check("broadhead: a charge starts within %d s" % int(WATCH_S), not ch2.is_empty(), str(attacks))
			var left := mate_states.values().filter(func(arr): return arr.any(func(x): return not CALM.has(str(x[1]))))
			check("broadhead: a second Broadhead of the herd leaves graze (defend)", not mates.is_empty() and not left.is_empty(), str(mate_states.values()))
	rec.events.clear()
	for x in [m] + mates:
		if is_instance_valid(x):
			ctx.set_ai(x, false)
	await ctx.wait(1.0)
	return info


static func _chest(m: Node) -> Vector3:
	var n3 := m as Node3D
	var h := 1.2
	if "body_height_m" in m:
		h = float(m.get("body_height_m")) * 0.7
	return n3.global_position + Vector3(0, h, 0)


static func _seen(polled: Array, which: Array) -> bool:
	return polled.any(func(x): return which.has(str(x[1])))


static func _ordered(states: Array) -> bool:
	var want := [CALM, WARY, ALERT, ["attack"]]
	var k := 0
	for s in states:
		if k < want.size() and want[k].has(s):
			k += 1
	return k == want.size()


static func _projectile_nodes(ctx) -> Array:
	var out := []
	for grp in ["machine_projectiles", "projectiles"]:
		out.append_array(ctx.tree.get_nodes_in_group(grp))
	return out


static func _proj_kind(n: Node, m: Node) -> String:
	## attack id / kind of a projectile as far as the node tells it; "?" when unknown
	for prop in ["attack_id", "attack", "kind"]:
		if prop in n and str(n.get(prop)) != "":
			return str(n.get(prop))
	for k in ["attack_id", "attack", "kind"]:
		if n.has_meta(k):
			return str(n.get_meta(k))
	if "current_attack" in m and str(m.get("current_attack")) != "":
		return "while " + str(m.get("current_attack"))
	return str(n.name)
