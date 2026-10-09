extends Node3D
## Visual + skeleton + hitboxes of a machine. Real content: hzd/machines/<id>/model.glb (real skeleton) and
## meta.json (bones, weak_spots [{part, bone}], height_m, leg_chains). Without a model (mock data) a placeholder
## skeleton is built in code with the same structure (leg chains, head, eye) so the same procedural animation runs.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const Animator := preload("res://machines/machine_animator.gd")

const LAYER_HITBOX := 8
const EYE_COLORS := {"calm": Color(0.25, 0.65, 1.0), "suspicious": Color(1.0, 0.8, 0.15), "alert": Color(1.0, 0.15, 0.1)}

var machine: Node3D
var machine_type := ""
var skeleton: Skeleton3D
var animator: Node
var hitboxes: Array = []
var body_height := 2.4
var body_radius := 0.6
var eye_bone := -1
var head_bone := -1
var leg_chains: Array = []      # Array of PackedInt32Array (hip..foot)
var is_placeholder := true
var _eye_mats: Array = []
var _flash := 0.0


func build(m: Node3D, type: String, meta: Dictionary) -> void:
	machine = m
	machine_type = type
	body_height = float(meta.get("height_m", Sheets.machine_num(type, "body_height_m", 2.4)))
	var model_path := Game.cache_root.path_join("hzd/machines/%s/model.glb" % type)
	if not meta.get("mock", false) and FileAccess.file_exists(model_path) and _build_from_glb(model_path, meta):
		is_placeholder = false
	else:
		_build_placeholder(type)
	animator = Animator.new()
	animator.name = "Animator"
	animator.rig = self
	skeleton.add_child(animator)
	set_eye_mood("calm")


# ------------------------------------------------------------------ real model

func _build_from_glb(path: String, meta: Dictionary) -> bool:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		Log.warn("machine model failed to load: %s" % path)
		return false
	var scene := doc.generate_scene(state)
	if scene == null:
		return false
	var sk := _find_skeleton(scene)
	if sk == null:
		Log.warn("machine model has no skeleton: %s" % path)
		scene.free()
		return false
	add_child(scene)
	skeleton = sk
	# leg chains from meta (names) -> bone indices
	for chain in meta.get("leg_chains", []):
		var ids := PackedInt32Array()
		var names: Array = chain if chain is Array else str(chain).split(",")
		for n in names:
			var b := skeleton.find_bone(str(n).strip_edges())
			if b >= 0:
				ids.append(b)
		if ids.size() >= 3:
			leg_chains.append(ids)
	head_bone = _find_bone_like(["head"])
	eye_bone = _find_bone_like(["eye"])
	var aabb := _skeleton_aabb()
	body_radius = maxf(aabb.size.x, aabb.size.z) * 0.25
	if body_height <= 0.1:
		body_height = aabb.size.y
	# hitboxes: torso box from the skeleton bounds, weak spots at their bones
	var torso := BoxShape3D.new()
	torso.size = Vector3(maxf(aabb.size.x * 0.5, 0.5), maxf(body_height * 0.35, 0.5), maxf(aabb.size.z * 0.5, 0.6))
	_add_hitbox_static("body", false, torso, Vector3(0, body_height * 0.6, 0))
	for ws in meta.get("weak_spots", []):
		var bone := skeleton.find_bone(str(ws.get("bone", "")))
		var sph := SphereShape3D.new()
		sph.radius = float(ws.get("radius", 0.25))
		if bone >= 0:
			_add_hitbox_bone(str(ws.get("part", "weak")), true, sph, bone, Vector3.ZERO)
	Log.info("machine %s: real model, %d bones, %d leg chains, height %.2f m" % [machine_type, skeleton.get_bone_count(), leg_chains.size(), body_height])
	return true


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


func _find_bone_like(keys: Array) -> int:
	for i in skeleton.get_bone_count():
		var n := skeleton.get_bone_name(i).to_lower()
		for k in keys:
			if n.contains(k):
				return i
	return -1


func _skeleton_aabb() -> AABB:
	var aabb := AABB()
	for i in skeleton.get_bone_count():
		var p := skeleton.get_bone_global_rest(i).origin
		aabb = AABB(p, Vector3.ZERO) if i == 0 else aabb.expand(p)
	return aabb


# ------------------------------------------------------------------ placeholder

func _build_placeholder(type: String) -> void:
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.55, 0.55, 0.58) if type == "watcher" else (Color(0.5, 0.42, 0.33) if type == "grazer" else Color(0.42, 0.45, 0.5))
	metal.metallic = 0.6
	metal.roughness = 0.45
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.15, 0.17)
	dark.metallic = 0.3
	var h := body_height
	if type == "watcher":
		var hip_h := h * 0.55
		var root := _bone("root", -1, Vector3.ZERO)
		var pelvis := _bone("pelvis", root, Vector3(0, hip_h, 0))
		var spine := _bone("spine", pelvis, Vector3(0, h * 0.08, -h * 0.12))
		var neck := _bone("neck", spine, Vector3(0, h * 0.12, -h * 0.15))
		head_bone = _bone("head", neck, Vector3(0, h * 0.1, -h * 0.1))
		eye_bone = _bone("eye", head_bone, Vector3(0, 0.02, -h * 0.16))
		var t1 := _bone("tail1", pelvis, Vector3(0, 0.05, h * 0.22))
		var t2 := _bone("tail2", t1, Vector3(0, -0.05, h * 0.25))
		_part(pelvis, "box", Vector3(h * 0.22, h * 0.2, h * 0.36), Vector3(0, 0.05, -0.05), metal)
		_part(spine, "box", Vector3(h * 0.2, h * 0.18, h * 0.22), Vector3(0, 0.05, -0.1), metal)
		_part(neck, "box", Vector3(h * 0.08, h * 0.16, h * 0.08), Vector3(0, 0.06, -0.05), dark)
		_part(head_bone, "box", Vector3(h * 0.16, h * 0.13, h * 0.22), Vector3(0, 0, -0.05), metal)
		_part(t1, "box", Vector3(h * 0.06, h * 0.06, h * 0.25), Vector3(0, 0, h * 0.12), dark)
		_part(t2, "box", Vector3(h * 0.04, h * 0.04, h * 0.25), Vector3(0, 0, h * 0.12), dark)
		_eye(eye_bone, h * 0.06)
		for side in [-1.0, 1.0]:
			var sname: String = "l" if side < 0 else "r"
			var thigh := _bone(sname + "_thigh", pelvis, Vector3(side * h * 0.11, -0.05, 0))
			var shin := _bone(sname + "_shin", thigh, Vector3(0, -hip_h * 0.48, -h * 0.1))
			var ankle := _bone(sname + "_ankle", shin, Vector3(0, -hip_h * 0.47, h * 0.12))
			var toe := _bone(sname + "_toe", ankle, Vector3(0, -hip_h * 0.05, -h * 0.1))
			_limb(thigh, shin, h * 0.07, metal)
			_limb(shin, ankle, h * 0.05, dark)
			_limb(ankle, toe, h * 0.05, dark)
			leg_chains.append(PackedInt32Array([thigh, shin, ankle, toe]))
		_add_hitbox_bone("body", false, _box(Vector3(h * 0.24, h * 0.22, h * 0.5)), pelvis, Vector3(0, 0.05, -0.1))
		_add_hitbox_bone("head", false, _box(Vector3(h * 0.17, h * 0.14, h * 0.18)), head_bone, Vector3(0, 0, 0.0))
		var eye_s := SphereShape3D.new()
		eye_s.radius = maxf(h * 0.07, 0.16)
		_add_hitbox_bone("eye", true, eye_s, eye_bone, Vector3(0, 0, -0.03))
		body_radius = h * 0.2
	else:
		var hip_h := h * 0.6
		var body_len := h * (0.75 if type == "strider" else 0.7)
		var root := _bone("root", -1, Vector3.ZERO)
		var pelvis := _bone("pelvis", root, Vector3(0, hip_h, body_len * 0.45))
		var spine := _bone("spine", pelvis, Vector3(0, 0.05, -body_len * 0.45))
		var chest := _bone("chest", spine, Vector3(0, 0.05, -body_len * 0.45))
		var neck := _bone("neck", chest, Vector3(0, h * 0.15, -h * 0.12))
		head_bone = _bone("head", neck, Vector3(0, h * 0.14, -h * 0.12))
		eye_bone = _bone("eye", head_bone, Vector3(0, 0.03, -h * 0.14))
		var can := _bone("canister", spine, Vector3(0, h * 0.13, 0))
		_part(pelvis, "box", Vector3(h * 0.26, h * 0.22, body_len * 0.5), Vector3(0, 0, -body_len * 0.1), metal)
		_part(spine, "box", Vector3(h * 0.24, h * 0.2, body_len * 0.5), Vector3(0, 0, -body_len * 0.2), metal)
		_part(chest, "box", Vector3(h * 0.26, h * 0.24, body_len * 0.35), Vector3(0, 0, 0), metal)
		_part(neck, "box", Vector3(h * 0.08, h * 0.2, h * 0.08), Vector3(0, 0.05, -0.04), dark)
		_part(head_bone, "box", Vector3(h * 0.1, h * 0.1, h * 0.24), Vector3(0, 0, -0.07), metal)
		_eye(eye_bone, h * 0.04)
		var canister_mat := StandardMaterial3D.new()
		canister_mat.albedo_color = Color(0.9, 0.55, 0.1)
		canister_mat.emission_enabled = true
		canister_mat.emission = Color(0.6, 0.3, 0.05)
		_part(can, "cyl", Vector3(h * 0.07, h * 0.18, h * 0.07), Vector3.ZERO, canister_mat, Vector3(PI * 0.5, 0, 0))
		var bones := {"front": chest, "hind": pelvis}
		for end in ["front", "hind"]:
			for side in [-1.0, 1.0]:
				var sname: String = ("l" if side < 0 else "r") + "_" + end
				var bend: float = -1.0 if end == "front" else 1.0
				var thigh := _bone(sname + "_thigh", bones[end], Vector3(side * h * 0.12, -0.05, 0))
				var shin := _bone(sname + "_shin", thigh, Vector3(0, -hip_h * 0.48, bend * h * 0.06))
				var foot := _bone(sname + "_foot", shin, Vector3(0, -hip_h * 0.5, -bend * h * 0.06))
				_limb(thigh, shin, h * 0.06, metal)
				_limb(shin, foot, h * 0.045, dark)
				leg_chains.append(PackedInt32Array([thigh, shin, foot]))
		_add_hitbox_bone("body", false, _box(Vector3(h * 0.3, h * 0.26, body_len * 1.1)), spine, Vector3(0, 0, -body_len * 0.05))
		_add_hitbox_bone("head", false, _box(Vector3(h * 0.12, h * 0.12, h * 0.26)), head_bone, Vector3(0, 0, -0.07))
		var parts: Variant = Sheets.machine(type, "weak_spot_parts")
		if not parts is Array:
			parts = ["blaze_canister"]
		for part in parts:
			var cs := SphereShape3D.new()
			cs.radius = maxf(h * 0.1, 0.22)
			_add_hitbox_bone(str(part), true, cs, can, Vector3(0, h * 0.04, 0))
		body_radius = h * 0.22


func _bone(bname: String, parent: int, offset: Vector3) -> int:
	var i := skeleton.get_bone_count()
	skeleton.add_bone(bname)
	if parent >= 0:
		skeleton.set_bone_parent(i, parent)
	skeleton.set_bone_rest(i, Transform3D(Basis(), offset))
	skeleton.set_bone_pose_position(i, offset)
	return i


func _attach(bone: int) -> BoneAttachment3D:
	var ba := BoneAttachment3D.new()
	ba.name = "BA_" + skeleton.get_bone_name(bone)
	skeleton.add_child(ba)
	ba.bone_idx = bone
	return ba


func _part(bone: int, kind: String, size: Vector3, offset: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	if kind == "box":
		var b := BoxMesh.new()
		b.size = size
		mi.mesh = b
	else:
		var c := CylinderMesh.new()
		c.top_radius = size.x
		c.bottom_radius = size.x
		c.height = size.y
		mi.mesh = c
	mi.material_override = mat
	mi.position = offset
	mi.rotation = rot
	_attach(bone).add_child(mi)


func _limb(a: int, b: int, thick: float, mat: Material) -> void:
	var off := skeleton.get_bone_rest(b).origin
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(thick, off.length(), thick)
	mi.mesh = box
	mi.material_override = mat
	mi.position = off * 0.5
	if off.length() > 0.001:
		mi.basis = Basis(Quaternion(Vector3.UP, off.normalized()))
	_attach(a).add_child(mi)


func _eye(bone: int, r: float) -> void:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	mi.mesh = s
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	mi.material_override = m
	_eye_mats.append(m)
	_attach(bone).add_child(mi)


func _box(size: Vector3) -> BoxShape3D:
	var b := BoxShape3D.new()
	b.size = size
	return b


func _make_hitbox(part: String, weak: bool, shape: Shape3D) -> Area3D:
	var a := Area3D.new()
	a.name = "Hit_" + part
	a.collision_layer = LAYER_HITBOX
	a.collision_mask = 0
	a.monitoring = false
	a.monitorable = true
	a.set_meta("part", part)
	a.set_meta("weak", weak)
	a.set_meta("machine", machine)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	a.add_child(cs)
	hitboxes.append(a)
	return a


func _add_hitbox_bone(part: String, weak: bool, shape: Shape3D, bone: int, offset: Vector3) -> void:
	var a := _make_hitbox(part, weak, shape)
	a.position = offset
	_attach(bone).add_child(a)


func _add_hitbox_static(part: String, weak: bool, shape: Shape3D, offset: Vector3) -> void:
	var a := _make_hitbox(part, weak, shape)
	a.position = offset
	add_child(a)


# ------------------------------------------------------------------ runtime

func eye_global() -> Vector3:
	if eye_bone >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(eye_bone).origin
	if head_bone >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(head_bone).origin
	return global_position + Vector3(0, body_height * 0.8, 0)


func set_eye_mood(mood: String) -> void:
	var c: Color = EYE_COLORS.get(mood, EYE_COLORS["calm"])
	for m in _eye_mats:
		(m as StandardMaterial3D).albedo_color = c
		(m as StandardMaterial3D).emission = c
		(m as StandardMaterial3D).emission_energy_multiplier = 2.5


func on_state(s: String) -> void:
	match s:
		"suspicious":
			set_eye_mood("suspicious")
		"alert", "attack", "flee":
			set_eye_mood("alert")
		"dead":
			set_eye_mood("calm")
			for m in _eye_mats:
				(m as StandardMaterial3D).emission_energy_multiplier = 0.0
		_:
			set_eye_mood("calm")
	if animator:
		animator.on_state(s)


func play_pose(pose: String, duration: float) -> void:
	if animator:
		animator.play_pose(pose, duration)


func flinch(weak: bool) -> void:
	if animator:
		animator.flinch(1.0 if weak else 0.5)
