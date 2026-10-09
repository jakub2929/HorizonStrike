extends RigidBody3D
## Thrown HE grenade (explodes after the fuse: damage linear from weapon.damage at the centre to 0 at weapon.range,
## combat.he_falloff) or molotov (bursts on landing into fire: combat.molotov_radius_m for
## combat.molotov_burn_time_s, weapon.damage per second). Damage goes through the normal hit paths.

const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")

const LAYER_WORLD := 1
const HE_FUSE_S := 1.6
const MOLOTOV_MAX_AIR_S := 2.5
const FIRE_TICK_S := 0.25

var weapon_id := "hegrenade"
var thrower: Node3D
var _t := 0.0
var _burst := false
var _fire_left := 0.0
var _fire_tick := 0.0
var _fire_pos := Vector3.ZERO
var _fire_node: Node3D


func _ready() -> void:
	collision_layer = 16
	collision_mask = LAYER_WORLD
	contact_monitor = true
	max_contacts_reported = 2
	continuous_cd = true
	mass = 0.4
	var cs := CollisionShape3D.new()
	var s := SphereShape3D.new()
	s.radius = 0.06
	cs.shape = s
	add_child(cs)
	var mi := MeshInstance3D.new()
	var m: PrimitiveMesh = SphereMesh.new() if weapon_id == "hegrenade" else CylinderMesh.new()
	if m is SphereMesh:
		(m as SphereMesh).radius = 0.06
		(m as SphereMesh).height = 0.12
	else:
		(m as CylinderMesh).top_radius = 0.03
		(m as CylinderMesh).bottom_radius = 0.045
		(m as CylinderMesh).height = 0.2
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.35, 0.2) if weapon_id == "hegrenade" else Color(0.5, 0.35, 0.15)
	mi.material_override = mat
	add_child(mi)
	body_entered.connect(_on_body_entered)


func _on_body_entered(_b: Node) -> void:
	if weapon_id == "molotov" and not _burst and _t > 0.05:
		_ignite()


func _physics_process(delta: float) -> void:
	_t += delta
	if _burst:
		_fire_left -= delta
		_fire_tick -= delta
		if _fire_tick <= 0.0:
			_fire_tick = FIRE_TICK_S
			_burn(FIRE_TICK_S)
		if _fire_left <= 0.0:
			queue_free()
		return
	if weapon_id == "hegrenade" and _t >= HE_FUSE_S:
		_explode()
	elif weapon_id == "molotov" and _t >= MOLOTOV_MAX_AIR_S:
		_ignite()


func _explode() -> void:
	var c := global_position
	var radius := Sheets.u2m(Sheets.weapon_num(weapon_id, "range", 350.0))
	var dmg := Sheets.weapon_num(weapon_id, "damage", 99.0)
	Log.info("%s exploded at %s (radius %.1f m, damage %.0f)" % [weapon_id, c, radius, dmg])
	Game.make_noise(c, float(Sheets.weapon_row(weapon_id).get("suspicion_radius_m", 80.0)), Sheets.sys_num("suspicion.shot_gain_center", 1.0), Sheets.sys_num("suspicion.shot_gain_edge", 0.4))
	for m in Game.machines.duplicate():
		if not is_instance_valid(m) or m.is_dead():
			continue
		var d: float = m.aim_point("body").distance_to(c)
		if d < radius and _clear(c, m.aim_point("body"), m):
			m.take_hit(weapon_id, dmg * (1.0 - d / radius), "body", false)
	var p: Node3D = Game.player
	if p and p.is_alive():
		var dp: float = p.head_position().distance_to(c)
		if dp < radius:
			p.apply_damage(dmg * (1.0 - dp / radius), Sheets.weapon_num(weapon_id, "armor_ratio", 1.0), self, weapon_id)
	_flash(Color(1.0, 0.7, 0.3), radius)
	queue_free()


func _clear(from: Vector3, to: Vector3, target: Node) -> bool:
	var q := PhysicsRayQueryParameters3D.create(from + Vector3(0, 0.1, 0), to, LAYER_WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.get("collider") == target


func _ignite() -> void:
	_burst = true
	freeze = true
	_fire_pos = global_position
	_fire_left = Sheets.sys_num("combat.molotov_burn_time_s", 7.0)
	Log.info("molotov burst at %s" % _fire_pos)
	Game.make_noise(_fire_pos, float(Sheets.weapon_row(weapon_id).get("suspicion_radius_m", 25.0)), Sheets.sys_num("suspicion.shot_gain_center", 1.0), Sheets.sys_num("suspicion.shot_gain_edge", 0.4))
	var r := Sheets.sys_num("combat.molotov_radius_m", 3.5)
	_fire_node = Node3D.new()
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = r * 0.8
	cyl.bottom_radius = r
	cyl.height = 0.6
	mi.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.45, 0.1, 0.55)
	mi.material_override = mat
	_fire_node.add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.5, 0.2)
	l.omni_range = r * 3.0
	l.light_energy = 2.0
	l.position.y = 1.0
	_fire_node.add_child(l)
	add_child(_fire_node)
	_fire_node.global_position = _fire_pos + Vector3(0, 0.3, 0)


func _burn(dt: float) -> void:
	var r := Sheets.sys_num("combat.molotov_radius_m", 3.5)
	var dps := Sheets.weapon_num(weapon_id, "damage", 40.0)
	for m in Game.machines.duplicate():
		if not is_instance_valid(m) or m.is_dead():
			continue
		var p: Vector3 = m.global_position
		if Vector2(p.x - _fire_pos.x, p.z - _fire_pos.z).length() <= r + 0.5 and absf(p.y - _fire_pos.y) < 2.5:
			m.take_hit(weapon_id, dps * dt, "body", false)
	var pl: Node3D = Game.player
	if pl and pl.is_alive():
		var pp := pl.global_position
		if Vector2(pp.x - _fire_pos.x, pp.z - _fire_pos.z).length() <= r and absf(pp.y - _fire_pos.y) < 2.0:
			pl.apply_damage(dps * dt, Sheets.weapon_num(weapon_id, "armor_ratio", 1.0), self, weapon_id)


func _flash(c: Color, radius: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = c
	l.omni_range = radius * 2.0
	l.light_energy = 6.0
	get_parent().add_child(l)
	l.global_position = global_position + Vector3(0, 0.5, 0)
	var tw := l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.4)
	tw.tween_callback(l.queue_free)
