extends SceneTree
## H1 smoke test (dev only, not exported):
##   godot --headless --path game --script res://dev/smoke.gd -- --mock-data
## Boots the real main scene, waits for world_ready and checks the vertical slice through the Game API:
## start loadout + money, CS movement speed, buy wheel items + buying, hitscan body vs weak spot, kill reward.

const Sheets := preload("res://core/sheets.gd")
const Combat := preload("res://core/combat.gd")

var _fails: PackedStringArray = []
var _game: Node


func _initialize() -> void:
	var main: Node = load("res://main/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond:
		_fails.append(what)


func _wait(sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(sec * 1000.0):
		await physics_frame


func _run() -> void:
	_game = root.get_node("Game")
	var t0 := Time.get_ticks_msec()
	while not _game.is_world_ready and Time.get_ticks_msec() - t0 < 90000:
		await process_frame
	_check(_game.is_world_ready, "world_ready within 90 s (bootstrap %.2f s)" % _game.bootstrap_seconds)
	if not _game.is_world_ready:
		_finish()
		return
	await _wait(0.5)
	var p: Node3D = _game.player
	# 1. start loadout + money
	var inv: Array = p.inventory
	_check(inv == Sheets.start_loadout_ids(), "start inventory %s == %s" % [inv, Sheets.start_loadout_ids()])
	_check(_game.money == int(Sheets.sys_num("economy.start_money", 800)), "start money $%d" % _game.money)
	var ga: Vector2i = p.ammo("glock")
	_check(ga.x == int(Sheets.weapon_num("glock", "clip_size", 0)) and ga.x > 0, "glock clip %d" % ga.x)
	_check(p.current_weapon == "glock", "glock equipped")
	# 2. terrain under the player + CS movement on ground
	var on_floor_ok := false
	for i in 120:
		await physics_frame
		if p.is_on_floor():
			on_floor_ok = true
			break
	_check(on_floor_ok, "player stands on the terrain at %s" % p.global_position)
	p.scripted = true
	p.scripted_move = Vector2(0, -1)
	await _wait(1.5)
	var hs := Vector2(p.velocity.x, p.velocity.z).length()
	var expect := Sheets.weapon_pair("glock", "max_speed") * Sheets.sys_num("combat.units_to_m", 0.0254)
	_check(absf(hs - expect) < expect * 0.06, "run speed %.2f m/s ~ glock max_speed %.2f m/s" % [hs, expect])
	p.scripted_move = Vector2.ZERO
	await _wait(1.0)
	hs = Vector2(p.velocity.x, p.velocity.z).length()
	_check(hs < 0.05, "friction stops the player (%.3f m/s)" % hs)
	var y0: float = p.global_position.y
	p.scripted_jump = true
	var peak := y0
	for i in 60:
		await physics_frame
		peak = maxf(peak, p.global_position.y)
	var u := Sheets.sys_num("combat.units_to_m", 0.0254)
	var jh := pow(Sheets.sys_num("movement.jump_impulse_u", 301.99) * u, 2) / (2.0 * Sheets.sys_num("movement.gravity_u", 800) * u)
	_check(absf((peak - y0) - jh) < 0.12, "jump height %.2f m ~ %.2f m" % [peak - y0, jh])
	p.scripted = false
	await _wait(0.8)
	# 3. buy wheel + buying
	_game.open_buy_wheel()
	await process_frame
	var wheel: Node = _game.buy_wheel
	_check(wheel.is_open(), "buy wheel opens")
	var items: Array = _game.buy_wheel_item_ids()
	_check(items.size() == 12, "buy wheel lists 12 items (%d)" % items.size())
	_game.close_buy_wheel()
	# t03-style: money 3000, ak47 then hegrenade then awp (expectations from resolved prices)
	_game.money = 3000
	var ok1: bool = _game.buy("ak47")
	var after_ak: int = _game.money
	var ok2: bool = _game.buy("hegrenade")
	var after_he: int = _game.money
	var inv_before: Array = p.inventory.duplicate()
	var ok3: bool = _game.buy("awp")
	var exp_ak := maxi(3000 - Sheets.price("ak47"), 0)
	_check(ok1 and after_ak == 3000 - Sheets.price("ak47") and p.inventory.has("ak47"), "t03 ak47: money %d == %d" % [after_ak, exp_ak])
	var exp_he := after_ak - Sheets.price("hegrenade")
	_check(ok2 == (exp_he >= 0) and (not ok2 or (after_he == exp_he and p.inventory.has("hegrenade"))), "t03 hegrenade: money %d (expected %d)" % [after_he, exp_he])
	_check(not ok3 and _game.money == after_he and p.inventory == inv_before, "t03 awp refused, money stays %d" % _game.money)
	_game.money = 5000
	var price := Sheets.price("ak47")
	var ok: bool = _game.buy("ak47")
	_check(ok and _game.money == 5000 - price and p.inventory.has("ak47"), "buy ak47: money %d (price %d), inventory %s" % [_game.money, price, p.inventory])
	_game.money = 0
	_check(not _game.buy("awp") and _game.money == 0, "buy awp with $0 refused")
	# 4. hitscan: weak spot vs body on a machine without AI
	_game.equip("ak47")
	await _wait(0.2)
	var fwd: Vector3 = -p.global_transform.basis.z
	var pos: Vector3 = p.global_position + fwd * 10.0
	var m: Node = _game.spawn_machine("watcher", pos + Vector3(0, 1.0, 0))
	m.ai_enabled = false
	var m2: Node = _game.spawn_machine("watcher", pos + p.global_transform.basis.x * 4.0 + Vector3(0, 1.0, 0))
	m2.ai_enabled = false
	await _wait(1.5)
	_check(m.weak_spots().size() >= 1, "watcher weak spots %s" % [m.weak_spots()])
	_game.aim_at(m, "eye")
	var r1: Dictionary = _game.fire()
	await _wait(0.3)
	_game.aim_at(m2, "body")
	var r2: Dictionary = _game.fire()
	print("  weak: %s   body: %s" % [r1, r2])
	print("  eye at %s, player cam %s" % [m.aim_point("eye"), p.camera.global_position])
	_check(r1.get("hit", false) and r1.get("part") == "eye", "weak-spot shot hits the eye")
	_check(r2.get("hit", false) and r2.get("part") == "body", "body shot hits the body")
	_check(float(r1.get("damage", 0)) > float(r2.get("damage", 0)), "weak damage %.1f > body damage %.1f" % [r1.get("damage", 0), r2.get("damage", 0)])
	var d_eye: float = p.camera.global_position.distance_to(m.aim_point("eye"))
	var exp_weak := Combat.range_falloff("ak47", Sheets.weapon_num("ak47", "damage"), d_eye) * Sheets.weapon_num("ak47", "headshot_mult")
	_check(absf(float(r1.get("damage", 0)) - exp_weak) < exp_weak * 0.02, "weak damage %.2f == damage x falloff x headshot %.2f" % [r1.get("damage", 0), exp_weak])
	# 5. every machine type has a weak spot, then a kill pays the reward
	var other := ["grazer", "strider"]
	for o in other:
		var mm: Node = _game.spawn_machine(o, pos + p.global_transform.basis.x * -5.0 + Vector3(0, 1.0, 0))
		mm.ai_enabled = false
		await _wait(0.5)
		_check(mm.weak_spots().size() >= 1, "%s weak spots %s" % [o, mm.weak_spots()])
		mm.queue_free()
	if is_instance_valid(m) and not m.is_dead():
		m.queue_free()
	m = _game.spawn_machine("watcher", pos + Vector3(0, 1.0, 0))
	m.ai_enabled = false
	await _wait(1.0)
	_game.money = 800
	var got := [-1]
	_game.kill_reward.connect(func(_t, _w, amount): got[0] = amount)
	var shots := 0
	while not m.is_dead() and shots < 60:
		_game.aim_at(m, "body")
		var fr: Dictionary = _game.fire()
		if shots < 3:
			print("  kill shot %d: %s (target %s health %.1f armor %.1f max %.1f)" % [shots, fr, m.name, m.health, m.armor, m.max_health])
		shots += 1
		if fr.get("reason", "") == "empty":
			await _wait(Sheets.weapon_num("ak47", "reload_time", 2.5) + 0.3)
		await _wait(0.2)
	var expect_reward := Combat.kill_reward("ak47", "watcher")
	_check(m.is_dead(), "watcher killed in %d shots" % shots)
	_check(got[0] == expect_reward and _game.money == 800 + expect_reward, "kill reward +$%d (expected %d), money $%d" % [got[0], expect_reward, _game.money])
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		print("SMOKE FAIL (%d): %s" % [_fails.size(), "; ".join(_fails)])
		quit(1)
