extends RefCounted
## Simulated player input inside the game process (Input.parse_input_event): the events take the same path as a
## real keyboard / mouse (GUI first, then _unhandled_input, action states for Input.is_action_*). The OS cursor and
## the user's devices are never touched. Keys and buttons come from the game's InputMap (its bindings), so the test
## presses whatever the player would press.

var ctx
var sent: Array = []  # what was sent, for the details


func _init(p_ctx) -> void:
	ctx = p_ctx


func binding(action: String) -> InputEvent:
	## first key / mouse button bound to the action; null when the game has no such action
	if not InputMap.has_action(action):
		return null
	for e in InputMap.action_get_events(action):
		if e is InputEventKey or e is InputEventMouseButton:
			return e
	return null


func describe(action: String) -> String:
	var e := binding(action)
	if e is InputEventKey:
		var k := (e as InputEventKey).physical_keycode if (e as InputEventKey).physical_keycode != 0 else (e as InputEventKey).keycode
		return OS.get_keycode_string(k)
	if e is InputEventMouseButton:
		return "mouse button %d" % (e as InputEventMouseButton).button_index
	return "unbound"


func press(action: String) -> bool:
	return _action(action, true)


func release(action: String) -> bool:
	return _action(action, false)


func tap(action: String, hold_frames: int = 3) -> bool:
	## press, keep it down for a few frames (games poll is_action_just_pressed in _process/_physics_process), release
	if not press(action):
		return false
	await ctx.frames(hold_frames + 1)
	await ctx.physics_frames(1)
	release(action)
	await ctx.frames(1)
	return true


func _action(action: String, pressed: bool) -> bool:
	var b := binding(action)
	if b == null:
		sent.append("%s: not bound" % action)
		return false
	var e: InputEvent
	if b is InputEventKey:
		var k := InputEventKey.new()
		k.physical_keycode = (b as InputEventKey).physical_keycode
		k.keycode = (b as InputEventKey).keycode if (b as InputEventKey).keycode != 0 else (b as InputEventKey).physical_keycode
		k.pressed = pressed
		e = k
	else:
		var m := InputEventMouseButton.new()
		m.button_index = (b as InputEventMouseButton).button_index
		m.pressed = pressed
		var pos := _cursor_window()
		m.position = pos
		m.global_position = pos
		m.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and m.button_index == MOUSE_BUTTON_LEFT else 0
		e = m
	Input.parse_input_event(e)
	sent.append("%s %s" % [action, "down" if pressed else "up"])
	return true


var _cursor := Vector2(-1, -1)


func _cursor_window() -> Vector2:
	if _cursor.x < 0.0:
		_cursor = to_window(ctx.runner.get_viewport().get_visible_rect().size * 0.5)
	return _cursor


func to_window(canvas_pos: Vector2) -> Vector2:
	## canvas (viewport) coordinates -> window coordinates, the space input events arrive in
	return ctx.runner.get_tree().root.get_final_transform() * canvas_pos


func mouse_move(canvas_pos: Vector2) -> void:
	var to := to_window(canvas_pos)
	var from := _cursor_window()
	var e := InputEventMouseMotion.new()
	e.position = to
	e.global_position = to
	e.relative = to - from
	e.screen_relative = to - from
	Input.parse_input_event(e)
	_cursor = to
	sent.append("mouse move to %s" % str(canvas_pos.round()))
	await ctx.frames(2)


func click(canvas_pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	await mouse_move(canvas_pos)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = button
		e.pressed = pressed
		e.position = _cursor
		e.global_position = _cursor
		e.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
		Input.parse_input_event(e)
		await ctx.frames(2)
	sent.append("click at %s" % str(canvas_pos.round()))


static func slot_action(weapon_id: String) -> String:
	## CS weapon slots: 1 primary, 2 pistol, 3 knife, 4 grenades (sheet column weapons.slot)
	var slot := str(WeaponsSheet.ROWS.get(weapon_id, {}).get("slot", ""))
	return {"primary": "slot1", "secondary": "slot2", "knife": "slot3", "grenade": "slot4"}.get(slot, "")


func equip(weapon_id: String) -> bool:
	## the player's way to take a weapon: its slot key, pressed again while another item of that slot is in hand
	var action := slot_action(weapon_id)
	if action == "":
		return false
	var p: Node = ctx.player
	if p != null and str(p.get("current_weapon")) == weapon_id:
		# already in hand: switch away first, so the slot key itself is exercised (a dead key must not pass)
		var away := "slot3" if action != "slot3" else "slot2"
		await tap(away)
		await ctx.wait(0.1)
		if str(p.get("current_weapon")) == weapon_id:
			sent.append("%s had no effect (still %s)" % [away, weapon_id])
			return false
	for i in 4:
		if p == null or str(p.get("current_weapon")) == weapon_id:
			break
		await tap(action)
		await ctx.wait(0.1)
	var ok: bool = p != null and str(p.get("current_weapon")) == weapon_id
	if ok:
		var deploy: float = ctx.oracle.num(ctx.oracle.weapon(weapon_id, "deploy_time"))
		await ctx.wait((deploy if not is_nan(deploy) else 1.0) + 0.15)
	return ok
