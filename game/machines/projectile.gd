extends Node3D
## Machine projectile (e.g. Watcher eye bolt): moves straight, ray-tests its path each frame against the world and
## the player, damages the player through the normal damage path.

const LAYER_WORLD := 1
const LAYER_PLAYER := 2

var attack: Dictionary = {}
var source: Node = null
var velocity := Vector3.ZERO
var _life := 3.0


func _ready() -> void:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.12
	s.height = 0.24
	mi.mesh = s
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.85, 0.3)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.7, 0.2)
	mi.material_override = m
	add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.7, 0.3)
	l.omni_range = 3.0
	add_child(l)
	add_to_group("machine_projectiles")


func _physics_process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		queue_free()
		return
	var from := global_position
	var to := from + velocity * delta
	var q := PhysicsRayQueryParameters3D.create(from, to, LAYER_WORLD | LAYER_PLAYER)
	if source and source is CollisionObject3D:
		q.exclude = [(source as CollisionObject3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		var col: Object = hit["collider"]
		if col == Game.player and Game.player.is_alive():
			Game.player.apply_damage(float(attack.get("damage", 10)), float(attack.get("armor_ratio", 1.0)), source, str(attack.get("id", "projectile")))
			Game.player.knockback(velocity.normalized() * float(attack.get("knockback_mps", 1.0)))
		queue_free()
		return
	global_position = to
