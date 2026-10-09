extends "res://autotest/lib/scenario.gd"
## s01 Screenshot: buy wheel open with every item affordable (money = economy.max_money).


func _init() -> void:
	timeout_s = 1500.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["money"], ["open_buy_wheel", "close_buy_wheel"])):
		return false
	var o = ctx.oracle
	g.set("money", o.i(o.system("economy.max_money")))
	await ctx.call_api(g, "open_buy_wheel")
	await ctx.wait(0.5)
	var want: Array = o.wheel_items().map(func(w): return w.id)
	var wheel: Dictionary = await ctx.read_wheel()
	var shown: Array = wheel.items.map(func(it): return it.id)
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
	await ctx.call_api(g, "close_buy_wheel")
	return true
