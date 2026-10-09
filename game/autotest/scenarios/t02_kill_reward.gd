extends "res://autotest/lib/scenario.gd"
## t02 Kill adds the right reward: reward = round(weapon.kill_award * economy.kill_award_factor *
## machine.kill_reward_mult), money capped at economy.max_money; the kill_reward signal amount equals the money delta.

const Combat := preload("res://autotest/lib/combat.gd")


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["money", "player"], ["buy", "equip", "spawn_machine", "aim_at", "fire"], ["kill_reward"]) + ctx.missing_api(p, ["inventory"])):
		return false
	var o = ctx.oracle
	var factor: float = o.f(o.system("economy.kill_award_factor"))
	var cap: int = o.i(o.system("economy.max_money"))
	var start: int = o.i(o.system("economy.start_money"))
	data.kill_award_factor = factor
	data.max_money = cap

	# setup: own an ak47 (bought through the normal buy path if not owned yet)
	if not Array(p.get("inventory")).has("ak47"):
		g.set("money", maxi(3500, o.i(o.weapon("ak47", "price"))))  # 3500 per sheet; enough for any price table
		await ctx.frames(1)
		check("setup: buy(ak47)", (await ctx.call_api(g, "buy", ["ak47"])) == true)
	var cases := [
		{"label": "case 1", "machine": "watcher", "weapon": "ak47", "money": start, "dist": 15.0, "angle": 0.0},
		{"label": "case 2", "machine": "grazer", "weapon": "knife", "money": start, "dist": 3.5, "angle": 40.0},
		{"label": "case 3", "machine": "watcher", "weapon": "ak47", "money": cap - 100, "dist": 15.0, "angle": -40.0},
	]
	var out := []
	var base: Vector3 = ctx.forward()
	for c in cases:
		c.base = base
		out.append(await _case(ctx, g, o, c, factor, cap))
	data.cases = out
	return true


func _case(ctx, g: Node, o, c: Dictionary, factor: float, cap: int) -> Dictionary:
	var award: int = o.i(o.weapon(c.weapon, "kill_award"))
	var mult: float = o.f(o.machine(c.machine, "kill_reward_mult"))
	var reward := int(round(award * factor * mult))
	var expected := mini(int(c.money) + reward, cap)
	var info := {"label": c.label, "machine": c.machine, "weapon": c.weapon, "kill_award": award, "machine_mult": mult, "start_money": c.money, "expected_money": expected}
	await Combat.equip(ctx, c.weapon)
	g.set("money", int(c.money))
	await ctx.frames(1)
	var m: Node = await ctx.spawn_ahead(c.machine, c.dist, c.angle, false, c.base)
	if not check("%s: spawn_machine(%s)" % [c.label, c.machine], m != null):
		return info
	await ctx.physics_frames(3)
	var rec = ctx.record(g, "kill_reward")
	var k: Dictionary = await Combat.kill(ctx, m, c.weapon, "body")
	await ctx.wait(0.5)
	var money := int(g.get("money"))
	info.kill = k
	info.money = money
	check("%s: %s killed with %s" % [c.label, c.machine, c.weapon], k.dead, str(k))
	check("%s: money == min(%d + round(%d * %s * %s), %d) = %d" % [c.label, c.money, award, str(factor), str(mult), cap, expected], money == expected, "money %d" % money)
	var sig: Array = rec.events.map(func(e): return {"machine_type": str(e.args[0]), "weapon_id": str(e.args[1]), "amount": e.args[2]})
	info.kill_reward_signals = sig
	var delta := money - int(c.money)
	var sig_ok: bool = sig.size() == 1 and sig[0].machine_type == c.machine and sig[0].weapon_id == c.weapon and int(sig[0].amount) == delta
	check("%s: one kill_reward(%s, %s, amount == money delta %d)" % [c.label, c.machine, c.weapon, delta], sig_ok, str(sig))
	return info
