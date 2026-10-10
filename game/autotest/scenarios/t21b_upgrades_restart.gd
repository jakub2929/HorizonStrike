extends "res://autotest/lib/scenario.gd"
## t21 part B (a new process with the --user-dir of part A): after the restart progression.json still has upgrades
## damage 1, max_health 1, points 0; health == the upgraded max; a Glock body hit deals part A's base x the upgrade.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const PartA := preload("res://autotest/scenarios/t21a_upgrades.gd")


func _init() -> void:
	timeout_s = 600.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(800.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player", "progression"], ["spawn_machine", "max_health"], ["player_hit_machine"])):
		return false
	var o = ctx.oracle
	var p: Node = ctx.player
	var inp = InputSim.new(ctx)
	# aiming is mouse motion: --headless has no mouse capture, so this test needs a window run
	if not check("window run (aiming by mouse motion needs a captured mouse)", not InputSim.headless_look()):
		return false
	p.set("invulnerable", true)
	var prog: Dictionary = g.get("progression")
	data.progression = prog
	check("upgrades damage 1, max_health 1, points 0 after restart", int(prog.upgrades.damage) == 1 and int(prog.upgrades.max_health) == 1 and int(prog.points) == 0, str(prog))
	var up_d: Dictionary = o.system("upgrades.damage")
	var up_h: Dictionary = o.system("upgrades.max_health")
	var want_max := float(up_h.get("base", 100)) + float(up_h.get("hp_per_level", 0))
	data.health = {"max_health": g.call("max_health"), "health": p.get("health")}
	check("max health and health %.0f after restart" % want_max, is_equal_approx(float(g.call("max_health")), want_max) and is_equal_approx(float(p.get("health")), want_max), str(data.health))
	var base_v: Variant = load("res://autotest/lib/oracle.gd").read_json(PartA.base_file(ctx))
	var base: float = float(base_v.get("dealt", -1.0)) if base_v is Dictionary else -1.0
	data.base_from_a = base_v
	if not check("part A's base body damage available (%s)" % PartA.base_file(ctx), base > 0.0, str(base_v)):
		return false
	inp.capture_for_look()
	check("Glock drawn with its slot key", await inp.equip(PartA.WEAPON), str(p.get("current_weapon")))
	var hit: Dictionary = await PartA.body_hit(ctx, inp, self)
	data.hit = hit
	var want_mult := 1.0 + float(up_d.get("pct_per_level", 0)) / 100.0
	var ratio: float = float(hit.get("dealt", 0.0)) / base
	data.ratio = snappedf(ratio, 0.0001)
	check("damage after restart == base x %.2f (+-0.5 %%): %.2f -> %.2f" % [want_mult, base, float(hit.get("dealt", -1.0))], hit.ok and absf(ratio - want_mult) <= want_mult * 0.005, "x%.4f" % ratio)
	return true
