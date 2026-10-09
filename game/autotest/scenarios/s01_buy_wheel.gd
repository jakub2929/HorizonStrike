extends "res://autotest/lib/scenario.gd"
## s01 Screenshot: buy wheel open with every item affordable (money = economy.max_money). The wheel is opened and
## closed with the player's buy key (simulated input), as a player does.

const InputSim := preload("res://autotest/lib/inputsim.gd")


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["money"])):
		return false
	var o = ctx.oracle
	g.set("money", o.i(o.system("economy.max_money")))
	var inp = InputSim.new(ctx)
	data.buy_key = inp.describe("buy")
	await inp.tap("buy")
	await ctx.wait(0.5)
	var want: Array = o.wheel_items().map(func(w): return w.id)
	# what the player sees: the wheel's slots on screen, identified by their item names
	var on_screen: Array = ctx.wheel_on_screen()
	var names := {}
	for id in WeaponsSheet.ROWS:
		names[str(WeaponsSheet.ROWS[id].display_name)] = id
	var shown: Array = on_screen.map(func(it): return names.get(it.name, "?" + str(it.name)))
	var wheel := {"source": "on screen after the buy key", "items": on_screen.map(func(it): return {"name": it.name, "price": it.price_shown})}
	var shot: Dictionary = await ctx.screenshot("buy_wheel.png")
	data.screenshot = shot
	data.wheel = wheel
	check("file exists (fresh)", shot.get("exists", false) and shot.get("fresh", false), shot.get("path"))
	check("frame >= 1280x720", int(shot.get("width", 0)) >= 1280 and int(shot.get("height", 0)) >= 720, "%sx%s" % [str(shot.get("width")), str(shot.get("height"))])
	check("not blank (luma stddev > 10)", float(shot.get("luma_stddev", 0.0)) > 10.0, str(shot.get("luma_stddev")))
	var a := shown.duplicate()
	a.sort()
	var b := want.duplicate()
	b.sort()
	check("wheel shows the %d items" % want.size(), a == b, "shown %s (%s)" % [str(shown), wheel.source])
	if not ctx.wheel_on_screen().is_empty():
		await inp.tap("buy")
	return true
