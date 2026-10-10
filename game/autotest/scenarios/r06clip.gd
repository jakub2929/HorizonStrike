extends "res://autotest/lib/scenario.gd"
## r06clip (movie-maker child of r06, knife from env HZS_R06_KNIFE, own --user-dir): wait until the knife is converted,
## choose it in Esc > Knife (key + clicks), Back + Esc, 3 draws it, F inspects; the clip runs 4 s from the F press
## (drawn-frame range in <out>/clips.json).

const InputSim := preload("res://autotest/lib/inputsim.gd")
const GfxState := preload("res://autotest/lib/gfxstate.gd")
const RecClip := preload("res://autotest/lib/recclip.gd")
const Movie := preload("res://autotest/lib/movie.gd")
const CLIP_S := 4.0

var clips := {}


func _init() -> void:
	timeout_s = 780.0


func _run(ctx):
	var knife := OS.get_environment("HZS_R06_KNIFE")
	data.knife = knife
	if not check("knife given (env HZS_R06_KNIFE)", knife != "", knife):
		return _why(ctx, "no knife given")
	if not check("world_ready", await ctx.need_world(1400.0)):
		return _why(ctx, "world not ready")
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, [], ["knife_ids", "knife_selected", "knife_model", "knife_last_anim"])):
		return _why(ctx, "Game knife API missing")
	ctx.player.set("invulnerable", true)
	if not check("%s converted and offered (<= 600 s)" % knife, await ctx.wait_until(func(): return (g.call("knife_ids") as Array).has(knife), 600.0), str(g.call("knife_ids"))):
		return _why(ctx, "knife not offered: %s" % str(g.call("knife_ids")))
	var inp = InputSim.new(ctx)
	await inp.tap("menu")
	await ctx.frames(2)
	await GfxState.click_control(ctx, inp, "KnifeButton")
	await ctx.frames(2)
	var list := GfxState.control(ctx, "KnifeList") as ItemList
	var idx := -1
	if list != null:
		for i in list.item_count:
			if str(list.get_item_metadata(i)) == knife:
				idx = i
	if idx >= 0:
		await inp.click(list.get_global_transform() * list.get_item_rect(idx).get_center())
	check("menu click selects %s" % knife, str(g.call("knife_selected")) == knife, str(g.call("knife_selected")))
	await GfxState.click_control(ctx, inp, "KnifeBack")
	await inp.tap("menu")
	await ctx.frames(2)
	check("menu closed", not ctx.tree.paused)
	await inp.equip("knife")
	check("%s in hand" % knife, await ctx.wait_until(func(): return str(g.call("knife_model")) == knife, 30.0), str(g.call("knife_model")))
	await ctx.wait(1.5)   # draw animation over, idle
	var f0 := Movie.frame_now()
	await ctx.wait(0.2)
	await inp.tap("inspect")
	var anim_seen := false
	var t_end := CLIP_S - 0.2
	var waited := 0.0
	while waited < t_end:
		await ctx.wait(0.1)
		waited += 0.1
		anim_seen = anim_seen or str(g.call("knife_last_anim")).ends_with("inspect")
	clips.inspect = [f0, Movie.frame_now()]
	RecClip.save_clips(ctx, clips)
	data.last_anim = g.call("knife_last_anim")
	check("F played %s's inspect clip" % knife, anim_seen, str(data.last_anim))
	data.input = inp.sent
	return true


func _why(ctx, why: String) -> bool:
	clips.why = why
	RecClip.save_clips(ctx, clips)
	return false
