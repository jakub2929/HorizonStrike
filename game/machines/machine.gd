extends CharacterBody3D
## A Horizon machine with Horizon logic (sheets machines.json + machine_attacks.json, systems suspicion.*):
## guards patrol and go suspicious -> alert -> attack; herds graze and flee on alert (fighting back when cornered).
## Damage uses the CS rules: body hits go through the machine's armor, weak spots ignore it (D4/D17).

const Sheets := preload("res://core/sheets.gd")
const Combat := preload("res://core/combat.gd")
const Log := preload("res://core/log.gd")
const MachineRig := preload("res://machines/machine_rig.gd")
const Projectile := preload("res://machines/projectile.gd")
const MachineAudio := preload("res://machines/machine_audio.gd")

const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_MACHINE := 4
const LAYER_HITBOX := 8
## Peripheral vision (outside the sight cone, up to peripheral_range_m) builds suspicion at this fraction of the
## direct rate: machines notice movement behind them slowly instead of instantly (design, hra).
const PERIPHERAL_GAIN := 0.3

var machine_type := "watcher"
var state := "idle"
var health := 100.0
var max_health := 100.0
var armor := 0.0
var suspicion := 0.0
var ai_enabled := true
var site: Dictionary = {}
var herd: Array = []
var home := Vector3.ZERO
var rig: Node3D
var last_hit_weapon := ""
var meta := {}
var audio: Node3D

# tuning from sheets
var archetype := "guard"
var walk_speed := 1.6
var run_speed := 7.0
var turn_rate := deg_to_rad(180.0)
var sight_range := 40.0
var sight_fov := deg_to_rad(100.0)
var peripheral_range := 15.0
var hearing_range := 25.0
var imm_susp := 8.0
var imm_alert := 4.0
var gain_per_s := 0.6
var decay_per_s := 0.12
var susp_threshold := 0.35
var alert_threshold := 1.0
var search_time := 20.0
var alert_call_radius := 0.0
var flee_on_alert := false
var flee_distance := 0.0
var fight_back_radius := 0.0
var attacks: Array = []

# ai state
var _state_time := 0.0
var _goal := Vector3.ZERO
var _has_goal := false
var _wait := 0.0
var _stimulus := Vector3.ZERO
var _last_seen := Vector3.ZERO
var _last_seen_time := -100.0
var _flee_from := Vector3.ZERO
var _attack: Dictionary = {}
var _attack_phase := ""
var _attack_t := 0.0
var _attack_dealt := false
var _cooldowns := {}
var _alert_announce := 0.0
var _sees_player := false
var _speed_now := 0.0
var _stuck_t := 0.0
var _dead_t := 0.0
var _rng := RandomNumberGenerator.new()
var _gravity := 9.8
var _perc_acc := randf() * 0.1   # perception runs at 10 Hz, staggered


func setup(type: String, machine_meta: Dictionary) -> void:
	machine_type = type
	meta = machine_meta
	archetype = str(Sheets.machine(type, "archetype"))
	max_health = Sheets.machine_num(type, "health", 200.0)
	health = max_health
	armor = Sheets.machine_num(type, "armor_points", 0.0)
	walk_speed = Sheets.machine_num(type, "walk_speed_mps", 1.6)
	run_speed = Sheets.machine_num(type, "run_speed_mps", 7.0)
	turn_rate = deg_to_rad(Sheets.machine_num(type, "turn_rate_dps", 180.0))
	sight_range = Sheets.machine_num(type, "sight_range_m", 40.0)
	sight_fov = deg_to_rad(Sheets.machine_num(type, "sight_fov_deg", 100.0))
	# meta.json perception names the HZD value a half angle (DirectHeadingAngle); the sheet column is the full cone
	var perc: Dictionary = machine_meta.get("perception", {})
	if perc.has("sight_half_angle_deg"):
		sight_fov = deg_to_rad(2.0 * float(perc["sight_half_angle_deg"]))
	peripheral_range = Sheets.machine_num(type, "peripheral_range_m", 15.0)
	hearing_range = Sheets.machine_num(type, "hearing_range_m", 25.0)
	imm_susp = Sheets.machine_num(type, "immediate_suspicion_m", 8.0)
	imm_alert = Sheets.machine_num(type, "immediate_alert_m", 4.0)
	gain_per_s = Sheets.machine_num(type, "suspicion_gain_per_s", 0.6)
	decay_per_s = Sheets.machine_num(type, "suspicion_decay_per_s", 0.12)
	susp_threshold = Sheets.machine_num(type, "suspicious_threshold", 0.35)
	alert_threshold = Sheets.machine_num(type, "alert_threshold", 1.0)
	search_time = Sheets.machine_num(type, "search_time_s", 20.0)
	alert_call_radius = Sheets.machine_num(type, "alert_call_radius_m", 0.0)
	flee_on_alert = bool(Sheets.machine(type, "flee_on_alert"))
	flee_distance = Sheets.machine_num(type, "flee_distance_m", 0.0)
	fight_back_radius = Sheets.machine_num(type, "fight_back_radius_m", 0.0)
	attacks.clear()
	var al = Sheets.machine(type, "attacks")
	if al is Array:
		for a in al:
			var row := Sheets.attack(str(a))
			if not row.is_empty():
				attacks.append(row)


func _ready() -> void:
	name = "%s_%d" % [machine_type.capitalize(), get_instance_id() % 100000]
	add_to_group("machines")
	collision_layer = LAYER_MACHINE
	collision_mask = LAYER_WORLD | LAYER_PLAYER | LAYER_MACHINE
	floor_max_angle = deg_to_rad(55.0)
	floor_snap_length = 0.6
	_rng.randomize()
	_gravity = 9.81
	rig = MachineRig.new()
	rig.name = "Rig"
	add_child(rig)
	rig.build(self, machine_type, meta)
	audio = MachineAudio.new()
	audio.name = "Audio"
	add_child(audio)
	audio.setup(self)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	var hgt: float = rig.body_height
	cap.radius = clampf(rig.body_radius, 0.3, 1.2)
	cap.height = maxf(hgt * 0.8, cap.radius * 2.0 + 0.1)
	cs.shape = cap
	cs.position = Vector3(0, cap.height * 0.5 + 0.1, 0)
	add_child(cs)
	# long bodies (Strider, Grazer, Watcher torso): a horizontal capsule along the trunk so the player cannot walk
	# through the front or the back of the machine
	var trunk: AABB = rig.trunk_bounds()
	if trunk.size.z > cap.radius * 2.5:
		var tc := CollisionShape3D.new()
		var tcap := CapsuleShape3D.new()
		tcap.radius = clampf(minf(trunk.size.x, trunk.size.y) * 0.45, 0.25, 0.8)
		tcap.height = maxf(trunk.size.z, tcap.radius * 2.0 + 0.05)
		tc.shape = tcap
		tc.rotation = Vector3(PI * 0.5, 0, 0)
		tc.position = trunk.get_center()
		# separate body: blocks the player but never the machine's own movement over slopes
		var tb := AnimatableBody3D.new()
		tb.name = "TrunkBody"
		tb.collision_layer = LAYER_MACHINE
		tb.collision_mask = 0
		tb.sync_to_physics = false
		tb.add_child(tc)
		add_child(tb)
		add_collision_exception_with(tb)
	home = global_position
	_set_state("patrol" if archetype == "guard" else "graze")
	Game.register_machine(self)


func _exit_tree() -> void:
	Game.unregister_machine(self)


# ------------------------------------------------------------------ contract

func weak_spots() -> Array[String]:
	var out: Array[String] = []
	for h in rig.hitboxes:
		var part := str(h.get_meta("part", ""))
		if h.get_meta("weak", false) and not out.has(part):
			out.append(part)
	return out


func aim_point(part: String) -> Vector3:
	for h in rig.hitboxes:
		if str(h.get_meta("part", "")) == part:
			return (h as Node3D).global_position
	for h in rig.hitboxes:
		if str(h.get_meta("part", "")) == "body":
			return (h as Node3D).global_position
	return global_position + Vector3(0, rig.body_height * 0.6, 0)


func targets_player() -> bool:
	return state in ["alert", "attack"] or (state == "flee" and _attack_phase != "")


func is_dead() -> bool:
	return state == "dead"


# ------------------------------------------------------------------ damage

## Hit from the player. part = hitbox part; returns the health damage dealt.
func take_hit(weapon_id: String, base_damage: float, part: String, is_weak: bool) -> float:
	if state == "dead":
		return 0.0
	var dmg: float
	if is_weak:
		dmg = base_damage * Sheets.weapon_num(weapon_id, "headshot_mult", 1.0)
	else:
		var r := Combat.apply_armor(base_damage, Sheets.weapon_num(weapon_id, "armor_ratio", 1.0), armor)
		dmg = r["health"]
		armor = maxf(armor - float(r["armor_lost"]), 0.0)
	health -= dmg
	last_hit_weapon = weapon_id
	if rig:
		rig.flinch(is_weak)
	if audio:
		audio.play_role("hit")
	if health <= 0.0:
		health = 0.0
		_die(weapon_id)
	elif ai_enabled and Sheets.sys_bool("suspicion.hit_sets_alert", true):
		if Game.player:
			_last_seen = Game.player.global_position
			_last_seen_time = _now()
		suspicion = maxf(suspicion, alert_threshold)
		if state != "alert" and state != "attack" and state != "flee":
			_go_alert()
	return dmg


func _die(weapon_id: String) -> void:
	_set_state("dead")
	velocity = Vector3.ZERO
	collision_layer = 0
	for h in rig.hitboxes:
		(h as Area3D).collision_layer = 0
	Game.award_kill(machine_type, weapon_id)
	if site.has("on_death"):
		(site["on_death"] as Callable).call(self)


# ------------------------------------------------------------------ perception

func hear_noise(pos: Vector3, radius: float, gain_center: float, gain_edge: float, loud: bool = false) -> void:
	if state == "dead" or not ai_enabled:
		return
	var d := global_position.distance_to(pos)
	if d > radius:
		return
	var g := lerpf(gain_center, gain_edge, clampf(d / maxf(radius, 0.01), 0.0, 1.0))
	suspicion = minf(suspicion + g, alert_threshold * 1.5)
	_stimulus = pos
	# herd rule: grazing herds bolt from a gunshot or blast they hear (they flee instead of investigating)
	if loud and flee_on_alert and archetype == "herd" and suspicion >= susp_threshold and state in ["idle", "graze", "suspicious"]:
		suspicion = maxf(suspicion, alert_threshold)
		_last_seen = pos
		_last_seen_time = _now()
	_after_suspicion_change()


func notice_impact(pos: Vector3) -> void:
	if state == "dead" or not ai_enabled:
		return
	if global_position.distance_to(pos) > Sheets.sys_num("suspicion.impact_radius_m", 6.0):
		return
	suspicion = minf(suspicion + Sheets.sys_num("suspicion.impact_gain", 0.5), alert_threshold * 1.5)
	_stimulus = pos
	_after_suspicion_change()


func _after_suspicion_change() -> void:
	if suspicion >= alert_threshold and state not in ["alert", "attack", "flee"]:
		if Game.player:
			_last_seen = Game.player.global_position
			_last_seen_time = _now()
		_go_alert()
	elif suspicion >= susp_threshold and state in ["idle", "patrol", "graze"]:
		_set_state("suspicious")


func eye_position() -> Vector3:
	return rig.eye_global() if rig else global_position + Vector3(0, 2, 0)


func forward() -> Vector3:
	return -global_transform.basis.z


func _perceive(delta: float) -> void:
	var p: Node3D = Game.player
	_sees_player = false
	if p == null or not p.is_alive():
		suspicion = maxf(suspicion - decay_per_s * delta, 0.0)
		return
	var eye := eye_position()
	var target: Vector3 = p.head_position()
	var to := target - eye
	var d := to.length()
	var flat := Vector3(to.x, 0, to.z).normalized()
	var ang := forward().angle_to(flat) if flat.length() > 0.01 else 0.0
	var in_cone := ang <= sight_fov * 0.5
	var rng := sight_range if in_cone else peripheral_range
	if state in ["alert", "attack"]:
		rng = maxf(rng, sight_range * 1.5)
	var vis: float = p.visibility_factor()
	var visible := d <= rng and _line_of_sight(eye, target)
	if visible:
		_sees_player = true
		_last_seen = p.global_position
		_last_seen_time = _now()
		# immediate detection only inside the sight cone, at distances scaled by stance x stealth grass
		if in_cone and d <= imm_alert * vis:
			suspicion = maxf(suspicion, alert_threshold)
		elif in_cone and d <= imm_susp * vis:
			suspicion = maxf(suspicion, susp_threshold)
		var g := gain_per_s * vis * clampf(1.0 - d / maxf(rng, 0.01), 0.0, 1.0)
		if not in_cone:
			g *= PERIPHERAL_GAIN
		suspicion = minf(suspicion + g * delta, alert_threshold * 1.5)
		_stimulus = p.global_position
	else:
		suspicion = maxf(suspicion - decay_per_s * delta, 0.0)
	_after_suspicion_change()


func _line_of_sight(from: Vector3, to: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from, to, LAYER_WORLD)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# ------------------------------------------------------------------ state machine

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _set_state(s: String) -> void:
	if s == state:
		return
	var old := state
	state = s
	_state_time = 0.0
	_has_goal = false
	_attack_phase = ""
	if s != "dead":
		Log.info("machine %s %s -> %s (suspicion %.2f)" % [name, old, s, suspicion])
	Game.emit_machine_state(self, old, s)
	if rig:
		rig.on_state(s)
	if audio:
		audio.on_state(s)


func _go_alert() -> void:
	_set_state("alert")
	_alert_announce = 0.0
	# guards call nearby machines, herds alert their herd (systems suspicion.herd_alert_radius_m)
	var call_r := alert_call_radius if archetype == "guard" else Sheets.sys_num("suspicion.herd_alert_radius_m", 60.0)
	if call_r > 0.0:
		for m in Game.machines:
			if m == self or not is_instance_valid(m) or m.is_dead() or not m.ai_enabled:
				continue
			if m.global_position.distance_to(global_position) <= call_r and m.state not in ["alert", "attack", "flee"]:
				m.receive_alert(_last_seen if _last_seen != Vector3.ZERO else global_position)


func receive_alert(threat_pos: Vector3) -> void:
	suspicion = maxf(suspicion, alert_threshold)
	_last_seen = threat_pos
	_last_seen_time = _now()
	_go_alert()


## Return to calm (respawn.reset_machine_alert).
func reset_calm() -> void:
	if state == "dead":
		return
	suspicion = 0.0
	_set_state("patrol" if archetype == "guard" else "graze")


func _physics_process(delta: float) -> void:
	if state == "dead":
		_dead_t += delta
		_apply_gravity(delta)
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		if _dead_t > 30.0:
			queue_free()
		return
	_state_time += delta
	for k in _cooldowns.keys():
		_cooldowns[k] = maxf(float(_cooldowns[k]) - delta, 0.0)
	var desired := Vector3.ZERO
	var speed := 0.0
	if ai_enabled:
		_perc_acc += delta
		if _perc_acc >= 0.1:
			_perceive(_perc_acc)
			_perc_acc = 0.0
		var r := _think(delta)
		desired = r[0]
		speed = r[1]
	_steer(desired, speed, delta)
	_apply_gravity(delta)
	move_and_slide()
	_speed_now = Vector3(velocity.x, 0, velocity.z).length()
	_check_stuck(delta, speed)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = maxf(velocity.y, -1.0)


## Returns [desired direction (flat), speed].
func _think(delta: float) -> Array:
	var p: Node3D = Game.player
	match state:
		"idle":
			if _state_time > 2.0:
				_set_state("patrol" if archetype == "guard" else "graze")
			return [Vector3.ZERO, 0.0]
		"patrol", "graze":
			return _wander(delta, archetype == "guard")
		"suspicious":
			if suspicion < susp_threshold * 0.5:
				_set_state("patrol" if archetype == "guard" else "graze")
				return [Vector3.ZERO, 0.0]
			var to := _stimulus - global_position
			to.y = 0
			_face(to, delta)
			if archetype == "guard" and to.length() > 6.0 and _state_time > 1.5:
				return [to.normalized(), walk_speed]
			return [Vector3.ZERO, 0.0]
		"alert":
			if archetype == "herd" and flee_on_alert:
				_flee_from = _last_seen if _last_seen != Vector3.ZERO else (p.global_position if p else global_position)
				_set_state("flee")
				return [Vector3.ZERO, 0.0]
			var to2 := (_last_seen - global_position)
			to2.y = 0
			_face(to2, delta)
			_alert_announce += delta
			if _alert_announce > 0.6:
				_set_state("attack")
			return [Vector3.ZERO, 0.0]
		"attack":
			return _do_attack(delta)
		"flee":
			return _do_flee(delta)
	return [Vector3.ZERO, 0.0]


func _wander(_delta: float, guard: bool) -> Array:
	var radius := float(site.get("radius", 25.0))
	if _wait > 0.0:
		_wait -= _delta
		return [Vector3.ZERO, 0.0]
	if not _has_goal:
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(radius * 0.2, radius)
		_goal = home + Vector3(cos(a) * r, 0, sin(a) * r)
		_has_goal = true
	var to := _goal - global_position
	to.y = 0
	if to.length() < 1.5:
		_has_goal = false
		_wait = _rng.randf_range(2.0, 5.0) if guard else _rng.randf_range(4.0, 10.0)
		return [Vector3.ZERO, 0.0]
	return [to.normalized(), walk_speed if guard else walk_speed * 0.7]


func _do_attack(delta: float) -> Array:
	var p: Node3D = Game.player
	if p == null or not p.is_alive():
		_set_state("suspicious")
		return [Vector3.ZERO, 0.0]
	var to := p.global_position - global_position
	to.y = 0
	var d := to.length()
	if not _sees_player and _now() - _last_seen_time > search_time:
		suspicion = susp_threshold
		_set_state("suspicious")
		return [Vector3.ZERO, 0.0]
	if _attack_phase != "":
		return _run_attack(delta, to, d)
	# choose an attack that fits the distance
	var best: Dictionary = {}
	for a in attacks:
		if float(_cooldowns.get(a["id"], 0.0)) > 0.0:
			continue
		if d >= float(a["range_min_m"]) and d <= float(a["range_max_m"]):
			if a["direction"] == "rear":
				continue
			best = a
			break
	if not best.is_empty() and _facing(to) < deg_to_rad(25.0):
		_start_attack(best)
		return [Vector3.ZERO, 0.0]
	_face(to, delta)
	# no attack fits (out of range or cooling down): close in to melee range
	if best.is_empty() and d > 2.0:
		return [to.normalized(), run_speed if d > 8.0 else walk_speed * 1.5]
	return [Vector3.ZERO, 0.0]


func _start_attack(a: Dictionary) -> void:
	if audio:
		audio.play_role("attack")
	_attack = a
	_attack_phase = "windup"
	_attack_t = 0.0
	_attack_dealt = false
	if rig:
		rig.play_pose(str(a.get("pose", "")), float(a["windup_s"]) + float(a["active_s"]))
	Log.info("machine %s attack %s" % [name, a["id"]])


func _run_attack(delta: float, to: Vector3, d: float) -> Array:
	_attack_t += delta
	var a := _attack
	match _attack_phase:
		"windup":
			_face(to, delta)
			if _attack_t >= float(a["windup_s"]):
				_attack_phase = "active"
				_attack_t = 0.0
				if a["kind"] == "ranged":
					_fire_projectile(a)
					_attack_dealt = true
			return [Vector3.ZERO, 0.0]
		"active":
			var move := Vector3.ZERO
			var spd := 0.0
			if a["kind"] == "charge":
				move = forward()
				spd = run_speed * 1.4
			if not _attack_dealt and a["kind"] != "ranged":
				var p: Node3D = Game.player
				var reach := float(a["range_max_m"]) if a["kind"] == "melee" else 2.5
				if p and d <= reach + rig.body_radius and _direction_ok(a, to):
					p.apply_damage(float(a["damage"]), float(a["armor_ratio"]), self, str(a["id"]))
					p.knockback((to.normalized() + Vector3.UP * 0.3) * float(a["knockback_mps"]))
					_attack_dealt = true
			if _attack_t >= float(a["active_s"]):
				_attack_phase = ""
				_cooldowns[a["id"]] = float(a["cooldown_s"])
			return [move, spd]
	return [Vector3.ZERO, 0.0]


func _direction_ok(a: Dictionary, to: Vector3) -> bool:
	match str(a["direction"]):
		"front":
			return _facing(to) < deg_to_rad(60.0)
		"rear":
			return _facing(to) > deg_to_rad(120.0)
	return true


func _fire_projectile(a: Dictionary) -> void:
	var p: Node3D = Game.player
	if p == null:
		return
	var proj := Projectile.new()
	proj.attack = a
	proj.source = self
	get_parent().add_child(proj)
	var from := eye_position() + forward() * 0.5
	proj.global_position = from
	var aim: Vector3 = p.head_position() - Vector3(0, 0.3, 0)
	proj.velocity = (aim - from).normalized() * maxf(float(a["projectile_speed_mps"]), 1.0)


func _do_flee(delta: float) -> Array:
	var p: Node3D = Game.player
	if p and p.is_alive() and fight_back_radius > 0.0:
		var top := p.global_position - global_position
		top.y = 0
		if _attack_phase != "":
			return _run_attack(delta, top, top.length())
		if top.length() <= fight_back_radius:
			for a in attacks:
				if float(_cooldowns.get(a["id"], 0.0)) <= 0.0 and top.length() <= float(a["range_max_m"]) and _direction_ok(a, top):
					_start_attack(a)
					return [Vector3.ZERO, 0.0]
	var away := global_position - _flee_from
	away.y = 0
	if away.length() < 0.1:
		away = -forward()
	if away.length() >= flee_distance and not _sees_player:
		suspicion = minf(suspicion, susp_threshold * 0.9)
		_set_state("suspicious")
		return [Vector3.ZERO, 0.0]
	if p:
		var pd := global_position - p.global_position
		pd.y = 0
		if pd.length() < away.length():
			_flee_from = p.global_position
	return [away.normalized(), run_speed]


func _facing(to: Vector3) -> float:
	if to.length() < 0.01:
		return 0.0
	return forward().angle_to(Vector3(to.x, 0, to.z).normalized())


func _face(dir: Vector3, delta: float) -> void:
	if dir.length() < 0.01:
		return
	var target_yaw := atan2(-dir.x, -dir.z)
	var yaw := rotation.y
	var diff := wrapf(target_yaw - yaw, -PI, PI)
	rotation.y = yaw + clampf(diff, -turn_rate * delta, turn_rate * delta)


func _steer(dir: Vector3, speed: float, delta: float) -> void:
	if speed > 0.0 and dir.length() > 0.01:
		_face(dir, delta)
		var f := forward()
		var align := clampf(f.dot(dir.normalized()), 0.0, 1.0)
		var target_v := f * speed * (0.25 + 0.75 * align)
		velocity.x = move_toward(velocity.x, target_v.x, 12.0 * delta)
		velocity.z = move_toward(velocity.z, target_v.z, 12.0 * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, 10.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 10.0 * delta)


func _check_stuck(delta: float, wanted_speed: float) -> void:
	if wanted_speed > 0.5 and _speed_now < wanted_speed * 0.2:
		_stuck_t += delta
		if _stuck_t > 1.2:
			_stuck_t = 0.0
			_has_goal = false
			rotation.y += _rng.randf_range(-2.0, 2.0)
	else:
		_stuck_t = 0.0


func speed_now() -> float:
	return _speed_now
