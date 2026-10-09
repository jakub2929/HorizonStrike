extends Node3D
## Campfire (respawn point). Walking within respawn.campfire_activate_radius_m activates it (world.gd checks).
## Visual is a simple placeholder made in code: stone ring, flame and a flickering light.

var campfire_id := ""
var _light: OmniLight3D
var _flame: MeshInstance3D
var _t := 0.0
var _sound_tries := 5
var _sound_wait := 0.0


func _ready() -> void:
	add_to_group("campfires")
	var stone_mat := StandardMaterial3D.new()
	stone_mat.albedo_color = Color(0.35, 0.33, 0.31)
	for i in 8:
		var s := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.16
		m.height = 0.22
		m.radial_segments = 8
		m.rings = 4
		s.mesh = m
		s.material_override = stone_mat
		var a := TAU * i / 8.0
		s.position = Vector3(cos(a) * 0.55, 0.06, sin(a) * 0.55)
		add_child(s)
	_flame = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.3
	cone.height = 0.8
	cone.radial_segments = 8
	_flame.mesh = cone
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(1.0, 0.55, 0.15)
	fm.emission_enabled = true
	fm.emission = Color(1.0, 0.45, 0.1)
	fm.emission_energy_multiplier = 3.0
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flame.material_override = fm
	_flame.position = Vector3(0, 0.4, 0)
	add_child(_flame)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.6, 0.3)
	_light.omni_range = 9.0
	_light.light_energy = 1.6
	_light.position = Vector3(0, 0.9, 0)
	add_child(_light)
	if campfire_id != "":
		Game.campfires[campfire_id] = self


func _exit_tree() -> void:
	if Game.campfires.get(campfire_id) == self:
		Game.campfires.erase(campfire_id)


func _process(delta: float) -> void:
	_t += delta
	if _sound_tries > 0:
		_sound_wait -= delta
		if _sound_wait <= 0.0:
			_sound_wait = 1.0
			_sound_tries -= 1
			_try_sound()
	_light.light_energy = 1.4 + 0.3 * sin(_t * 11.0) * sin(_t * 3.7)
	_flame.scale = Vector3(1, 0.9 + 0.15 * sin(_t * 9.0), 1)


## Crackling loop from the audio contract (ambience kind "campfire"), once the audio director exists.
func _try_sound() -> void:
	var ad: Node = Game.main.get_node_or_null("AudioDirector") if Game.main else null
	if ad == null:
		return
	_sound_tries = 0
	var f: String = ad.loop_for("campfire")
	if f == "":
		return
	var s: AudioStream = load("res://audio/sound_lib.gd").load_stream(f)
	if s == null:
		return
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.unit_size = 3.0
	p.max_distance = 25.0
	p.position = Vector3(0, 0.5, 0)
	add_child(p)
	p.play()


## Where the player is placed on respawn (inside the activation radius, beside the fire).
func respawn_point() -> Vector3:
	return global_position + Vector3(1.6, 0.1, 0.0)
