extends CharacterBody3D
## First-person player with CS2-style movement (systems movement.*: friction, accelerate, air accelerate,
## stop speed, gravity, jump impulse, walk/crouch multipliers; run speed = active weapon max_speed) and CS damage
## rules (kevlar via combat.armor_*). Weapons live in player/weapons.gd.

const Sheets := preload("res://core/sheets.gd")
const Combat := preload("res://core/combat.gd")
const Log := preload("res://core/log.gd")
const Settings := preload("res://core/settings.gd")
const Weapons := preload("res://player/weapons.gd")

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_MACHINE := 4

# ---- contract state
var inventory: Array[String] = []
var current_weapon := ""
var health := 100.0
var armor := 0.0
var invulnerable := false
var speed_mult := 1.0          ## test setup only (perf.stress_speed_mult): scales the CS max speed; movement still by input
## Knife model id of the knife slot (core/knives.gd; read-only for tests, chosen in the Esc menu).
var knife_id: String:
	get:
		return load("res://core/knives.gd").selected()

var head: Node3D
var camera: Camera3D
var weapons: Node
var crouched := false
var walking := false
var frozen := false
var dead := false
## Dev/test driver: when `scripted` is true the movement input comes from scripted_move (x right, y back) instead
## of the keyboard; everything else (CS movement, collisions) is the normal path.
var scripted := false
var scripted_move := Vector2.ZERO
var scripted_jump := false

var _u := 0.0254
var _shape: CollisionShape3D
var _capsule: CapsuleShape3D
var _eye_h := 1.6
var _yaw := 0.0
var _pitch := 0.0
var _was_on_floor := true
var _fall_speed := 0.0
var _step_acc := 0.0
var _hold_until_ground := false
var _knock := Vector3.ZERO
var _land_penalty := 0.0
var _mouse_sens := 0.0022


func _ready() -> void:
	name = "Player"
	_u = Sheets.sys_num("combat.units_to_m", 0.0254)
	collision_layer = LAYER_PLAYER
	collision_mask = LAYER_WORLD | LAYER_MACHINE
	floor_max_angle = acos(clampf(Sheets.sys_num("movement.standable_normal", 0.7), 0.0, 1.0))
	floor_snap_length = Sheets.sys_num("movement.step_height_u", 18.0) * _u
	floor_stop_on_slope = true
	_capsule = CapsuleShape3D.new()
	_capsule.radius = Sheets.sys_num("movement.hull_width_u", 32.0) * _u * 0.5
	_capsule.height = Sheets.sys_num("movement.hull_height_u", 72.0) * _u
	_shape = CollisionShape3D.new()
	_shape.shape = _capsule
	_shape.position.y = _capsule.height * 0.5
	add_child(_shape)
	head = Node3D.new()
	head.name = "Head"
	_eye_h = Sheets.sys_num("movement.eye_height_u", 64.0) * _u
	head.position.y = _eye_h
	add_child(head)
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 73.74 # CS2 90 deg horizontal at 4:3 = 73.74 deg vertical
	camera.near = 0.03
	camera.far = 4000.0
	camera.current = true
	head.add_child(camera)
	weapons = Weapons.new()
	weapons.name = "Weapons"
	weapons.player = self
	add_child(weapons)
	_mouse_sens = 0.0022 * float(Settings.get_value("mouse_sensitivity", 1.0))
	health = Sheets.sys_num("combat.player_max_health", 100.0)
	reset_loadout()


# ------------------------------------------------------------------ contract helpers

func ammo(weapon_id: String) -> Vector2i:
	return weapons.ammo_of(weapon_id)


func is_alive() -> bool:
	return not dead


func head_position() -> Vector3:
	return head.global_position


func stance() -> String:
	if crouched:
		return "crouch"
	if walking:
		return "walk"
	return "stand"


## Visibility for machine perception: stance factor x stealth grass (systems suspicion.*).
func visibility_factor() -> float:
	var st: Dictionary = Sheets.sys("suspicion.stance_visibility") if Sheets.sys("suspicion.stance_visibility") is Dictionary else {}
	var f := float(st.get(stance(), 1.0))
	if Game.world and Game.world.stealth_at(global_position) > 0.5 and crouched:
		f *= Sheets.sys_num("suspicion.stealth_grass_visibility", 0.15)
	return f


func reset_loadout() -> void:
	inventory.clear()
	for id in Sheets.start_loadout_ids():
		inventory.append(id)
	weapons.reset(inventory)
	var best := ""
	for id in inventory:
		if Sheets.weapon_row(id).get("slot") == "secondary":
			best = id
	if best == "" and not inventory.is_empty():
		best = inventory[0]
	equip(best)


func equip(weapon_id: String) -> void:
	if not inventory.has(weapon_id):
		return
	var previous := current_weapon
	current_weapon = weapon_id
	weapons.on_equip(weapon_id, previous)


## "" if buying is allowed, else the reason (shown on the HUD).
func can_buy(item_id: String) -> String:
	var row := Sheets.weapon_row(item_id)
	if row.is_empty() or int(row.get("buy_wheel_index", -1)) < 0:
		return "Not for sale"
	if dead:
		return "You are dead"
	if Game.in_combat():
		return "Can't buy during combat"
	if Game.money < Sheets.price(item_id):
		return "Not enough money"
	if row.get("slot") == "grenade":
		var total := 0
		for id in inventory:
			if Sheets.weapon_row(id).get("slot") == "grenade":
				total += weapons.grenade_count(id)
		if weapons.grenade_count(item_id) >= int(Sheets.sys_num("economy.grenade_limit_per_type", 1)):
			return "Can't carry more of this grenade"
		if total >= int(Sheets.sys_num("economy.grenade_limit_total", 4)):
			return "Can't carry more grenades"
	return ""


func give_item(item_id: String) -> void:
	var row := Sheets.weapon_row(item_id)
	var slot := str(row.get("slot", ""))
	if slot == "armor":
		armor = minf(Sheets.weapon_num(item_id, "armor_points", 100.0), Sheets.sys_num("combat.player_max_armor", 100.0))
		return
	if slot == "primary" or slot == "secondary":
		for id in inventory.duplicate():
			if Sheets.weapon_row(id).get("slot") == slot:
				inventory.erase(id)
				weapons.drop(id)
	if slot == "grenade":
		if not inventory.has(item_id):
			inventory.append(item_id)
		weapons.add_grenade(item_id)
		return
	inventory.append(item_id)
	weapons.give(item_id)
	equip(item_id)


func look_at_point(p: Vector3) -> void:
	var from := head.global_position
	var d := p - from
	if d.length() < 0.001:
		return
	_yaw = atan2(-d.x, -d.z)
	_pitch = atan2(d.y, Vector2(d.x, d.z).length())
	_apply_look()


func fire_once() -> Dictionary:
	return weapons.fire(true)


func teleport(pos: Vector3) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO
	_fall_speed = 0.0
	_hold_until_ground = true
	Log.info("teleport to %s" % pos)


func knockback(v: Vector3) -> void:
	if dead or invulnerable:
		return
	_knock += v


## Damage through the CS armor rule (kevlar protects the body; machines never deal headshots, D16).
func apply_damage(dmg: float, armor_ratio: float, source: Variant, cause: String) -> void:
	if dead:
		return
	var r := Combat.apply_armor(dmg, armor_ratio, armor)
	var hp := float(r["health"])
	Game.player_damaged.emit(hp, cause)
	if invulnerable and cause != "kill_player":
		Log.info("player hit by %s for %.1f (invulnerable)" % [cause, hp])
		Game.hud_message.emit("Hit: %s (%.0f)" % [cause, hp])
		return
	armor = maxf(armor - float(r["armor_lost"]), 0.0)
	health -= hp
	Log.info("player hit by %s for %.1f, health %.1f armor %.1f" % [cause, hp, maxf(health, 0.0), armor])
	if Game.hud:
		Game.hud.flash_damage()
	if health <= 0.0:
		health = 0.0
		_die(cause)


func _die(cause: String) -> void:
	dead = true
	velocity = Vector3.ZERO
	weapons.on_death()
	Log.info("player died (%s)" % cause)
	Game.player_died.emit()
	if Game.main and Game.main.has_method("on_player_died"):
		Game.main.on_player_died()


## Called by main.gd when respawning at a campfire.
func respawn_at(pos: Vector3, yaw: float) -> void:
	dead = false
	health = Sheets.sys_num("respawn.health", 100.0)
	if not Sheets.sys_bool("respawn.keep_armor", false):
		armor = 0.0
	reset_loadout()
	_yaw = yaw
	_pitch = 0.0
	_apply_look()
	teleport(pos)


# ------------------------------------------------------------------ input / look

func _unhandled_input(event: InputEvent) -> void:
	if dead or frozen:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		var zoom_scale: float = weapons.zoom_sensitivity()
		_yaw -= mm.relative.x * _mouse_sens * zoom_scale
		_pitch = clampf(_pitch - mm.relative.y * _mouse_sens * zoom_scale, deg_to_rad(-89.0), deg_to_rad(89.0))
		_apply_look()


func set_sensitivity(v: float) -> void:
	_mouse_sens = 0.0022 * v


func _apply_look() -> void:
	rotation = Vector3(0, _yaw, 0)
	head.rotation = Vector3(_pitch, 0, 0)


func aim_direction() -> Vector3:
	return -camera.global_transform.basis.z


# ------------------------------------------------------------------ movement

func _physics_process(delta: float) -> void:
	if _hold_until_ground:
		# wait for the terrain under a teleport/spawn target to exist, then make sure we stand on it
		if Game.world and Game.world.has_ground_at(global_position):
			var gh: float = Game.world.height_at(global_position)
			if not is_nan(gh) and global_position.y < gh + 0.05:
				global_position.y = gh + 0.05
			_hold_until_ground = false
		else:
			velocity = Vector3.ZERO
			return
	if frozen:
		return
	var input_enabled := not dead and Game.gameplay_input_allowed()   # mouse-look alone needs the captured mouse
	var wish := Vector2.ZERO
	var jump_pressed := false
	if scripted and not dead:
		wish = scripted_move.limit_length(1.0)
		jump_pressed = scripted_jump
		scripted_jump = false
	elif input_enabled and not scripted:
		wish = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		walking = Input.is_action_pressed("walk")
		_set_crouch(Input.is_action_pressed("crouch"))
		jump_pressed = Input.is_action_just_pressed("jump")
	var max_speed: float = weapons.max_speed_u() * _u * speed_mult
	if crouched:
		max_speed *= Sheets.sys_num("movement.crouch_mult", 0.34)
	elif walking:
		max_speed *= Sheets.sys_num("movement.walk_mult", 0.52)
	var basis := Basis(Vector3.UP, _yaw)
	var wish_dir := (basis * Vector3(wish.x, 0, wish.y))
	var wish_speed := minf(wish_dir.length(), 1.0) * max_speed
	if wish_dir.length() > 0.001:
		wish_dir = wish_dir.normalized()
	var on_floor := is_on_floor()
	var g := Sheets.sys_num("movement.gravity_u", 800.0) * _u
	if on_floor:
		_friction(delta)
		_accelerate(wish_dir, wish_speed, Sheets.sys_num("movement.accelerate", 5.5), delta)
		if jump_pressed:
			velocity.y = Sheets.sys_num("movement.jump_impulse_u", 301.993377) * _u
			on_floor = false
	else:
		_air_accelerate(wish_dir, wish_speed, delta)
		velocity.y -= g * delta
	if _knock.length() > 0.01:
		velocity += _knock
		_knock = Vector3.ZERO
	if not on_floor:
		_fall_speed = maxf(_fall_speed, -velocity.y)
	move_and_slide()
	var now_floor := is_on_floor()
	if now_floor and not _was_on_floor:
		var fd := Combat.fall_damage(_fall_speed)
		if fd > 0.0:
			apply_damage(fd, 0.0, null, "fall")
		if _fall_speed > 3.0:
			Game.make_noise(global_position, Sheets.sys_num("suspicion.landing_radius_m", 10.0), 0.6, 0.3)
		_land_penalty = 1.0
		_fall_speed = 0.0
	_was_on_floor = now_floor
	_land_penalty = maxf(_land_penalty - delta * 3.0, 0.0)
	# running footsteps are heard (walk/crouch are silent like CS)
	var hs := Vector2(velocity.x, velocity.z).length()
	if now_floor and not walking and not crouched and hs > 2.0:
		_step_acc += hs * delta
		if _step_acc > 1.8:
			_step_acc = 0.0
			var r := Sheets.sys_num("suspicion.footstep_radius_run_m", 12.0)
			if r > 0.0:
				Game.make_noise(global_position, r, 0.25, 0.1)
	if global_position.y < -500.0 and not dead:
		apply_damage(1000.0, 0.0, null, "fell out of the world")


func _friction(delta: float) -> void:
	var v := Vector3(velocity.x, 0, velocity.z)
	var speed := v.length()
	if speed < 0.001:
		velocity.x = 0
		velocity.z = 0
		return
	var stop := Sheets.sys_num("movement.stop_speed_u", 80.0) * _u
	var control := maxf(speed, stop)
	var drop := control * Sheets.sys_num("movement.friction", 5.2) * delta
	var ns := maxf(speed - drop, 0.0) / speed
	velocity.x *= ns
	velocity.z *= ns


func _accelerate(dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	if wish_speed <= 0.0:
		return
	var current := Vector3(velocity.x, 0, velocity.z).dot(dir)
	var add := wish_speed - current
	if add <= 0.0:
		return
	var a := minf(accel * delta * wish_speed, add)
	velocity.x += a * dir.x
	velocity.z += a * dir.z


func _air_accelerate(dir: Vector3, wish_speed: float, delta: float) -> void:
	if wish_speed <= 0.0:
		return
	var cap := Sheets.sys_num("movement.air_max_wishspeed_u", 30.0) * _u
	var ws := minf(wish_speed, cap)
	var current := Vector3(velocity.x, 0, velocity.z).dot(dir)
	var add := ws - current
	if add <= 0.0:
		return
	var a := minf(Sheets.sys_num("movement.air_accelerate", 12.0) * wish_speed * delta, add)
	velocity.x += a * dir.x
	velocity.z += a * dir.z


## Crouch/stand through the normal hull change (used by input and by test drivers).
func set_crouch(want: bool) -> void:
	_set_crouch(want)


func _set_crouch(want: bool) -> void:
	if want == crouched:
		return
	var stand_h := Sheets.sys_num("movement.hull_height_u", 72.0) * _u
	var crouch_h := Sheets.sys_num("movement.hull_height_crouch_u", 54.0) * _u
	if not want:
		# only stand up when there is room
		var xf := global_transform
		if test_move(xf, Vector3(0, stand_h - crouch_h, 0)):
			return
	crouched = want
	_capsule.height = crouch_h if crouched else stand_h
	_shape.position.y = _capsule.height * 0.5


func _process(delta: float) -> void:
	var target_eye := Sheets.sys_num("movement.eye_height_crouch_u" if crouched else "movement.eye_height_u", 64.0) * _u
	_eye_h = move_toward(_eye_h, target_eye, delta * 3.0)
	head.position.y = _eye_h if not dead else move_toward(head.position.y, 0.3, delta * 2.0)


func speed_fraction() -> float:
	var ms: float = weapons.max_speed_u() * _u
	return Vector2(velocity.x, velocity.z).length() / maxf(ms, 0.01)


func land_penalty() -> float:
	return _land_penalty
