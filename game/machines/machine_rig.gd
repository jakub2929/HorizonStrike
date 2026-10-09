extends Node3D
## Visual + skeleton + hitboxes of a machine. Real content: hzd/machines/<id>/model.glb (real skeleton) and
## meta.json (bones, weak_spots [{part, bone}], height_m, leg_chains). Without a model (mock data) a placeholder
## skeleton is built in code with the same structure (leg chains, head, eye) so the same procedural animation runs.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const Animator := preload("res://machines/machine_animator.gd")

const LAYER_HITBOX := 8
const LAYER_WEAK := 16
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
var _eye_light: OmniLight3D
var _eye_attach: Node3D        ## follows the animated eye bone (bone poses read in _process are the unmodified ones)


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

## Per machine type: the glb scene packed once, and per-bone hitbox boxes from the skinned vertices.
static var _scene_cache := {}     # type -> PackedScene
static var _box_cache := {}       # type -> Array of [bone_name, AABB in bone rest space, vertex count]

var helper_bones := {}            # bone index -> true (meta helper bones: never animated)


func _build_from_glb(path: String, meta: Dictionary) -> bool:
	var scene: Node = null
	if _scene_cache.has(machine_type):
		scene = (_scene_cache[machine_type] as PackedScene).instantiate()
	else:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) != OK:
			Log.warn("machine model failed to load: %s" % path)
			return false
		scene = doc.generate_scene(state)
		if scene == null:
			return false
		_own_all(scene, scene)
		var ps := PackedScene.new()
		if ps.pack(scene) == OK:
			_scene_cache[machine_type] = ps
	var sk := _find_skeleton(scene)
	if sk == null:
		Log.warn("machine model has no skeleton: %s" % path)
		scene.free()
		return false
	add_child(scene)
	skeleton = sk
	for b in meta.get("bones", []):
		if b.get("helper", false):
			var bi := skeleton.find_bone(str(b.get("name", "")))
			if bi >= 0:
				helper_bones[bi] = true
	# leg chains from meta (names) -> bone indices
	for chain in meta.get("leg_chains", []):
		var ids := PackedInt32Array()
		var names: Array = chain if chain is Array else Array(str(chain).split(","))
		for n in names:
			var b := skeleton.find_bone(str(n).strip_edges())
			if b >= 0:
				ids.append(b)
		if ids.size() >= 3:
			leg_chains.append(ids)
	var weak_bones := {}
	for ws in meta.get("weak_spots", []):
		var wb := skeleton.find_bone(str(ws.get("bone", "")))
		if wb >= 0:
			weak_bones[wb] = str(ws.get("part", "weak"))
	# head: an exact head joint, else the parent of the eye, else a non-helper bone named like a head
	for cand in ["headJoint", "Head", "head", "Head_Bone", "Cam_Bone"]:
		if head_bone < 0:
			head_bone = skeleton.find_bone(cand)
	for wb in weak_bones:
		if eye_bone < 0 and str(weak_bones[wb]) == "eye":
			eye_bone = wb
	if eye_bone < 0:
		for cand2 in ["eye_helper", "Eye_helper", "Eye_Lx_helper", "eyeJoint"]:
			if eye_bone < 0:
				eye_bone = skeleton.find_bone(cand2)
	if head_bone < 0 and eye_bone >= 0:
		head_bone = skeleton.get_bone_parent(eye_bone)
	if head_bone < 0:
		for i in skeleton.get_bone_count():
			if head_bone < 0 and not helper_bones.has(i) and skeleton.get_bone_name(i).to_lower().contains("head"):
				head_bone = i
	var aabb := _skeleton_aabb()
	body_radius = clampf(aabb.size.x * 0.6, 0.35, 0.9)
	if body_height <= 0.1:
		body_height = aabb.size.y
	_build_hitboxes(scene, weak_bones)
	_add_eye_glow()
	Log.info("machine %s: real model, %d bones, %d leg chains, head %s, eye %s, %d hitboxes, height %.2f m" % [machine_type,
		skeleton.get_bone_count(), leg_chains.size(), skeleton.get_bone_name(head_bone) if head_bone >= 0 else "-",
		skeleton.get_bone_name(eye_bone) if eye_bone >= 0 else "-", hitboxes.size(), body_height])
	return true


func _own_all(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_own_all(c, owner_node)


## Hitboxes: one box per bone that dominates enough skinned vertices (tight fit in the bone's rest space); weak-spot
## bones get spheres on the weak layer (their own vertex box when they have one, else a sphere sized to the machine).
func _build_hitboxes(scene: Node, weak_bones: Dictionary) -> void:
	if not _box_cache.has(machine_type):
		_box_cache[machine_type] = _compute_bone_boxes(scene)
	var boxes: Array = _box_cache[machine_type]
	var weak_done := {}
	for e in boxes:
		var b := skeleton.find_bone(str(e[0]))
		if b < 0:
			continue
		var bb: AABB = e[1]
		if weak_bones.has(b):
			var sph := SphereShape3D.new()
			sph.radius = maxf(bb.size[bb.get_longest_axis_index()] * 0.5, 0.12)
			_add_hitbox_bone(str(weak_bones[b]), true, sph, b, bb.get_center())
			weak_done[b] = true
			continue
		if int(e[2]) < 24 or bb.size.length() < 0.08:
			continue
		var box := BoxShape3D.new()
		box.size = (bb.size * 0.92).max(Vector3(0.05, 0.05, 0.05))
		_add_hitbox_bone("body", false, box, b, bb.get_center())
	var h := maxf(body_height, 1.0)
	for b in weak_bones:
		if weak_done.has(b):
			continue
		var sph2 := SphereShape3D.new()
		sph2.radius = clampf(h * 0.08, 0.15, 0.35)
		_add_hitbox_bone(str(weak_bones[b]), true, sph2, b, Vector3.ZERO)


func _compute_bone_boxes(scene: Node) -> Array:
	var per_bone := {}    # bone index -> [AABB, count]
	var t0 := Time.get_ticks_msec()
	var sk_inv := skeleton.global_transform.affine_inverse()
	var rest_inv := {}
	for mi in _mesh_instances(scene):
		var mesh_i: MeshInstance3D = mi
		if mesh_i.skin == null or mesh_i.mesh == null:
			continue
		var skin := mesh_i.skin
		var bind_to_bone := PackedInt32Array()
		for i in skin.get_bind_count():
			var bb := skin.get_bind_bone(i)
			if bb < 0:
				bb = skeleton.find_bone(String(skin.get_bind_name(i)))
			bind_to_bone.append(bb)
		var to_sk := sk_inv * mesh_i.global_transform
		for s in mesh_i.mesh.get_surface_count():
			var arr := mesh_i.mesh.surface_get_arrays(s)
			if arr[Mesh.ARRAY_BONES] == null or arr[Mesh.ARRAY_WEIGHTS] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array = arr[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
			var per := weights.size() / maxi(verts.size(), 1)
			for v in verts.size():
				var best := 0
				var bw := -1.0
				for k in per:
					var w := weights[v * per + k]
					if w > bw:
						bw = w
						best = bones[v * per + k]
				if best < 0 or best >= bind_to_bone.size():
					continue
				var bone := bind_to_bone[best]
				if bone < 0:
					continue
				if not rest_inv.has(bone):
					rest_inv[bone] = skeleton.get_bone_global_rest(bone).affine_inverse()
				var lp: Vector3 = (rest_inv[bone] as Transform3D) * (to_sk * verts[v])
				if per_bone.has(bone):
					var e: Array = per_bone[bone]
					e[0] = (e[0] as AABB).expand(lp)
					e[1] = int(e[1]) + 1
				else:
					per_bone[bone] = [AABB(lp, Vector3.ZERO), 1]
	var out: Array = []
	for b in per_bone:
		out.append([skeleton.get_bone_name(b), per_bone[b][0], per_bone[b][1]])
	Log.info("machine %s: hitbox boxes for %d bones in %d ms" % [machine_type, out.size(), Time.get_ticks_msec() - t0])
	return out


func _mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_mesh_instances(c))
	return out


func _add_eye_glow() -> void:
	if eye_bone < 0:
		return
	var ba := _attach(eye_bone)
	_eye_attach = ba
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = clampf(body_height * 0.025, 0.03, 0.08)
	sm.height = sm.radius * 2.0
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	mi.material_override = m
	_eye_mats.append(m)
	ba.add_child(mi)
	_eye_light = OmniLight3D.new()
	_eye_light.omni_range = 3.0
	_eye_light.light_energy = 1.5
	ba.add_child(_eye_light)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s:
			return s
	return null


func _skeleton_aabb() -> AABB:
	var aabb := AABB()
	var first := true
	for i in skeleton.get_bone_count():
		if helper_bones.has(i):
			continue
		var p := skeleton.get_bone_global_rest(i).origin
		aabb = AABB(p, Vector3.ZERO) if first else aabb.expand(p)
		first = false
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
	var ba := _attach(bone)
	_eye_attach = ba
	ba.add_child(mi)


func _box(size: Vector3) -> BoxShape3D:
	var b := BoxShape3D.new()
	b.size = size
	return b


func _make_hitbox(part: String, weak: bool, shape: Shape3D) -> Area3D:
	var a := Area3D.new()
	a.name = "Hit_" + part
	a.collision_layer = LAYER_WEAK if weak else LAYER_HITBOX
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
	if _eye_attach:
		return _eye_attach.global_position
	if eye_bone >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(eye_bone).origin
	if head_bone >= 0:
		return skeleton.global_transform * skeleton.get_bone_global_pose(head_bone).origin
	return global_position + Vector3(0, body_height * 0.8, 0)


func set_eye_mood(mood: String) -> void:
	var c: Color = EYE_COLORS.get(mood, EYE_COLORS["calm"])
	if _eye_light:
		_eye_light.light_color = c
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
