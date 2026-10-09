extends Node
## Buy wheel through REAL input events (dev only, not exported). Used two ways:
##   editor:  godot --path game --script res://dev/buy_input.gd -- [--mock-data | --game ... --cache-dir ...]
##   release: copy this file next to the exported exe and add it as an autoload in an override.cfg there
##            ([autoload] BuyInputDriver="*C:/abs/path/buy_input_driver.gd"); release templates ignore --script.
##            Start with --exit-after so the run counts as automated (the game never captures the user's mouse).
## Drives the wheel like a player: B key (InputEventKey), mouse motion onto the item (InputEventMouseMotion), left
## click (InputEventMouseButton), plus the hold-B / release-to-buy variant. Buys a pistol, a rifle, a grenade and
## kevlar, then a denied buy without money. Prints "BUYINPUT OK" or "BUYINPUT FAIL ..." and quits.
## Money is set directly between steps (setup, printed) so the rifle and the denied buy are reachable.

const Sheets := preload("res://core/sheets.gd")

var _fails: PackedStringArray = []
var _game: Node
var _mouse := Vector2.ZERO


func _ready() -> void:
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


## Canvas position -> window position (the events are window coordinates, like the OS sends them).
func _to_window(p: Vector2) -> Vector2:
	return get_tree().root.get_final_transform() * p


func _move(target: Vector2) -> void:
	# a few steps like a real mouse sweep
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
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		Input.parse_input_event(ev)
		await _frames(2)


func _item_pos(id: String) -> Vector2:
	var slot: Control = _game.buy_wheel.find_child("BuyItem_" + id, true, false)
	if slot == null:
		return Vector2(-1, -1)
	return _to_window(slot.get_global_rect().get_center())


func _wheel_open() -> bool:
	return _game.buy_wheel != null and _game.buy_wheel.is_open()


## B tap opens, mouse onto the item, click buys, B tap closes.
func _buy_click(id: String) -> void:
	await _key(KEY_B, true)
	await _key(KEY_B, false)
	_check(_wheel_open(), "B tap opens the wheel (%s)" % id)
	var at := _item_pos(id)
	await _move(at)
	await _click(at)
	await _key(KEY_B, true)
	await _key(KEY_B, false)
	_check(not _wheel_open(), "B tap closes the wheel (%s)" % id)


func _run() -> void:
	_game = get_tree().root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	_check(_game.is_world_ready, "world_ready")
	if not _game.is_world_ready:
		_finish()
		return
	await _frames(30)
	var p: Node = _game.player
	var vs: Vector2 = get_tree().root.get_visible_rect().size
	print("window %s, viewport %s, mouse mode %d, in combat %s" % [DisplayServer.window_get_size(), vs, Input.mouse_mode, _game.in_combat()])
	_mouse = _to_window(vs * 0.5)

	# 1. pistol (click)
	var m0: int = _game.money
	await _buy_click("p250")
	_check(_game.money == m0 - Sheets.price("p250") and p.inventory.has("p250"), "pistol p250 bought: money %d -> %d, inventory %s" % [m0, _game.money, p.inventory])

	# 2. rifle (hold B, hover, release B)
	_game.money = 10000
	print("  setup: money set to $10000")
	await _key(KEY_B, true)
	_check(_wheel_open(), "B held opens the wheel")
	await _move(_item_pos("ak47"))
	await _ms(400)   # held long enough to count as a hold
	await _key(KEY_B, false)
	_check(p.inventory.has("ak47") and _game.money == 10000 - Sheets.price("ak47"), "rifle ak47 bought by releasing B: money %d, inventory %s" % [_game.money, p.inventory])
	_check(not _wheel_open(), "releasing B after the buy closes the wheel")

	# 3. grenade (click)
	m0 = _game.money
	await _buy_click("hegrenade")
	_check(p.inventory.has("hegrenade") and _game.money == m0 - Sheets.price("hegrenade"), "grenade hegrenade bought: money %d -> %d" % [m0, _game.money])

	# 4. kevlar (click)
	m0 = _game.money
	var a0: float = p.armor
	await _buy_click("kevlar")
	_check(p.armor > a0 and _game.money == m0 - Sheets.price("kevlar"), "kevlar bought: armor %.0f -> %.0f, money %d -> %d" % [a0, p.armor, m0, _game.money])

	# 5. denied without money (click)
	_game.money = 0
	print("  setup: money set to $0")
	await _buy_click("deagle")
	_check(not p.inventory.has("deagle") and _game.money == 0, "deagle denied without money (money %d, inventory %s)" % [_game.money, p.inventory])
	_finish()


func _finish() -> void:
	print("BUYINPUT OK" if _fails.is_empty() else "BUYINPUT FAIL %s" % ", ".join(_fails))
	get_tree().quit(0 if _fails.is_empty() else 1)
