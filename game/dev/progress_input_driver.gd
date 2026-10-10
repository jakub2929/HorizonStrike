extends Node
## XP, levels, upgrades and the silent strike (0.3 H2) through REAL input events (dev only, not exported):
##   godot --path game --script res://dev/progress_input.gd -- --mock-data --user-dir <dir> [--prog-phase restart]
## Phase "play": progression reset (setup); body kill with the pistol (left clicks) -> xp + machines.xp_reward; weak
## kill -> + weak bonus; silent strike (knife, right click into a machine turned away) -> + silent bonus and one stab
## kills; crossing a level -> level + 1, points + xp.points_per_level, HUD LevelUpNotice; points = 2 (setup), K opens
## the upgrades menu, clicks on Upgrade_damage and Upgrade_max_health; pistol damage x (1 + pct), max health and
## health after respawn = base + hp_per_level.
## Phase "restart": a new process with the same --user-dir; level, points and upgrades are still there.
## Prints "PROGINPUT OK" or "PROGINPUT FAIL ...". State is read through the Game API only (setup writes as stated).

const Sheets := preload("res://core/sheets.gd")
const Progression := preload("res://core/progression.gd")

var _fails: PackedStringArray = []
var _game: Node
var _mouse := Vector2.ZERO
var _phase := "play"
var _last_hit := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		if a[i] == "--prog-phase" and i + 1 < a.size():
			_phase = a[i + 1]
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


func _click(at: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	await _move(at)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.position = at
		ev.global_position = at
		ev.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if pressed else 0
		Input.parse_input_event(ev)
		await _frames(3)


func _center() -> Vector2:
	return _to_window(get_tree().root.get_visible_rect().size * 0.5)


func _control(n: String) -> Control:
	return get_tree().root.find_child(n, true, false) as Control


func _spawn(dist: float, facing_away: bool) -> Node:
	var p: Node3D = _game.player
	var fwd := -p.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var m: Node = _game.spawn_machine(Sheets.machine_ids()[0], p.global_position + fwd * dist)
	m.ai_enabled = false
	if facing_away:
		(m as Node3D).rotate_y(PI)
	await _ms(800)
	return m


## Fires with real clicks at the given part until the machine dies; returns the XP of the kill (-1 = no kill).
func _kill(m: Node, part: String, button: MouseButton = MOUSE_BUTTON_LEFT, max_clicks: int = 40) -> int:
	var xp0 := int(_game.progression["xp"])
	for i in max_clicks:
		if not is_instance_valid(m) or str(m.state) == "dead":
			break
		_game.aim_at(m, part)
		await _frames(2)
		await _click(_center(), button)
		await _ms(450 if button == MOUSE_BUTTON_LEFT else 1100)
	var killed := is_instance_valid(m) and str(m.state) == "dead"
	await _ms(200)
	if is_instance_valid(m):
		_game.unregister_machine(m)
		m.queue_free()
	return int(_game.progression["xp"]) - xp0 if killed else -1


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
	_game.player_hit_machine.connect(func(_m, dmg, weak, _pos, killed): _last_hit = {"damage": dmg, "weak": weak, "killed": killed})
	var up_d: Dictionary = Sheets.sys("upgrades.damage")
	var up_h: Dictionary = Sheets.sys("upgrades.max_health")
	if _phase == "restart":
		var p: Dictionary = _game.progression
		print("  progression after restart: %s" % JSON.stringify(p))
		_check(int(p["upgrades"]["damage"]) == 1 and int(p["upgrades"]["max_health"]) == 1 and int(p["points"]) == 0,
			"after restart: upgrades damage 1, max_health 1, points 0")
		_check(int(p["level"]) >= 1, "after restart: level kept (%d)" % int(p["level"]))
		var mh: float = float(up_h["base"]) + float(up_h["hp_per_level"])
		_check(is_equal_approx(_game.player.health, mh), "after restart: health %.0f == %.0f" % [_game.player.health, mh])
		_finish()
		return
	_game.set_progression({"xp": 0, "level": 0, "points": 0, "upgrades": {"damage": 0, "max_health": 0, "bhop": 0}})
	var type: String = Sheets.machine_ids()[0]
	var reward := int(Sheets.machine_num(type, "xp_reward", 0.0))
	print("  machine %s, xp_reward %d" % [type, reward])
	# 1. body kill with the pistol
	await _tap(KEY_2)
	await _ms(600)
	var m := await _spawn(4.0, false)
	var xp := await _kill(m, "body")
	var exp_body := Progression.kill_xp(type, bool(_last_hit.get("weak", false)), false)
	_check(xp == exp_body and not bool(_last_hit.get("weak", true)), "body kill: +%d xp (expected %d = xp_reward, last hit weak %s)" % [xp, exp_body, _last_hit.get("weak")])
	# 2. weak-spot kill
	var weak_part := ""
	m = await _spawn(4.0, false)
	for w in m.weak_spots():
		weak_part = str(w.get("part", "")) if typeof(w) == TYPE_DICTIONARY else str(w)
		break
	xp = await _kill(m, weak_part)
	var exp_weak := Progression.kill_xp(type, true, false)
	_check(xp == exp_weak and bool(_last_hit.get("weak", false)), "weak kill (%s): +%d xp (expected %d)" % [weak_part, xp, exp_weak])
	# 3. silent strike: knife, right click into a machine turned away
	await _tap(KEY_3)
	await _ms(800)
	m = await _spawn(1.4, true)
	print("  machine state %s" % m.state)
	xp = await _kill(m, "body", MOUSE_BUTTON_RIGHT, 1)
	var exp_silent := Progression.kill_xp(type, bool(_last_hit.get("weak", false)), true)
	_check(xp == exp_silent, "silent strike: one stab kills, +%d xp (expected %d)" % [xp, exp_silent])
	# 4. level-up (setup: xp 1 below the next level, then one kill)
	var p: Dictionary = _game.progression
	var next := Progression.total_for(int(p["level"]) + 1)
	_game.set_progression({"xp": next - 1})
	var pts0 := int(_game.progression["points"])
	var lvl0 := int(_game.progression["level"])
	await _tap(KEY_2)
	await _ms(600)
	m = await _spawn(4.0, false)
	await _kill(m, "body")
	p = _game.progression
	_check(int(p["level"]) == lvl0 + 1 and int(p["points"]) == pts0 + int(Sheets.sys_num("xp.points_per_level", 1.0)),
		"level-up: level %d -> %d, points %d -> %d" % [lvl0, int(p["level"]), pts0, int(p["points"])])
	var notice := _control("LevelUpNotice")
	_check(notice != null and notice.visible, "HUD LevelUpNotice visible")
	var shot := OS.get_environment("HZS_PROG_SHOT")
	# 5. upgrades through the K menu
	var base_hit := await _one_hit()
	_game.set_progression({"points": 2})
	await _tap(KEY_K)
	_check(get_tree().paused and _control("UpgradesMenu").visible, "K opens the upgrades menu")
	await _click(_to_window(_control("Upgrade_damage").get_global_rect().get_center()))
	await _click(_to_window(_control("Upgrade_max_health").get_global_rect().get_center()))
	if shot != "":
		await _ms(300)
		get_tree().root.get_texture().get_image().save_png(shot)
		print("  upgrades screenshot %s" % shot)
	p = _game.progression
	_check(int(p["upgrades"]["damage"]) == 1 and int(p["upgrades"]["max_health"]) == 1 and int(p["points"]) == 0,
		"clicks bought damage 1 and max_health 1 (%s)" % JSON.stringify(p["upgrades"]))
	await _tap(KEY_K)
	_check(not get_tree().paused, "K closes the menu")
	var up_hit := await _one_hit()
	var ratio := up_hit / maxf(base_hit, 0.001)
	var want := 1.0 + float(up_d["pct_per_level"]) / 100.0
	_check(absf(ratio - want) <= want * 0.005, "pistol body hit %.2f -> %.2f (x%.4f, expected x%.2f)" % [base_hit, up_hit, ratio, want])
	var mh: float = float(up_h["base"]) + float(up_h["hp_per_level"])
	_game.kill_player()
	t0 = Time.get_ticks_msec()
	while not _game.player.is_alive() and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	await _ms(500)
	_check(is_equal_approx(_game.max_health(), mh) and is_equal_approx(_game.player.health, mh), "after respawn max health %.0f, health %.0f (expected %.0f)" % [_game.max_health(), _game.player.health, mh])
	_finish()


## One pistol body hit on a fresh machine (full health and armour): the health damage dealt.
func _one_hit() -> float:
	var m := await _spawn(4.0, false)
	_last_hit = {}
	for i in 6:
		_game.aim_at(m, "body")
		await _frames(2)
		await _click(_center())
		await _frames(3)
		if not _last_hit.is_empty() and not bool(_last_hit["weak"]):
			break
		_last_hit = {}
		await _ms(450)
	_game.unregister_machine(m)
	m.queue_free()
	return float(_last_hit.get("damage", -1.0))


func _finish() -> void:
	if _fails.is_empty():
		print("PROGINPUT OK")
	else:
		print("PROGINPUT FAIL %s" % "; ".join(_fails))
	_game.quit(0 if _fails.is_empty() else 1)
