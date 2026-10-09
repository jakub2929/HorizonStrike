extends Node3D
## Visual + skeleton + hitboxes of a machine. Real content: hzd/machines/<id>/model.glb (real skeleton) and
## meta.json (bones, weak_spots [{part, bone}], height_m, leg_chains). Without a model (mock data) a placeholder
## skeleton is built in code with the same structure (leg chains, head, eye) so the same procedural animation runs.

const Log := preload("res://core/log.gd")
const Sheets := preload("res://core/sheets.gd")
const Animator := preload("res://machines/machine_animator.gd")
const Content := preload("res://core/content.gd")

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
var roles := {}                 # role -> bone index (content contract bone_roles)
var points := {}                # point name -> {bone: int, offset: Vector3, radius: float, kind, part}
var is_placeholder := true
var _eye_mats: Array = []
var _eye_light: OmniLight3D
var _eye_attach: Node3D        ## follows the animated eye bone (bone poses read in _process are the unmodified ones)


func build(m: Node3D, type: String, meta: Dictionary) -> void:
	machine = m
	machine_type = type
	body_height = float(meta.get("height_m", Sheets.machine_num(type, "body_height_m", 2.4)))
	var model_path := Content.machine_model(type)
	if not meta.get("mock", false) and model_path != "" and _build_from_glb(model_path, meta):
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
	# content contract: roles, points and leg chains (role names or bone names) -> bone indices
	var role_names := Content.machine_bone_roles(machine_type)
	for r in role_names:
		var rb := skeleton.find_bone(str(role_names[r]))
		if rb >= 0:
			roles[str(r)] = rb
	for chain in Content.machine_leg_chains(machine_type):
		var ids := PackedInt32Array()
		var names: Array = chain if chain is Array else Array(str(chain).split(">" if str(chain).contains(">") else ","))
		for n in names:
			var key := str(n).strip_edges()
			var b: int = roles.get(key, skeleton.find_bone(key))
			if b >= 0:
				ids.append(b)
		if ids.size() >= 3:
			leg_chains.append(ids)
	var pts := Content.machine_points(machine_type)
	for pn in pts:
		var parts := Content.point_parts(pts[pn])
		var pb: int = roles.get(parts[0], skeleton.find_bone(parts[0]))
		if pb >= 0:
			points[str(pn)] = {"bone": pb, "offset": parts[1], "radius": parts[2], "kind": str(pts[pn].get("kind", "")),
				"part": str(pts[pn].get("part", pn))}
	head_bone = int(roles.get("head", -1))
	var sense := _sense_point()
	eye_bone = int(sense["bone"]) if not sense.is_empty() else int(roles.get("eye", head_bone))
	var weak_bones := {}
	for pn in points:
		if points[pn]["kind"] == "weak_spot":
			weak_bones[points[pn]["bone"]] = points[pn]
	var aabb := _skeleton_aabb()
	body_radius = clampf(aabb.size.x * 0.6, 0.35, 0.9)
	if body_height <= 0.1:
		body_height = aabb.size.y
	_build_hitboxes(scene, weak_bones)
	_add_eye_glow()
	Log.info("machine %s: real model, %d bones, %d leg chains, head %s, eye %s, %d hitboxes, height %.2f m" % [machine_type,
		skeleton.get_bone_count(), leg_chains.size(), "role" if head_bone >= 0 else "-",
		"point" if not _sense_point().is_empty() else "-", hitboxes.size(), body_height])
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
	var spheres: Array = []   # [bone, centre in skeleton rest space, part] of every weak spot
	for e in boxes:
		var b := skeleton.find_bone(str(e[0]))
		if b < 0:
			continue
		var bb: AABB = e[1]
		if weak_bones.has(b):
			var wp: Dictionary = weak_bones[b]
			var sph := SphereShape3D.new()
			sph.radius = float(wp["radius"]) if float(wp["radius"]) > 0.0 else maxf(bb.size[bb.get_longest_axis_index()] * 0.5, 0.12)
			var off: Vector3 = wp["offset"] if (wp["offset"] as Vector3).length() > 0.0 else bb.get_center()
			_add_hitbox_bone(str(wp["part"]), true, sph, b, off)
			spheres.append([b, skeleton.get_bone_global_rest(b) * off, str(wp["part"])])
			weak_done[b] = true
	var h := maxf(body_height, 1.0)
	for b in weak_bones:
		if weak_done.has(b):
			continue
		var wp2: Dictionary = weak_bones[b]
		var sph2 := SphereShape3D.new()
		sph2.radius = float(wp2["radius"]) if float(wp2["radius"]) > 0.0 else clampf(h * 0.08, 0.15, 0.35)
		_add_hitbox_bone(str(wp2["part"]), true, sph2, b, wp2["offset"])
		spheres.append([b, skeleton.get_bone_global_rest(b) * (wp2["offset"] as Vector3), str(wp2["part"])])
	for e in boxes:
		var b := skeleton.find_bone(str(e[0]))
		if b < 0 or weak_bones.has(b):
			continue
		var bb: AABB = e[1]
		if int(e[2]) < 24 or bb.size.length() < 0.08:
			continue
		var sz := (bb.size * 0.92).max(Vector3(0.05, 0.05, 0.05))
		var aabb := AABB(bb.get_center() - sz * 0.5, sz)
		# the skinned geometry of a weak spot often hangs on the PARENT of the weak-spot bone (Grazer: the canister
		# mesh on its own bone, the content's weak point on a helper child of it); that box is the weak part itself,
		# not body - as body it enclosed the weak sphere and every shot at the canister counted as a body hit
		var part := _weak_part_of_geometry(b, aabb, spheres)
		var box := BoxShape3D.new()
		box.size = aabb.size
		_add_hitbox_bone(part if part != "" else "body", part != "", box, b, aabb.get_center())


## Part name when bone `bone` carries only weak-spot bones as children (the weak part's own geometry bone) and the
## weak-spot centre lies inside its `box` (bone rest space). A trunk bone with other children (legs, plates) stays body.
func _weak_part_of_geometry(bone: int, box: AABB, spheres: Array) -> String:
	var weak_children := {}
	for sp in spheres:
		if skeleton.get_bone_parent(int(sp[0])) == bone:
			weak_children[int(sp[0])] = sp
	if weak_children.is_empty():
		return ""
	for c in skeleton.get_bone_children(bone):
		if not weak_children.has(c):
			return ""
	var inv := skeleton.get_bone_global_rest(bone).affine_inverse()
	for c in weak_children:
		var sp: Array = weak_children[c]
		if box.grow(0.02).has_point(inv * (sp[1] as Vector3)):
			return str(sp[2])
	return ""


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


## The machine's sensing point (point kind "sense" or named "eye"), else {}.
func _sense_point() -> Dictionary:
	for pn in points:
		if points[pn]["kind"] == "sense":
			return points[pn]
	return points.get("eye", {})


func _add_eye_glow() -> void:
	if eye_bone < 0:
		return
	var ba: Node3D = _attach(eye_bone)
	var sp := _sense_point()
	if not sp.is_empty():
		var holder := Node3D.new()
		holder.position = sp["offset"]
		ba.add_child(holder)
		ba = holder
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
	_eye_attach = ba


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
		roles = {"root": root, "spine": spine, "neck": neck, "head": head_bone, "tail": t1}
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
		roles = {"root": root, "spine": spine, "neck": neck, "head": head_bone}
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

## Bounds (machine space) of the trunk: the body hitboxes that are not on leg chains or the tail.
func trunk_bounds() -> AABB:
	var skip := {}
	for ch in leg_chains:
		for b in ch:
			skip[b] = true
	if animator:
		for b in animator.tail_chain():
			skip[b] = true
	var to_machine := global_transform.affine_inverse()
	var aabb := AABB()
	var first := true
	for h in hitboxes:
		var a := h as Area3D
		if a.get_meta("weak", false):
			continue
		var ba := a.get_parent() as BoneAttachment3D
		if ba and skip.has(ba.bone_idx):
			continue
		var p := to_machine * a.global_position
		aabb = AABB(p, Vector3.ZERO) if first else aabb.expand(p)
		first = false
	return aabb.grow(0.2)


## World position of a named point (follows the animation), or `fallback` when the point does not exist.
func point_global(point_name: String, fallback: Vector3) -> Vector3:
	if not points.has(point_name):
		return fallback
	var pt: Dictionary = points[point_name]
	if not pt.has("_node"):
		var n := Node3D.new()
		n.position = pt["offset"]
		_attach(int(pt["bone"])).add_child(n)
		pt["_node"] = n
	return (pt["_node"] as Node3D).global_position


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
		(m as StandardMaterial3D).emission_energy_multiplier = 4.0


## Horizon-style awareness marker above the machine: yellow "?" suspicious, red "!" alert/attack/flee.
var _marker: Label3D


func _set_marker(text: String, color: Color) -> void:
	if _marker == null:
		_marker = Label3D.new()
		_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_marker.no_depth_test = true
		_marker.fixed_size = true
		_marker.pixel_size = 0.0012
		_marker.font_size = 48
		_marker.outline_size = 12
		_marker.outline_modulate = Color(0, 0, 0, 0.8)
		_marker.position = Vector3(0, body_height + 0.5, 0)
		add_child(_marker)
	_marker.text = text
	_marker.modulate = color
	_marker.visible = text != ""


func on_state(s: String) -> void:
	match s:
		"suspicious":
			_set_marker("?", Color(1.0, 0.82, 0.2))
		"alert", "attack", "flee":
			_set_marker("!", Color(1.0, 0.2, 0.15))
		_:
			_set_marker("", Color.WHITE)
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


## Scavenger radar ping: an expanding ring from the radar part (point whose part/name is "radar", else the eye).
func radar_pulse(radius: float) -> void:
	var from := eye_global()
	for pn in points:
		if str(points[pn].get("part", "")).contains("radar") or str(pn).contains("radar"):
			from = point_global(str(pn), from)
			break
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.92
	tm.outer_radius = 1.0
	tm.rings = 48
	ring.mesh = tm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.35, 0.2, 0.7)
	mat.no_depth_test = true
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var parent := machine.get_parent() if machine and machine.get_parent() else self
	parent.add_child(ring)
	ring.global_position = from
	ring.scale = Vector3.ONE * 0.3
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * maxf(radius, 1.0), 0.9)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.9)
	tw.chain().tween_callback(ring.queue_free)


## Attack pose with the machine_attacks row timing (pose, windup_s, active_s).
func play_attack(a: Dictionary) -> void:
	if animator:
		animator.play_attack(str(a.get("pose", "")), float(a.get("windup_s", 0.4)), float(a.get("active_s", 0.2)))


func flinch(weak: bool) -> void:
	if animator:
		animator.flinch(1.0 if weak else 0.5)
