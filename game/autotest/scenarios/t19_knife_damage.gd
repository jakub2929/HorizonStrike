extends "res://autotest/lib/scenario.gd"
## t19 Knife damage = default knife; inspect plays for every knife. For every ok knife: choose it through the Esc menu
## (Esc, click "Knife", click its row, Esc), a fresh Watcher (AI off, full health and armor) 1.2 m ahead, Game.aim_at
## its body (setup, like mouse look), one slash with the left mouse button; then F (inspect key).
## Expected slash: knife damage through the CS armor rule (machine armor > 0):
##   health damage = damage x armor_ratio x combat.armor_ratio_scale (armor lost (damage - that) x armor_bonus; when
##   that exceeds the armor left the rest goes to health) x upgrades damage multiplier (progression reset = 1)
## Inspect: within 0.5 s of F the viewmodel's current clip is the inspect clip and it plays for >= 1 s.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const KnifeMenu := preload("res://autotest/lib/knifemenu.gd")
const DIST_M := 1.2


func _init() -> void:
	timeout_s = 2400.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	if not api_check(ctx.missing_api(g, ["player", "progression"], ["knife_ids", "knife_selected", "spawn_machine", "aim_at", "set_progression"], ["player_hit_machine"])):
		return false
	var o = ctx.oracle
	var p: Node = ctx.player
	var inp = InputSim.new(ctx)
	var km = KnifeMenu.new(ctx, inp)
	p.set("invulnerable", true)
	# setup: no damage upgrade (the expected value is the plain knife row)
	g.call("set_progression", {"upgrades": {"damage": 0}})
	await km.wait_index_settled(1500.0)
	var ids: Array = km.ok_ids()
	if not check("knives listed in index.json", not ids.is_empty(), str(km.index().get("knives", []).size())):
		return false
	await km.wait_converted(ids, 120.0)
	var stats_row := "knife"
	var sel: Variant = o.system("knives.selection")
	if sel is Dictionary and str(sel.get("stats_row", "")) != "":
		stats_row = str(sel.stats_row)
	var dmg: float = o.num(o.weapon(stats_row, "damage"))
	var ar: float = o.num(o.weapon(stats_row, "armor_ratio"))
	var ars: float = o.f(o.system("combat.armor_ratio_scale"))
	var bonus: float = o.f(o.system("combat.armor_bonus"))
	data.knife_row = {"row": stats_row, "damage": dmg, "armor_ratio": ar, "armor_ratio_scale": ars, "armor_bonus": bonus}
	var hits = ctx.record(g, "player_hit_machine")
	inp.capture_for_look()
	if not check("knife drawn with its slot key", await inp.equip("knife"), str(p.get("current_weapon"))):
		return false
	var per := {}
	var base_dir: Vector3 = ctx.forward()
	for id in ids:
		var rec := {}
		var r: Dictionary = await km.choose(id)
		rec.menu = r.ok
		if not r.ok:
			rec.menu_steps = r.steps
			rec.menu_why = r.why
		rec.in_hand = id if await km.wait_in_hand(id, 15.0) else km.in_hand()
		inp.capture_for_look()
		# slash: a fresh watcher in front, aim at its body, left mouse button once
		var m: Node = await ctx.spawn_ahead("watcher", DIST_M, 0.0, false, base_dir)
		if m == null:
			rec.why = "spawn failed"
			per[id] = rec
			continue
		await ctx.wait(0.6)
		await ctx.wait(maxf(0.0, float(o.f(o.system("combat.knife_primary_interval_s")))))
		var armor0 := float(m.get("armor"))
		var health0 := float(m.get("health"))
		var exp_dmg := _expected(dmg, ar, ars, bonus, armor0)
		var n0: int = hits.events.size()
		var tries := 0
		var dealt := -1.0
		var weak := false
		while tries < 4 and dealt < 0.0:
			tries += 1
			await ctx.call_api(g, "aim_at", [m, "body"])
			await ctx.physics_frames(1)
			await inp.tap("fire")
			await ctx.physics_frames(3)
			for e in hits.events.slice(n0):
				if e.args[0] == m:
					dealt = float(e.args[1])
					weak = bool(e.args[2])
			if dealt < 0.0:
				# out of reach: one step closer (setup), then again after the knife interval
				var to: Vector3 = (m as Node3D).global_position - ctx.player_pos()
				to.y = 0.0
				if to.length() > 0.9:
					await ctx.call_api(g, "teleport", [ctx.player_pos() + to.normalized() * 0.3])
				await ctx.wait(float(o.f(o.system("combat.knife_primary_interval_s"))) + 0.1)
		rec.slash = {"dealt": snappedf(dealt, 0.01), "expected": snappedf(exp_dmg, 0.01), "weak": weak, "armor_before": armor0, "health_before": health0, "presses": tries}
		ctx.despawn(m)
		# inspect: F, then watch the viewmodel's current clip
		await ctx.wait(0.6)
		rec.inspect = await _inspect(ctx, inp, km)
		per[id] = rec
		ctx.note("t19 %s: menu %s, in hand %s, slash %.2f (expected %.2f, weak %s), inspect %s" % [id, str(r.ok), rec.in_hand, dealt, exp_dmg, str(weak), str(rec.inspect)])
	data.knives = per
	var chosen := ids.filter(func(i): return per[i].get("menu", false) and per[i].get("in_hand") == i)
	check("every knife chosen through the menu and in hand (%d/%d)" % [chosen.size(), ids.size()], chosen.size() == ids.size(), str(ids.filter(func(i): return not chosen.has(i))))
	var dmg_ok := ids.filter(func(i): return per[i].has("slash") and not per[i].slash.weak and per[i].slash.dealt >= 0.0 and absf(per[i].slash.dealt - per[i].slash.expected) <= 0.01)
	var default_id := str(o.system("knives.default"))
	var d0: float = float(per.get(default_id, {}).get("slash", {}).get("dealt", -1.0))
	check("slash damage == default knife damage through the CS armor rule for every knife (%d/%d, default %s %.2f)" % [dmg_ok.size(), ids.size(), default_id, d0], dmg_ok.size() == ids.size() and d0 > 0.0, str(ids.filter(func(i): return not dmg_ok.has(i)).map(func(i): return [i, per[i].get("slash")])))
	var insp_ok := ids.filter(func(i): return per[i].get("inspect", {}).get("ok", false))
	check("F: inspect clip within 0.5 s, playing >= 1 s, for every knife (%d/%d)" % [insp_ok.size(), ids.size()], insp_ok.size() == ids.size(), str(ids.filter(func(i): return not insp_ok.has(i)).map(func(i): return [i, per[i].get("inspect")])))
	await km.choose(default_id)
	return true


static func _expected(damage: float, armor_ratio: float, scale: float, bonus: float, armor: float) -> float:
	## CS armor rule, written from the rule text (independent of core/combat.gd)
	if armor <= 0.0 or armor_ratio <= 0.0:
		return damage
	var health := damage * armor_ratio * scale
	var lost := (damage - health) * bonus
	if lost > armor:
		health = damage - armor / bonus
	return health


func _inspect(ctx, inp, km) -> Dictionary:
	var vm: Node = km.viewmodel()
	if vm == null:
		return {"ok": false, "why": "no viewmodel"}
	var t_press := Time.get_ticks_msec()
	await inp.tap("inspect")
	var started := -1.0
	var clip := ""
	var played := 0.0
	while (Time.get_ticks_msec() - t_press) / 1000.0 < 4.0:
		var c := str(vm.call("current_clip"))
		var t := (Time.get_ticks_msec() - t_press) / 1000.0
		if c.ends_with("inspect"):
			if started < 0.0:
				started = t
				clip = c
			played = t - started
			if played >= 1.0:
				break
		elif started >= 0.0:
			break
		if started < 0.0 and t > 0.5:
			break
		await ctx.frames(1)
	return {"ok": started >= 0.0 and started <= 0.5 and played >= 1.0, "clip": clip, "start_s": snappedf(started, 0.001), "played_s": snappedf(played, 0.01), "key": inp.describe("inspect"), "clips": Array(vm.call("clips"))}
