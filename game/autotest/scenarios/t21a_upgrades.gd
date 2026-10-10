extends "res://autotest/lib/scenario.gd"
## t21 part A (child process, own --user-dir): progression reset with 2 points (setup); one Glock body hit on a fresh
## Watcher (AI off, full health and armor) = base damage; K (key), click "Damage +" and "Max health +" (mouse), K
## closes; the same hit again -> base x (1 + upgrades.damage.pct_per_level / 100) (+-0.5 %); max health base +
## hp_per_level; Game.kill_player() (setup) -> after the respawn health == that max. The base damage goes to
## <out>/../t21_base.json for part B (t21b, a new process with the same --user-dir).

const InputSim := preload("res://autotest/lib/inputsim.gd")
const HitCheck := preload("res://autotest/lib/hitcheck.gd")
const DIST_M := 6.0
const WEAPON := "glock"


func _init() -> void:
	timeout_s = 900.0


static func base_file(ctx) -> String:
	## shared by part A and B: next to their own out dirs (<out>/t21/t21a, <out>/t21/t21b)
	return ctx.out_dir.get_base_dir().path_join("t21_base.json")


static func body_hit(ctx, inp, scn) -> Dictionary:
	## one fire-button press at the lower body of a fresh Watcher (AI off) DIST_M ahead: the health damage dealt
	var g: Node = ctx.game
	var hits = ctx.record(g, "player_hit_machine")
	var m: Node = await ctx.spawn_ahead("watcher", DIST_M, 0.0, false)
	if m == null:
		return {"ok": false, "why": "spawn failed"}
	await ctx.wait(0.8)
	var out := {"ok": false, "armor_before": m.get("armor"), "health_before": m.get("health")}
	var interval: float = load("res://autotest/lib/combat.gd").shot_interval(ctx, WEAPON)
	for attempt in 6:
		await inp.aim_at_point(HitCheck.target_point(m, "body"), 0.002, 120)
		var n0: int = hits.events.size()
		await inp.tap("fire")
		await ctx.physics_frames(3)
		for e in hits.events.slice(n0):
			if e.args[0] == m and not bool(e.args[2]):
				out.ok = true
				out.dealt = float(e.args[1])
				out.distance_m = snappedf(ctx.player_camera().global_position.distance_to(e.args[3]), 0.01) if e.args[3] is Vector3 and (e.args[3] as Vector3).is_finite() else -1.0
		if out.ok:
			break
		if not hits.events.slice(n0).is_empty():
			# a weak-spot hit is not a body hit: a fresh machine (full armor) for the next try
			ctx.despawn(m)
			m = await ctx.spawn_ahead("watcher", DIST_M, 0.0, false)
			await ctx.wait(0.8)
		await ctx.wait(interval)
	out.presses = inp.sent.filter(func(s): return str(s).begins_with("fire down")).size()
	ctx.despawn(m)
	return out


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player", "progression"], ["set_progression", "spawn_machine", "kill_player", "max_health"], ["player_hit_machine", "player_respawned"])):
		return false
	var o = ctx.oracle
	var p: Node = ctx.player
	var inp = InputSim.new(ctx)
	if InputSim.headless_look():
		note("--headless: no mouse capture, the camera is pointed as setup (look_at_point) instead of by mouse motion")
		data.headless_setup_look = true
	p.set("invulnerable", true)
	g.call("set_progression", {"xp": 0, "level": 0, "points": 2, "upgrades": {"damage": 0, "max_health": 0, "bhop": 0}})
	await ctx.frames(2)
	data.progression_start = g.get("progression")
	var up_d: Dictionary = o.system("upgrades.damage")
	var up_h: Dictionary = o.system("upgrades.max_health")
	var want_mult := 1.0 + float(up_d.get("pct_per_level", 0)) / 100.0
	var want_max := float(up_h.get("base", 100)) + float(up_h.get("hp_per_level", 0))
	inp.capture_for_look()
	check("Glock drawn with its slot key", await inp.equip(WEAPON), str(p.get("current_weapon")))
	var base: Dictionary = await body_hit(ctx, inp, self)
	data.base_hit = base
	if not check("base body hit (no upgrade)", base.ok, str(base)):
		return false
	ctx.write_json(base_file(ctx), {"dealt": base.dealt, "weapon": WEAPON, "distance_m": base.get("distance_m")})

	# K menu: real key and clicks
	await inp.tap("upgrades")
	await ctx.frames(3)
	var menu: Control = inp.find_control("UpgradesMenu")
	check("K (%s) opens the upgrades menu" % inp.describe("upgrades"), menu != null and menu.visible and ctx.tree.paused, "visible %s, paused %s" % [str(menu.visible if menu else null), str(ctx.tree.paused)])
	var c1: bool = await inp.click_control("Upgrade_damage")
	await ctx.frames(3)
	var c2: bool = await inp.click_control("Upgrade_max_health")
	await ctx.frames(3)
	var prog: Dictionary = g.get("progression")
	data.after_clicks = prog
	check("clicks bought damage 1 and max_health 1, points 0", c1 and c2 and int(prog.upgrades.damage) == 1 and int(prog.upgrades.max_health) == 1 and int(prog.points) == 0, str(prog))
	await inp.tap("upgrades")
	await ctx.frames(3)
	check("K closes the menu", menu == null or (not menu.visible and not ctx.tree.paused), "paused %s" % str(ctx.tree.paused))
	inp.capture_for_look()

	var up: Dictionary = await body_hit(ctx, inp, self)
	data.upgraded_hit = up
	var ratio: float = float(up.get("dealt", 0.0)) / maxf(float(base.dealt), 0.001)
	data.ratio = snappedf(ratio, 0.0001)
	check("damage == base body damage x %.2f (+-0.5 %%): %.2f -> %.2f" % [want_mult, float(base.dealt), float(up.get("dealt", -1.0))], up.ok and absf(ratio - want_mult) <= want_mult * 0.005, "x%.4f" % ratio)
	check("max health %.0f" % want_max, is_equal_approx(float(g.call("max_health")), want_max), str(g.call("max_health")))

	var resp = ctx.record(g, "player_respawned")
	p.set("invulnerable", false)
	await ctx.call_api(g, "kill_player")
	var back: bool = await ctx.wait_until(func(): return not resp.events.is_empty(), float(o.f(o.system("respawn.delay_s"))) + 30.0)
	await ctx.wait(0.3)
	p.set("invulnerable", true)
	data.after_respawn = {"respawned": back, "max_health": g.call("max_health"), "health": p.get("health"), "progression": g.get("progression")}
	check("max health %.0f and health %.0f after respawn" % [want_max, want_max], back and is_equal_approx(float(g.call("max_health")), want_max) and is_equal_approx(float(p.get("health")), want_max), str(data.after_respawn))
	return true
