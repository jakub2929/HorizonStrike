extends CharacterBody3D
## A Horizon machine with Horizon logic (sheets machines.json + machine_attacks.json, systems suspicion.*):
## guards patrol and go suspicious -> alert -> attack; herds graze and flee on alert (fighting back when cornered) or,
## with behaviour.defend_charge, stand their ground and charge a threat inside fight_back_radius_m; predators prowl,
## stalk the player low and slow (stalk_speed_mps) until stalk_until_m, then pounce/charge/bite; scavengers scavenge
## in packs, radar-ping the area every radar_ping_interval_s (reveals the player within radar_ping_radius_m), call the
## pack within pack_call_radius_m and fight at range (laser bursts) while circling the player.
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
## Corpses lie where the machine fell; they are freed after CORPSE_MIN_S once the player is farther than
## CORPSE_FREE_DISTANCE_M, and always after CORPSE_MAX_S (design, stroje).
const CORPSE_MIN_S := 45.0
const CORPSE_MAX_S := 240.0
const CORPSE_FREE_DISTANCE_M := 80.0

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
var behaviour := {}
## Id of the attack being performed (machine_attacks row id; "" when none) - frozen interface (PLAN-0.2).
var current_attack := ""

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
var _ping_t := 3.0
var _hit_time := -100.0
var _burst_fired := 0
var _charge_speed := 0.0
var _strafe_sign := 1.0
var _strafe_t := 0.0
var _sees_player := false
var _speed_now := 0.0
var _stuck_t := 0.0
var _dead_t := 0.0
var _rng := RandomNumberGenerator.new()
var _gravity := 9.8
var _perc_acc := randf() * 0.1   # perception runs at 10 Hz, staggered

## Dev/bench only: with ai_enabled false these drive the machine through the normal steering (dev/machine_bench.gd).
## drive_face (when non-zero) turns the machine in place towards that direction.
var drive_dir := Vector3.ZERO
var drive_speed := 0.0
var drive_face := Vector3.ZERO

## Motion facts for the animator (updated every physics tick): yaw rate (rad/s, + = turning left) and forward
## acceleration (m/s^2).
var yaw_rate := 0.0
var accel_fwd := 0.0
var turn_in_place_rate := deg_to_rad(180.0)
var _last_yaw := 0.0
var _last_hv := Vector3.ZERO


func setup(type: String, machine_meta: Dictionary) -> void:
	machine_type = type
	meta = machine_meta
	archetype = str(Sheets.machine(type, "archetype"))
	# D36: real HZD InitialHealth x combat.machine_health_scale; the design `health` only when unresolved
	var hzd_hp := Sheets.machine_num(type, "hzd_health", 0.0)
	max_health = hzd_hp * Sheets.sys_num("combat.machine_health_scale", 1.0) if hzd_hp > 0.0 else Sheets.machine_num(type, "health", 200.0)
	health = max_health
	armor = Sheets.machine_num(type, "armor_points", 0.0)
	walk_speed = Sheets.machine_num(type, "walk_speed_mps", 1.6)
	run_speed = Sheets.machine_num(type, "run_speed_mps", 7.0)
	turn_rate = deg_to_rad(Sheets.machine_num(type, "turn_rate_dps", 180.0))
	var anim: Variant = Sheets.machine(type, "anim")
	turn_in_place_rate = deg_to_rad(float((anim as Dictionary).get("turn_in_place_dps", rad_to_deg(turn_rate)))) if anim is Dictionary else turn_rate
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
	var bh: Variant = Sheets.machine(type, "behaviour")
	behaviour = bh if bh is Dictionary else {}
	_ping_t = randf_range(1.0, maxf(float(behaviour.get("radar_ping_interval_s", 6.0)), 1.5))
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
	_set_state(_calm_state())
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


## Weak spot: its hitbox centre. "body": centre of mass = the largest body hitbox (the trunk).
## A part can have several hitboxes (Grazer: four canisters); with `from` (the shooter) the nearest one is used.
## Game.aim_at picks among weak_points() the one a shot from the camera actually reaches.
func aim_point(part: String, from: Variant = null) -> Vector3:
	if part != "body":
		var pts := weak_points(part)
		if not pts.is_empty():
			if from is Vector3:
				var eye: Vector3 = from
				pts.sort_custom(func(a, b): return eye.distance_squared_to(a) < eye.distance_squared_to(b))
			return pts[0]
	var best: Node3D = null
	var best_v := -1.0
	for h in rig.hitboxes:
		if str(h.get_meta("part", "")) != "body":
			continue
		var cs := (h as Node).get_child(0) as CollisionShape3D
		var v := 0.0
		if cs and cs.shape is BoxShape3D:
			var sz: Vector3 = (cs.shape as BoxShape3D).size
			v = sz.x * sz.y * sz.z
		if v > best_v:
			best_v = v
			best = h
	if best:
		return best.global_position
	return global_position + Vector3(0, rig.body_height * 0.6, 0)


## Centres of every hitbox of a weak-spot part (spheres from the content points and the part's own geometry boxes).
## With `samples`, also points inside each hitbox towards its surface (up, and both ways along its axes): a canister
## whose centre is behind the body's back can still show its upper half.
func weak_points(part: String, samples: bool = false) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for h in rig.hitboxes:
		if str(h.get_meta("part", "")) != part:
			continue
		var c: Vector3 = (h as Node3D).global_position
		out.append(c)
		if not samples:
			continue
		var cs := (h as Node).get_child(0) as CollisionShape3D
		var ext := Vector3(0.1, 0.1, 0.1)
		if cs and cs.shape is SphereShape3D:
			var r: float = (cs.shape as SphereShape3D).radius * 0.5
			ext = Vector3(r, r, r)
		elif cs and cs.shape is BoxShape3D:
			ext = (cs.shape as BoxShape3D).size * 0.25
		var b: Basis = (h as Node3D).global_transform.basis.orthonormalized()
		out.append(c + Vector3.UP * ext.y)
		for ax in [b.x * ext.x, b.z * ext.z, b.y * ext.y]:
			out.append(c + ax)
			out.append(c - ax)
	return out


func targets_player() -> bool:
	return state in ["alert", "attack", "stalk"] or (state == "flee" and _attack_phase != "")


## The calm state of this machine: guards and predators patrol, scavengers scavenge, herds graze.
func _calm_state() -> String:
	match archetype:
		"guard", "predator":
			return "patrol"
		"scavenger":
			return "scavenge" if bool(behaviour.get("scavenge", true)) else "patrol"
	return "graze"


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
	_hit_time = _now()
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
		if state == "stalk":
			_set_state("attack")   # a stalking predator that is shot goes for the shooter at once
		elif state != "alert" and state != "attack" and state != "flee":
			_go_alert()
	return dmg


func _die(weapon_id: String) -> void:
	_set_state("dead")
	velocity = Vector3.ZERO
	collision_layer = 0
	var tb := get_node_or_null("TrunkBody") as CollisionObject3D
	if tb:
		tb.collision_layer = 0
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
	if loud and archetype == "herd" and suspicion >= susp_threshold and state in ["idle", "graze", "suspicious"]:
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
	if suspicion >= alert_threshold and state not in ["alert", "attack", "flee", "stalk"]:
		if Game.player:
			_last_seen = Game.player.global_position
			_last_seen_time = _now()
		_go_alert()
	elif suspicion >= susp_threshold and state in ["idle", "patrol", "graze", "scavenge"]:
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
	if state in ["alert", "attack", "stalk"]:
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
	current_attack = ""
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
	# guards call nearby machines, scavengers call their pack, herds alert their herd (systems
	# suspicion.herd_alert_radius_m); lone predators call nobody unless behaviour.call_on_alert
	var call_r := 0.0
	match archetype:
		"guard":
			call_r = alert_call_radius if bool(behaviour.get("call_on_alert", true)) else 0.0
		"scavenger":
			call_r = float(behaviour.get("pack_call_radius_m", alert_call_radius)) if bool(behaviour.get("call_on_alert", true)) else 0.0
		"predator":
			call_r = alert_call_radius if bool(behaviour.get("call_on_alert", false)) else 0.0
		_:
			call_r = Sheets.sys_num("suspicion.herd_alert_radius_m", 60.0)
	if call_r > 0.0:
		for m in Game.machines:
			if m == self or not is_instance_valid(m) or m.is_dead() or not m.ai_enabled:
				continue
			if m.global_position.distance_to(global_position) <= call_r and m.state not in ["alert", "attack", "flee", "stalk"]:
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
	_set_state(_calm_state())


func _physics_process(delta: float) -> void:
	if state == "dead":
		_dead_t += delta
		_apply_gravity(delta)
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		if _dead_t > CORPSE_MAX_S or (_dead_t > CORPSE_MIN_S and (Game.player == null or Game.player.global_position.distance_to(global_position) > CORPSE_FREE_DISTANCE_M)):
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
		_radar(delta)
		var r := _think(delta)
		desired = r[0]
		speed = r[1]
	else:
		desired = drive_dir
		speed = drive_speed
		if drive_face != Vector3.ZERO:
			_face(drive_face, delta)
	_steer(desired, speed, delta)
	_apply_gravity(delta)
	move_and_slide()
	_speed_now = Vector3(velocity.x, 0, velocity.z).length()
	_check_stuck(delta, speed)
	_track_motion(delta)


func _track_motion(delta: float) -> void:
	yaw_rate = wrapf(rotation.y - _last_yaw, -PI, PI) / maxf(delta, 0.0001)
	_last_yaw = rotation.y
	var hv := Vector3(velocity.x, 0, velocity.z)
	accel_fwd = (hv - _last_hv).dot(forward()) / maxf(delta, 0.0001)
	_last_hv = hv


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
				_set_state(_calm_state())
			return [Vector3.ZERO, 0.0]
		"patrol", "graze", "scavenge":
			return _wander(delta, archetype in ["guard", "predator"])
		"suspicious":
			if suspicion < susp_threshold * 0.5:
				_set_state(_calm_state())
				return [Vector3.ZERO, 0.0]
			var to := _stimulus - global_position
			to.y = 0
			_face(to, delta)
			# guards, predators and scavengers walk over to investigate; herds stand and look
			if archetype != "herd" and to.length() > 6.0 and _state_time > 1.5:
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
				match archetype:
					"predator":
						var dp := _player_distance()
						_set_state("stalk" if dp > float(behaviour.get("stalk_until_m", 18.0)) else "attack")
					"herd":
						# defend_charge herds hold their ground and charge a threat that comes close (or shot them)
						if _player_distance() <= _defend_radius():
							_set_state("attack")
						elif not _sees_player and _now() - _last_seen_time > search_time:
							suspicion = susp_threshold
							_set_state("suspicious")
					_:
						_set_state("attack")
			return [Vector3.ZERO, 0.0]
		"stalk":
			return _do_stalk(delta)
		"attack":
			return _do_attack(delta)
		"flee":
			return _do_flee(delta)
	return [Vector3.ZERO, 0.0]


func _player_distance() -> float:
	var p: Node3D = Game.player
	if p == null or not p.is_alive():
		return INF
	return Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()


## Distance at which a defend_charge herd attacks: fight_back_radius_m, doubled for 10 s after being shot.
func _defend_radius() -> float:
	var r := fight_back_radius if bool(behaviour.get("defend_charge", false)) else 0.0
	if _now() - _hit_time < 10.0:
		r *= 2.0
	return r


## Predator stalk: low and slow towards where the player was seen, until stalk_until_m, then the attack.
func _do_stalk(delta: float) -> Array:
	var p: Node3D = Game.player
	if p == null or not p.is_alive():
		_set_state("suspicious")
		return [Vector3.ZERO, 0.0]
	if not _sees_player and _now() - _last_seen_time > search_time:
		suspicion = susp_threshold
		_set_state("suspicious")
		return [Vector3.ZERO, 0.0]
	var target := p.global_position if _sees_player else _last_seen
	var to := target - global_position
	to.y = 0
	if _player_distance() <= float(behaviour.get("stalk_until_m", 18.0)) or _state_time > 15.0:
		_set_state("attack")
		return [Vector3.ZERO, 0.0]
	if to.length() < 1.5:
		_face(p.global_position - global_position, delta)
		return [Vector3.ZERO, 0.0]
	return [to.normalized(), float(behaviour.get("stalk_speed_mps", walk_speed))]


## Scavenger radar: every radar_ping_interval_s a ping reveals the player inside radar_ping_radius_m (no line of
## sight needed): suspicion rises by systems-free design value 0.5 per ping, so two pings in range alert the pack.
func _radar(delta: float) -> void:
	var interval := float(behaviour.get("radar_ping_interval_s", 0.0))
	var radius := float(behaviour.get("radar_ping_radius_m", 0.0))
	if archetype != "scavenger" or interval <= 0.0 or radius <= 0.0:
		return
	_ping_t -= delta
	if _ping_t > 0.0:
		return
	_ping_t = interval * randf_range(0.85, 1.15)
	if rig and rig.has_method("radar_pulse"):
		rig.radar_pulse(radius)
	var p: Node3D = Game.player
	var hit: bool = p != null and p.is_alive() and p.global_position.distance_to(global_position) <= radius
	Log.info("machine %s radar ping (player %s)" % [name, "inside" if hit else "outside"])
	if hit:
		_stimulus = p.global_position
		_last_seen = p.global_position
		_last_seen_time = _now()
		suspicion = minf(suspicion + 0.5 * alert_threshold, alert_threshold * 1.5)
		_after_suspicion_change()


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
	# a defending herd animal goes back to watching when the threat has backed off
	if archetype == "herd" and best.is_empty() and d > _defend_radius() * 1.5:
		_set_state("alert")
		_alert_announce = 0.0
		return [Vector3.ZERO, 0.0]
	_face(to, delta)
	# scavengers circle the player at laser range while their attacks cool down
	if archetype == "scavenger" and best.is_empty() and d > 5.0 and d < 30.0:
		_strafe_t -= delta
		if _strafe_t <= 0.0:
			_strafe_t = _rng.randf_range(2.5, 5.0)
			_strafe_sign = -_strafe_sign
		var tang := Vector3(-to.z, 0, to.x).normalized() * _strafe_sign
		var radial := 0.0
		if d < 10.0:
			radial = -0.6
		elif d > 20.0:
			radial = 0.6
		return [(tang + to.normalized() * radial).normalized(), walk_speed * 1.6]
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
	_burst_fired = 0
	current_attack = str(a["id"])
	if rig:
		rig.play_attack(a)
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
				# leaps (pounce, lunge) cover the distance to the player within the active time; charges run
				var pose := str(a.get("pose", ""))
				_charge_speed = run_speed * 1.4
				if pose in ["pounce", "lunge"]:
					_charge_speed = clampf(d / maxf(float(a["active_s"]), 0.1), run_speed * 0.6, run_speed * 1.8)
			return [Vector3.ZERO, 0.0]
		"active":
			var move := Vector3.ZERO
			var spd := 0.0
			if a["kind"] == "ranged":
				# a burst: one bolt per 0.15 s of active time (laser burst 0.6 s = 4 bolts; eye bolt 0.1 s = 1)
				var shots := maxi(1, roundi(float(a["active_s"]) / 0.15))
				while _burst_fired < shots and _attack_t >= float(_burst_fired) * float(a["active_s"]) / shots:
					_face(to, delta)
					_fire_projectile(a)
					_burst_fired += 1
				_attack_dealt = true
			if a["kind"] == "charge":
				move = forward()
				spd = _charge_speed
			if not _attack_dealt and a["kind"] != "ranged":
				var p: Node3D = Game.player
				var reach := float(a["range_max_m"]) if a["kind"] == "melee" else 2.5
				if p and d <= reach + rig.body_radius and _direction_ok(a, to):
					p.apply_damage(float(a["damage"]), float(a["armor_ratio"]), self, str(a["id"]))
					p.knockback((to.normalized() + Vector3.UP * 0.3) * float(a["knockback_mps"]))
					_attack_dealt = true
			if _attack_t >= float(a["active_s"]):
				_attack_phase = ""
				current_attack = ""
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
	# attack origin point: "attack_<attack id>" or "attack_<id without the machine prefix>", else the eye
	var aid := str(a["id"])
	var from: Vector3 = rig.point_global("attack_" + aid, rig.point_global("attack_" + aid.substr(aid.find("_") + 1), eye_position() + forward() * 0.5))
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
	# keep running until flee_distance_m from the threat; then the herd settles where it ended up (its new home),
	# so it does not graze its way back towards the threat
	if away.length() >= flee_distance and not _sees_player:
		home = global_position
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
	var rate := turn_rate if _speed_now > 0.5 else minf(turn_rate, turn_in_place_rate)
	rotation.y = yaw + clampf(diff, -rate * delta, rate * delta)


## Obstacle avoidance: feelers at body height; when the wanted direction is blocked, take the freest of a fan of
## directions around it (keeps herds and guards from piling up against rocks, walls and fences).
var _avoid_dir := Vector3.ZERO
var _avoid_t := 0.0


func _avoid(dir: Vector3, speed: float, delta: float) -> Vector3:
	_avoid_t -= delta
	if _avoid_t > 0.0 and _avoid_dir != Vector3.ZERO:
		return _avoid_dir
	_avoid_t = 0.15
	var d := Vector3(dir.x, 0, dir.z).normalized()
	var reach: float = clampf(speed * 0.9, 2.0, 9.0) + float(rig.body_radius)
	if _clear(d, reach) >= reach:
		_avoid_dir = Vector3.ZERO
		return d
	var best := d
	var best_free := -1.0
	for deg in [30.0, -30.0, 60.0, -60.0, 90.0, -90.0, 135.0, -135.0]:
		var cand := d.rotated(Vector3.UP, deg_to_rad(deg))
		var free := _clear(cand, reach) - absf(deg) * 0.01
		if free > best_free:
			best_free = free
			best = cand
	_avoid_dir = best
	return best


func _clear(d: Vector3, reach: float) -> float:
	var from := global_position + Vector3(0, clampf(rig.body_height * 0.35, 0.5, 1.5), 0)
	var q := PhysicsRayQueryParameters3D.create(from, from + d * reach, LAYER_WORLD)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return reach
	var n: Vector3 = hit["normal"]
	if n.y > 0.75:
		return reach   # walkable slope, not an obstacle
	return from.distance_to(hit["position"])


func _steer(dir: Vector3, speed: float, delta: float) -> void:
	if speed > 0.0 and dir.length() > 0.01:
		dir = _avoid(dir, speed, delta)
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
