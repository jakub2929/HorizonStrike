extends Node3D
## First-person weapon view, rendered in its own SubViewport world on top of the scene (no clipping into terrain).
## Real content: cache cs2/weapons/<id>/view.glb (arms + weapon; origin = eye, forward -Z -> identity under the
## view camera; bind pose is meaningless, a clip always plays): draw, idle, fire, reload, inspect (+ fire2 knife
## heavy, pullpin grenades). Missing model: a simple placeholder gun made in code with procedural motion.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const Content := preload("res://core/content.gd")
const Knives := preload("res://core/knives.gd")

const VM_FOV := 60.0

var camera: Camera3D           ## view camera inside the SubViewport (set by setup())
var main_camera: Camera3D
var knife_model := ""          ## knife model id shown the last time the knife slot was drawn ("" = not yet)
var last_anim := ""            ## clip name the last play() started ("" = the model has no such clip)
var last_anim_request := ""    ## the gameplay clip asked for last (draw, fire, fire2, inspect, ...)
var _light: DirectionalLight3D
var _cache := {}               # content key (weapon id or "knives/<id>") -> Node3D
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


## Loading screen (world/precompile.gd): load and show a weapon model so its glTF parse and shaders happen there.
func preload_model(id: String) -> void:
	var m := _get_model(Knives.content_id(id), id)
	m.visible = true


## End of the loading screen: only the current weapon stays visible.
func end_preload() -> void:
	for id in _cache:
		(_cache[id] as Node3D).visible = (_cache[id] == _current)


## Draws a weapon (the knife slot shows the selected knife model, core/knives.gd).
func show_weapon(id: String) -> void:
	_weapon = id
	if _current:
		_current.visible = false
	var cid := Knives.content_id(id)
	_current = _get_model(cid, id)
	_current.visible = true
	_anim = _current.get_meta("anim") if _current.has_meta("anim") else null
	_draw = 0.0 if _anim else 1.0
	last_anim_request = "draw"
	last_anim = ""
	if _anim and _play_clip("draw", "idle"):
		last_anim = _clip_name("draw")
	if is_knife():
		knife_model = str(_current.get_meta("knife_model", Knives.model_of(cid)))
		Log.info("knife: equipped %s" % knife_model)


func is_knife() -> bool:
	return str(Sheets.weapon_row(_weapon).get("category", "")) == "knife"


## The knife selection changed (Esc menu): a drawn knife is drawn again as the new model.
func refresh_knife() -> void:
	if _weapon != "" and is_knife():
		show_weapon(_weapon)


## cid = content key (weapon id or "knives/<id>"), weapon_id = the sheet row (placeholder kind, default model).
func _get_model(cid: String, weapon_id: String) -> Node3D:
	if _cache.has(cid):
		return _cache[cid]
	var id := cid
	var root: Node3D = null
	var path := Content.weapon_view_model(cid)
	if path == "" and cid != weapon_id:
		Log.warn("viewmodel %s: no view.glb, showing %s" % [cid, weapon_id])
		path = Content.weapon_view_model(weapon_id)
		id = weapon_id
	if path != "":
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
				root.set_meta("points", _attach_points(root, id))
				Log.info("viewmodel %s: view.glb, clips %s" % [id, ap.get_animation_list() if ap else []])
			elif scene:
				scene.free()
		else:
			Log.warn("viewmodel %s: view.glb failed to load" % id)
	if root == null:
		root = _placeholder(weapon_id)
		id = weapon_id
	if str(Sheets.weapon_row(weapon_id).get("category", "")) == "knife":
		root.set_meta("knife_model", Knives.model_of(id))
	add_child(root)
	_cache[cid] = root
	return root


## Named points of the weapon (content contract): a Node3D per point on its bone (bone name or bone role),
## with the point's local offset and rotation. Returns name -> Node3D.
func _attach_points(root: Node, id: String) -> Dictionary:
	var out := {}
	var sk := _find_skeleton(root)
	if sk == null:
		return out
	var roles := Content.weapon_bone_roles(id)
	var pts := Content.weapon_points(id)
	for pn in pts:
		var pt: Dictionary = pts[pn]
		var bname := str(pt.get("bone", ""))
		var b := sk.find_bone(bname)
		if b < 0 and roles.has(bname):
			b = sk.find_bone(str(roles[bname]))
		if b < 0:
			continue
		var ba := BoneAttachment3D.new()
		sk.add_child(ba)
		ba.bone_idx = b
		var n := Node3D.new()
		n.name = "Point_" + str(pn).validate_node_name()
		var off: Array = pt.get("offset", [0, 0, 0])
		var rot: Array = pt.get("rotation", [0, 0, 0, 1])
		n.transform = Transform3D(Basis(Quaternion(rot[0], rot[1], rot[2], rot[3])), Vector3(off[0], off[1], off[2]))
		var fw: Array = pt.get("forward", [0, 0, -1])
		n.set_meta("forward", Vector3(fw[0], fw[1], fw[2]))
		ba.add_child(n)
		out[str(pn)] = n
	return out


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


## Muzzle flash at the "muzzle" point (or "flame") and a shell out of the "eject" point.
func _fire_fx() -> void:
	if _current == null or not _current.has_meta("points"):
		return
	var pts: Dictionary = _current.get_meta("points")
	var muzzle: Node3D = pts.get("muzzle", pts.get("flame"))
	if muzzle:
		var fl := OmniLight3D.new()
		fl.light_color = Color(1.0, 0.75, 0.4)
		fl.omni_range = 2.5
		fl.light_energy = 3.0
		var spr := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.09, 0.09)
		spr.mesh = q
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(1.0, 0.8, 0.45, 0.9)
		spr.material_override = m
		muzzle.add_child(fl)
		muzzle.add_child(spr)
		get_tree().create_timer(0.05).timeout.connect(fl.queue_free)
		get_tree().create_timer(0.04).timeout.connect(spr.queue_free)
	var eject: Node3D = pts.get("eject")
	if eject:
		var shell := MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = 0.004
		c.bottom_radius = 0.004
		c.height = 0.02
		shell.mesh = c
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.8, 0.6, 0.25)
		sm.metallic = 0.8
		shell.material_override = sm
		shell.top_level = true
		add_child(shell)
		shell.global_transform = eject.global_transform
		var dir: Vector3 = (eject.global_transform.basis * (eject.get_meta("forward") as Vector3)).normalized()
		var tw := shell.create_tween()
		tw.set_parallel(true)
		tw.tween_property(shell, "global_position", shell.global_position + dir * 0.35 + Vector3(0, -0.25, 0), 0.45)
		tw.tween_property(shell, "rotation", shell.rotation + Vector3(6, 3, 0), 0.45)
		tw.chain().tween_callback(shell.queue_free)


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
	last_anim_request = clip
	last_anim = _clip_name(clip) if played else ""
	match clip:
		"fire", "fire2":
			_kick = 0.3 if played else 1.0
			if clip == "fire" and str(Sheets.weapon_row(_weapon).get("category", "")) not in ["knife", "grenade", "equipment"]:
				_fire_fx()
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
