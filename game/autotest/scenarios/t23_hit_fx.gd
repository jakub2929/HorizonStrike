extends "res://autotest/lib/scenario.gd"
## t23 Hit effects shown. Dealing damage (Watcher, AI off, 8 m, Glock by the fire button; the camera turned by relative
## mouse motion onto the lower body, Game.aim_at for the weak spot): body hit -> Hitmarker with the normal style within
## 2 frames and a DamageNumbers label with the dealt value, both seen in the rendered frame; weak hit -> weak style and
## more impact particles at the hit point; damage numbers off by a click on the Esc menu toggle -> a hit spawns no
## number; on again. Taking damage (Scrapper with AI on, player not invulnerable, health topped up = setup): direction
## indicator visible and pointing at the scrapper (+-30 deg), red arc in the rendered frame, vignette alpha > 0 and
## higher at lower health, aimpunch > 0 then back to 0, hurt sound playing.

const InputSim := preload("res://autotest/lib/inputsim.gd")
const HitCheck := preload("res://autotest/lib/hitcheck.gd")


func _init() -> void:
	timeout_s = 600.0


func _run(ctx):
	if not check("world_ready", await ctx.need_world(1400.0)):
		return false
	var g: Node = ctx.game
	var p: Node = ctx.player
	if not api_check(ctx.missing_api(g, ["player", "hud"], ["fx_stats", "spawn_machine", "aim_at", "max_health", "set_progression"], ["player_hit_machine", "player_hurt"]) + ctx.missing_api(p, ["aimpunch_deg", "health"])):
		return false
	var o = ctx.oracle
	var inp = InputSim.new(ctx)
	# aiming is mouse motion: --headless has no mouse capture, so this test needs a window run
	if not check("window run (aiming by mouse motion needs a captured mouse)", not InputSim.headless_look()):
		return false
	var hud: Node = g.get("hud")
	var names := {}
	for n in ["Hitmarker", "DamageNumbers", "DamageIndicator", "Vignette"]:
		names[n] = hud.find_child(n, true, false) as Control
	if not check("HUD nodes Hitmarker, DamageNumbers, DamageIndicator, Vignette", names.values().all(func(c): return c != null), str(names.keys().filter(func(k): return names[k] == null))):
		return false
	p.set("invulnerable", true)
	g.call("set_progression", {"upgrades": {"damage": 0, "max_health": 0}})
	var hits = ctx.record(g, "player_hit_machine")
	inp.capture_for_look()
	check("Glock drawn with its slot key", await inp.equip("glock"), str(p.get("current_weapon")))
	var m: Node = await ctx.spawn_ahead("watcher", 8.0, 0.0, false)
	if not check("watcher spawned (AI off)", m != null):
		return false
	await ctx.wait(0.8)

	# body hit
	var body: Dictionary = await _shoot(ctx, inp, hits, m, "body", names)
	data.body_hit = body
	check("body hit: hitmarker shown (normal style) within 2 frames", body.hit and not body.weak and body.marker_frames >= 0 and body.marker_frames <= 2 and body.style == "normal" and body.marker_pixels, str(body))
	check("body hit: damage number shown with the dealt value", body.hit and body.number_text == str(int(round(float(body.get("dealt", -1.0))))) and body.number_visible, "label '%s' visible %s, dealt %.2f" % [body.number_text, str(body.number_visible), float(body.get("dealt", -1.0))])
	await ctx.wait(0.8)
	# weak hit (a fresh watcher: every sub-test starts at full health - a 110-damage eye shot kills a 90-health watcher,
	# and a dead machine takes no further hit)
	m = await _fresh(ctx, m)
	var weak_part := str(m.call("weak_spots")[0]) if m.has_method("weak_spots") and not m.call("weak_spots").is_empty() else ""
	var weak: Dictionary = await _shoot(ctx, inp, hits, m, weak_part, names)
	data.weak_hit = weak
	check("weak hit (%s): weak hitmarker style" % weak_part, weak.hit and weak.weak and weak.style == "weak" and weak.marker_frames >= 0, str(weak))
	check("machine-side impact particles: weak %d > normal %d" % [int(weak.get("particles", 0)), int(body.get("particles", 0))], int(weak.get("particles", 0)) > int(body.get("particles", 0)) and int(body.get("particles", 0)) > 0, "fx_stats sparks %s" % str(g.call("fx_stats").get("sparks")))
	await ctx.wait(0.8)

	# damage numbers off through the Esc menu, one hit, on again
	m = await _fresh(ctx, m)
	var tog: bool = await _toggle_numbers(ctx, inp)
	var off_state := _numbers_setting(ctx)
	inp.capture_for_look()
	var n0 := int(g.call("fx_stats").get("numbers", 0))
	var off: Dictionary = await _shoot(ctx, inp, hits, m, "body", names)
	var n1 := int(g.call("fx_stats").get("numbers", 0))
	data.numbers_off = {"toggle_clicked": tog, "setting": off_state, "hit": off, "numbers": [n0, n1]}
	check("numbers off (Esc menu toggle): a hit spawns no number", tog and not off_state and off.hit and n1 == n0, str(data.numbers_off))
	var tog2: bool = await _toggle_numbers(ctx, inp)
	data.numbers_back_on = _numbers_setting(ctx)
	check("numbers toggled on again", tog2 and data.numbers_back_on)
	ctx.despawn(m)

	# taking damage: a scrapper with AI on
	inp.capture_for_look()
	await inp.equip("knife")
	p.set("health", float(g.call("max_health")))
	p.set("invulnerable", false)
	var hurt = ctx.record(g, "player_hurt")
	await ctx.wait(1.0)
	var edge0 := _edge_red(await _frame(ctx))
	data.edge_red_before = snappedf(edge0, 0.001)
	var sc: Node = await ctx.spawn_ahead("scrapper", 9.0, 60.0, true)
	if not check("scrapper spawned (AI on)", sc != null):
		return false
	var first: Dictionary = await _wait_hurt(ctx, hurt, sc, names, 60.0)
	data.hurt_full = first
	check("player hit: direction indicator visible towards the scrapper (+-30 deg)", first.got and first.indicator_visible and absf(first.bearing_err_deg) <= 30.0 and first.arc_pixels, str(first))
	check("player hit: aimpunch > 0 then back to 0", first.got and first.aimpunch_max > 0.0 and first.aimpunch_end == 0.0, "max %.3f, end %.3f" % [first.get("aimpunch_max", -1.0), first.get("aimpunch_end", -1.0)])
	var snd_dir: String = ctx.oracle.cache_dir.path_join("cs2/ui/snd")
	if DirAccess.dir_exists_absolute(snd_dir):
		check("player hit: hurt sound playing", first.got and first.hurt_sound, str(first.get("last_sound")))
	else:
		note("no cs2/ui/snd in the cache: hurt sound not checked")
	# low health: setup health to 30 % of max, the next hit
	p.set("health", float(g.call("max_health")) * 0.3)
	var low: Dictionary = await _wait_hurt(ctx, hurt, sc, names, 60.0)
	data.hurt_low = low
	check("vignette alpha > 0 and higher at lower health (%.3f at %.0f %% > %.3f at %.0f %%)" % [low.get("vignette", -1.0), low.get("health_pct", -1.0), first.get("vignette", -1.0), first.get("health_pct", -1.0)],
		first.got and low.got and float(first.vignette) > 0.0 and float(low.vignette) > float(first.vignette), str({"full": [first.get("vignette"), first.get("health_pct")], "low": [low.get("vignette"), low.get("health_pct")]}))
	check("vignette seen in the rendered frame: screen corners redder at low health (%.3f) than before the hits (%.3f)" % [float(low.get("edge_red", 0.0)), edge0], low.got and float(low.get("edge_red", 0.0)) > edge0 + 0.02, str(low.get("edge_red")))
	p.set("invulnerable", true)
	if is_instance_valid(sc):
		ctx.set_ai(sc, false)
	p.set("health", float(g.call("max_health")))
	return true


func _shoot(ctx, inp, hits, m: Node, part: String, names: Dictionary) -> Dictionary:
	## one press of the fire button at a part; what the HUD did in the frames after it
	var g: Node = ctx.game
	var out := {"hit": false, "weak": false, "part": part, "marker_frames": -1, "style": "", "number_text": "", "number_visible": false, "marker_pixels": false}
	for attempt in 5:
		if part == "body":
			# a body point whose shot line first meets a non-weak body hitbox (lib/hitcheck.gd aim_body), by mouse motion
			var a: Dictionary = await HitCheck.aim_body(ctx, inp, m)
			out.aim = str(a.get("by", a.get("why", "")))
			if not a.get("ok", false):
				await ctx.wait(0.3)
				continue
		else:
			await ctx.call_api(g, "aim_at", [m, part])
			await ctx.physics_frames(1)
		var st0: Dictionary = g.call("fx_stats")
		var n0: int = hits.events.size()
		var nums: Control = names.DamageNumbers
		var kids0 := nums.get_child_count()
		inp.press("fire")
		# frames from the hit (player_hit_machine) until the hitmarker counter moved
		var f_hit := -1
		for f in 10:
			await ctx.frames(1)
			if f_hit < 0 and hits.events.size() > n0:
				f_hit = f
			var st: Dictionary = g.call("fx_stats")
			if f_hit >= 0 and int(st.get("hitmarkers", 0)) > int(st0.get("hitmarkers", 0)):
				out.marker_frames = f - f_hit
				out.style = str(st.get("hitmarker_style"))
				out.marker_visible = bool(st.get("hitmarker_visible")) and (names.Hitmarker as Control).is_visible_in_tree()
				break
		inp.release("fire")
		var ev: Array = hits.events.slice(n0).filter(func(e): return e.args[0] == m)
		if ev.is_empty():
			await ctx.wait(0.5)
			continue
		out.hit = true
		out.dealt = float(ev[0].args[1])
		out.weak = bool(ev[0].args[2])
		out.hit_pos = ev[0].args[3]
		out.particles = _particles_at(ctx, ev[0].args[3])
		# the rendered frame: hitmarker lines at the crosshair and the number label
		var img: Image = await _frame(ctx)
		out.marker_pixels = _marker_pixels(img, ctx, out.style)
		if nums.get_child_count() > kids0:
			var l := nums.get_child(nums.get_child_count() - 1) as Label
			out.number_text = l.text
			out.number_visible = l.is_visible_in_tree() and l.modulate.a > 0.1
			out.number_pos = [snappedf(l.position.x, 1.0), snappedf(l.position.y, 1.0)]
		break
	return out


func _marker_pixels(img: Image, ctx, style: String) -> bool:
	## the hitmarker's four diagonal strokes around the screen centre: the style colour at 70 % of its size
	if img == null:
		return false
	var row: Dictionary = ctx.oracle.system("fx.hitmarker").get(style if style != "" else "normal", {})
	var size := float(row.get("size_px", 14))
	var col: Array = row.get("color", [1, 1, 1, 1])
	var want := Color(float(col[0]), float(col[1]), float(col[2]))
	var vp: Vector2 = ctx.runner.get_viewport().get_visible_rect().size
	var sx := img.get_width() / vp.x
	var sy := img.get_height() / vp.y
	var c := vp * 0.5
	var found := 0
	for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var best := 9.0
		for t in [0.6, 0.7, 0.8]:
			var q: Vector2 = c + d.normalized() * size * t
			var px := img.get_pixel(clampi(int(q.x * sx), 0, img.get_width() - 1), clampi(int(q.y * sy), 0, img.get_height() - 1))
			best = minf(best, absf(px.r - want.r) + absf(px.g - want.g) + absf(px.b - want.b))
		if best < 0.35:
			found += 1
	return found >= 3


func _particles_at(ctx, pos: Variant) -> int:
	## impact particles the machine fx started at the hit point (sparks + debris emitters placed there: amount x ratio)
	if not (pos is Vector3):
		return 0
	var total := 0
	for n in ctx.tree.root.find_children("*", "GPUParticles3D", true, false):
		var gp := n as GPUParticles3D
		var root := gp.get_parent() as Node3D
		if root != null and root.global_position.distance_to(pos) < 0.05 and gp.emitting:
			total += int(round(gp.amount * gp.amount_ratio))
	return total


func _numbers_setting(ctx) -> bool:
	var t: Variant = ctx.tree.root.find_child("DamageNumbersToggle", true, false)
	return bool(t.button_pressed) if t is BaseButton else false


func _toggle_numbers(ctx, inp) -> bool:
	## Esc, click "Damage numbers", Esc
	await inp.tap("menu")
	await ctx.frames(2)
	var ok: bool = await inp.click_control("DamageNumbersToggle")
	await ctx.frames(2)
	await inp.tap("menu")
	await ctx.frames(2)
	return ok and not ctx.tree.paused


func _wait_hurt(ctx, hurt, src: Node, names: Dictionary, timeout_s: float) -> Dictionary:
	## the next player_hurt from the scrapper; indicator, vignette, aimpunch and sound right after it
	var g: Node = ctx.game
	var p: Node = ctx.player
	var n0: int = hurt.events.size()
	var got: bool = await ctx.wait_until(func(): return hurt.events.size() > n0 and float(hurt.events[n0].args[0]) > 0.0, timeout_s)
	if not got:
		return {"got": false, "machine_state": str(src.get("state")) if is_instance_valid(src) else "gone", "distance_m": snappedf((src as Node3D).global_position.distance_to(ctx.player_pos()), 0.1) if is_instance_valid(src) else -1.0}
	var e: Dictionary = hurt.events[n0]
	var out := {"got": true, "amount": e.args[0], "source_pos": str(e.args[1])}
	var aim_max := float(p.get("aimpunch_deg"))
	await ctx.frames(2)
	aim_max = maxf(aim_max, float(p.get("aimpunch_deg")))
	var st: Dictionary = g.call("fx_stats")
	out.health_pct = snappedf(float(p.get("health")) / float(g.call("max_health")) * 100.0, 0.1)
	out.indicator_visible = bool(st.get("indicator_visible")) and (names.DamageIndicator as Control).is_visible_in_tree()
	out.bearing_deg = snappedf(float(st.get("indicator_bearing_deg", 0.0)), 0.1)
	var cam: Camera3D = ctx.player_camera()
	var srcp: Vector3 = e.args[1] if e.args[1] is Vector3 and (e.args[1] as Vector3).is_finite() else ((src as Node3D).global_position if is_instance_valid(src) else Vector3.ZERO)
	var local: Vector3 = cam.global_transform.basis.inverse() * ((src as Node3D).global_position - cam.global_position) if is_instance_valid(src) else Vector3.FORWARD
	var true_b := rad_to_deg(atan2(local.x, -local.z))
	out.scrapper_bearing_deg = snappedf(true_b, 0.1)
	out.bearing_err_deg = snappedf(absf(wrapf(float(st.get("indicator_bearing_deg", 0.0)) - true_b, -180.0, 180.0)), 0.1)
	out.hurt_sound = bool(st.get("hurt_sound_playing"))
	out.last_sound = st.get("last_sound")
	# the rendered frame: the red arc at the indicator's bearing, red screen edge for the vignette
	var img: Image = await _frame(ctx)
	out.arc_pixels = _arc_pixels(img, ctx, deg_to_rad(float(st.get("indicator_bearing_deg", 0.0))), names.DamageIndicator)
	out.vignette = snappedf(float(g.call("fx_stats").get("vignette_alpha", 0.0)), 0.001)
	out.vignette_pixels = _edge_red(img) > 0.02
	out.edge_red = snappedf(_edge_red(img), 0.001)
	# aimpunch decays back to 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1500:
		aim_max = maxf(aim_max, float(p.get("aimpunch_deg")))
		if float(p.get("aimpunch_deg")) == 0.0 and Time.get_ticks_msec() - t0 > 100:
			break
		await ctx.frames(1)
	out.aimpunch_max = snappedf(aim_max, 0.001)
	out.aimpunch_end = float(p.get("aimpunch_deg"))
	out.srcp = str(srcp)
	return out


func _arc_pixels(img: Image, ctx, bearing: float, ind: Control) -> bool:
	## a red pixel on the indicator arc (radius 0.32 x the short side, centred on the bearing)
	if img == null:
		return false
	var vp: Vector2 = ctx.runner.get_viewport().get_visible_rect().size
	var sx := img.get_width() / vp.x
	var sy := img.get_height() / vp.y
	var c := ind.size * 0.5
	var r := minf(ind.size.x, ind.size.y) * 0.32
	var mid := -PI * 0.5 + bearing
	for dr in [-3.0, 0.0, 3.0]:
		for da in [-0.1, 0.0, 0.1]:
			var q: Vector2 = c + Vector2(cos(mid + da), sin(mid + da)) * (r + dr)
			var px := img.get_pixel(clampi(int(q.x * sx), 0, img.get_width() - 1), clampi(int(q.y * sy), 0, img.get_height() - 1))
			if px.r > 0.5 and px.r > px.g * 2.0 and px.r > px.b * 2.0:
				return true
	return false


static func _edge_red(img: Image) -> float:
	## how much redder than green/blue the screen corners are (vignette): mean of r - max(g, b) over corner samples
	if img == null:
		return 0.0
	var w := img.get_width()
	var h := img.get_height()
	var acc := 0.0
	var n := 0
	for fx in [0.02, 0.05, 0.95, 0.98]:
		for fy in [0.03, 0.06, 0.94, 0.97]:
			var px := img.get_pixel(int(fx * (w - 1)), int(fy * (h - 1)))
			acc += px.r - maxf(px.g, px.b)
			n += 1
	return acc / n


func _frame(ctx) -> Image:
	## the frame as rendered (HUD layers included); null with --headless (nothing is drawn, frame_post_draw never comes)
	if DisplayServer.get_name() == "headless":
		return null
	await RenderingServer.frame_post_draw
	return ctx.runner.get_viewport().get_texture().get_image()


func _fresh(ctx, old: Node) -> Node:
	## replaces the watcher by a fresh one (AI off) at the same distance in front
	var base: Vector3 = ctx.forward()
	ctx.despawn(old)
	await ctx.wait(0.2)
	var m: Node = await ctx.spawn_ahead("watcher", 8.0, 0.0, false, base)
	await ctx.wait(0.8)
	return m
