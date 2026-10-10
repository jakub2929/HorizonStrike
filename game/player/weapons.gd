extends Node
## CS2 weapon behaviour from resolved stats (core/sheets.gd): damage + range falloff, CS armor rule, weak-spot
## headshot multiplier, fire rate (cycle_time), clip/reserve, reload time (incl. single shells), deploy time,
## inaccuracy (stand/crouch/move/jump/land/fire with recovery) + spread, recoil (seeded pattern + view punch),
## knife slash/stab, HE grenade and molotov, scope (zoom levels). Shots make noise (D5).

const Sheets := preload("res://core/sheets.gd")
const Combat := preload("res://core/combat.gd")
const Log := preload("res://core/log.gd")
const Grenade := preload("res://player/grenade.gd")
const Viewmodel := preload("res://player/viewmodel.gd")
const WeaponAudio := preload("res://audio/weapon_audio.gd")

const LAYER_WORLD := 1
const LAYER_HITBOX := 8
const LAYER_WEAK := 16
## Weak spots win when they lie this close behind a body hitbox along the same ray (our per-bone boxes are coarser
## than the real armour shells around an eye or canister).
const WEAK_SLACK_M := 0.15

var player: CharacterBody3D
var viewmodel: Node3D
var audio: Node

var _ammo := {}            # id -> Vector2i(clip, reserve)
var _grenades := {}        # id -> count
var _next_fire := 0.0
var _reload_end := -1.0
var _reload_shell_next := -1.0
var _deploy_end := 0.0
var _penalty := 0.0
var _punch := Vector2.ZERO # degrees: x = pitch up, y = yaw
var _last_shot := -10.0
var _spray_index := 0
var _zoom := 0
var _rng := RandomNumberGenerator.new()
var _recoil_rng := RandomNumberGenerator.new()
var _prev_weapon := ""


func _ready() -> void:
	_rng.randomize()
	viewmodel = Viewmodel.new()
	viewmodel.name = "Viewmodel"
	player.add_child(viewmodel.setup(player.camera))
	audio = WeaponAudio.new()
	audio.name = "WeaponAudio"
	add_child(audio)
	# the start loadout's sounds (and the selected knife model's) are read from disk now, not at the first shot
	for id in Sheets.start_loadout_ids():
		audio.preload_weapon(id)


func _t() -> float:
	return Time.get_ticks_msec() / 1000.0


func mode(id: String) -> int:
	var m := int(Sheets.weapon_row(id).get("default_mode", 0))
	if _zoom > 0 and Sheets.weapon_num(id, "zoom_levels", 0) > 0:
		m = 1
	return m


func pair(id: String, col: String) -> float:
	return Sheets.weapon_pair(id, col, mode(id))


# ------------------------------------------------------------------ inventory

func reset(inv: Array[String]) -> void:
	_ammo.clear()
	_grenades.clear()
	for id in inv:
		give(id)
	_reload_end = -1.0
	_zoom = 0
	_penalty = 0.0
	_punch = Vector2.ZERO


func give(id: String) -> void:
	var slot := str(Sheets.weapon_row(id).get("slot", ""))
	if slot == "grenade":
		add_grenade(id)
		return
	var clip := int(Sheets.weapon_num(id, "clip_size", 0))
	var reserve := int(Sheets.weapon_num(id, "reserve_max", 0))
	if Sheets.weapon_bool(id, "reserve_as_clips"):
		reserve *= maxi(clip, 0)
	_ammo[id] = Vector2i(clip, reserve)


func drop(id: String) -> void:
	_ammo.erase(id)


func add_grenade(id: String) -> void:
	_grenades[id] = int(_grenades.get(id, 0)) + 1


func grenade_count(id: String) -> int:
	return int(_grenades.get(id, 0))


func ammo_of(id: String) -> Vector2i:
	if _grenades.has(id):
		return Vector2i(int(_grenades[id]), 0)
	return _ammo.get(id, Vector2i(0, 0))


func on_equip(id: String, previous: String) -> void:
	if previous != "" and previous != id:
		_prev_weapon = previous
	_reload_end = -1.0
	_zoom = 0
	player.camera.fov = 73.74
	if viewmodel:
		viewmodel.visible = true
	_deploy_end = _t() + Sheets.weapon_num(id, "deploy_time", 0.5)
	if viewmodel:
		viewmodel.show_weapon(id)
	if audio:
		audio.cancel_scheduled()
		audio.play_event(id, "draw")


func on_death() -> void:
	_zoom = 0
	player.camera.fov = 73.74
	_reload_end = -1.0


func max_speed_u() -> float:
	var id: String = player.current_weapon
	if id == "":
		return 250.0
	var v := pair(id, "max_speed")
	return v if v > 0.0 else 250.0


func zoom_sensitivity() -> float:
	return 1.0 if _zoom == 0 else player.camera.fov / 73.74


func is_reloading() -> bool:
	return _reload_end > 0.0


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	var t_proc := Time.get_ticks_usec()
	_process_timed(delta)
	load("res://core/frame_stats.gd").note("weapons", t_proc)


func _process_timed(delta: float) -> void:
	var id: String = player.current_weapon
	if id == "":
		return
	# accuracy recovery: penalty decays to 10% over recovery_time (CS)
	var rec := Sheets.weapon_num(id, "recovery_time_crouch" if player.crouched else "recovery_time_stand", 0.4)
	if rec > 0.0:
		_penalty *= exp(-delta * log(10.0) / rec)
	if _t() - _last_shot > 0.12:
		_punch = _punch.lerp(Vector2.ZERO, clampf(delta * 7.0, 0.0, 1.0))
		if _t() - _last_shot > 0.5:
			_spray_index = 0
	player.camera.rotation = Vector3(deg_to_rad(_punch.x + float(player.aimpunch_deg)), deg_to_rad(_punch.y), 0)
	_update_reload()
	if player.dead or not Game.gameplay_input_allowed():
		return
	var auto := Sheets.weapon_bool(id, "full_auto")
	if (Input.is_action_pressed("fire") if auto else Input.is_action_just_pressed("fire")):
		fire(false)
	if Input.is_action_just_pressed("alt_fire"):
		alt_fire()
	if Input.is_action_just_pressed("reload"):
		start_reload()
	for i in 4:
		if Input.is_action_just_pressed("slot%d" % (i + 1)):
			select_slot(i)
	if Input.is_action_just_pressed("next_weapon"):
		cycle(1)
	if Input.is_action_just_pressed("prev_weapon"):
		cycle(-1)
	if Input.is_action_just_pressed("inspect") and viewmodel and _reload_end < 0.0:
		viewmodel.play("inspect")
		audio.play_event(id, "inspect")
		if viewmodel.is_knife():
			Log.info("knife: inspect %s %s" % [viewmodel.knife_model, viewmodel.last_anim if viewmodel.last_anim != "" else "(no inspect clip)"])


func select_slot(i: int) -> void:
	var slots := ["primary", "secondary", "knife", "grenade"]
	for id in player.inventory:
		if Sheets.weapon_row(id).get("slot") == slots[i] and id != player.current_weapon:
			player.equip(id)
			return


func cycle(dir: int) -> void:
	var inv: Array[String] = player.inventory
	if inv.is_empty():
		return
	var i := inv.find(player.current_weapon)
	player.equip(inv[posmod(i + dir, inv.size())])


func alt_fire() -> void:
	var id: String = player.current_weapon
	var cat := str(Sheets.weapon_row(id).get("category", ""))
	if cat == "knife":
		fire(false, true)
		return
	var levels := int(Sheets.weapon_num(id, "zoom_levels", 0))
	if levels > 0:
		_zoom = (_zoom + 1) % (levels + 1)
		var zf := Sheets.weapon_num(id, "zoom_fov", 40.0)
		player.camera.fov = 73.74 if _zoom == 0 else _hfov_to_vfov(zf / (1.0 + 3.0 * (_zoom - 1)))
		audio.play_event(id, "zoom" if _zoom > 0 else "zoomout")
		if viewmodel:
			viewmodel.visible = _zoom == 0


static func _hfov_to_vfov(hfov_deg: float) -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(hfov_deg) * 0.5) * 0.75))


func start_reload() -> void:
	var id: String = player.current_weapon
	var a: Vector2i = _ammo.get(id, Vector2i(-1, 0))
	var clip_size := int(Sheets.weapon_num(id, "clip_size", 0))
	if a.x < 0 or clip_size <= 0 or a.x >= clip_size or a.y <= 0 or _reload_end > 0.0:
		return
	var rt := Sheets.weapon_num(id, "reload_time", 2.0)
	_zoom = 0
	player.camera.fov = 73.74
	if viewmodel:
		viewmodel.visible = true
	if Sheets.weapon_bool(id, "reload_single_shells"):
		_reload_shell_next = _t() + rt
		_reload_end = _reload_shell_next
	else:
		_reload_end = _t() + rt
	if viewmodel:
		viewmodel.play("reload")
	audio.play_event(id, "reload")


func _update_reload() -> void:
	if _reload_end < 0.0:
		return
	var id: String = player.current_weapon
	var a: Vector2i = _ammo.get(id, Vector2i(0, 0))
	var clip_size := int(Sheets.weapon_num(id, "clip_size", 0))
	if Sheets.weapon_bool(id, "reload_single_shells"):
		if _t() >= _reload_shell_next and a.y > 0 and a.x < clip_size:
			a.x += 1
			a.y -= 1
			_ammo[id] = a
			if a.x < clip_size and a.y > 0:
				# next shell: the reload clip is one shell (+ pump), replay it per shell
				_reload_shell_next = _t() + Sheets.weapon_num(id, "reload_time", 0.5)
				_reload_end = _reload_shell_next
				if viewmodel:
					viewmodel.play("reload")
				audio.play_event(id, "reload")
		if a.x >= clip_size or a.y <= 0:
			_reload_end = -1.0
		return
	if _t() >= _reload_end:
		var take := mini(clip_size - a.x, a.y)
		a.x += take
		a.y -= take
		_ammo[id] = a
		_reload_end = -1.0


# ------------------------------------------------------------------ firing

func inaccuracy(id: String) -> float:
	var base := pair(id, "inaccuracy_crouch" if player.crouched else "inaccuracy_stand")
	var move := pair(id, "inaccuracy_move")
	var sf: float = player.speed_fraction()
	var move_scale := clampf(remap(sf, 0.34, 0.95, 0.0, 1.0), 0.0, 1.0)
	var v := base + move * move_scale
	if not player.is_on_floor():
		v += pair(id, "inaccuracy_jump")
	v += pair(id, "inaccuracy_land") * player.land_penalty()
	return v + _penalty


## One trigger pull. api = called through Game.fire() (ignores the fire-rate/deploy gates; the autotest drives the
## timing, everything else is the normal path). Returns {hit, target, part, damage}.
func fire(api: bool, secondary: bool = false) -> Dictionary:
	var res := {"hit": false, "target": null, "part": "", "damage": 0.0, "point": Vector3.ZERO, "distance": 0.0}
	var id: String = player.current_weapon
	if id == "" or player.dead:
		return res
	var row := Sheets.weapon_row(id)
	var cat := str(row.get("category", ""))
	var now := _t()
	if not api and (now < _next_fire or now < _deploy_end):
		return res
	if _reload_end > 0.0 and not Sheets.weapon_bool(id, "reload_single_shells"):
		if not api:
			return res
		_reload_end = -1.0
	_reload_end = -1.0
	if cat == "knife":
		return _knife(id, secondary, res)
	if cat == "grenade":
		return _throw(id, res)
	if cat == "equipment":
		return res
	var a: Vector2i = _ammo.get(id, Vector2i(0, 0))
	if a.x <= 0:
		res["reason"] = "empty"
		start_reload()
		audio.play_event(id, "dry")
		return res
	a.x -= 1
	_ammo[id] = a
	_next_fire = now + pair(id, "cycle_time")
	_last_shot = now
	var cam: Camera3D = player.camera
	var origin := cam.global_position
	var basis := cam.global_transform.basis
	var inacc := inaccuracy(id)
	var spread := pair(id, "spread")
	var bullets := maxi(int(Sheets.weapon_num(id, "bullets", 1)), 1)
	var range_m := Sheets.u2m(Sheets.weapon_num(id, "range", 8192.0))
	var dmg := Sheets.weapon_num(id, "damage", 0.0)
	var first_target: Node = null
	for b in bullets:
		var r1 := _rng.randf() * inacc
		var t1 := _rng.randf() * TAU
		var r2 := _rng.randf() * spread
		var t2 := _rng.randf() * TAU
		var off := Vector2(cos(t1) * r1 + cos(t2) * r2, sin(t1) * r1 + sin(t2) * r2)
		var dir := (-basis.z + basis.x * off.x + basis.y * off.y).normalized()
		var h := _trace(origin, dir, range_m)
		if h.is_empty():
			continue
		var pos: Vector3 = h["position"]
		_impact_noise(pos)
		var col: Object = h["collider"]
		if col is Area3D and col.has_meta("machine"):
			var m: Node = col.get_meta("machine")
			if not is_instance_valid(m):
				continue
			var part := str(col.get_meta("part", "body"))
			var weak: bool = col.get_meta("weak", false)
			var d := Combat.range_falloff(id, dmg, origin.distance_to(pos))
			var dealt: float = Combat.player_hit(m, id, d, part, weak, pos, h.get("normal", Vector3.ZERO))
			if first_target == null or first_target == m:
				if first_target == null:
					res["point"] = pos
					res["distance"] = origin.distance_to(pos)
				first_target = m
				res["hit"] = true
				res["target"] = m
				res["part"] = part
				res["damage"] = float(res["damage"]) + dealt
		_tracer(origin + basis * Vector3(0.1, -0.12, -0.6), pos)
	_penalty += pair(id, "inaccuracy_fire")
	_recoil(id)
	_shot_noise(id)
	if viewmodel:
		viewmodel.play("fire")
	audio.play_event(id, "fire")
	if a.x <= 0:
		start_reload()
	return res


func _trace(origin: Vector3, dir: Vector3, range_m: float) -> Dictionary:
	var space := player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * range_m, LAYER_WORLD | LAYER_HITBOX | LAYER_WEAK)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return hit
	var col: Object = hit["collider"]
	if col is Area3D and col.has_meta("machine") and not col.get_meta("weak", false):
		# a weak spot of the same machine wins when it lies just behind the body surface (WEAK_SLACK_M) or inside a
		# body box of that machine (body boxes over-cover the mesh and can wrap a weak spot completely)
		var d := origin.distance_to(hit["position"])
		var qw := PhysicsRayQueryParameters3D.create(origin, origin + dir * range_m, LAYER_WEAK)
		qw.collide_with_areas = true
		qw.collide_with_bodies = false
		var hw := space.intersect_ray(qw)
		if not hw.is_empty() and (hw["collider"] as Object).get_meta("machine", null) == col.get_meta("machine"):
			var dw := origin.distance_to(hw["position"])
			if dw <= d + WEAK_SLACK_M or _wrapped(col.get_meta("machine"), hw["position"]):
				return hw
	return hit


## Point inside any body hitbox box of machine m.
static func _wrapped(m: Node, p: Vector3) -> bool:
	if not is_instance_valid(m) or m.get("rig") == null:
		return false
	for h in m.rig.hitboxes:
		if not (h as Area3D).get_meta("weak", false) and _inside_box(h as Area3D, p):
			return true
	return false


## Point inside the (first) box shape of a hitbox area.
static func _inside_box(area: Area3D, p: Vector3) -> bool:
	for c in area.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			var lp: Vector3 = ((c as CollisionShape3D).global_transform.affine_inverse()) * p
			var half: Vector3 = ((c as CollisionShape3D).shape as BoxShape3D).size * 0.5
			return absf(lp.x) <= half.x and absf(lp.y) <= half.y and absf(lp.z) <= half.z
	return false


func _recoil(id: String) -> void:
	_recoil_rng.seed = int(Sheets.weapon_num(id, "recoil_seed", 0)) * 1000 + _spray_index
	_spray_index += 1
	var ang := pair(id, "recoil_angle") + _recoil_rng.randf_range(-1.0, 1.0) * pair(id, "recoil_angle_variance")
	var mag := pair(id, "recoil_magnitude") + _recoil_rng.randf_range(-1.0, 1.0) * pair(id, "recoil_magnitude_variance")
	mag *= 0.035
	var ar := deg_to_rad(ang)
	_punch.x = clampf(_punch.x + cos(ar) * mag, -20.0, 20.0)
	_punch.y = clampf(_punch.y - sin(ar) * mag, -15.0, 15.0)


func _shot_noise(id: String) -> void:
	var r := float(Sheets.weapon_row(id).get("suspicion_radius_m", 30.0))
	if r <= 0.0:
		return
	Game.make_noise(player.global_position, r, Sheets.sys_num("suspicion.shot_gain_center", 1.0), Sheets.sys_num("suspicion.shot_gain_edge", 0.4), true)


func _impact_noise(pos: Vector3) -> void:
	for m in Game.machines:
		if is_instance_valid(m):
			m.notice_impact(pos)


func _knife(id: String, stab: bool, res: Dictionary) -> Dictionary:
	var interval := Sheets.sys_num("combat.knife_secondary_interval_s" if stab else "combat.knife_primary_interval_s", 0.4)
	_next_fire = _t() + interval
	var reach := Sheets.sys_num("combat.knife_reach_m", 1.6)
	var dmg := Sheets.weapon_num(id, "damage", 40.0) * (Sheets.sys_num("combat.knife_secondary_mult", 1.3) if stab else 1.0)
	var cam: Camera3D = player.camera
	var h := _trace(cam.global_position, -cam.global_transform.basis.z, reach)
	if viewmodel:
		viewmodel.play("fire2" if stab and viewmodel.has_clip("fire2") else "fire")
	audio.play_event(id, "fire2" if stab else "fire")
	if h.is_empty():
		return res
	var col: Object = h["collider"]
	if col is Area3D and col.has_meta("machine"):
		var m: Node = col.get_meta("machine")
		var part := str(col.get_meta("part", "body"))
		var weak: bool = col.get_meta("weak", false)
		# silent strike (combat.silent_strike_rule): a stab on an unaware machine from outside its sight cone - any
		# knife model, the attack is the knife row's
		var silent := stab and Combat.is_silent_strike(m, cam.global_position)
		if silent:
			dmg *= Sheets.sys_num("combat.silent_strike_mult", 1.0)
			Log.info("silent strike on %s (%s): %.0f damage before armour" % [m.get("machine_type"), m.get("state"), dmg * Combat.Progression.damage_mult()])
		var dealt: float = Combat.player_hit(m, id, dmg, part, weak, h["position"], h.get("normal", Vector3.ZERO), silent)
		res["silent"] = silent
		res["hit"] = true
		res["target"] = m
		res["part"] = part
		res["damage"] = dealt
		res["point"] = h["position"]
		res["distance"] = cam.global_position.distance_to(h["position"])
	return res


func _throw(id: String, res: Dictionary) -> Dictionary:
	if grenade_count(id) <= 0:
		return res
	_grenades[id] = grenade_count(id) - 1
	_next_fire = _t() + 1.0
	var g := Grenade.new()
	g.weapon_id = id
	g.thrower = player
	player.get_parent().add_child(g)
	var cam: Camera3D = player.camera
	var dir := (-cam.global_transform.basis.z + Vector3.UP * 0.12).normalized()
	g.global_position = cam.global_position + dir * 0.5
	g.linear_velocity = dir * Sheets.u2m(Sheets.weapon_num(id, "throw_velocity", 750.0)) * 0.9 + player.velocity * 1.25
	audio.play_event(id, "fire")
	if viewmodel:
		viewmodel.play("fire")
	Log.info("threw %s" % id)
	res["thrown"] = true
	if grenade_count(id) <= 0:
		_grenades.erase(id)
		player.inventory.erase(id)
		var back := _prev_weapon if player.inventory.has(_prev_weapon) else ""
		if back == "":
			for w in player.inventory:
				back = w
		player.equip(back)
	return res



## Short-lived bullet tracer in the main world.
func _tracer(from: Vector3, to: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from)
	im.surface_add_vertex(to)
	im.surface_end()
	mi.mesh = im
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.9, 0.6, 0.6)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = m
	mi.top_level = true
	player.get_parent().add_child(mi)
	mi.global_transform = Transform3D.IDENTITY
	get_tree().create_timer(0.05).timeout.connect(mi.queue_free)
