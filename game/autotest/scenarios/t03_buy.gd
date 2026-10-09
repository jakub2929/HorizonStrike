extends "res://autotest/lib/scenario.gd"
## t03 Buying subtracts the price: money = ak47.price + hegrenade.price (= 3000 on CS2 b25815307) -> buy ak47 ->
## buy hegrenade (money 0) -> buy awp (refused). Prices come from the resolved cache (synthetic ones with --mock-data);
## the wheel must list exactly the weapons rows with buy_wheel_index >= 0 at those prices.


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["money", "player", "machines"], ["buy", "open_buy_wheel", "close_buy_wheel"]) + ctx.missing_api(p, ["inventory"])):
		return false
	var o = ctx.oracle
	var busy := []
	for m in g.get("machines"):
		if is_instance_valid(m) and str(m.get("state")) in ["alert", "attack"]:
			busy.append("%s %s" % [m.get("machine_type"), m.get("state")])
	check("setup: no machine alerted", busy.is_empty(), str(busy))
	var inv0: Array = Array(p.get("inventory")).map(func(x): return str(x))
	data.inventory_start = inv0
	check("setup: ak47 and hegrenade not owned yet", not inv0.has("ak47") and not inv0.has("hegrenade"), str(inv0))

	var p_ak: int = o.i(o.weapon("ak47", "price"))
	var p_he: int = o.i(o.weapon("hegrenade", "price"))
	var p_awp: int = o.i(o.weapon("awp", "price"))
	data.prices = {"ak47": p_ak, "hegrenade": p_he, "awp": p_awp}
	var start := p_ak + p_he
	data.start_money = start
	check("setup: awp is dearer than nothing (awp.price > 0)", p_awp > 0, str(p_awp))
	g.set("money", start)
	await ctx.frames(1)
	await ctx.call_api(g, "open_buy_wheel")
	await ctx.wait(0.3)
	await _check_wheel(ctx, g, o)
	var money_rec = ctx.record(g, "money_changed")

	var ok_ak: Variant = await ctx.call_api(g, "buy", ["ak47"])
	await ctx.frames(2)
	var m1 := int(g.get("money"))
	var inv1: Array = Array(p.get("inventory")).map(func(x): return str(x))
	check("buy(ak47) returns true", ok_ak == true, str(ok_ak))
	check("after ak47: money == %d - ak47.price (%d)" % [start, start - p_ak], m1 == start - p_ak, "money %d" % m1)
	check("after ak47: inventory contains ak47", inv1.has("ak47"), str(inv1))

	var ok_he: Variant = await ctx.call_api(g, "buy", ["hegrenade"])
	await ctx.frames(2)
	var m2 := int(g.get("money"))
	var inv2: Array = Array(p.get("inventory")).map(func(x): return str(x))
	check("buy(hegrenade) returns true", ok_he == true, str(ok_he))
	check("after hegrenade: money == %d" % (start - p_ak - p_he), m2 == start - p_ak - p_he, "money %d" % m2)
	check("after hegrenade: inventory contains hegrenade", inv2.has("hegrenade"), str(inv2))

	var ok_awp: Variant = await ctx.call_api(g, "buy", ["awp"])
	await ctx.frames(2)
	var m3 := int(g.get("money"))
	var inv3: Array = Array(p.get("inventory")).map(func(x): return str(x))
	check("buy(awp) with $%d < %d returns false" % [m2, p_awp], ok_awp == false, str(ok_awp))
	check("after awp: money unchanged (%d)" % m2, m3 == m2, "money %d" % m3)
	check("after awp: inventory unchanged", inv3 == inv2, str(inv3))
	var vals := []
	for e in money_rec.events:
		vals.append(e.args[0])
	data.money_changed = vals
	check("money_changed reported the new values", vals.size() >= 2 and int(vals[vals.size() - 1]) == m2, str(vals))
	await ctx.call_api(g, "close_buy_wheel")
	return true


func _check_wheel(ctx, g: Node, o) -> void:
	## wheel items as shown (ctx.read_wheel: API, else the wheel's UI nodes)
	var want: Array = o.wheel_items()
	data.wheel_expected = want
	var wheel: Dictionary = await ctx.read_wheel()
	var got: Array = wheel.items
	data.wheel_shown = wheel
	var ok: bool = got.size() == want.size() and want.size() <= o.i(o.system("economy.buy_wheel_max_items"))
	var diffs := []
	for w in want:
		var hit := got.filter(func(x): return x.id == w.id)
		if hit.is_empty():
			diffs.append("%s missing" % w.id)
			ok = false
		elif hit[0].price != int(w.price):
			diffs.append("%s price %d != %d" % [w.id, hit[0].price, int(w.price)])
			ok = false
	check("wheel lists exactly the buy_wheel_index >= 0 rows (%d) with resolved prices" % want.size(), ok, "%d shown; %s" % [got.size(), "; ".join(diffs)])
