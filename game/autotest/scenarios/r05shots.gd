extends "res://autotest/lib/scenario.gd"
## r05shots (child of r05, own --user-dir): progression with 3 points (setup); Esc (key) -> Knife (click) -> the
## Karambit entry (click) -> knife_menu.png; Back + Esc; K (key) -> upgrades_menu.png; K closes it.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const GfxState := preload("res://autotest/lib/gfxstate.gd")
const SHOW_KNIFE := "knife_karambit"


func _init() -> void:
	timeout_s = 800.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, [], ["set_progression", "knife_ids", "knife_selected", "screenshot"])):
		return false
	g.call("set_progression", {"points": 3})
	ctx.player.set("invulnerable", true)
	# knives are converted on demand after the start cells: wait for the one shown in the preview (else any)
	await ctx.wait_until(func(): return (g.call("knife_ids") as Array).has(SHOW_KNIFE), 300.0)
	data.knives = g.call("knife_ids")
	await ctx.wait(1.0)
	var inp = InputSim.new(ctx)
	await inp.tap("menu")
	await ctx.frames(2)
	check("Esc opens the menu", ctx.tree.paused, str(inp.sent.slice(-2)))
	check("click Knife opens the knife panel", await GfxState.click_control(ctx, inp, "KnifeButton") and GfxState.control(ctx, "KnifePanel") != null and GfxState.control(ctx, "KnifePanel").visible)
	var list := GfxState.control(ctx, "KnifeList") as ItemList
	var target := -1
	if list != null:
		for i in list.item_count:
			if str(list.get_item_metadata(i)) == SHOW_KNIFE:
				target = i
	if target >= 0:
		await inp.click(list.get_global_transform() * list.get_item_rect(target).get_center())
	data.knife_selected = g.call("knife_selected")
	check("click on %s selects it" % SHOW_KNIFE, str(data.knife_selected) == SHOW_KNIFE, str(data.knife_selected))
	await ctx.wait(2.0)   # the preview model loads and turns
	var s1: Dictionary = await ctx.screenshot("knife_menu.png")
	check("knife_menu.png not blank", float(s1.get("luma_stddev", 0.0)) > 10.0, str(s1.get("luma_stddev")))
	await GfxState.click_control(ctx, inp, "KnifeBack")
	await inp.tap("menu")
	await ctx.frames(2)
	check("Back + Esc close the menu", not ctx.tree.paused)
	await ctx.wait(0.5)
	await inp.tap("upgrades")
	await ctx.wait(0.8)
	var um := GfxState.control(ctx, "UpgradesMenu")
	check("K opens the upgrades menu", um != null and um.visible)
	var s2: Dictionary = await ctx.screenshot("upgrades_menu.png")
	check("upgrades_menu.png not blank", float(s2.get("luma_stddev", 0.0)) > 10.0, str(s2.get("luma_stddev")))
	await inp.tap("upgrades")
	await ctx.frames(2)
	data.shots = [s1, s2]
	data.input = inp.sent
	return true
