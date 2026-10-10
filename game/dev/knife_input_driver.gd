extends Node
## Knife models (0.3) through REAL input events (dev only, not exported):
##   godot --path game --script res://dev/knife_input.gd -- --mock-data [--knife-phase restart --knife-expect <id>]
## Phase "select" (default): 3 draws the knife, a left click hits a spawned machine (damage of the default model), F
## inspects; Esc opens the menu, a click on "Knife", a click on a knife in the list selects it (preview shown, knife
## in hand switches), Down / Up arrows move the selection, "Back" + Esc close the menu; F inspects the new model, a
## left click hits with the same damage; after death + respawn 3 draws the selected model again.
## Phase "restart": a new process; 3 draws the knife saved by the previous run (--knife-expect).
## Prints "KNIFEINPUT OK" or "KNIFEINPUT FAIL ..." and quits. Selection state is read through the Game API only.

const Sheets := preload("res://core/sheets.gd")

var _fails: PackedStringArray = []
var _game: Node
var _mouse := Vector2.ZERO
var _phase := "select"
var _expect := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		if a[i] == "--knife-phase" and i + 1 < a.size():
			_phase = a[i + 1]
		if a[i] == "--knife-expect" and i + 1 < a.size():
			_expect = a[i + 1]
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


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)
	await _frames(3)


func _tap(code: Key) -> void:
	await _key(code, true)
	await _key(code, false)


func _to_window(p: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * p


func _move(target: Vector2) -> void:
	var from := _mouse
	for k in range(1, 5):
		var p := from.lerp(target, k / 4.0)
		var ev := InputEventMouseMotion.new()
		ev.position = p
		ev.global_position = p
		ev.relative = p - _mouse
		_mouse = p
		Input.parse_input_event(ev)
		await _frames(1)
	await _frames(2)


func _click(at: Vector2) -> void:
	await _move(at)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		Input.parse_input_event(ev)
		await _frames(3)


func _control_center(c: Control) -> Vector2:
	return _to_window(c.get_global_rect().get_center())


func _menu() -> Node:
	return get_tree().root.find_child("SettingsLayer", true, false)


func _menu_control(n: String) -> Control:
	var m := _menu()
	return m.find_child(n, true, false) as Control if m else null


## Draws the knife with its slot key and returns the model in hand.
func _draw_knife() -> String:
	await _tap(KEY_3)
	await _ms(300)
	return _game.knife_model()


## Spawns a machine in front, aims at its body and hits it with a real left click; returns the health lost.
func _hit_once(tag: String) -> float:
	var p: Node3D = _game.player
	var fwd := -p.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var m: Node = _game.spawn_machine(Sheets.machine_ids()[0], p.global_position + fwd * 1.4)
	if m == null or not is_instance_valid(m):
		_check(false, "%s: machine spawned" % tag)
		return -1.0
	m.ai_enabled = false
	await _ms(800)
	var lost := -1.0
	for attempt in 8:
		_game.aim_at(m, "body")
		await _frames(2)
		var before: float = m.health
		await _click(_to_window(get_tree().root.get_visible_rect().size * 0.5))
		await _frames(2)
		if is_instance_valid(m) and m.health < before:
			lost = before - m.health
			break
		await _ms(1100)   # knife interval, then again (the machine may have stood out of reach)
	if is_instance_valid(m):
		_game.unregister_machine(m)
		m.queue_free()
	print("  %s: knife hit took %.1f health" % [tag, lost])
	return lost


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
	var vs: Vector2 = get_tree().root.get_visible_rect().size
	_mouse = _to_window(vs * 0.5)
	# knives are converted on demand: the saved one first, the rest after the start cells
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 180000:
		if _phase == "restart" and _game.knife_selected() == _expect:
			break
		if _phase != "restart" and _game.knife_ids().size() >= 3:
			break
		await _ms(500)
	print("  knives ready after %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	var ids: Array = _game.knife_ids()
	print("knives offered: %s, selected %s" % [ids, _game.knife_selected()])
	if _phase == "restart":
		_check(_game.knife_selected() == _expect, "after restart the selection is still %s (got %s)" % [_expect, _game.knife_selected()])
		var model := await _draw_knife()
		_check(model == _expect, "after restart 3 draws %s (got %s)" % [_expect, model])
		await _tap(KEY_F)
		_check(str(_game.knife_last_anim()).ends_with("inspect"), "after restart F plays %s's inspect clip (%s)" % [model, _game.knife_last_anim()])
		# back to the default knife through the menu (leaves the player's settings as they were)
		await _ms(2600)
		await _tap(KEY_ESCAPE)
		await _click(_control_center(_menu_control("KnifeButton")))
		var l := _menu_control("KnifeList") as ItemList
		for i in l.item_count:
			if str(l.get_item_metadata(i)) == "default":
				await _click(_to_window(l.get_global_transform() * l.get_item_rect(i).get_center()))
		await _click(_control_center(_menu_control("KnifeBack")))
		await _tap(KEY_ESCAPE)
		_check(_game.knife_selected() == "default" and _game.knife_model() == "default", "menu back to the default knife (%s, in hand %s)" % [_game.knife_selected(), _game.knife_model()])
		_finish()
		return
	_check(ids.size() >= 2, "index.json knives offered (%d incl. default)" % ids.size())
	var start_model := await _draw_knife()
	_check(start_model == _game.knife_selected(), "3 draws the selected knife %s (got %s)" % [_game.knife_selected(), start_model])
	var dmg_before := await _hit_once("before")
	await _tap(KEY_F)
	print("  inspect before: request %s, clip '%s'" % [_game.last_anim_request(), _game.knife_last_anim()])
	# pick a knife different from the current one, through the menu
	var target := ""
	for id in ids:
		if target == "" and str(id) != _game.knife_selected() and str(id) != "default":
			target = str(id)
	if target == "":
		target = "default" if _game.knife_selected() != "default" else ""
	_check(target != "", "a knife to switch to")
	await _tap(KEY_ESCAPE)
	_check(get_tree().paused, "Esc opens the menu (game paused)")
	var kb := _menu_control("KnifeButton")
	_check(kb != null and kb.is_visible_in_tree(), "Knife item in the Esc menu")
	if kb:
		await _click(_control_center(kb))
	var panel := _menu_control("KnifePanel")
	var list := _menu_control("KnifeList") as ItemList
	_check(panel != null and panel.visible and list != null, "Knife panel open")
	if list == null:
		_finish()
		return
	# knives keep converting in the background: the list is compared with the offer at this moment
	_check(list.item_count == _game.knife_ids().size(), "list shows %d knives (%d)" % [_game.knife_ids().size(), list.item_count])
	var ti := -1
	for i in list.item_count:
		if str(list.get_item_metadata(i)) == target:
			ti = i
	var r := list.get_item_rect(ti)
	await _click(_to_window(list.get_global_transform() * r.get_center()))
	await _frames(5)
	_check(_game.knife_selected() == target, "click on '%s' selects %s (selected %s)" % [list.get_item_text(ti), target, _game.knife_selected()])
	_check(_game.knife_model() == target, "the knife in hand is %s now (%s)" % [target, _game.knife_model()])
	var pivot: Node = _menu().find_child("Pivot", true, false)
	_check(pivot != null and pivot.get_child_count() > 0, "preview shows a model")
	# keyboard: Down then Up comes back to the target
	await _tap(KEY_DOWN)
	var after_down: String = _game.knife_selected()
	await _tap(KEY_UP)
	_check(_game.knife_selected() == target, "Down / Up in the list (%s -> %s -> %s)" % [target, after_down, _game.knife_selected()])
	var shot := OS.get_environment("HZS_KNIFE_SHOT")
	if shot != "":
		await _ms(1500)   # the preview turns a bit
		get_tree().root.get_texture().get_image().save_png(shot)
		print("  menu screenshot %s" % shot)
	await _click(_control_center(_menu_control("KnifeBack")))
	await _tap(KEY_ESCAPE)
	_check(not get_tree().paused, "Back + Esc close the menu")
	await _ms(800)
	await _tap(KEY_F)
	await _frames(3)
	_check(_game.last_anim_request() == "inspect", "F asks for inspect")
	if target != "default":
		_check(str(_game.knife_last_anim()).ends_with("inspect"), "F plays %s's inspect clip ('%s')" % [target, _game.knife_last_anim()])
	await _ms(2600)
	var dmg_after := await _hit_once("after")
	_check(dmg_before > 0.0 and is_equal_approx(dmg_before, dmg_after), "same knife damage with %s (%.1f == %.1f)" % [target, dmg_after, dmg_before])
	# death + respawn
	_game.kill_player()
	t0 = Time.get_ticks_msec()
	while not _game.player.is_alive() and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	_check(_game.player.is_alive(), "respawned")
	await _ms(1000)
	var after_respawn := await _draw_knife()
	_check(after_respawn == target, "after respawn 3 draws %s (got %s)" % [target, after_respawn])
	print("KNIFE TARGET %s" % target)
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("KNIFEINPUT OK")
	else:
		print("KNIFEINPUT FAIL %s" % "; ".join(_fails))
	_game.quit(0 if _fails.is_empty() else 1)
