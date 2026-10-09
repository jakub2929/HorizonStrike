extends SkeletonModifier3D
## Procedural machine motion on the machine's own skeleton (real HZD skeleton or the placeholder):
## gait with per-leg phases and planted feet, analytic two-bone IK per leg chain (hip, knee, ankle[, toe]),
## body bob/lean, head look-at, grazing, attack poses, flinch and death collapse. Works in skeleton space and only
## uses bone rests, so it does not depend on the bones' axis conventions.

var rig: Node3D

var _legs: Array = []          # [{chain, offset, planted, from, to, swing, swing_t}]
var _phase := 0.0
var _body_bone := -1
var _spine_bones: PackedInt32Array = PackedInt32Array()
var _neck_bones: PackedInt32Array = PackedInt32Array()
var _tail_bones: PackedInt32Array = PackedInt32Array()
var _state := "idle"
var _pose := ""
var _pose_t := 0.0
var _pose_dur := 0.0
var _flinch := 0.0
var _dead_t := 0.0
var _graze := 0.0
var _graze_timer := 0.0
var _look := Vector3.ZERO
var _look_w := 0.0
var _stride := 1.6
var _step_h := 0.35
var _gait := "biped"
var _initialized := false


func on_state(s: String) -> void:
	_state = s
	if s == "dead":
		_dead_t = 0.0


func play_pose(pose: String, duration: float) -> void:
	_pose = pose
	_pose_t = 0.0
	_pose_dur = maxf(duration, 0.1)


func flinch(amount: float) -> void:
	_flinch = maxf(_flinch, amount)


func _init_legs(sk: Skeleton3D) -> void:
	_initialized = true
	var Sheets := preload("res://core/sheets.gd")
	_stride = Sheets.machine_num(rig.machine_type, "stride_m", 1.6)
	_step_h = Sheets.machine_num(rig.machine_type, "step_height_m", 0.35)
	_gait = str(Sheets.machine(rig.machine_type, "gait"))
	var n: int = rig.leg_chains.size()
	# biped: alternate; quadruped walk: LH 0, LF 0.25, RH 0.5, RF 0.75 (lateral sequence)
	for i in n:
		var chain: PackedInt32Array = rig.leg_chains[i]
		var off := 0.5 * i
		if n == 4:
			off = [0.25, 0.75, 0.0, 0.5][i]
		var foot_world := _rest_foot_world(sk, chain)
		_legs.append({"chain": chain, "offset": fmod(off, 1.0), "planted": foot_world, "from": foot_world,
			"to": foot_world, "swing": false, "swing_t": 0.0})
	# body bone = common parent of the leg roots
	if n > 0:
		var roots := []
		for l in _legs:
			roots.append(sk.get_bone_parent((l["chain"] as PackedInt32Array)[0]))
		_body_bone = roots[0]
		while _body_bone >= 0 and not _is_ancestor_of_all(sk, _body_bone, roots):
			_body_bone = sk.get_bone_parent(_body_bone)
	for i in sk.get_bone_count():
		var nm := sk.get_bone_name(i).to_lower()
		if nm.contains("tail"):
			_tail_bones.append(i)
		elif nm.contains("neck"):
			_neck_bones.append(i)
		elif nm.contains("spine") or nm.contains("chest"):
			_spine_bones.append(i)


func _is_ancestor_of_all(sk: Skeleton3D, b: int, bones: Array) -> bool:
	for x in bones:
		var p: int = x
		var ok := false
		while p >= 0:
			if p == b:
				ok = true
				break
			p = sk.get_bone_parent(p)
		if not ok:
			return false
	return true


func _rest_global(sk: Skeleton3D, b: int) -> Transform3D:
	return sk.get_bone_global_rest(b)


func _rest_foot_world(sk: Skeleton3D, chain: PackedInt32Array) -> Vector3:
	return sk.global_transform * _rest_global(sk, chain[chain.size() - 1]).origin


## Global pose (skeleton space) from the current local poses.
func _global(sk: Skeleton3D, b: int) -> Transform3D:
	var t := sk.get_bone_pose(b)
	var p := sk.get_bone_parent(b)
	while p >= 0:
		t = sk.get_bone_pose(p) * t
		p = sk.get_bone_parent(p)
	return t


func _set_global_basis(sk: Skeleton3D, b: int, basis: Basis) -> void:
	var p := sk.get_bone_parent(b)
	var pb := _global(sk, p).basis if p >= 0 else Basis()
	sk.set_bone_pose_rotation(b, (pb.orthonormalized().inverse() * basis.orthonormalized()).get_rotation_quaternion())


func _rotate_global(sk: Skeleton3D, b: int, q: Quaternion) -> void:
	if b < 0:
		return
	var g := _global(sk, b)
	_set_global_basis(sk, b, Basis(q) * g.basis.orthonormalized())


func _ground(world_pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return world_pos.y
	var q := PhysicsRayQueryParameters3D.create(world_pos + Vector3(0, 2.5, 0), world_pos - Vector3(0, 4.0, 0), 1)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return world_pos.y
	return (hit["position"] as Vector3).y


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or rig == null or rig.machine == null:
		return
	if not _initialized:
		_init_legs(sk)
	for i in sk.get_bone_count():
		sk.set_bone_pose(i, sk.get_bone_rest(i))
	var m: Node3D = rig.machine
	var speed: float = m.speed_now()
	var xf := sk.global_transform
	var inv := xf.affine_inverse()
	var h: float = rig.body_height
	if _state == "dead":
		_dead_t += delta
		var k := clampf(_dead_t / 0.9, 0.0, 1.0)
		k = k * k * (3.0 - 2.0 * k)
		if _body_bone >= 0:
			var bp := sk.get_bone_pose_position(_body_bone)
			sk.set_bone_pose_position(_body_bone, bp + Vector3(0, -h * 0.38 * k, 0))
			_rotate_global(sk, _body_bone, Quaternion(Vector3.FORWARD, deg_to_rad(75.0) * k))
		return
	# ---- gait phase
	var freq := speed / maxf(_stride, 0.2)
	_phase = fmod(_phase + freq * delta, 1.0)
	var swing_frac := 0.38 if _gait == "quadruped" else 0.45
	var vel: Vector3 = m.velocity
	vel.y = 0.0
	# ---- body bob + lean
	var bob := 0.0
	if speed > 0.1:
		bob = -absf(sin(_phase * TAU * (2.0 if _gait == "biped" else 1.0))) * clampf(speed / 6.0, 0.0, 1.0) * h * 0.03
	var lean := clampf(speed / 10.0, 0.0, 1.0) * deg_to_rad(6.0)
	if _body_bone >= 0:
		var bp := sk.get_bone_pose_position(_body_bone)
		sk.set_bone_pose_position(_body_bone, bp + Vector3(0, bob, 0))
	# ---- feet
	for leg in _legs:
		var chain: PackedInt32Array = leg["chain"]
		var rest_world := _rest_foot_world(sk, chain)
		var foot_h := rest_world.y - m.global_position.y
		var home := rest_world + vel * ((1.0 - swing_frac) / maxf(freq, 0.5)) * 0.5
		home.y = _ground(home) + foot_h
		var lp := fmod(_phase + float(leg["offset"]), 1.0)
		var moving := speed > 0.15
		if moving:
			var in_swing := lp < swing_frac
			if in_swing and not leg["swing"]:
				leg["swing"] = true
				leg["from"] = leg["planted"]
				leg["to"] = home
			if in_swing:
				leg["to"] = home
				var s := lp / swing_frac
				var p: Vector3 = (leg["from"] as Vector3).lerp(leg["to"], s)
				p.y += sin(PI * s) * _step_h
				leg["planted_now"] = p
			else:
				if leg["swing"]:
					leg["swing"] = false
					leg["planted"] = leg["to"]
				leg["planted_now"] = leg["planted"]
		else:
			# settle: step back under the body when a foot drifted
			var drift := (leg["planted"] as Vector3).distance_to(home)
			if drift > _stride * 0.25 and not leg["swing"]:
				leg["swing"] = true
				leg["swing_t"] = 0.0
				leg["from"] = leg["planted"]
				leg["to"] = home
			if leg["swing"]:
				leg["swing_t"] = float(leg["swing_t"]) + delta * 3.0
				var s2 := clampf(float(leg["swing_t"]), 0.0, 1.0)
				var p2: Vector3 = (leg["from"] as Vector3).lerp(leg["to"], s2)
				p2.y += sin(PI * s2) * _step_h * 0.6
				leg["planted_now"] = p2
				if s2 >= 1.0:
					leg["swing"] = false
					leg["planted"] = leg["to"]
			else:
				leg["planted_now"] = leg["planted"]
		_solve_leg(sk, chain, inv * (leg["planted_now"] as Vector3))
	# ---- spine lean, grazing, attack poses, flinch
	if lean > 0.0 and _body_bone >= 0:
		_rotate_global(sk, _body_bone, Quaternion((xf.basis.inverse() * m.global_transform.basis.x).normalized(), lean * 0.5))
	_graze_timer -= delta
	var want_graze := 0.0
	if _state == "graze" and speed < 0.2:
		if _graze_timer <= 0.0:
			_graze_timer = randf_range(3.0, 7.0)
			_graze = 1.0 - _graze
		want_graze = _graze
	_look_w = move_toward(_look_w, want_graze, delta * 1.2)
	var right_sk := (xf.basis.inverse() * m.global_transform.basis.x).normalized()
	var up_sk := (xf.basis.inverse() * Vector3.UP).normalized()
	if _look_w > 0.001:
		for b in _neck_bones:
			_rotate_global(sk, b, Quaternion(right_sk, -deg_to_rad(35.0) * _look_w))
	if _pose != "":
		_pose_t += delta
		var e := clampf(_pose_t / _pose_dur, 0.0, 1.0)
		var env := sin(PI * e)
		match _pose:
			"lunge_bite", "ram", "charge":
				for b in _neck_bones:
					_rotate_global(sk, b, Quaternion(right_sk, -deg_to_rad(25.0) * env))
			"tail_sweep":
				for b in _tail_bones:
					_rotate_global(sk, b, Quaternion(up_sk, deg_to_rad(70.0) * sin(TAU * e)))
			"eye_charge":
				for b in _neck_bones:
					_rotate_global(sk, b, Quaternion(right_sk, deg_to_rad(10.0) * env))
			"rear_kick":
				if _body_bone >= 0:
					_rotate_global(sk, _body_bone, Quaternion(right_sk, -deg_to_rad(12.0) * env))
			"rotor_sweep":
				for b in _neck_bones:
					_rotate_global(sk, b, Quaternion(up_sk, deg_to_rad(40.0) * sin(TAU * e)))
		if e >= 1.0:
			_pose = ""
	if _flinch > 0.0:
		for b in _spine_bones:
			_rotate_global(sk, b, Quaternion(right_sk, deg_to_rad(8.0) * _flinch))
		_flinch = maxf(_flinch - delta * 4.0, 0.0)
	# ---- head look-at the player when aware
	var head: int = rig.head_bone
	var p: Node3D = Game.player
	if head >= 0 and p and _state in ["suspicious", "alert", "attack"]:
		var hg := _global(sk, head)
		var target_sk: Vector3 = inv * p.head_position()
		var fwd_sk := (xf.basis.inverse() * -m.global_transform.basis.z).normalized()
		var to := (target_sk - hg.origin).normalized()
		var ang := fwd_sk.angle_to(to)
		if ang > 0.01:
			var axis := fwd_sk.cross(to).normalized()
			var lim := minf(ang, deg_to_rad(55.0))
			_rotate_global(sk, head, Quaternion(axis, lim * 0.7))
			for b in _neck_bones:
				_rotate_global(sk, b, Quaternion(axis, lim * 0.3 / maxf(_neck_bones.size(), 1)))


## Analytic two-bone IK in skeleton space. chain = [hip, knee, ankle(, toe...)]; target is where the last joint goes.
func _solve_leg(sk: Skeleton3D, chain: PackedInt32Array, target_last: Vector3) -> void:
	var hip := chain[0]
	var knee := chain[1]
	var ankle := chain[2]
	var target := target_last
	if chain.size() > 3:
		# keep the ankle->toe offset of the current pose: ankle target = toe target - offset
		var last := chain[chain.size() - 1]
		target = target_last - (_global(sk, last).origin - _global(sk, ankle).origin)
	var gh := _global(sk, hip)
	var gk := _global(sk, knee)
	var ga := _global(sk, ankle)
	var A := gh.origin
	var B := gk.origin
	var C := ga.origin
	var a := A.distance_to(B)
	var b := B.distance_to(C)
	if a < 0.001 or b < 0.001:
		return
	var to_t := target - A
	var dist := clampf(to_t.length(), absf(a - b) + 0.001, (a + b) * 0.999)
	var dir := to_t.normalized() if to_t.length() > 0.0001 else (C - A).normalized()
	var bend := (B - A) - dir * (B - A).dot(dir)
	if bend.length() < 0.0001:
		bend = (C - A).cross(Vector3.RIGHT).cross(dir)
	bend = bend.normalized()
	var cos_a := clampf((a * a + dist * dist - b * b) / (2.0 * a * dist), -1.0, 1.0)
	var sin_a := sqrt(maxf(1.0 - cos_a * cos_a, 0.0))
	var B2 := A + dir * (a * cos_a) + bend * (a * sin_a)
	var q1 := _rot_between(B - A, B2 - A)
	_set_global_basis(sk, hip, Basis(q1) * gh.basis.orthonormalized())
	var gk2 := _global(sk, knee)
	var ga2 := _global(sk, ankle)
	var C2 := ga2.origin
	var T2 := A + dir * dist
	var q2 := _rot_between(C2 - gk2.origin, T2 - gk2.origin)
	_set_global_basis(sk, knee, Basis(q2) * gk2.basis.orthonormalized())


static func _rot_between(u: Vector3, v: Vector3) -> Quaternion:
	var a := u.normalized()
	var b := v.normalized()
	var d := a.dot(b)
	if d > 0.99999:
		return Quaternion.IDENTITY
	if d < -0.99999:
		var axis := a.cross(Vector3.UP)
		if axis.length() < 0.001:
			axis = a.cross(Vector3.RIGHT)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(a.cross(b).normalized(), acos(d))
