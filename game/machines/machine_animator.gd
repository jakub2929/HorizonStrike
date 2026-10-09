extends SkeletonModifier3D
## Procedural machine animation on the machine's own skeleton (real HZD skeleton or the placeholder), one pass per
## frame (stroje M1):
##  1. locomotion: a gait clock driven by speed and turning (sheet anim: run_gait, walk_cycle_s, run_cycle_s) and a
##     per-leg stance/swing planner in world space. A planted foot is locked where it touched down; a swinging foot
##     flies to where the leg's neutral position will be at mid-stance (velocity + turn rate prediction).
##  2. body: terrain pitch/roll from the feet, acceleration lean, banking, gait bob/rock/flex, pose channels (attacks,
##     hit reactions, idle actions, grazing), then reach correction: the body lowers until every planted foot is
##     reachable, so feet never slide because a leg is too short.
##  3. legs: analytic two-bone IK hip -> knee -> ankle; the ankle then pivots so the contact joint lands exactly on its
##     target (rolls onto the toe when the leg is stretched). Joints between hip, knee and ankle move rigidly.
##  4. neck/head (graze to the ground, look at the player, idle actions), jaw, tail, rotors.
##  Death: knees buckle, the body topples to one side and settles on the terrain plane (trunk hitboxes resting on it),
##  then stays put.
## Content contract: bones only through bone_roles + the leg chains; legs are grouped (front/hind, left/right) from the
## bind-pose geometry. Works in skeleton space with global poses (verified: get_bone_global_pose inside a modifier
## reflects the poses set in this pass; Godot restores the unmodified poses after the frame).

const Sheets := preload("res://core/sheets.gd")
const Gaits := preload("res://machines/anim/gaits.gd")
const Poses := preload("res://machines/anim/poses.gd")

const LAYER_WORLD := 1
## One physics tick (the machine moves in physics steps; feet must keep up with one step of travel).
const TICK := 1.0 / 60.0

var rig: Node3D

## Dev: count of bones the last modification moved and IK diagnostics (only computed when debug_measure is on).
var debug_measure := false
var debug_moved := 0
var debug_info := {}

# ---- skeleton facts (bind pose)
var _initialized := false
var _ok := false
var _body := -1
var _body_rest_m := Transform3D()      # body bone global rest in machine space
var _m_from_s := Transform3D()         # machine space <- skeleton space (fixed: the rig never moves inside the machine)
var _s_from_m := Transform3D()
var _pivot_m := Vector3.ZERO           # body pitch/roll pivot (between fore and hind leg roots)
var _rear_pivot_m := Vector3.ZERO
var _front_pivot_m := Vector3.ZERO
var _body_len := 1.0
var _body_w := 0.5
var _hip_h := 1.0                      # body bone height above the bind-pose ground
var _spine := PackedInt32Array()
var _neck := PackedInt32Array()
var _head := -1
var _jaws: Array = []                  # [bone, side]: role jaw, or a pair of mandibles (jaw_l / jaw_r)
var _tail := PackedInt32Array()
var _rotors: Array = []                # [bone, axis (bone space)]
var _legs: Array = []
var _biped := false
var _touched := PackedInt32Array()
var _trunk_boxes: Array = []           # [bone, Transform3D in bone space, half extents]
var _trunk_bones := PackedInt32Array()  # non-helper trunk bones (death settling probes besides the boxes)
var _turn_r := 0.5
var _travel_max := 1.0
var _head_rest_h := 1.0

# ---- sheet profile
var _run_gait := "gallop"
var _walk_cycle := 1.0
var _run_cycle := 0.5
var _tilt_max := deg_to_rad(10.0)
var _idle_actions: Array = []
var _graze_pose := "none"
var _hit_react := "flinch_back"
var _death_fall := "side"
var _neck_rest := 0.0                  # anim.neck_rest_pitch_deg: neutral neck pitch (+ down) for heads raised in the bind pose
var _walk_speed := 1.6
var _run_speed := 8.0
var _step_h := 0.35

# ---- runtime
var _state := "idle"
var _t := 0.0
var _clock := 0.0
var _gait := ""
var _gait_prev := ""
var _gait_blend := 1.0
var _duty := 0.65
var _period := 1.0
var _moving := false
var _speed := 0.0
var _yaw_rate := 0.0
var _acc_fwd := 0.0
var _vel := Vector3.ZERO
var _tg := 0.0                         # smoothed ground height under the body (machine space)
var _tp := 0.0                         # smoothed terrain pitch
var _tr := 0.0                         # smoothed terrain roll
var _lean_p := 0.0
var _lean_r := 0.0
var _reach_f := 0.0
var _reach_r := 0.0
var _ch := {}                          # pose channels this frame
var _attack := {}
var _hit := {}
var _idle := {}
var _idle_timer := 3.0
var _graze_w := 0.0
var _graze_on := false
var _graze_timer := 0.0
var _graze_angle := 0.6
var _look_yaw := 0.0
var _look_pitch := 0.0
var _look_w := 0.0
var _rotor_angle := 0.0
var _tail_lag := 0.0
var _last_pos := Vector3.ZERO
var _first := true
var _rng := RandomNumberGenerator.new()
var _last_slack := 1.0

# ---- death
var _dead := false
var _dead_t := 0.0
var _death_side := 1.0
var _death_n := Vector3.UP              # terrain normal under the corpse (machine space)
var _death_d := 0.0                     # plane: n.dot(p) = d (machine space)
var _death_corr := 0.0
var _death_neck := 0.0
var _death_frozen := false
var _death_start := {}
var _death_tail := 0.0
var _frozen_poses := {}                 # bone -> local pose of the settled corpse
var _grp_head := PackedInt32Array()     # sampled non-helper bones of the neck/head subtree (ground clearance)
var _grp_tail := PackedInt32Array()


# ------------------------------------------------------------------ public API (rig / machine)

func on_state(s: String) -> void:
	_state = s
	if s == "dead" and not _dead:
		_dead = true
		_dead_t = 0.0
		_death_side = -1.0 if _rng.randf() < 0.5 else 1.0
		var p: Node3D = Game.player
		if p and rig and rig.machine and _death_fall == "side":
			# fall away from the shooter
			var lp: Vector3 = rig.machine.global_transform.affine_inverse() * p.global_position
			_death_side = -1.0 if lp.x > 0.0 else 1.0
		_death_start = {"tg": _tg, "tp": _tp, "tr": _tr}
		_attack = {}
		_idle = {}
	if s in ["graze", "scavenge"]:
		_graze_timer = _rng.randf_range(0.1, 0.6)
		_graze_on = false


## Attack pose with the attack row's timing (wind-up telegraph, strike, recovery).
func play_attack(pose: String, windup: float, active: float) -> void:
	var def: Dictionary = Poses.ATTACKS.get(pose, Poses.ATTACKS["lunge_bite"])
	_attack = {"def": def, "t": 0.0, "windup": maxf(windup, 0.05), "active": maxf(active, 0.05), "recover": 0.45}
	_idle = {}


## Legacy entry (pose + total duration).
func play_pose(pose: String, duration: float) -> void:
	play_attack(pose, duration * 0.6, duration * 0.4)


## Hit reaction (amount 0.5 body, 1.0 weak spot): additive twitch away from the shooter.
func flinch(amount: float) -> void:
	if _dead:
		return
	if not _hit.is_empty() and float(_hit["t"]) < 0.1:
		_hit["amp"] = maxf(float(_hit["amp"]), amount)
		return
	var id := _hit_react
	if id == "rear_up" and amount < 0.9:
		id = "flinch_back"
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	var p: Node3D = Game.player
	if p and rig and rig.machine:
		var lp: Vector3 = rig.machine.global_transform.affine_inverse() * p.global_position
		side = -1.0 if lp.x > 0.0 else 1.0
	var slow := id == "rear_up"
	_hit = {"def": Poses.HITS.get(id, Poses.HITS["flinch_back"]), "t": 0.0, "side": side, "amp": amount,
		"windup": 0.15 if slow else 0.03, "active": 0.4 if slow else 0.1, "recover": 0.5 if slow else 0.3}


## Dev: leg geometry as text (bench trace).
func debug_dump() -> String:
	var sk: Skeleton3D = rig.skeleton
	var out := "body %s hip_h %.2f len %.2f travel_max %.2f
" % [sk.get_bone_name(_body) if _body >= 0 else "-", _hip_h, _body_len, _travel_max]
	for l in _legs:
		out += "  %s hip %s knee %s ankle %s end %s a %.2f b %.2f L %.2f foot %.2f home %s mid %s hip_m %s
" % [l["group"],
			sk.get_bone_name(int(l["hip"])), sk.get_bone_name(int(l["knee"])), sk.get_bone_name(int(l["ankle"])),
			sk.get_bone_name(int(l["end"])), float(l["a"]), float(l["b"]), float(l["L"]), float(l["foot_len"]), l["home_m"], l.get("mid_m"), l["hip_m"]]
	return out


## True when leg i (rig.leg_chains order) is planted (bench).
func leg_planted(i: int) -> bool:
	if i < 0 or i >= _legs.size():
		return false
	return str(_legs[i]["state"]) == "stance"


## The tail: the role "tail" bone and its chain of (non-helper) first children.
func tail_chain() -> PackedInt32Array:
	var out := PackedInt32Array()
	var sk: Skeleton3D = rig.skeleton
	var b := int(rig.roles.get("tail", -1))
	var helpers: Dictionary = rig.helper_bones
	while b >= 0 and out.size() < 64:
		out.append(b)
		var next := -1
		for c in sk.get_bone_children(b):
			if not helpers.has(c):
				next = c
				break
		b = next
	return out


# ------------------------------------------------------------------ init

func _init_rig(sk: Skeleton3D) -> void:
	_initialized = true
	_rng.randomize()
	var m: Node3D = rig.machine
	var type: String = rig.machine_type
	_walk_speed = Sheets.machine_num(type, "walk_speed_mps", 1.6)
	_run_speed = maxf(Sheets.machine_num(type, "run_speed_mps", 8.0), _walk_speed + 0.5)
	_step_h = Sheets.machine_num(type, "step_height_m", 0.35)
	var prof: Variant = Sheets.machine(type, "anim")
	var anim: Dictionary = prof if prof is Dictionary else {}
	_run_gait = str(anim.get("run_gait", "gallop"))
	_walk_cycle = float(anim.get("walk_cycle_s", 1.0))
	_run_cycle = float(anim.get("run_cycle_s", 0.5))
	_tilt_max = deg_to_rad(float(anim.get("body_tilt_max_deg", 10.0)))
	_idle_actions = anim.get("idle_actions", []) if anim.get("idle_actions", []) is Array else []
	_graze_pose = str(anim.get("graze_pose", "none"))
	_hit_react = str(anim.get("hit_react", "flinch_back"))
	_death_fall = str(anim.get("death_fall", "side"))
	_neck_rest = deg_to_rad(float(anim.get("neck_rest_pitch_deg", 0.0)))
	_m_from_s = m.global_transform.affine_inverse() * sk.global_transform
	_s_from_m = _m_from_s.affine_inverse()
	var helpers: Dictionary = rig.helper_bones
	# legs: chain, hip (chain root), knee (furthest bend between hip and ankle), ankle (role foot, else the joint above
	# the contact), contact (chain end); groups from the bind pose
	var chains: Array = rig.leg_chains
	_biped = chains.size() == 2
	var roots := []
	for ci in chains.size():
		var chain: PackedInt32Array = chains[ci]
		if chain.size() < 3:
			continue
		var end := chain[chain.size() - 1]
		var ankle := chain[chain.size() - 2]
		for r in rig.roles:
			if str(r).begins_with("leg_") and str(r).ends_with("_foot") and chain.has(int(rig.roles[r])) and int(rig.roles[r]) != end:
				ankle = int(rig.roles[r])
		var ai := chain.find(ankle)
		if ai < 2:
			ankle = end
			ai = chain.size() - 1
		var knee_i := _pick_knee(sk, chain, ai)
		var hip := chain[0]
		var knee := chain[knee_i]
		var H := _rest_m(sk, hip)
		var K := _rest_m(sk, knee)
		var A := _rest_m(sk, ankle)
		var C := _rest_m(sk, end)
		var leg := {"chain": chain, "hip": hip, "knee": knee, "ankle": ankle, "end": end, "home_m": C, "c0": C.y,
			"a": H.distance_to(K), "b": K.distance_to(A), "foot_m": A - C, "foot_len": A.distance_to(C),
			"state": "stance", "planted": Vector3.ZERO, "cur": Vector3.ZERO, "sw_from": Vector3.ZERO, "sw_to": Vector3.ZERO,
			"sw_t": 0.0, "sw_dur": 0.3, "sw_h": _step_h, "p_prev": 0.0, "age": 0.0, "over": 0.0, "slack": 1.0, "free_target": null,
			"sw_phase": false, "sw_acc": 0.0, "sw_len": 0.4,
			"bend_m": _perp(K - H, A - H), "hip_m": H, "off": 0.0, "group": ""}
		leg["L"] = (float(leg["a"]) + float(leg["b"])) * 0.985
		_legs.append(leg)
		roots.append(sk.get_bone_parent(hip))
		for b in chain:
			_touch(b)
	# groups: front = forward half (-Z), left = -X
	var zc := 0.0
	for l in _legs:
		zc += (l["home_m"] as Vector3).z
	zc /= maxf(_legs.size(), 1)
	for l in _legs:
		var hm: Vector3 = l["home_m"]
		var side := "l" if hm.x < 0.0 else "r"
		l["front"] = hm.z < zc
		l["group"] = side if _biped else ("f" if hm.z < zc else "b") + side
	# body bone: the hips role when it carries every leg, else the common ancestor of the leg roots
	var hips := int(rig.roles.get("hips", -1))
	if hips >= 0 and _is_ancestor_of_all(sk, hips, roots):
		_body = hips
	elif not roots.is_empty():
		_body = roots[0]
		while _body >= 0 and not _is_ancestor_of_all(sk, _body, roots):
			_body = sk.get_bone_parent(_body)
	if _body < 0:
		_body = int(rig.roles.get("spine", -1))
	if _body >= 0:
		_touch(_body)
		_body_rest_m = _m_from_s * sk.get_bone_global_rest(_body)
		_hip_h = maxf(_body_rest_m.origin.y, 0.2)
	# pivots and body size from the leg roots
	var fz := []
	var bz := []
	var minx := 0.0
	var maxx := 0.0
	for l in _legs:
		var hm2: Vector3 = l["hip_m"]
		(fz if l["front"] else bz).append(hm2)
		minx = minf(minx, hm2.x)
		maxx = maxf(maxx, hm2.x)
	_front_pivot_m = _avg(fz, _body_rest_m.origin)
	_rear_pivot_m = _avg(bz, _body_rest_m.origin)
	if _biped:
		_front_pivot_m = _body_rest_m.origin
		_rear_pivot_m = _body_rest_m.origin
	_pivot_m = (_front_pivot_m + _rear_pivot_m) * 0.5
	_pivot_m.y = _body_rest_m.origin.y
	_body_len = maxf(absf(_front_pivot_m.z - _rear_pivot_m.z), 0.4)
	_body_w = maxf(maxx - minx, 0.3)
	# foot speed when turning in place: the farthest foot from the turning axis (the machine origin) sets the cadence
	_turn_r = 0.2
	for l in _legs:
		var hm3: Vector3 = l["home_m"]
		_turn_r = maxf(_turn_r, Vector2(hm3.x, hm3.z).length())
	# while moving, a foot's stance is centred halfway between its bind-pose contact and the hip's projection (legs
	# raked back in the bind pose, like the Grazer's hind legs, would otherwise run out of reach behind the hip);
	# how far a foot can travel under its hip while planted: reach with a 10 % crouch and toe roll
	_travel_max = 99.0
	for l in _legs:
		var hm: Vector3 = l["home_m"]
		var hip_m: Vector3 = l["hip_m"]
		var mid := Vector3(hm.x, hm.y, lerpf(hm.z, hip_m.z, 0.5))
		l["mid_m"] = mid
		var dy := hip_m.y - (mid + (l["foot_m"] as Vector3)).y
		var reach := float(l["L"]) + 0.6 * float(l["foot_len"])
		var x := sqrt(maxf(reach * reach - pow(dy * 0.9, 2.0), 0.0)) - absf(mid.z - hip_m.z)
		_travel_max = minf(_travel_max, 2.0 * maxf(x, 0.05) * 0.85)
	_travel_max = clampf(_travel_max, 0.15, 4.0)
	# upper body chains (roles only)
	var spine_role := int(rig.roles.get("chest", rig.roles.get("spine", -1)))
	if spine_role >= 0 and _body >= 0:
		_spine = _path(sk, _body, spine_role)
		if not _spine.is_empty():
			_spine.remove_at(0)        # the body bone itself is posed separately
			_spine.append(spine_role)
	_head = int(rig.roles.get("head", -1))
	_neck = _path(sk, int(rig.roles.get("neck", -1)), _head)
	if _neck.is_empty() and _head >= 0 and int(rig.roles.get("neck", -1)) >= 0:
		_neck = PackedInt32Array([int(rig.roles.get("neck", -1))])
	for r in rig.roles:
		if str(r).begins_with("jaw"):
			_jaws.append([int(rig.roles[r]), -1.0 if str(r).ends_with("_l") else (1.0 if str(r).ends_with("_r") else 0.0)])
			_touch(int(rig.roles[r]))
	_tail = tail_chain()
	for r in ["rotor_l", "rotor_r"]:
		var rb := int(rig.roles.get(r, -1))
		if rb >= 0:
			var axis := Vector3.UP
			for c in sk.get_bone_children(rb):
				if sk.get_bone_rest(c).origin.length() > 0.01:
					axis = sk.get_bone_rest(c).origin.normalized()
					break
			_rotors.append([rb, axis])
			_touch(rb)
	for b in _spine:
		_touch(b)
	for b in _neck:
		_touch(b)
	for b in _tail:
		_touch(b)
	if _head >= 0:
		_touch(_head)
	_head_rest_h = _rest_m(sk, _head).y if _head >= 0 else _hip_h
	# trunk boxes (death settling): body hitboxes not on legs, neck, head or tail
	# (whole subtrees of legs, neck/head and tail are excluded: plates hanging on a leg are not trunk)
	var skip := {}
	var roots_skip := []
	for l in _legs:
		roots_skip.append(int(l["hip"]))
	if not _tail.is_empty():
		roots_skip.append(_tail[0])
	if not _neck.is_empty():
		roots_skip.append(_neck[0])
	if _head >= 0:
		roots_skip.append(_head)
	for r0 in roots_skip:
		for b in _subtree(sk, r0, {}, 100000):
			skip[b] = true
	if _body >= 0:
		var tb_all := PackedInt32Array()
		for b in _subtree(sk, _body, helpers, 100000):
			if not skip.has(b):
				tb_all.append(b)
		# plates on a leg root (above the knee) move with the trunk, not with the foot
		for l in _legs:
			var below_knee := {}
			for b in _subtree(sk, int(l["knee"]), {}, 100000):
				below_knee[b] = true
			for b in _subtree(sk, int(l["hip"]), helpers, 100000):
				if not below_knee.has(b):
					tb_all.append(b)
		_trunk_bones = tb_all if tb_all.size() <= 64 else _subtree_sample(tb_all, 64)
	for h in rig.hitboxes:
		var area := h as Area3D
		if area == null or area.get_meta("weak", false):
			continue
		var ba := area.get_parent() as BoneAttachment3D
		var cs := area.get_child(0) as CollisionShape3D if area.get_child_count() > 0 else null
		if ba == null or cs == null or skip.has(ba.bone_idx):
			continue
		var half := Vector3(0.1, 0.1, 0.1)
		if cs.shape is BoxShape3D:
			half = (cs.shape as BoxShape3D).size * 0.5
		elif cs.shape is SphereShape3D:
			var r := (cs.shape as SphereShape3D).radius
			half = Vector3(r, r, r)
		_trunk_boxes.append([ba.bone_idx, area.transform, half])
	if not _neck.is_empty():
		_grp_head = _subtree(sk, _neck[0], helpers, 128)
	elif _head >= 0:
		_grp_head = _subtree(sk, _head, helpers, 128)
	if not _tail.is_empty():
		_grp_tail = _subtree(sk, _tail[0], helpers)
	for l in _legs:
		l["grp"] = _subtree(sk, int(l["hip"]), helpers)
		l["dlift"] = 0.0
	_ok = _body >= 0 and not _legs.is_empty()
	_gait = "biped_walk" if _biped else "walk"
	_gait_prev = _gait
	_duty = float(Gaits.params(_gait)["duty"])
	_period = _walk_cycle
	for l in _legs:
		l["off"] = Gaits.offset(_gait, str(l["group"]))


## Non-helper bones of the subtree under `b` (evenly sampled down to 32): ground-clearance probes.
func _subtree(sk: Skeleton3D, b: int, helpers: Dictionary, cap: int = 32) -> PackedInt32Array:
	var all := PackedInt32Array()
	var stack := [b]
	while not stack.is_empty():
		var x: int = stack.pop_back()
		if not helpers.has(x):
			all.append(x)
		for c in sk.get_bone_children(x):
			stack.append(c)
	if all.size() <= cap:
		return all
	var out := PackedInt32Array()
	for i in cap:
		out.append(all[int(float(i) * all.size() / float(cap))])
	return out


static func _subtree_sample(all: PackedInt32Array, cap: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in cap:
		out.append(all[int(float(i) * all.size() / float(cap))])
	return out


## Lowest clearance (m) of the bones above the terrain (raycast per bone, world space).
func _min_clear(sk: Skeleton3D, bones: PackedInt32Array) -> float:
	var S := sk.global_transform
	var low := INF
	for b in bones:
		var w: Vector3 = S * sk.get_bone_global_pose(b).origin
		low = minf(low, w.y - _ground(w))
	return low


func _touch(b: int) -> void:
	if b >= 0 and not _touched.has(b):
		_touched.append(b)


func _rest_m(sk: Skeleton3D, b: int) -> Vector3:
	return _m_from_s * sk.get_bone_global_rest(b).origin


static func _avg(pts: Array, fallback: Vector3) -> Vector3:
	if pts.is_empty():
		return fallback
	var s := Vector3.ZERO
	for p in pts:
		s += p
	return s / pts.size()


static func _perp(v: Vector3, axis: Vector3) -> Vector3:
	var a := axis.normalized()
	return v - a * v.dot(a)


## The knee: the joint between hip and ankle that bends furthest off the hip->ankle line (25..80 % of the length).
func _pick_knee(sk: Skeleton3D, chain: PackedInt32Array, ankle_i: int) -> int:
	if ankle_i <= 2:
		return 1
	var pts: Array = []
	for i in ankle_i + 1:
		pts.append(sk.get_bone_global_rest(chain[i]).origin)
	var total := 0.0
	var cum: Array = [0.0]
	for i in range(1, pts.size()):
		total += (pts[i] as Vector3).distance_to(pts[i - 1])
		cum.append(total)
	var a: Vector3 = pts[0]
	var line := ((pts[ankle_i] as Vector3) - a).normalized()
	var best := 1
	var best_d := -1.0
	for i in range(1, ankle_i):
		var f: float = cum[i] / maxf(total, 0.0001)
		if f < 0.25 or f > 0.8:
			continue
		var v: Vector3 = (pts[i] as Vector3) - a
		var d := (v - line * v.dot(line)).length()
		if d > best_d:
			best_d = d
			best = i
	return best


## Bones from `from` down to `to` (exclusive) along the parent chain; empty when `to` is not below `from`.
func _path(sk: Skeleton3D, from: int, to: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if from < 0 or to < 0:
		return out
	var b := sk.get_bone_parent(to)
	while b >= 0:
		out.insert(0, b)
		if b == from:
			return out
		b = sk.get_bone_parent(b)
	return PackedInt32Array()


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


# ------------------------------------------------------------------ frame

func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or rig == null or rig.machine == null:
		return
	if not _initialized:
		_init_rig(sk)
	if not _ok:
		return
	delta = clampf(delta, 0.0001, 0.1)
	for b in _touched:
		sk.set_bone_pose(b, sk.get_bone_rest(b))
	var m: Node3D = rig.machine
	var M: Transform3D = m.global_transform
	_t += delta
	if _first or M.origin.distance_to(_last_pos) > 3.0:
		_reset_feet(M)
		_first = false
	_last_pos = M.origin
	if _dead:
		_dead_t += delta
		_process_death(sk, M, delta)
	else:
		_update_motion(m, M, delta)
		_update_channels(delta)
		_plan_feet(M, delta)
		_pose_body(sk, M, delta)
		_solve_legs(sk, M)
		_pose_upper(sk, M, delta)
	if debug_measure:
		var feet := []
		for l in _legs:
			feet.append(sk.global_transform * sk.get_bone_global_pose(int(l["end"])).origin)
		debug_info["feet"] = feet
		debug_info["frame"] = Engine.get_process_frames()
		debug_info["mpos"] = rig.machine.global_position
		debug_moved = 0
		for i in sk.get_bone_count():
			if sk.get_bone_global_pose(i).origin.distance_to(sk.get_bone_global_rest(i).origin) > 0.01:
				debug_moved += 1


func _reset_feet(M: Transform3D) -> void:
	for l in _legs:
		var p := _home_world(l, M, 0.0, 0.0, Vector3.ZERO)
		l["planted"] = p
		l["cur"] = p
		l["state"] = "stance"
		l["age"] = 1.0
	_tg = _ground_m(M, Vector3.ZERO)


# ------------------------------------------------------------------ locomotion

func _update_motion(m: Node3D, M: Transform3D, delta: float) -> void:
	var v: Vector3 = m.velocity
	v.y = 0.0
	_vel = v
	var spd := v.length()
	_speed = spd
	var yr: float = m.get("yaw_rate") if m.get("yaw_rate") != null else 0.0
	_yaw_rate = lerpf(_yaw_rate, yr, clampf(delta * 12.0, 0.0, 1.0))
	var af: float = m.get("accel_fwd") if m.get("accel_fwd") != null else 0.0
	_acc_fwd = lerpf(_acc_fwd, af, clampf(delta * 4.0, 0.0, 1.0))
	var g := Gaits.select(_run_gait, _biped, spd, _walk_speed, _run_speed, _gait)
	if g != _gait:
		_gait_prev = _gait
		_gait = g
		_gait_blend = 0.0
	_gait_blend = minf(_gait_blend + delta / 0.3, 1.0)
	var pa := Gaits.params(_gait_prev)
	var pb := Gaits.params(_gait)
	_duty = lerpf(float(pa["duty"]), float(pb["duty"]), _gait_blend)
	for l in _legs:
		var oa := Gaits.offset(_gait_prev, str(l["group"]))
		var ob := Gaits.offset(_gait, str(l["group"]))
		l["off"] = fposmod(oa + wrapf(ob - oa, -0.5, 0.5) * _gait_blend, 1.0)
	var turn_v := absf(_yaw_rate) * _turn_r
	var loco := maxf(spd, turn_v)
	_moving = loco > 0.15
	if _moving:
		var T: float
		if loco <= _walk_speed:
			T = _walk_cycle * clampf(sqrt(_walk_speed / maxf(loco, 0.05)), 1.0, 1.5)
		else:
			T = lerpf(_walk_cycle, _run_cycle, clampf((loco - _walk_speed) / maxf(_run_speed - _walk_speed, 0.1), 0.0, 1.0))
		# a planted foot travels loco * duty * T under its hip: keep that inside the legs' reach
		T = minf(T, _travel_max / maxf(loco * _duty, 0.01))
		T = maxf(T, 0.1 / maxf(1.0 - _duty, 0.1))
		_period = T
		_clock = fposmod(_clock + delta / T, 1.0)


## Where leg l's contact should be `ahead` seconds from now (machine moving with `vel`, turning at `yaw_rate`).
func _home_world(l: Dictionary, M: Transform3D, ahead: float, yaw_rate: float, vel: Vector3) -> Vector3:
	var hm: Vector3 = l["mid_m"] if vel.length() > 0.3 else l["home_m"]
	var off := Basis(Vector3.UP, yaw_rate * ahead) * Vector3(hm.x, 0.0, hm.z)
	var p := M.origin + vel * ahead + M.basis * off
	p.y = _ground(p) + float(l["c0"])
	return p


func _plan_feet(M: Transform3D, delta: float) -> void:
	var planted := 0
	var swinging := 0
	for l in _legs:
		if str(l["state"]) == "stance":
			planted += 1
		elif str(l["state"]) == "swing":
			swinging += 1
	var walking := _gait in ["walk", "biped_walk"] or not _moving
	var min_support := (1 if _biped else 2) if walking else 0
	var stance_half := _duty * _period * 0.5
	var free_req := _free_requests(M)
	for i in _legs.size():
		var l: Dictionary = _legs[i]
		var st := str(l["state"])
		var p := fposmod(_clock + float(l["off"]), 1.0)
		var req: Variant = free_req[i]
		# pose-driven free legs (attacks, rearing, pouncing)
		if req != null:
			if st == "stance":
				planted -= 1
			l["state"] = "free"
			l["free_target"] = req if req is Vector3 else null
			l["p_prev"] = p
			continue
		if st == "free":
			_start_swing(l, l["cur"], M, 0.28, false)
			st = "swing"
		match st:
			"stance":
				l["age"] = float(l["age"]) + delta
				l["cur"] = l["planted"]
				var lift := false
				var phased := false
				var dur := 0.3
				if _moving:
					var edge := p >= _duty and (float(l["p_prev"]) < _duty or float(l["p_prev"]) > p)
					var overdue := float(l["age"]) > _period * 1.2
					if (edge or overdue) and float(l["age"]) > 0.04:
						lift = true
						phased = true
				else:
					var home := _home_world(l, M, 0.0, 0.0, Vector3.ZERO)
					var drift := Vector2((l["planted"] as Vector3).x - home.x, (l["planted"] as Vector3).z - home.z).length()
					if drift > maxf(0.06, float(l["L"]) * 0.08) and swinging == 0:
						lift = true
						dur = clampf(_walk_cycle * 0.35, 0.22, 0.45)
				# about to run out of reach (within one physics tick of travel): step now instead of sliding
				var margin := 0.015 + (_speed + absf(_yaw_rate) * _turn_r) * TICK * 1.5
				if float(l["slack"]) < margin and float(l["age"]) > 0.04 and not lift:
					lift = true
					phased = false
					dur = clampf((1.0 - _duty) * _period * 0.8, 0.1, 0.35)
				var emergency := lift and not phased and _moving and float(l["slack"]) < 0.0
				if lift and (planted - 1 >= min_support or (emergency and planted - 1 >= 1)):
					planted -= 1
					swinging += 1
					_start_swing(l, l["planted"], M, dur, _moving and phased)
			"swing":
				# phase-locked swings land exactly at the leg's touchdown phase (also while the cadence changes);
				# timed swings (settling, emergency steps, stopping mid-swing) run on their own clock
				if bool(l["sw_phase"]) and _moving:
					var dp := fposmod(p - float(l["p_prev"]) + 0.5, 1.0) - 0.5
					l["sw_acc"] = float(l["sw_acc"]) + maxf(dp, 0.0)
					var s_ph := float(l["sw_acc"]) / maxf(float(l["sw_len"]), 0.05)
					l["sw_t"] = s_ph * float(l["sw_dur"])
					l["sw_dur"] = maxf(float(l["sw_len"]) * _period, 0.05)
					l["sw_t"] = s_ph * float(l["sw_dur"])
				else:
					if bool(l["sw_phase"]):
						# the clock stopped: finish this swing in a short timed step
						l["sw_phase"] = false
						var rem := clampf(float(l["sw_dur"]) - float(l["sw_t"]), 0.08, 0.25)
						l["sw_dur"] = float(l["sw_t"]) + rem
					l["sw_t"] = float(l["sw_t"]) + delta
				var s := clampf(float(l["sw_t"]) / float(l["sw_dur"]), 0.0, 1.0)
				if s < 0.75:
					var ahead := float(l["sw_dur"]) - float(l["sw_t"]) + (stance_half if _moving else 0.0)
					l["sw_to"] = _home_world(l, M, ahead, _yaw_rate if _moving else 0.0, _vel if _moving else Vector3.ZERO)
				var from: Vector3 = l["sw_from"]
				var to: Vector3 = l["sw_to"]
				var e := s - sin(TAU * s) / TAU
				var pos := from.lerp(to, e)
				pos.y = lerpf(from.y, to.y, e) + pow(sin(PI * s), 0.8) * float(l["sw_h"])
				var floor_y := _ground(pos) + float(l["c0"])
				pos.y = maxf(pos.y, floor_y)
				l["cur"] = pos
				if s >= 1.0:
					l["state"] = "stance"
					to.y = _ground(to) + float(l["c0"])
					l["planted"] = to
					l["cur"] = to
					l["age"] = 0.0
					l["over"] = 0.0
					swinging -= 1
					planted += 1
		l["p_prev"] = p


func _start_swing(l: Dictionary, from: Vector3, M: Transform3D, dur: float, moving: bool) -> void:
	l["state"] = "swing"
	l["sw_from"] = from
	l["sw_t"] = 0.0
	l["sw_phase"] = moving
	l["sw_acc"] = 0.0
	l["sw_len"] = maxf(1.0 - _duty, 0.1)
	if moving:
		dur = maxf(float(l["sw_len"]) * _period, 0.05)
	l["sw_dur"] = dur
	var lift_k := float(Gaits.params(_gait)["lift"]) if moving else 0.6
	l["sw_h"] = _step_h * lift_k * (clampf(0.5 + _speed / maxf(_walk_speed * 2.0, 0.5), 0.5, 1.0) if moving else 1.0)
	var ahead := dur + (_duty * _period * 0.5 if moving else 0.0)
	l["sw_to"] = _home_world(l, M, ahead, _yaw_rate if moving else 0.0, _vel if moving else Vector3.ZERO)


## Per leg: null (normal locomotion), true (free, rest-relative) or a world target (free, IK) from pose channels.
func _free_requests(M: Transform3D) -> Array:
	var out := []
	out.resize(_legs.size())
	var air := float(_ch.get("air", 0.0)) > 0.5
	var lift := float(_ch.get("front_lift", 0.0)) > 0.35
	var kick := float(_ch.get("rear_kick", 0.0))
	var paw := float(_ch.get("paw", 0.0))
	var fwd := -M.basis.z
	var paw_done := false
	for i in _legs.size():
		var l: Dictionary = _legs[i]
		if air:
			out[i] = true
		elif lift and bool(l["front"]) and not _biped:
			out[i] = true
		elif kick > 0.2 and not bool(l["front"]) and not _biped:
			var h := _home_world(l, M, 0.0, 0.0, Vector3.ZERO)
			out[i] = h - fwd * (0.8 * float(l["L"]) * kick) + Vector3.UP * (0.45 * float(l["L"]) * kick)
		elif paw > 0.3 and bool(l["front"]) and not paw_done and not _moving:
			paw_done = true
			var h2 := _home_world(l, M, 0.0, 0.0, Vector3.ZERO)
			var scrape := 0.12 + 0.18 * sin(_t * 7.0)
			out[i] = h2 + fwd * (scrape * float(l["L"])) + Vector3.UP * (0.04 + 0.06 * maxf(sin(_t * 7.0), 0.0))
	return out


# ------------------------------------------------------------------ pose channels

func _update_channels(delta: float) -> void:
	_ch = {}
	if not _attack.is_empty():
		_attack["t"] = float(_attack["t"]) + delta
		var a := Poses.sample(_attack["def"], float(_attack["t"]), float(_attack["windup"]), float(_attack["active"]), float(_attack["recover"]))
		if a.is_empty():
			_attack = {}
		else:
			_add_ch(a, 1.0, 1.0)
	if not _hit.is_empty():
		_hit["t"] = float(_hit["t"]) + delta
		var h := Poses.sample(_hit["def"], float(_hit["t"]), float(_hit["windup"]), float(_hit["active"]), float(_hit["recover"]))
		if h.is_empty():
			_hit = {}
		else:
			_add_ch(h, clampf(float(_hit["amp"]) * 1.4, 0.4, 1.4), float(_hit["side"]))
	# grazing / scavenging: head down to the ground in bouts while standing
	var calm := _state in ["graze", "scavenge", "idle", "patrol"]
	var grazing_state := _state in ["graze", "scavenge"] and _graze_pose != "none"
	if grazing_state and _speed < 0.25 and _attack.is_empty():
		_graze_timer -= delta
		if _graze_timer <= 0.0:
			_graze_on = not _graze_on
			_graze_timer = _rng.randf_range(4.0, 9.0) if _graze_on else _rng.randf_range(1.5, 4.0)
	else:
		_graze_on = false
	_graze_w = move_toward(_graze_w, 1.0 if _graze_on else 0.0, delta * 1.3)
	if _graze_w > 0.0:
		_ch["body_pitch"] = float(_ch.get("body_pitch", 0.0)) - (0.07 if not _biped else 0.15) * _graze_w
		_ch["body_dy"] = float(_ch.get("body_dy", 0.0)) - 0.03 * _graze_w
		if _graze_pose.contains("rotors"):
			_ch["rotor"] = maxf(float(_ch.get("rotor", 0.0)), _graze_w)
		if _graze_pose.contains("drill"):
			_ch["head_pitch"] = float(_ch.get("head_pitch", 0.0)) + 0.06 * sin(_t * 25.0) * _graze_w
	# predators stalk low with the head down; alerted quadrupeds paw the ground while they size up the threat
	if _state == "stalk":
		_ch["body_dy"] = float(_ch.get("body_dy", 0.0)) - 0.1
		_ch["neck_pitch"] = float(_ch.get("neck_pitch", 0.0)) + 0.25
		_ch["head_pitch"] = float(_ch.get("head_pitch", 0.0)) - 0.15
	elif _state == "alert" and not _biped and _speed < 0.2 and _attack.is_empty() and fmod(_t, 4.0) < 1.3:
		_ch["paw"] = maxf(float(_ch.get("paw", 0.0)), 1.0)
	# idle actions while calm and standing
	if calm and _speed < 0.2 and _attack.is_empty() and _graze_w < 0.05 and not _idle_actions.is_empty():
		if _idle.is_empty():
			_idle_timer -= delta
			if _idle_timer <= 0.0:
				_idle = {"id": str(_idle_actions[_rng.randi() % _idle_actions.size()]), "t": 0.0}
				_idle_timer = _rng.randf_range(3.0, 8.0)
		else:
			_idle["t"] = float(_idle["t"]) + delta
			var c := Poses.sample_idle(str(_idle["id"]), float(_idle["t"]))
			if c.is_empty():
				_idle = {}
			else:
				_add_ch(c, 1.0, 1.0)
	elif not _idle.is_empty() and (not calm or _speed >= 0.2 or not _attack.is_empty()):
		_idle = {}


func _add_ch(src: Dictionary, amp: float, side: float) -> void:
	for k in src:
		if str(k).begins_with("_"):
			continue
		var v := float(src[k]) * amp
		if k in ["body_roll", "body_yaw", "neck_yaw", "head_yaw", "neck_roll", "tail_yaw"]:
			v *= side
		if k in ["air", "front_lift", "rear_kick", "paw", "rotor", "jaw"]:
			_ch[k] = maxf(float(_ch.get(k, 0.0)), v)
		else:
			_ch[k] = float(_ch.get(k, 0.0)) + v


# ------------------------------------------------------------------ body

func _pose_body(sk: Skeleton3D, M: Transform3D, delta: float) -> void:
	var Minv := M.affine_inverse()
	# terrain under the feet (machine space): heights where the feet are / will land
	var gf := []
	var gb := []
	var gl := []
	var gr := []
	for l in _legs:
		var st := str(l["state"])
		if st == "free":
			continue
		var p: Vector3 = l["planted"] if st == "stance" else l["sw_to"]
		var h := (Minv * p).y - float(l["c0"])
		(gf if bool(l["front"]) else gb).append(h)
		(gl if (l["home_m"] as Vector3).x < 0.0 else gr).append(h)
	var ground := _ground_m(M, Vector3.ZERO)
	var pitch_t := 0.0
	var roll_t := 0.0
	if _biped:
		var ah := _ground_m(M, Vector3(0, 0, -_body_len * 0.5 - 0.4))
		var bh := _ground_m(M, Vector3(0, 0, _body_len * 0.5 + 0.4))
		pitch_t = atan2(ah - bh, _body_len + 0.8) * 0.5
		if not gl.is_empty() or not gr.is_empty():
			ground = (_mean(gl, ground) + _mean(gr, ground)) * 0.5
	else:
		var f := _mean(gf, ground)
		var b := _mean(gb, ground)
		ground = (f + b) * 0.5
		pitch_t = atan2(f - b, _body_len)
		roll_t = atan2(_mean(gl, ground) - _mean(gr, ground), _body_w) * 0.5
	var k := clampf(delta * 10.0, 0.0, 1.0)
	_tg = lerpf(_tg, ground, k)
	_tp = lerpf(_tp, clampf(pitch_t, -0.55, 0.55), clampf(delta * 6.0, 0.0, 1.0))
	_tr = lerpf(_tr, clampf(roll_t, -0.3, 0.3), clampf(delta * 6.0, 0.0, 1.0))
	# lean: accelerating lifts the nose, banking into turns, running carries the head low
	var run_k := clampf((_speed - _walk_speed) / maxf(_run_speed - _walk_speed, 0.1), 0.0, 1.0)
	var lean_p := clampf(_acc_fwd * 0.02, -_tilt_max * 0.6, _tilt_max * 0.6) - 0.03 * run_k
	var lean_r := clampf(-_speed * _yaw_rate * 0.03, -_tilt_max, _tilt_max)
	_lean_p = lerpf(_lean_p, lean_p, clampf(delta * 5.0, 0.0, 1.0))
	_lean_r = lerpf(_lean_r, lean_r, clampf(delta * 5.0, 0.0, 1.0))
	var gp := Gaits.params(_gait)
	var move_k := clampf(_speed / maxf(_walk_speed, 0.3), 0.0, 1.0)
	var n := float(gp["bob_per_cycle"])
	var bob := -float(gp["bob"]) * (0.5 - 0.5 * cos(TAU * n * _clock)) * move_k
	var rock := float(gp["rock"]) * sin(TAU * _clock) * run_k
	var breathe := 0.004 * sin(_t * 1.7) * (1.0 - move_k)
	var crouch := -0.04 * run_k
	var pitch := _tp + _lean_p + rock + float(_ch.get("body_pitch", 0.0))
	var roll := _tr + _lean_r + float(_ch.get("body_roll", 0.0))
	var yaw := float(_ch.get("body_yaw", 0.0))
	var dy := _tg + _hip_h * (bob + crouch + breathe + float(_ch.get("body_dy", 0.0)))
	var dz := _body_len * float(_ch.get("body_dz", 0.0))
	var lift := clampf(float(_ch.get("front_lift", 0.0)), 0.0, 1.0)
	var pivot := _pivot_m.lerp(_rear_pivot_m, lift)
	var flex := float(gp["flex"]) * sin(TAU * _clock + 0.5) * run_k
	_apply_body(sk, pitch, roll, yaw, dy, dz, pivot, flex)
	# reach correction: lower the fore/hind body until each planted foot is reachable (applied at once, released slowly)
	var need_f := 0.0
	var need_b := 0.0
	var S := sk.global_transform
	for l in _legs:
		if str(l["state"]) != "stance":
			continue
		var H: Vector3 = S * sk.get_bone_global_pose(int(l["hip"])).origin
		var C: Vector3 = l["planted"]
		var A := C + (H - C).normalized() * float(l["foot_len"])
		var hd := Vector2(H.x - A.x, H.z - A.z).length()
		var L := float(l["L"])
		var d := (H.y - A.y) - sqrt(maxf(L * L - hd * hd, 0.0))
		if bool(l["front"]) or _biped:
			need_f = maxf(need_f, d)
		if not bool(l["front"]) or _biped:
			need_b = maxf(need_b, d)
	var cap := _hip_h * 0.3
	need_f = clampf(need_f, 0.0, cap)
	need_b = clampf(need_b, 0.0, cap)
	var rel := _hip_h * 0.6 * delta
	_reach_f = maxf(need_f, _reach_f - rel)
	_reach_r = maxf(need_b, _reach_r - rel)
	if _reach_f > 0.0005 or _reach_r > 0.0005:
		var extra_dy := -(_reach_f + _reach_r) * 0.5
		var extra_p := 0.0 if _biped else atan2(_reach_r - _reach_f, _body_len)
		_apply_body(sk, pitch + extra_p, roll, yaw, dy + extra_dy, dz, pivot, flex)


static func _mean(a: Array, fallback: float) -> float:
	if a.is_empty():
		return fallback
	var s := 0.0
	for x in a:
		s += float(x)
	return s / a.size()


## Sets the body bone (machine space pose: rest rotated by yaw/pitch/roll around `pivot`, raised by dy, pushed
## forward by dz) and flexes the spine chain.
func _apply_body(sk: Skeleton3D, pitch: float, roll: float, yaw: float, dy: float, dz: float, pivot: Vector3, flex: float) -> void:
	var R := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.FORWARD, roll)
	var T := Transform3D(R, pivot + Vector3(0.0, dy, -dz)) * Transform3D(Basis(), -pivot) * _body_rest_m
	sk.set_bone_pose(_body, sk.get_bone_rest(_body))
	sk.set_bone_global_pose(_body, _s_from_m * T)
	for b in _spine:
		sk.set_bone_pose(b, sk.get_bone_rest(b))
	if absf(flex) > 0.0001 and not _spine.is_empty():
		_rot_chain(sk, _spine, (_s_from_m.basis * (R * Vector3.RIGHT)).normalized(), flex)


# ------------------------------------------------------------------ legs

func _solve_legs(sk: Skeleton3D, M: Transform3D) -> void:
	var S := sk.global_transform
	var Sinv := S.affine_inverse()
	for l in _legs:
		var st := str(l["state"])
		var target: Variant = l["cur"]
		if st == "free":
			target = l["free_target"]
		if target == null:
			# free leg without a target keeps its rest shape relative to the body, but never reaches into the ground
			var rel: Vector3 = S * sk.get_bone_global_pose(int(l["end"])).origin
			var floor_y := _ground(rel) + float(l["c0"])
			if rel.y < floor_y:
				rel.y = floor_y
				_ik_leg(sk, l, Sinv * rel, M)
			l["cur"] = rel
			l["over"] = 0.0
			continue
		var over := _ik_leg(sk, l, Sinv * (target as Vector3), M)
		l["over"] = over if st == "stance" else 0.0
		l["slack"] = _last_slack if st == "stance" else 1.0
		if debug_measure and st == "stance":
			var err := (S * sk.get_bone_global_pose(int(l["end"])).origin).distance_to(target)
			if err > float(debug_info.get("ik_err_max", 0.0)):
				debug_info["ik_err_max"] = err
				var Hm: Vector3 = M.affine_inverse() * (S * sk.get_bone_global_pose(int(l["hip"])).origin)
				var Tm: Vector3 = M.affine_inverse() * (target as Vector3)
				debug_info["ik_err_ctx"] = "leg %s gait %s speed %.1f over %.3f reach_f %.3f reach_r %.3f T %.3f duty %.2f age %.3f hip_m %s target_m %s L %.2f" % [l["group"], _gait, _speed, over, _reach_f, _reach_r, _period, _duty, float(l["age"]), Hm, Tm, float(l["L"])]
		if st == "free":
			l["cur"] = S * sk.get_bone_global_pose(int(l["end"])).origin


## Two-bone IK hip -> knee -> ankle, then the ankle pivots so the contact joint lands on `C` (skeleton space).
## Returns how far the target was out of reach (m).
func _ik_leg(sk: Skeleton3D, l: Dictionary, C: Vector3, _M: Transform3D) -> float:
	var hip := int(l["hip"])
	var knee := int(l["knee"])
	var ankle := int(l["ankle"])
	var end := int(l["end"])
	var H := sk.get_bone_global_pose(hip).origin
	var L := float(l["L"])
	var A := C
	var over := 0.0
	if ankle != end:
		var f: Vector3 = (_s_from_m.basis * (l["foot_m"] as Vector3)).normalized() * float(l["foot_len"])
		A = C + f
		if A.distance_to(H) > L:
			# roll onto the toe: pivot the foot segment towards the hip until the ankle is reachable
			var dir0 := f.normalized()
			var dir1 := (H - C).normalized()
			var lo := 0.0
			var hi := 1.0
			if (C + dir1 * float(l["foot_len"])).distance_to(H) > L:
				lo = 1.0
			else:
				for _i in 10:
					var mid := (lo + hi) * 0.5
					var dm := _slerp_dir(dir0, dir1, mid)
					if (C + dm * float(l["foot_len"])).distance_to(H) > L:
						lo = mid
					else:
						hi = mid
			A = C + _slerp_dir(dir0, dir1, hi if lo < 1.0 else 1.0) * float(l["foot_len"])
	over = maxf(A.distance_to(H) - L, 0.0)
	# slack: how much farther the hip could move away before this foot is out of reach (toe roll included)
	var best := C + (H - C).normalized() * float(l["foot_len"]) if ankle != end else C
	_last_slack = L - best.distance_to(H)
	_two_bone(sk, l, hip, knee, ankle, A)
	if ankle != end:
		var ga := sk.get_bone_global_pose(ankle)
		var ge := sk.get_bone_global_pose(end)
		var q := _rot_between(ge.origin - ga.origin, C - ga.origin)
		sk.set_bone_global_pose(ankle, Transform3D(Basis(q) * ga.basis, ga.origin))
	return over


static func _slerp_dir(a: Vector3, b: Vector3, t: float) -> Vector3:
	var ang := a.angle_to(b)
	if ang < 0.0001:
		return a
	var axis := a.cross(b)
	if axis.length() < 0.00001:
		return a.lerp(b, t).normalized()
	return a.rotated(axis.normalized(), ang * t)


func _two_bone(sk: Skeleton3D, l: Dictionary, hip: int, knee: int, ankle: int, target: Vector3) -> void:
	var gh := sk.get_bone_global_pose(hip)
	var gk := sk.get_bone_global_pose(knee)
	var A := gh.origin
	var B := gk.origin
	var C := sk.get_bone_global_pose(ankle).origin
	var a := A.distance_to(B)
	var b := B.distance_to(C)
	if a < 0.001 or b < 0.001:
		return
	var to_t := target - A
	var dist := clampf(to_t.length(), absf(a - b) + 0.001, (a + b) * 0.9995)
	var dir := to_t.normalized() if to_t.length() > 0.0001 else (C - A).normalized()
	var bend := (B - A) - dir * (B - A).dot(dir)
	if bend.length() < 0.002 * a:
		var bm: Vector3 = l["bend_m"]
		bend = _s_from_m.basis * bm
		bend = bend - dir * bend.dot(dir)
		if bend.length() < 0.0001:
			bend = (_s_from_m.basis * Vector3.FORWARD).cross(dir).cross(dir)
	bend = bend.normalized()
	var cos_a := clampf((a * a + dist * dist - b * b) / (2.0 * a * dist), -1.0, 1.0)
	var sin_a := sqrt(maxf(1.0 - cos_a * cos_a, 0.0))
	var B2 := A + dir * (a * cos_a) + bend * (a * sin_a)
	var q1 := _rot_between(B - A, B2 - A)
	sk.set_bone_global_pose(hip, Transform3D(Basis(q1) * gh.basis, gh.origin))
	var gk2 := sk.get_bone_global_pose(knee)
	var C2 := sk.get_bone_global_pose(ankle).origin
	var q2 := _rot_between(C2 - gk2.origin, (A + dir * dist) - gk2.origin)
	sk.set_bone_global_pose(knee, Transform3D(Basis(q2) * gk2.basis, gk2.origin))


static func _rot_between(u: Vector3, v: Vector3) -> Quaternion:
	if u.length() < 0.000001 or v.length() < 0.000001:
		return Quaternion.IDENTITY
	var a := u.normalized()
	var b := v.normalized()
	var d := a.dot(b)
	if d > 0.999999:
		return Quaternion.IDENTITY
	if d < -0.999999:
		var axis := a.cross(Vector3.UP)
		if axis.length() < 0.001:
			axis = a.cross(Vector3.RIGHT)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(a.cross(b).normalized(), acos(d))


# ------------------------------------------------------------------ upper body

func _rotate_global(sk: Skeleton3D, b: int, q: Quaternion) -> void:
	if b < 0:
		return
	var g := sk.get_bone_global_pose(b)
	sk.set_bone_global_pose(b, Transform3D(Basis(q) * g.basis, g.origin))


## Rotates a bone chain by `total` radians around `axis` (skeleton space), spread evenly over its bones.
func _rot_chain(sk: Skeleton3D, bones: PackedInt32Array, axis: Vector3, total: float) -> void:
	if bones.is_empty() or absf(total) < 0.00001:
		return
	var per := total / bones.size()
	var q := Quaternion(axis.normalized(), per)
	for b in bones:
		_rotate_global(sk, b, q)


func _pose_upper(sk: Skeleton3D, M: Transform3D, delta: float) -> void:
	var sb := _s_from_m.basis
	var right := (sb * Vector3.RIGHT).normalized()
	var up := (sb * Vector3.UP).normalized()
	var fwd := (sb * Vector3.FORWARD).normalized()
	var run_k := clampf((_speed - _walk_speed) / maxf(_run_speed - _walk_speed, 0.1), 0.0, 1.0)
	var move_k := clampf(_speed / maxf(_walk_speed, 0.3), 0.0, 1.0)
	# neck: posture by state + pose channels + grazing + gait nod
	var neck_pitch := _neck_rest + float(_ch.get("neck_pitch", 0.0)) + 0.12 * run_k
	if _state in ["alert", "suspicious"]:
		neck_pitch -= 0.12
	neck_pitch += _graze_angle * _graze_w
	neck_pitch += sin(TAU * 2.0 * _clock) * 0.05 * move_k * (0.5 if _biped else 1.0)
	var neck_yaw := float(_ch.get("neck_yaw", 0.0))
	var head_pitch := float(_ch.get("head_pitch", 0.0))
	var head_yaw := float(_ch.get("head_yaw", 0.0))
	# look at the player when aware (limited, split between neck and head)
	var want_look := 0.0
	var p: Node3D = Game.player
	if p and _state in ["suspicious", "alert", "attack"] and _head >= 0:
		want_look = 0.5 if not _attack.is_empty() else 1.0
		var hp := M * _rest_m(sk, _head)
		var target: Vector3 = p.head_position() if p.has_method("head_position") else p.global_position
		var lp: Vector3 = M.affine_inverse() * target
		var lh: Vector3 = M.affine_inverse() * hp
		var d: Vector3 = lp - lh
		var yaw_t := clampf(atan2(-d.x, -d.z), -1.2, 1.2)
		var pitch_t := clampf(-atan2(d.y, Vector2(d.x, d.z).length()), -0.6, 0.6)
		_look_yaw = lerpf(_look_yaw, yaw_t, clampf(delta * 6.0, 0.0, 1.0))
		_look_pitch = lerpf(_look_pitch, pitch_t, clampf(delta * 6.0, 0.0, 1.0))
	_look_w = move_toward(_look_w, want_look, delta * 2.5)
	neck_yaw += _look_yaw * _look_w * 0.4
	head_yaw += _look_yaw * _look_w * 0.6
	head_pitch += _look_pitch * _look_w * 0.6
	neck_pitch += _look_pitch * _look_w * 0.4
	if not _neck.is_empty():
		_rot_chain(sk, _neck, right, -neck_pitch)
		_rot_chain(sk, _neck, up, neck_yaw)
		_rot_chain(sk, _neck, fwd, float(_ch.get("neck_roll", 0.0)))
	elif _head >= 0:
		head_pitch += neck_pitch
		head_yaw += neck_yaw
	if _head >= 0:
		_rotate_global(sk, _head, Quaternion(up, head_yaw) * Quaternion(right, -head_pitch))
	# grazing: steer the neck angle so the head reaches the ground
	if _graze_w > 0.3 and _head >= 0:
		var hw := sk.global_transform * sk.get_bone_global_pose(_head).origin
		var clear := hw.y - _ground(hw)
		var want := maxf(_head_rest_h * 0.12, 0.12)
		_graze_angle = clampf(_graze_angle + (clear - want) * delta * 2.5, 0.2, 1.7)
	var jaw_open := clampf(float(_ch.get("jaw", 0.0)), 0.0, 1.0)
	if jaw_open > 0.001:
		for j in _jaws:
			# a single jaw drops; mandible pairs also spread sideways
			var q := Quaternion(right, -0.4 * jaw_open)
			if float(j[1]) != 0.0:
				q = Quaternion(up, float(j[1]) * 0.3 * jaw_open) * q
			_rotate_global(sk, int(j[0]), q)
	# tail: idle sway, lags behind turns, lifts when running, attack sweeps
	if not _tail.is_empty():
		_tail_lag = lerpf(_tail_lag, clampf(-_yaw_rate * 0.25, -0.8, 0.8), clampf(delta * 3.0, 0.0, 1.0))
		var nt := _tail.size()
		var tyaw := float(_ch.get("tail_yaw", 0.0))
		var tpitch := float(_ch.get("tail_pitch", 0.0)) + 0.25 * run_k
		for i in nt:
			var kk := float(i + 1) / nt
			var sway := sin(_t * (1.3 + 2.0 * move_k) - kk * 2.2) * (0.35 + 0.25 * move_k) / nt
			_rotate_global(sk, _tail[i], Quaternion(up, sway + (_tail_lag + tyaw) / nt) * Quaternion(right, (tpitch - 0.12) / nt))
	# rotors
	var spin := float(_ch.get("rotor", 0.0))
	if spin > 0.01 and not _rotors.is_empty():
		_rotor_angle = fposmod(_rotor_angle + delta * 14.0 * spin, TAU)
		for r in _rotors:
			var b: int = r[0]
			var g := sk.get_bone_global_pose(b)
			var axis: Vector3 = (g.basis * (r[1] as Vector3)).normalized()
			sk.set_bone_global_pose(b, Transform3D(Basis(axis, _rotor_angle * (1.0 if r == _rotors[0] else -1.0)) * g.basis, g.origin))


# ------------------------------------------------------------------ death

func _process_death(sk: Skeleton3D, M: Transform3D, delta: float) -> void:
	if _death_frozen:
		for b in _frozen_poses:
			sk.set_bone_pose(b, _frozen_poses[b])
		return
	if _dead_t <= delta * 1.5:
		_fit_death_plane(M)
	var t := _dead_t
	var buckle := _smooth(t / 0.35)
	var fall := clampf((t - 0.25) / 0.75, 0.0, 1.0)
	fall = fall * fall
	_apply_death_pose(sk, M, buckle, fall, true)
	if t > 2.4:
		_death_frozen = true
		if debug_measure:
			print("DEATH side %.0f neck %.2f tail %.2f corr %.2f head_clear %.2f n %s" % [_death_side, _death_neck, _death_tail, _death_corr, _min_clear(sk, _grp_head), _death_n])
		for b in _touched:
			_frozen_poses[b] = sk.get_bone_pose(b)


func _fit_death_plane(M: Transform3D) -> void:
	var r := maxf(_body_len * 0.5, 0.5)
	var c := _ground_m(M, Vector3.ZERO)
	var f := _ground_m(M, Vector3(0, 0, -r))
	var b := _ground_m(M, Vector3(0, 0, r))
	var lft := _ground_m(M, Vector3(-r, 0, 0))
	var rgt := _ground_m(M, Vector3(r, 0, 0))
	var n := Vector3(lft - rgt, 2.0 * r, f - b).normalized()   # normal of the plane through the four samples (machine space)
	_death_n = n if n.y > 0.5 else Vector3.UP
	_death_d = _death_n.dot(Vector3(0, c, 0))


func _apply_death_pose(sk: Skeleton3D, M: Transform3D, buckle: float, fall: float, settle: bool) -> void:
	var side := _death_side
	var bounce := 0.0
	if _dead_t > 1.0 and _dead_t < 1.6:
		bounce = sin((_dead_t - 1.0) / 0.6 * PI) * 0.06 * (1.0 - (_dead_t - 1.0) / 0.6)
	var roll := side * (PI * 0.5 - 0.12) * fall - side * bounce
	var tilt := Quaternion(Vector3.UP, _death_n)
	var R := Basis(tilt) * Basis(Vector3.RIGHT, float(_death_start.get("tp", 0.0)) * (1.0 - fall) - 0.08 * fall) * Basis(Vector3.FORWARD, roll)
	var drop := -_hip_h * 0.25 * buckle
	# topple around the lower side of the body at ground level
	var pivot := Vector3(side * _body_w * 0.5, float(_death_start.get("tg", 0.0)), _pivot_m.z)
	var base := Transform3D(Basis(), Vector3(0, drop + float(_death_start.get("tg", 0.0)), 0)) * _body_rest_m
	var T := Transform3D(R, pivot + Vector3(0, _death_corr, 0)) * Transform3D(Basis(), -pivot) * base
	sk.set_bone_global_pose(_body, _s_from_m * T)
	if settle:
		# keep the trunk on the terrain plane: never below while falling, resting on it at the end
		var low := INF
		for tb in _trunk_boxes:
			var g: Transform3D = _m_from_s * sk.get_bone_global_pose(int(tb[0])) * (tb[1] as Transform3D)
			var h: Vector3 = tb[2]
			var cdist := _death_n.dot(g.origin) - _death_d
			var ext := absf(_death_n.dot(g.basis.x.normalized() * h.x * g.basis.x.length())) \
				+ absf(_death_n.dot(g.basis.y.normalized() * h.y * g.basis.y.length())) \
				+ absf(_death_n.dot(g.basis.z.normalized() * h.z * g.basis.z.length()))
			low = minf(low, cdist - ext)
		for b in _trunk_bones:
			var bp: Vector3 = _m_from_s * sk.get_bone_global_pose(b).origin
			low = minf(low, _death_n.dot(bp) - _death_d - 0.02)
		if low < INF:
			var want := -low if fall >= 1.0 else maxf(-low, 0.0)
			_death_corr += want if fall >= 1.0 else maxf(want, 0.0)
			T = Transform3D(R, pivot + Vector3(0, _death_corr, 0)) * Transform3D(Basis(), -pivot) * base
			sk.set_bone_global_pose(_body, _s_from_m * T)
	# legs: stay planted while buckling, then blend to their body-relative shape, never through the ground
	var S := sk.global_transform
	var Sinv := S.affine_inverse()
	for l in _legs:
		var rel: Vector3 = S * sk.get_bone_global_pose(int(l["end"])).origin
		var tgt: Vector3 = (l["planted"] as Vector3).lerp(rel, _smooth(fall * 1.3))
		var gm := M.affine_inverse() * tgt
		var plane_h := (_death_d - _death_n.x * gm.x - _death_n.z * gm.z) / maxf(_death_n.y, 0.3)
		if gm.y < plane_h + 0.05:
			gm.y = plane_h + 0.05
			tgt = M * gm
		tgt.y += float(l["dlift"])
		if fall < 1.0 or tgt.distance_to(rel) > 0.01:
			_ik_leg(sk, l, Sinv * tgt, M)
		if settle and fall >= 1.0:
			# every bone of the leg above the terrain: raise the foot target until they clear it
			var lc := _min_clear(sk, l["grp"])
			if lc < 0.03:
				l["dlift"] = minf(float(l["dlift"]) + (0.03 - lc), _hip_h)
	# neck and tail sag to the ground
	var sb := _s_from_m.basis
	var down_axis := (sb * Vector3.FORWARD).normalized() * side
	if not _neck.is_empty() and _head >= 0:
		_rot_chain(sk, _neck, down_axis, _death_neck * fall)
		if settle and fall >= 1.0:
			# the head sinks until its lowest bone (horns, antennas, jaw) rests just above the ground
			var clear := _min_clear(sk, _grp_head)
			_death_neck = clampf(_death_neck + clampf((clear - 0.04) * 0.8, -0.15, 0.08), -1.6, 1.2)
			if _death_neck <= -1.6 and clear < 0.0:
				_death_corr += -clear   # horns/antennas still in the ground with the neck turned away: lift the corpse
	if not _tail.is_empty():
		_rot_chain(sk, _tail, down_axis, (0.35 + _death_tail) * fall)
		if settle and fall >= 1.0:
			var tc := _min_clear(sk, _grp_tail)
			_death_tail = clampf(_death_tail + clampf((tc - 0.04) * 0.8, -0.15, 0.08), -1.5, 0.6)
	for j in _jaws:
		_rotate_global(sk, int(j[0]), Quaternion((sb * Vector3.RIGHT).normalized(), -0.25 * fall))


static func _smooth(x: float) -> float:
	var c := clampf(x, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)


# ------------------------------------------------------------------ terrain

func _ground(world_pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return world_pos.y
	var q := PhysicsRayQueryParameters3D.create(world_pos + Vector3(0, 3.0, 0), world_pos - Vector3(0, 6.0, 0), LAYER_WORLD)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return world_pos.y
	return (hit["position"] as Vector3).y


## Ground height (machine space y) under a machine-space point.
func _ground_m(M: Transform3D, p_m: Vector3) -> float:
	var w := M * p_m
	return _ground(w) - M.origin.y
