extends Node
## Weapons converted after the start (0.3) through REAL input (dev only, not exported):
##   godot --path game --script res://dev/late_weapons.gd -- --mock-data --mock-weapons-late --user-dir <dir>
## Right after world_ready: B opens the wheel, a weapon that is still converting shows "Preparing...", a click on it
## is refused (log `buywheel: denied <id> (preparing)`, money unchanged); once its done event arrived the same click
## buys it. Prints "LATEINPUT OK" / "LATEINPUT FAIL ...".

const Sheets := preload("res://core/sheets.gd")
const WeaponAssets := preload("res://core/weapon_assets.gd")

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


func _key(code: Key, pressed: bool) -> void:
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
	await _frames(3)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		Input.parse_input_event(ev)
		await _frames(3)


func _item_pos(id: String) -> Vector2:
	var slot: Control = _game.buy_wheel.find_child("BuyItem_" + id, true, false)
	return _to_window(slot.get_global_rect().get_center()) if slot else Vector2(-1, -1)


func _run() -> void:
	_game = get_tree().root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	_check(_game.is_world_ready, "world_ready")
	await _frames(5)
	_mouse = _to_window(get_tree().root.get_visible_rect().size * 0.5)
	var target := "galilar"
	_game.money = 5000   # setup: enough money for a rifle
	_check(not WeaponAssets.is_ready(target), "%s is still converting right after world_ready (%s)" % [target, WeaponAssets.state(target)])
	await _key(KEY_B, true)
	await _key(KEY_B, false)
	_check(_game.buy_wheel.is_open(), "B opens the wheel")
	await _frames(3)
	var price_l: Label = _game.buy_wheel.find_child("BuyItem_" + target, true, false).get_node("Price")
	_check(price_l.text.begins_with("Preparing"), "the item shows '%s'" % price_l.text)
	var shot := OS.get_environment("HZS_LATE_SHOT")
	if shot != "":
		get_tree().root.get_texture().get_image().save_png(shot)
	var m0: int = _game.money
	await _click(_item_pos(target))
	_check(_game.money == m0 and not _game.player.inventory.has(target), "click on a preparing item does not buy it (money %d)" % _game.money)
	t0 = Time.get_ticks_msec()
	while not WeaponAssets.is_ready(target) and Time.get_ticks_msec() - t0 < 60000:
		await _frames(5)
	_check(WeaponAssets.is_ready(target), "%s became ready (done event)" % target)
	await _frames(3)
	_check(price_l.text.begins_with("$"), "the item shows its price now ('%s')" % price_l.text)
	await _click(_item_pos(target))
	_check(_game.player.inventory.has(target) and _game.money == m0 - Sheets.price(target), "the same click buys it now (money %d)" % _game.money)
	await _key(KEY_B, true)
	await _key(KEY_B, false)
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("LATEINPUT OK")
	else:
		print("LATEINPUT FAIL %s" % "; ".join(_fails))
	_game.quit(0 if _fails.is_empty() else 1)
