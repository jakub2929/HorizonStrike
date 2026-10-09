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


# --- mouse look (relative motion, like a player moving the mouse) ------------------------------------------------

var rad_per_px := 0.0022  # estimate; corrected from the camera's actual response
var look_events := 0


func look(dx: float, dy: float) -> void:
	## one relative mouse motion event; the game turns the camera by it (its mouse-look needs the captured mouse, see
	## capture_for_look)
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(dx, dy)
	e.screen_relative = Vector2(dx, dy)
	e.position = _cursor_window()
	e.global_position = e.position
	Input.parse_input_event(e)
	look_events += 1


func capture_for_look() -> bool:
	## mouse-look reacts only while the mouse is captured (as during play); returns whether it was captured before
	var was := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	return was


func yaw_pitch() -> Vector2:
	## camera yaw (0 = looking at -Z, positive to the left like Node3D.rotation.y) and pitch, radians
	var cam: Camera3D = ctx.camera()
	if cam == null:
		return Vector2.ZERO
	var f := -cam.global_transform.basis.z
	return Vector2(atan2(-f.x, -f.z), asin(clampf(f.y, -1.0, 1.0)))


static func yaw_pitch_to(from: Vector3, to: Vector3) -> Vector2:
	var d := to - from
	var h := Vector2(d.x, d.z).length()
	return Vector2(atan2(-d.x, -d.z), atan2(d.y, h))


func look_step(target_yaw: float, target_pitch: float, max_px: float = 300.0) -> Vector2:
	## one correction towards the target angles; returns the error (yaw, pitch) before this step
	var cur := yaw_pitch()
	var ey := wrapf(target_yaw - cur.x, -PI, PI)
	var ep := target_pitch - cur.y
	# the game turns yaw by -relative.x * sensitivity and pitch by -relative.y * sensitivity
	var dx := clampf(-ey / rad_per_px, -max_px, max_px)
	var dy := clampf(-ep / rad_per_px, -max_px, max_px)
	if absf(dx) >= 0.05 or absf(dy) >= 0.05:
		look(dx, dy)
	return Vector2(ey, ep)


func learn_sensitivity(before: Vector2, after: Vector2, sent_dx: float) -> void:
	if absf(sent_dx) > 3.0:
		var k := -wrapf(after.x - before.x, -PI, PI) / sent_dx
		if k > 0.00005 and k < 0.05:
			rad_per_px = lerpf(rad_per_px, k, 0.6)


func aim_at_point(p: Vector3, tol_rad: float = 0.002, max_frames: int = 240) -> Dictionary:
	## turn the camera onto a world point with relative mouse motion only (closed loop on the camera's real
	## orientation; the sensitivity is learned from the response)
	var cam: Camera3D = ctx.camera()
	if cam == null:
		return {"ok": false, "why": "no camera"}
	var err := Vector2(INF, INF)
	for i in max_frames:
		var before := yaw_pitch()
		var t := yaw_pitch_to(cam.global_position, p)
		err = look_step(t.x, t.y)
		if absf(err.x) < tol_rad and absf(err.y) < tol_rad:
			return {"ok": true, "frames": i, "rad_per_px": rad_per_px}
		var dx := clampf(-err.x / rad_per_px, -300.0, 300.0)
		await ctx.frames(1)
		learn_sensitivity(before, yaw_pitch(), dx)
	return {"ok": false, "why": "not converged", "error_rad": [err.x, err.y], "rad_per_px": rad_per_px}
