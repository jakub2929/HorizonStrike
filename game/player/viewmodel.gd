extends Node3D
## First-person weapon view, rendered in its own SubViewport world on top of the scene (no clipping into terrain).
## Real content: cache cs2/weapons/<id>/view.glb (arms + weapon; origin = eye, forward -Z -> identity under the
## view camera; bind pose is meaningless, a clip always plays): draw, idle, fire, reload, inspect (+ fire2 knife
## heavy, pullpin grenades). Missing model: a simple placeholder gun made in code with procedural motion.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")

const VM_FOV := 60.0

var camera: Camera3D           ## view camera inside the SubViewport (set by setup())
var main_camera: Camera3D
var _light: DirectionalLight3D
var _cache := {}               # id -> Node3D
var _current: Node3D
var _anim: AnimationPlayer
var _weapon := ""
var _kick := 0.0
var _dip := 0.0
var _dip_dur := 1.0
var _draw := 0.0
var _bob_t := 0.0


## Builds CanvasLayer > SubViewportContainer > SubViewport(own world) > Camera3D > self. Returns the layer.
func setup(main_cam: Camera3D) -> CanvasLayer:
	main_camera = main_cam
	var layer := CanvasLayer.new()
	layer.name = "ViewmodelLayer"
	layer.layer = 1
	var cont := SubViewportContainer.new()
	cont.name = "ViewmodelContainer"
	cont.stretch = true
	cont.set_anchors_preset(Control.PRESET_FULL_RECT)
	cont.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(cont)
	var svp := SubViewport.new()
	svp.name = "ViewmodelViewport"
	svp.transparent_bg = true
	svp.own_world_3d = true
	svp.gui_disable_input = true
	svp.msaa_3d = Viewport.MSAA_2X
	cont.add_child(svp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.72)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	svp.add_child(we)
	_light = DirectionalLight3D.new()
	_light.light_energy = 1.2
	svp.add_child(_light)
	camera = Camera3D.new()
	camera.name = "ViewCamera"
	camera.fov = VM_FOV
	camera.near = 0.01
	camera.far = 20.0
	camera.current = true
	svp.add_child(camera)
	camera.add_child(self)
	return layer


func show_weapon(id: String) -> void:
	_weapon = id
	if _current:
		_current.visible = false
	_current = _get_model(id)
	_current.visible = true
	_anim = _current.get_meta("anim") if _current.has_meta("anim") else null
	_draw = 0.0 if _anim else 1.0
	if _anim:
		_play_clip("draw", "idle")


func _get_model(id: String) -> Node3D:
	if _cache.has(id):
		return _cache[id]
	var root: Node3D = null
	var path := Game.cache_root.path_join("cs2/weapons/%s/view.glb" % id)
	if FileAccess.file_exists(path):
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(path, st) == OK:
			var scene := doc.generate_scene(st)
			if scene is Node3D:
				root = scene
				var ap := _find_anim(root)
				if ap:
					root.set_meta("anim", ap)
					for a in ap.get_animation_list():
						if String(a).ends_with("idle"):
							ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR
				root.set_meta("real", true)
				Log.info("viewmodel %s: view.glb, clips %s" % [id, ap.get_animation_list() if ap else []])
			elif scene:
				scene.free()
		else:
			Log.warn("viewmodel %s: view.glb failed to load" % id)
	if root == null:
		root = _placeholder(id)
	add_child(root)
	_cache[id] = root
	return root


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var a := _find_anim(c)
		if a:
			return a
	return null


func _clip_name(clip: String) -> String:
	if _anim == null:
		return ""
	for a in _anim.get_animation_list():
		var s := String(a)
		if s == clip or s.ends_with("/" + clip):
			return s
	return ""


func has_clip(clip: String) -> bool:
	return _clip_name(clip) != ""


func _play_clip(clip: String, then: String = "idle") -> bool:
	var n := _clip_name(clip)
	if n == "":
		return false
	_anim.stop()
	_anim.play(n)
	if then != "" and clip != then:
		var nt := _clip_name(then)
		if nt != "":
			_anim.queue(nt)
	return true


func play(clip: String) -> void:
	var played := _anim != null and _play_clip(clip)
	match clip:
		"fire", "fire2":
			_kick = 0.3 if played else 1.0
		"reload":
			if not played:
				_dip = 1.0
				_dip_dur = maxf(Sheets.weapon_num(_weapon, "reload_time", 2.0), 0.3)
		"inspect":
			if not played:
				_dip = 0.4
				_dip_dur = 1.5


func _process(delta: float) -> void:
	if _current == null:
		return
	if main_camera and _light:
		var sun: Node3D = Game.main.get_node_or_null("Sun") if Game.main else null
		if sun:
			_light.basis = main_camera.global_transform.basis.orthonormalized().inverse() * sun.global_transform.basis
	var p: Node3D = Game.player
	var spd := 0.0
	if p and "velocity" in p:
		spd = Vector2(p.velocity.x, p.velocity.z).length()
	_bob_t += delta * (2.0 + spd * 1.6)
	var amp := clampf(spd / 5.0, 0.0, 1.0)
	var bob := Vector3(sin(_bob_t) * 0.006, -absf(cos(_bob_t)) * 0.006, 0) * amp
	_kick = move_toward(_kick, 0.0, delta * 9.0)
	_draw = move_toward(_draw, 0.0, delta * 3.0)
	var dip := 0.0
	if _dip > 0.0:
		_dip = maxf(_dip - delta / _dip_dur, 0.0)
		dip = sin(PI * (1.0 - _dip)) * 0.12
	var real: bool = _current.get_meta("real", false)
	if real:
		_current.position = bob + Vector3(0, 0, _kick * 0.01)
		_current.rotation = Vector3.ZERO
	else:
		_current.position = Vector3(0.18, -0.17 - dip - _draw * 0.2, -0.38) + bob + Vector3(0, 0, _kick * 0.04)
		_current.rotation = Vector3(deg_to_rad(_kick * 6.0 - dip * 120.0), 0, deg_to_rad(dip * 80.0))
	_current.visible = p == null or p.is_alive()


func _placeholder(id: String) -> Node3D:
	var root := Node3D.new()
	root.name = "VM_" + id
	var cat := str(Sheets.weapon_row(id).get("category", "pistol"))
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.12, 0.12, 0.13)
	dark.metallic = 0.5
	dark.roughness = 0.4
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.42, 0.27, 0.15)
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.18, 0.2, 0.16)
	var length: float = {"knife": 0.25, "pistol": 0.2, "smg": 0.38, "rifle": 0.55, "sniper": 0.75, "shotgun": 0.6}.get(cat, 0.3)
	if cat == "knife":
		_box(root, Vector3(0.02, 0.03, 0.12), Vector3(0, 0, 0.02), dark)
		var blade := StandardMaterial3D.new()
		blade.albedo_color = Color(0.75, 0.76, 0.78)
		blade.metallic = 0.9
		blade.roughness = 0.2
		_box(root, Vector3(0.008, 0.035, 0.18), Vector3(0, 0.005, -0.13), blade)
	elif cat == "grenade":
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.04
		sm.height = 0.09
		s.mesh = sm
		s.material_override = skin
		root.add_child(s)
	else:
		_box(root, Vector3(0.04, 0.06, length), Vector3(0, 0, -length * 0.5), dark)
		_box(root, Vector3(0.035, 0.1, 0.05), Vector3(0, -0.07, -0.02), dark)
		if cat in ["rifle", "sniper", "shotgun", "smg"]:
			_box(root, Vector3(0.04, 0.07, 0.18), Vector3(0, -0.02, 0.12), wood)
			_box(root, Vector3(0.03, 0.09, 0.04), Vector3(0, -0.07, -length * 0.45), dark)
	_box(root, Vector3(0.07, 0.07, 0.25), Vector3(0.02, -0.08, 0.18), skin)
	return root


func _box(root: Node3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = pos
	mi.material_override = mat
	root.add_child(mi)
