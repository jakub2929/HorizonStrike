extends Node
## BHOP levels (0.3 H3) with REAL jump key presses timed to the landings (dev only, not exported):
##   godot --path game --script res://dev/bhop_input.gd -- --mock-data --user-dir <dir>
## For bhop levels 0, 1 and 5 (setup): knife out, one jump, then (setup) a horizontal speed of 1.6 x run speed in the
## air; after every landing the jump key is pressed 2 physics frames later (inside movement.bhop_window_ms), 7 jumps.
## Expected: jumps 1..N take off with >= 99 % of the landing speed, jump N+1 takes off at <= run speed x
## movement.bhop_clip_speed_mult (+1 %); level 0 clips every jump. Prints "BHOPINPUT OK" or "BHOPINPUT FAIL ...".

const Sheets := preload("res://core/sheets.gd")

var _fails: PackedStringArray = []
var _game: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_fails.append(what)


func _phys(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _jump() -> void:
	_key(KEY_SPACE, true)
	await _phys(1)
	_key(KEY_SPACE, false)


func _run() -> void:
	_game = get_tree().root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 120000:
		await get_tree().process_frame
	_check(_game.is_world_ready, "world_ready")
	if not _game.is_world_ready:
		_finish()
		return
	var p: CharacterBody3D = _game.player
	_key(KEY_3, true)
	await _phys(3)
	_key(KEY_3, false)
	await _phys(30)
	var run_speed: float = p.weapons.max_speed_u() * 0.0254
	var cap := run_speed * Sheets.sys_num("movement.bhop_clip_speed_mult", 1.0)
	print("  run speed %.2f m/s, clip cap %.2f m/s" % [run_speed, cap])
	for level in [0, 1, 5]:
		_game.set_progression({"upgrades": {"bhop": level}})
		await _phys(20)
		while not p.is_on_floor():
			await _phys(1)
		await _phys(10)
		await _jump()
		await _phys(4)
		# setup: a speed above the run speed, along the view direction
		var fwd := -p.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized() * run_speed * 1.6
		p.velocity.x = fwd.x
		p.velocity.z = fwd.z
		var rows: Array = []
		for j in range(1, 8):
			var guard := 0
			while not p.is_on_floor() and guard < 300:
				await _phys(1)
				guard += 1
			var landing: float = p.horizontal_speed
			await _phys(2)
			await _jump()
			# the take-off speed is read once the player is in the air (a jump can register a frame later)
			var g2 := 0
			while p.is_on_floor() and g2 < 10:
				await _phys(1)
				g2 += 1
			var takeoff: float = p.horizontal_speed
			rows.append([j, landing, takeoff])
		var line := PackedStringArray()
		for r in rows:
			line.append("%d: %.2f->%.2f" % [r[0], r[1], r[2]])
		print("  level %d: %s" % [level, ", ".join(line)])
		for r in rows:
			var j: int = r[0]
			if j <= level:
				_check(float(r[2]) >= float(r[1]) * 0.99, "level %d jump %d keeps speed (%.2f -> %.2f)" % [level, j, r[1], r[2]])
			elif j == level + 1:
				_check(float(r[2]) <= cap * 1.01 and float(r[1]) > cap * 1.0, "level %d jump %d clips (%.2f -> %.2f <= %.2f)" % [level, j, r[1], r[2], cap])
		await _phys(60)
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("BHOPINPUT OK")
	else:
		print("BHOPINPUT FAIL %s" % "; ".join(_fails))
	_game.quit(0 if _fails.is_empty() else 1)
