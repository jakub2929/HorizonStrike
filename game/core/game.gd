extends Node
## Autoload `Game`: shared state and the Game API used by the autotest (docs/ARCHITECTURE.md "Game API").
## Every method goes through the real gameplay code (player weapons, machine damage, economy, respawn).

signal world_ready
signal cell_loaded(cell: Vector2i)
signal cell_insert_started(cell: Vector2i)   ## a prepared cell starts entering the scene (budgeted steps follow)
signal cell_evicted(cell: Vector2i)
signal machine_state_changed(machine: Node, old: String, new: String)
signal money_changed(value: int)
signal player_died
signal player_respawned(campfire_id: String)
signal kill_reward(machine_type: String, weapon_id: String, amount: int)
signal hud_message(text: String)
## Every hit on the player (also while invulnerable: amount = the health damage it would have dealt).
signal player_damaged(amount: float, cause: String)

const Sheets := preload("res://core/sheets.gd")
const Combat := preload("res://core/combat.gd")
const Log := preload("res://core/log.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Settings := preload("res://core/settings.gd")
const Knives := preload("res://core/knives.gd")

# ---- state (contract)
var money: int = 0:
	set(v):
		var cap := int(Sheets.sys_num("economy.max_money", 16000))
		var nv := clampi(v, 0, cap)
		var changed := nv != money
		money = nv
		if changed:
			money_changed.emit(money)
var player: Node3D = null
var last_campfire_id := ""
var hzd_missing := false
var machines: Array = []
var cache_cap_bytes: int = 0
var bootstrap_seconds := 0.0
var cells_converted := 0
var converter_pid := 0

# ---- internals (set by main.gd / world.gd)
var args: RefCounted = null
var cache_root := ""
var is_world_ready := false
var main: Node = null
var world: Node = null
var hud: Node = null
var buy_wheel: Node = null
var campfires := {}          # id -> Node3D (Campfire)


# ------------------------------------------------------------------ machines

func spawn_machine(type: String, pos: Vector3) -> Node:
	if world == null:
		push_error("spawn_machine before the world exists")
		return null
	return world.spawn_machine(type, pos)


func register_machine(m: Node) -> void:
	if not machines.has(m):
		machines.append(m)


func unregister_machine(m: Node) -> void:
	machines.erase(m)


## Noise heard by machines within `radius` (shots D5, footsteps, landings, explosions).
func make_noise(pos: Vector3, radius: float, gain_center: float, gain_edge: float, loud: bool = false) -> void:
	for m in machines:
		if is_instance_valid(m):
			m.hear_noise(pos, radius, gain_center, gain_edge, loud)


## True when a machine in alert/attack targets the player within 60 m (economy.buy_allowed_rule, D19).
## Every quit (buttons, error screens, window close, tests) goes through main.quit_game: converter stopped first.
func quit(code: int = 0) -> void:
	if main and main.has_method("quit_game"):
		main.quit_game(code)
	else:
		get_tree().quit(code)


## Gameplay keys and buttons (move, crouch, jump, fire, reload, weapon slots) count only while no UI layer is open
## (buy wheel, Esc menu = paused tree) and the game window has focus. Not tied to mouse capture: after a menu the keys
## work at once. Mouse-look alone needs the captured mouse. Automated runs drive input into a window that may not have
## focus, so they skip the focus condition.
func gameplay_input_allowed() -> bool:
	if buy_wheel and buy_wheel.is_open():
		return false
	if get_tree().paused:
		return false
	if args and args.automated():
		return true
	return get_window().has_focus()


func in_combat() -> bool:
	if player == null:
		return false
	for m in machines:
		if not is_instance_valid(m):
			continue
		if m.state in ["alert", "attack", "stalk"] and m.targets_player() and m.global_position.distance_to(player.global_position) <= 60.0:
			return true
	return false


# ------------------------------------------------------------------ economy

## Same path as the buy wheel. Returns false when unaffordable, in combat or over a limit.
func buy(item_id: String) -> bool:
	if player == null:
		return false
	var reason: String = player.can_buy(item_id)
	if reason != "":
		Log.info("buy %s refused: %s" % [item_id, reason])
		hud_message.emit(reason)
		return false
	var cost := Sheets.price(item_id)
	money -= cost
	player.give_item(item_id)
	Log.info("bought %s for $%d, money $%d" % [item_id, cost, money])
	if buy_wheel and buy_wheel.has_method("on_bought"):
		buy_wheel.on_bought(item_id)
	return true


func award_kill(machine_type: String, weapon_id: String) -> int:
	var before := money
	var amount := Combat.kill_reward(weapon_id, machine_type)
	money = money + amount
	var delta := money - before
	Log.info("kill reward %s with %s: +$%d (formula %d), money $%d" % [machine_type, weapon_id, delta, amount, money])
	kill_reward.emit(machine_type, weapon_id, delta)
	hud_message.emit("+$%d  %s kill (%s)" % [delta, machine_type.capitalize(), Sheets.weapon_row(weapon_id).get("display_name", weapon_id)])
	return delta


func open_buy_wheel() -> void:
	if buy_wheel:
		buy_wheel.open()


func close_buy_wheel() -> void:
	if buy_wheel:
		buy_wheel.close()


func buy_wheel_item_ids() -> Array[String]:
	return Sheets.buy_wheel_ids()


# ------------------------------------------------------------------ knife models (0.3, read-only for tests)
# The choice itself is made through the Esc menu ("Knife": SettingsLayer/SettingsMenu/.../KnifeList) with real input.

## Knife model ids offered in the menu (knives.default first, then cs2/knives/index.json entries that converted).
func knife_ids() -> Array[String]:
	var out: Array[String] = []
	for k in Knives.available():
		out.append(str(k["id"]))
	return out


## The selected knife model id (loadout.json knife; knives.default while the saved one is not converted).
func knife_selected() -> String:
	return Knives.selected()


## Knife model the player's knife slot showed when it was last drawn ("" before the first draw).
func knife_model() -> String:
	var vm := _viewmodel()
	return str(vm.knife_model) if vm else ""


## Clip the viewmodel started last (animation name, "" when the model has no clip for the request) and the request.
func knife_last_anim() -> String:
	var vm := _viewmodel()
	return str(vm.last_anim) if vm else ""


func last_anim_request() -> String:
	var vm := _viewmodel()
	return str(vm.last_anim_request) if vm else ""


func _viewmodel() -> Node:
	if player == null or player.get("weapons") == null:
		return null
	return player.weapons.viewmodel


# ------------------------------------------------------------------ player

func equip(weapon_id: String) -> void:
	if player:
		player.equip(weapon_id)


func aim_at(target: Node3D, part: String) -> void:
	if player == null or target == null:
		return
	var p: Vector3
	if target.has_method("aim_point"):
		p = target.aim_point(part, player.camera.global_position)
		if part != "body" and target.has_method("weak_points"):
			p = _reachable_point(target, part, p)
	else:
		p = target.global_position
	player.look_at_point(p)


## Among a part's hitboxes and points on them (nearest first) the first one that the weapon's own trace from the
## camera hits as that part (a canister on the far side is behind the body); `fallback` when none is reachable.
func _reachable_point(target: Node3D, part: String, fallback: Vector3) -> Vector3:
	var eye: Vector3 = player.camera.global_position
	# hitbox centres first (most margin for the weapon's spread), then points towards their surfaces; nearest first
	var centres: Array = target.weak_points(part)
	var near := func(a, b): return eye.distance_squared_to(a) < eye.distance_squared_to(b)
	centres.sort_custom(near)
	var rest: Array = target.weak_points(part, true).filter(func(q): return not centres.has(q))
	rest.sort_custom(near)
	var pts: Array = centres + rest
	for pt in pts:
		var h: Dictionary = player.weapons._trace(eye, ((pt as Vector3) - eye).normalized(), eye.distance_to(pt) + 5.0)
		if h.is_empty():
			continue
		var col: Object = h["collider"]
		if col.has_meta("machine") and col.get_meta("machine") == target and str(col.get_meta("part", "")) == part:
			return pt
	return fallback


func fire() -> Dictionary:
	if player == null:
		return {"hit": false, "target": null, "part": "", "damage": 0.0}
	return player.fire_once()


func kill_player() -> void:
	if player:
		player.apply_damage(100000.0, 0.0, null, "kill_player")


func teleport(pos: Vector3) -> void:
	if player:
		player.teleport(pos)


func campfires_near(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	for id in campfires:
		var c: Node3D = campfires[id]
		if is_instance_valid(c) and c.global_position.distance_to(pos) <= radius:
			out.append(c)
	out.sort_custom(func(a, b): return a.global_position.distance_to(pos) < b.global_position.distance_to(pos))
	return out


func activate_campfire(id: String) -> void:
	if id == last_campfire_id:
		return
	last_campfire_id = id
	Log.info("campfire activated: %s" % id)
	hud_message.emit("Campfire activated")


# ------------------------------------------------------------------ cache

func cache_bytes() -> int:
	if world and world.has_method("cache_bytes"):
		return world.cache_bytes()
	return FsUtil.dir_bytes(cache_root) if cache_root != "" else 0


func cells_on_disk() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var dir := cache_root.path_join("hzd/cells")
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		if sub.ends_with(".tmp") or not FileAccess.file_exists(dir.path_join(sub).path_join("cell.json")):
			continue
		var parts := sub.split("_")
		if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
			out.append(Vector2i(int(parts[0]), int(parts[1])))
	return out


func set_cache_cap(bytes: int, persist: bool) -> void:
	cache_cap_bytes = bytes
	if persist:
		Settings.set_value("cache_cap_bytes", bytes)


# ------------------------------------------------------------------ misc

func screenshot(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tex := get_viewport().get_texture()
	if tex == null:
		Log.warn("screenshot: no viewport texture (headless?)")
		return
	var img := tex.get_image()
	if img == null:
		Log.warn("screenshot: no image (headless?)")
		return
	img.save_png(path)
	Log.info("screenshot %s (%dx%d)" % [path, img.get_width(), img.get_height()])


func emit_machine_state(m: Node, old: String, new: String) -> void:
	machine_state_changed.emit(m, old, new)


func mark_world_ready() -> void:
	if is_world_ready:
		return
	is_world_ready = true
	Log.info("world ready (playable) after %.2f s" % bootstrap_seconds)
	world_ready.emit()
