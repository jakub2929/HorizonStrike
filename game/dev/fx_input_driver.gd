extends Node
## Hit effects (0.3 H4) with REAL clicks (dev only, not exported):
##   godot --path game --script res://dev/fx_input.gd -- --mock-data --user-dir <dir>
## Body hit -> Hitmarker (normal) + a damage number with the dealt value; weak hit -> weak style + more impact sparks;
## damage numbers off through the Esc menu toggle (clicks) -> no number; player hurt by a machine (setup: damage from
## the machine as source) -> DamageIndicator towards it (+-30 deg), Vignette alpha > 0 and higher at lower health,
## aimpunch > 0 then back to 0. Screenshots with HZS_FX_SHOT=<prefix>. Prints "FXINPUT OK" / "FXINPUT FAIL ...".

const Sheets := preload("res://core/sheets.gd")

var _fails: PackedStringArray = []
var _game: Node
var _mouse := Vector2.ZERO
var _hit := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_fails.append(what)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _ms(n: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < n:
		await get_tree().process_frame


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(3)


func _to_window(p: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * p


func _click(at: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	mv.relative = at - _mouse
	_mouse = at
	Input.parse_input_event(mv)
	await _frames(2)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		Input.parse_input_event(ev)
		if pressed:
			await _frames(1)


func _center() -> Vector2:
	return _to_window(get_tree().root.get_visible_rect().size * 0.5)


func _shot(name: String) -> void:
	var pre := OS.get_environment("HZS_FX_SHOT")
	if pre != "":
		get_tree().root.get_texture().get_image().save_png("%s_%s.png" % [pre, name])


## One click at a part; returns the frames until the hitmarker showed (-1 = none) and fills _hit.
func _shoot(m: Node, part: String) -> int:
	_hit = {}
	for attempt in 6:
		_game.aim_at(m, part)
		await _frames(2)
		var before: int = _game.fx_stats()["hitmarkers"]
		await _click(_center())
		for f in 4:
			if int(_game.fx_stats()["hitmarkers"]) > before:
				return f
			await _frames(1)
		await _ms(400)
	return -1


func _run() -> void:
	_game = get_tree().root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	_check(_game.is_world_ready, "world_ready")
	if not _game.is_world_ready:
		_finish()
		return
	await _ms(1500)
	_mouse = _center()
	_game.player_hit_machine.connect(func(_m, dmg, weak, pos, _k): _hit = {"damage": dmg, "weak": weak, "pos": pos})
	var hud: Node = _game.hud
	var p: CharacterBody3D = _game.player
	var fwd := -p.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var m: Node = _game.spawn_machine(Sheets.machine_ids()[0], p.global_position + fwd * 5.0)
	m.ai_enabled = false
	await _ms(800)
	# body hit
	var f := await _shoot(m, "body")
	var st: Dictionary = _game.fx_stats()
	_check(f >= 0 and f <= 2 and st["hitmarker_style"] == ("weak" if _hit.get("weak", false) else "normal"), "body hit: hitmarker within %d frames, style %s" % [f, st["hitmarker_style"]])
	var nums: Control = hud.find_child("DamageNumbers", true, false)
	var last_num := ""
	if nums and nums.get_child_count() > 0:
		last_num = (nums.get_child(nums.get_child_count() - 1) as Label).text
	_check(last_num == str(int(round(float(_hit.get("damage", -1))))), "damage number '%s' == dealt %.1f" % [last_num, float(_hit.get("damage", -1))])
	var sparks_body := int(st.get("sparks", 0))
	await _frames(2)
	_shot("body")
	await _ms(600)
	# weak hit
	var weak_part := str(m.weak_spots()[0]) if m.weak_spots().size() > 0 else "body"
	var sp0 := int(_game.fx_stats().get("sparks", 0))
	f = await _shoot(m, weak_part)
	st = _game.fx_stats()
	_check(f >= 0 and st["hitmarker_style"] == "weak" and bool(_hit.get("weak", false)), "weak hit (%s): weak hitmarker (%s)" % [weak_part, st["hitmarker_style"]])
	print("  impact stats: %s (body spawned %d, before weak %d)" % [st.get("impact", {}), sparks_body, sp0])
	_shot("weak")
	await _ms(600)
	# numbers off through the Esc menu
	await _key(KEY_ESCAPE)
	var tog: Control = get_tree().root.find_child("DamageNumbersToggle", true, false)
	await _click(_to_window(tog.get_global_rect().get_center()))
	await _key(KEY_ESCAPE)
	await _ms(300)
	var n0 := int(_game.fx_stats()["numbers"])
	f = await _shoot(m, "body")
	_check(f >= 0 and int(_game.fx_stats()["numbers"]) == n0, "numbers off: hit without a number (%d -> %d)" % [n0, int(_game.fx_stats()["numbers"])])
	await _key(KEY_ESCAPE)
	await _click(_to_window(tog.get_global_rect().get_center()))
	await _key(KEY_ESCAPE)
	# player hurt from a machine on the right (setup: damage call with the machine as source)
	var right := p.global_transform.basis.x
	right.y = 0.0
	var src: Node = _game.spawn_machine(Sheets.machine_ids()[0], p.global_position + right.normalized() * 6.0)
	src.ai_enabled = false
	await _ms(500)
	p.health = _game.max_health()
	p.apply_damage(15.0, 0.0, src, "fx test")
	await _frames(1)   # fx.aimpunch decays a small kick within a few frames
	var punch := float(_game.fx_stats()["aimpunch_deg"])
	await _frames(2)
	st = _game.fx_stats()
	_check(bool(st["indicator_visible"]) and absf(float(st["indicator_bearing_deg"]) - 90.0) <= 30.0, "indicator towards the machine on the right (%.0f deg)" % float(st["indicator_bearing_deg"]))
	_check(punch > 0.0, "aimpunch %.2f deg one frame after the hit" % punch)
	if DirAccess.dir_exists_absolute(str(_game.cache_root).path_join("cs2/ui/snd")):
		_check(bool(st["hurt_sound_playing"]) and int(st["sounds"]) >= 3, "hurt sound playing, %d feedback sounds (last %s)" % [int(st["sounds"]), st["last_sound"]])
	_shot("hurt")
	await _ms(800)
	var a_high := float(_game.fx_stats()["vignette_alpha"])
	p.apply_damage(p.health - _game.max_health() * 0.2, 0.0, src, "fx test")
	await _ms(800)
	var a_low := float(_game.fx_stats()["vignette_alpha"])
	_check(a_low > 0.0 and a_low > a_high, "vignette alpha %.3f at %.0f %% health > %.3f at 85 %%" % [a_low, p.health / _game.max_health() * 100.0, a_high])
	_shot("lowhp")
	await _ms(1500)
	_check(float(_game.fx_stats()["aimpunch_deg"]) == 0.0, "aimpunch back to 0")
	print("  fx_stats %s" % JSON.stringify(_game.fx_stats()))
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("FXINPUT OK")
	else:
		print("FXINPUT FAIL %s" % "; ".join(_fails))
	_game.quit(0 if _fails.is_empty() else 1)
