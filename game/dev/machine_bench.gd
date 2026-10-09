extends SceneTree
## Dev only: machine animation bench (stroje M0/M1). Spawns each machine on a synthetic test terrain (bumps, a 12 deg
## ramp, a 4.6 deg cross slope) with its AI off, drives it through settle, walk, stop, turn in place, run, stop,
## graze/idle, every attack pose of its machine_attacks rows, hit react and death, and measures on the final
## (modified) skeleton pose, read in Skeleton3D.skeleton_updated:
##   foot_slide_cm   max horizontal drift of a foot contact (leg chain end) within one stance (planted) phase
##   penetration_cm  max depth of a foot contact below its bind-pose height above the terrain (all phases but death)
##   float_cm        mean height of planted foot contacts above that height (informational)
##   poses           walk, run, turn, graze, attack:<pose>, hit, death -> ok / fail (reason)
## Usage (real models need a cache with hzd/machines/<id>; --mock-data uses the placeholder rigs):
##   godot --headless --path game --script res://dev/machine_bench.gd -- --mock-data --machines watcher,strider,grazer
##   godot --headless --path game --script res://dev/machine_bench.gd -- --cache <dir> --machines watcher [--out f.json]
##   windowed (no --headless) with --shots <dir>: side-view screenshots at key moments of every phase
## Exit code 0 when every machine passes (slide < 5 cm, penetration < 5 cm, all poses ok), else 1.
## --ai: AI check instead (dev, not the autotest): a stand-in player (setup only) walks up to a group of each machine
## type; records the state sequence, attacks (machine.current_attack), radar pings, projectiles and hits, and checks
## the archetype's cycle (guard: alert -> attack; herd: alert -> flee, or with defend_charge alert -> attack;
## predator: alert -> stalk -> attack; scavenger: radar ping -> alert -> pack call -> laser burst).

const SLIDE_MAX_CM := 5.0
const PEN_MAX_CM := 5.0


func _initialize() -> void:
	var ua := OS.get_cmdline_user_args()
	var r := Runner.new()
	r.name = "MachineBench"
	var i := 0
	while i < ua.size():
		var a := ua[i]
		var nxt := ua[i + 1] if i + 1 < ua.size() else ""
		match a:
			"--mock-data":
				r.mock = true
			"--cache":
				r.cache = nxt
				i += 1
			"--machines":
				r.types = Array(nxt.split(",", false))
				i += 1
			"--out":
				r.out_path = nxt
				i += 1
			"--only":
				r.only = Array(nxt.split(",", false))
				i += 1
			"--shots":
				r.shots = nxt
				i += 1
			"--ai":
				r.ai = true
			"--perf":
				r.perf = int(nxt)
				i += 1
		i += 1
	if r.types.is_empty():
		r.types = ["watcher", "strider", "grazer"]
	root.add_child.call_deferred(r)


class Runner extends Node:
	# loaded at run time: these scripts use the Game autoload, which is not a known identifier while this --script compiles
	var Machine: GDScript
	var Sheets: GDScript
	var Content: GDScript

	var mock := false
	var cache := ""
	var out_path := ""
	var types: Array = []
	var only: Array = []          # optional phase filter (dev)
	var shots := ""               # screenshot directory (windowed runs)
	var ai := false
	var perf := 0                 # --perf N: N machines (types round-robin) with AI on; animator cost per frame
	var _fake: Node3D
	var _ai_group: Array = []
	var _ai_t := 0.0
	var _ai_rec := {}
	var _cam: Camera3D
	var _shot_done := {}
	var results: Array = []

	var _game: Node
	var _idx := -1
	var _m: Node                   # current machine
	var _sk: Skeleton3D
	var _an: Node
	var _phases: Array = []
	var _pi := -1
	var _pt := 0.0
	var _rec := {}
	var _c0: Array = []            # per leg: bind-pose contact height above the machine's ground (machine space)
	var _ends: Array = []          # per leg: chain end bone
	var _planted: Array = []
	var _start: Array = []
	var _ref_pose := {}            # bone -> machine-space position at the pose phase start
	var _bones: Array = []         # non-helper bones
	var _probe: BoneAttachment3D
	var _fwd0 := Vector3.FORWARD
	var _yaw0 := 0.0
	var _stand_head := 0.0
	var _stand_body := 0.0
	var _done := false

	func _ready() -> void:
		Machine = load("res://machines/machine.gd")
		Sheets = load("res://core/sheets.gd")
		Content = load("res://core/content.gd")
		_game = get_node("/root/Game")
		# watchdog: never hang an unattended run
		get_tree().create_timer(60.0 * maxf(types.size(), 1) + 30.0).timeout.connect(func():
			print("BENCH RESULT FAIL (watchdog timeout)")
			get_tree().quit(2))
		if cache != "":
			_game.cache_root = cache
			Sheets.load_resolved(cache)
			Content.forget()
		_build_terrain()
		if shots != "":
			_build_view()
		if perf > 0:
			_start_perf.call_deferred()
			return
		if ai:
			_fake = FakePlayer.new()
			add_child(_fake)
			_game.player = _fake
			_game.machine_state_changed.connect(_on_state_changed)
		_next_machine()

	# ------------------------------------------------------------ terrain

	static func height(x: float, z: float) -> float:
		return 0.18 * sin(0.7 * x + 0.3) * cos(0.55 * z) + clampf(-z - 4.0, 0.0, 20.0) * tan(deg_to_rad(12.0)) + 0.08 * x

	func _build_terrain() -> void:
		var n := 257
		var body := StaticBody3D.new()
		body.name = "BenchTerrain"
		body.collision_layer = 1
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var hm := HeightMapShape3D.new()
		hm.map_width = n
		hm.map_depth = n
		var data := PackedFloat32Array()
		data.resize(n * n)
		var half := (n - 1) * 0.5
		for zi in n:
			for xi in n:
				data[zi * n + xi] = height(xi - half, zi - half)
		hm.map_data = data
		cs.shape = hm
		body.add_child(cs)
		add_child(body)

	func _build_view() -> void:
		DirAccess.make_dir_recursive_absolute(shots)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for zi in range(-35, 55):
			for xi in range(-25, 25):
				var q := [Vector3(xi, 0, zi), Vector3(xi + 1, 0, zi), Vector3(xi + 1, 0, zi + 1), Vector3(xi, 0, zi + 1)]
				for k in q.size():
					q[k].y = height(q[k].x, q[k].z)
				var c := 0.45 + 0.08 * float((xi + zi) & 1)
				for idx in [0, 1, 2, 0, 2, 3]:
					st.set_color(Color(c, c * 1.05, c * 0.9))
					st.add_vertex(q[idx])
		st.generate_normals()
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		add_child(mi)
		var sun := DirectionalLight3D.new()
		sun.rotation = Vector3(deg_to_rad(-50), deg_to_rad(30), 0)
		sun.shadow_enabled = true
		add_child(sun)
		var env := WorldEnvironment.new()
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = Color(0.55, 0.65, 0.8)
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
		add_child(env)
		_cam = Camera3D.new()
		_cam.current = true
		add_child(_cam)

	func _update_cam() -> void:
		if _cam == null or _m == null:
			return
		var h: float = _m.rig.body_height
		var c: Vector3 = _m.global_position + Vector3(0, h * 0.45, 0)
		var side: Vector3 = _m.global_transform.basis.x
		_cam.global_position = c + side * maxf(h * 2.4, 3.5) + Vector3(0, h * 0.25, 0) - _m.global_transform.basis.z * h * 0.4
		_cam.look_at(c, Vector3.UP)

	func _shot(tag: String) -> void:
		if shots == "" or _shot_done.has(str(_rec["machine"]) + tag):
			return
		_shot_done[str(_rec["machine"]) + tag] = true
		var img := get_viewport().get_texture().get_image()
		if img:
			img.save_png(shots.path_join("%s_%s.png" % [_rec["machine"], tag.replace(":", "_").replace("(", "_").replace(")", "")]))

	func _ground(p: Vector3) -> float:
		var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 4.0, 0), p - Vector3(0, 8.0, 0), 1)
		var hit := get_viewport().world_3d.direct_space_state.intersect_ray(q)
		return (hit["position"] as Vector3).y if not hit.is_empty() else height(p.x, p.z)

	# ------------------------------------------------------------ machines

	func _next_machine() -> void:
		if is_instance_valid(_m):
			_m.queue_free()
		_m = null
		for g in _ai_group:
			if is_instance_valid(g):
				g.queue_free()
		_ai_group.clear()
		_idx += 1
		if _idx >= types.size():
			_finish()
			return
		var type := str(types[_idx])
		if ai:
			_start_ai(type)
			return
		var meta: Dictionary = {"mock": true}
		if not mock:
			var mm: Dictionary = Content.machine_meta(type)
			if not mm.is_empty():
				meta = mm
		var m: Node = Machine.new()
		m.setup(type, meta)
		m.ai_enabled = false
		add_child(m)
		m.global_position = Vector3(0, height(0, 0) + 0.4, 0)
		m.rotation.y = 0.0
		m.home = m.global_position
		_m = m
		_sk = m.rig.skeleton
		_an = m.rig.animator
		_rec = {"machine": type, "real": not m.rig.is_placeholder, "legs": m.rig.leg_chains.size(), "phases": {},
			"poses": {}, "foot_slide_cm": 0.0, "penetration_cm": 0.0, "float_cm": 0.0}
		_ends.clear()
		_c0.clear()
		_planted.clear()
		_start.clear()
		var to_m: Transform3D = m.global_transform.affine_inverse() * _sk.global_transform
		for ch in m.rig.leg_chains:
			var e: int = (ch as PackedInt32Array)[(ch as PackedInt32Array).size() - 1]
			_ends.append(e)
			_c0.append((to_m * _sk.get_bone_global_rest(e).origin).y)
			_planted.append(false)
			_start.append(Vector3.ZERO)
		_bones.clear()
		if not _ends.is_empty():
			_probe = BoneAttachment3D.new()
			_sk.add_child(_probe)
			_probe.bone_idx = _ends[0]
		_sk.skeleton_updated.connect(_on_skeleton_updated)
		_an.set("debug_measure", true)
		_fwd0 = -m.global_transform.basis.z
		_build_phases()
		_pi = -1
		_enter_next_phase()

	func _calm_state() -> String:
		return "patrol" if _m.archetype == "guard" else "graze"

	func _build_phases() -> void:
		_phases = [
			{"name": "settle", "dur": 1.5},
			{"name": "walk", "dur": 7.0},
			{"name": "stop", "dur": 1.5},
			{"name": "turn", "dur": 3.0},
			{"name": "run", "dur": 4.5},
			{"name": "stop2", "dur": 2.0},
			{"name": "graze", "dur": 5.0},
		]
		for a in _m.attacks:
			_phases.append({"name": "attack:%s(%s)" % [a["id"], a.get("pose", "")], "dur": float(a["windup_s"]) + float(a["active_s"]) + 0.8, "attack": a})
		_phases.append({"name": "hit", "dur": 1.0})
		_phases.append({"name": "death", "dur": 5.0})
		if not only.is_empty():
			_phases = _phases.filter(func(p): return only.has(p["name"]) or p["name"] in ["settle", "death"])

	func _enter_next_phase() -> void:
		if _pi >= 0:
			_close_phase(_phases[_pi])
		_pi += 1
		_pt = 0.0
		if _pi >= _phases.size():
			_close_machine()
			_next_machine()
			return
		var ph: Dictionary = _phases[_pi]
		var name_ := str(ph["name"])
		_rec["phases"][name_] = {"slide_max": 0.0, "pen_max": 0.0, "float_sum": 0.0, "float_n": 0, "swings": [], "frames": 0,
			"disp_max": 0.0, "head_min": INF, "body_min": INF, "clear_min": INF, "motion_last": 0.0, "start_pos": _m.global_position,
			"yaw0": _m.rotation.y}
		var st: Dictionary = _rec["phases"][name_]
		for i in _ends.size():
			st["swings"].append(0)
		_ref_pose.clear()
		var m := _m
		m.drive_face = Vector3.ZERO
		match name_:
			"walk":
				m.drive_dir = _fwd0
				m.drive_speed = m.walk_speed
			"stop", "stop2":
				m.drive_speed = 0.0
				m._set_state("idle")
			"turn":
				m.drive_speed = 0.0
				m.drive_face = m.global_transform.basis.z   # face backwards: 180 deg in place
			"run":
				m.drive_dir = -m.global_transform.basis.z
				m.drive_speed = m.run_speed
				m._set_state("flee" if m.archetype == "herd" else "attack")
			"graze":
				m.drive_speed = 0.0
				m._set_state("scavenge" if m.archetype == "scavenger" else _calm_state())
			"hit":
				m.rig.flinch(true)
			"death":
				m.take_hit("ak47", 1.0e6, "body", true)
		if name_.begins_with("attack:"):
			var a: Dictionary = ph["attack"]
			if m.rig.has_method("play_attack"):
				m.rig.play_attack(a)
			else:
				m.rig.play_pose(str(a.get("pose", "")), float(a["windup_s"]) + float(a["active_s"]))

	# ------------------------------------------------------------ performance

	func _start_perf() -> void:
		var Anim = load("res://machines/machine_animator.gd")
		var ms: Array = []
		for k in perf:
			var type := str(types[k % types.size()])
			var meta: Dictionary = {"mock": true}
			if not mock:
				var mm: Dictionary = Content.machine_meta(type)
				if not mm.is_empty():
					meta = mm
			var m: Node = Machine.new()
			m.setup(type, meta)
			m.site = {"radius": 10.0, "id": "perf"}
			add_child(m)
			var pos := Vector3((k % 6) * 12.0 - 30.0, 0, int(k / 6) * 12.0)
			m.global_position = Vector3(pos.x, height(pos.x, pos.z) + 0.4, pos.z)
			m.home = m.global_position
			ms.append(m)
		if OS.get_environment("BENCH_PERF_CAM") != "":
			# a camera at the edge of the group: machines from ~10 m to ~90 m away (distance LOD active)
			var cam := Camera3D.new()
			add_child(cam)
			cam.global_position = Vector3(0, height(0, -25) + 3.0, -25)
			cam.current = true
		await get_tree().create_timer(3.0).timeout
		Anim.profile = true
		Anim.prof_us = 0
		Anim.prof_calls = 0
		var f0 := Engine.get_process_frames()
		var t0 := Time.get_ticks_usec()
		await get_tree().create_timer(8.0).timeout
		var frames := Engine.get_process_frames() - f0
		var wall := (Time.get_ticks_usec() - t0) / 1000.0
		var us: int = Anim.prof_us
		var calls: int = Anim.prof_calls
		var moving := 0
		for m in ms:
			if m.speed_now() > 0.2:
				moving += 1
		print("PERF %d machines (%s): %d frames in %.0f ms, animator %.3f ms/frame total, %.1f us per machine update (%d calls), %d moving at the end" % [perf,
			",".join(PackedStringArray(types)), frames, wall, us / 1000.0 / maxf(frames, 1), float(us) / maxf(calls, 1), calls, moving])
		print("PERF parts (us total): %s" % str(Anim.prof_parts))
		get_tree().quit(0)

	# ------------------------------------------------------------ AI check

	func _start_ai(type: String) -> void:
		var meta: Dictionary = {"mock": true}
		if not mock:
			var mm: Dictionary = Content.machine_meta(type)
			if not mm.is_empty():
				meta = mm
		var n := clampi(int(Sheets.machine_num(type, "herd_size_min", 1)), 1, 2)
		for k in n:
			var m: Node = Machine.new()
			m.setup(type, meta)
			m.site = {"radius": 15.0, "id": "bench"}
			add_child(m)
			var pos := Vector3(k * 4.0 - 2.0 * (n - 1), 0, 0)
			m.global_position = Vector3(pos.x, height(pos.x, pos.z) + 0.4, pos.z)
			m.rotation.y = PI   # facing +Z, towards the approaching player
			m.home = m.global_position
			_ai_group.append(m)
		for g in _ai_group:
			g.herd = _ai_group
		_fake.global_position = Vector3(0, height(0, 70) + 0.1, 70)
		(_fake as FakePlayer).hits.clear()
		_ai_t = 0.0
		_ai_rec = {"machine": type, "states": [], "attacks": {}, "pings": 0, "pings_inside": 0, "max_proj": 0,
			"burst_max": 0, "others_alerted": false, "archetype": str(_ai_group[0].archetype)}

	func _on_state_changed(m: Node, _old: String, new: String) -> void:
		if not ai or _ai_group.is_empty():
			return
		if m == _ai_group[0]:
			_ai_rec["states"].append(new)
		elif _ai_group.has(m) and new in ["alert", "attack", "flee", "stalk"]:
			_ai_rec["others_alerted"] = true

	func _process_ai(delta: float) -> void:
		_ai_t += delta
		var lead: Node3D = _ai_group[0] if not _ai_group.is_empty() and is_instance_valid(_ai_group[0]) else null
		if lead == null:
			return
		# the stand-in walks towards the machine at 2.5 m/s and stops 4 m away
		var to := lead.global_position - _fake.global_position
		to.y = 0
		if to.length() > 4.0:
			var step := to.normalized() * 2.5 * delta
			var np := _fake.global_position + step
			np.y = height(np.x, np.z) + 0.1
			_fake.global_position = np
		var ca := str(lead.current_attack)
		if ca != "":
			_ai_rec["attacks"][ca] = int(_ai_rec["attacks"].get(ca, 0)) + (1 if str(_ai_rec.get("_last_ca", "")) != ca else 0)
		_ai_rec["_last_ca"] = ca
		var proj := get_tree().get_nodes_in_group("machine_projectiles").size()
		_ai_rec["max_proj"] = maxi(int(_ai_rec["max_proj"]), proj)
		_ai_rec["burst_max"] = maxi(int(_ai_rec["burst_max"]), int(lead.get("_burst_fired")))
		var pings := 0
		var pings_in := 0
		for g in _ai_group:
			if is_instance_valid(g):
				pings += int(g.radar_pings)
				pings_in += int(g.radar_pings_hit)
		_ai_rec["pings"] = pings
		_ai_rec["pings_inside"] = pings_in
		if _ai_t >= 32.0:
			_close_ai()
			_next_machine()

	func _close_ai() -> void:
		var r := _ai_rec
		r.erase("_last_ca")
		var st: Array = r["states"]
		var hits: Array = (_fake as FakePlayer).hits
		var arch := str(r["archetype"])
		var lead: Node = _ai_group[0]
		var want: Array = []
		match arch:
			"guard":
				want = ["alert", "attack"]
			"predator":
				want = ["alert", "stalk", "attack"]
			"scavenger":
				want = ["alert", "attack"]
			"herd":
				want = ["alert", "attack"] if bool(lead.behaviour.get("defend_charge", false)) else ["alert", "flee"]
		var problems: Array = []
		var at := 0
		for w in want:
			var f := st.find(w, at)
			if f < 0:
				problems.append("no %s after %s" % [w, st.slice(0, at)])
				break
			at = f + 1
		if arch != "herd" or bool(lead.behaviour.get("defend_charge", false)):
			if (r["attacks"] as Dictionary).is_empty():
				problems.append("no attack performed")
			if hits.is_empty():
				problems.append("player never hit")
		if arch == "herd" and bool(lead.behaviour.get("defend_charge", false)) and st.has("flee"):
			problems.append("defender fled")
		if arch == "scavenger":
			if int(r["pings_inside"]) < 1:
				problems.append("no radar ping reached the player")
			if (r["attacks"] as Dictionary).has("scrapper_laser_burst") and int(r["burst_max"]) < 2:
				problems.append("laser burst fired %d bolts" % int(r["burst_max"]))
		if _ai_group.size() > 1 and not bool(r["others_alerted"]) and arch != "predator":
			problems.append("second machine never alerted")
		r["hits"] = hits.size()
		r["damage"] = hits.reduce(func(acc, h): return acc + float(h[0]), 0.0)
		r["hit_causes"] = hits.map(func(h): return h[1])
		r["pass"] = problems.is_empty()
		r["problems"] = problems
		results.append(r)
		print("AI %s (%s, %d machines): %s | states %s | attacks %s | hits %d (%.0f HP: %s) | pings %d (inside %d) | burst max %d | pack/herd alerted %s" % [r["machine"], arch, _ai_group.size(),
			"PASS" if r["pass"] else "FAIL " + "; ".join(problems), " > ".join(st), r["attacks"], r["hits"], r["damage"],
			",".join(PackedStringArray(r["hit_causes"])), r["pings"], r["pings_inside"], r["burst_max"], r["others_alerted"]])

	func _process(delta: float) -> void:
		if ai:
			if not _done and not _ai_group.is_empty():
				_process_ai(delta)
			return
		if _done or _m == null or _pi < 0 or _pi >= _phases.size():
			return
		_pt += delta
		if shots != "":
			_update_cam()
			var ph: Dictionary = _phases[_pi]
			var nm := str(ph["name"])
			if nm.begins_with("attack:"):
				var a: Dictionary = ph["attack"]
				if _pt >= float(a["windup_s"]) * 0.95:
					_shot(nm + "_windup")
				if _pt >= float(a["windup_s"]) + float(a["active_s"]) * 0.6:
					_shot(nm + "_active")
			elif nm in ["walk", "run", "turn"]:
				if _pt >= float(ph["dur"]) * 0.6:
					_shot(nm)
				if _pt >= float(ph["dur"]) * 0.6 + 0.12:
					_shot(nm + "_b")
			elif nm == "hit" and _pt >= 0.12:
				_shot(nm)
			elif nm in ["graze", "death", "stop"] and _pt >= float(ph["dur"]) - 0.2:
				_shot(nm)
		if _pt >= float(_phases[_pi]["dur"]):
			_enter_next_phase()

	# ------------------------------------------------------------ measuring

	## Bones that carry the machine: the non-helper bones under the animator's body bone. Reference bones outside it
	## (root/ground at the machine origin, below the terrain by the collision capsule's offset; HZD IK target bones)
	## carry no geometry.
	func _collect_bones() -> void:
		var body: int = _an.get("_body") if _an.get("_body") != null else -1
		if body < 0:
			return
		var stack := [body]
		while not stack.is_empty():
			var b: int = stack.pop_back()
			if not _m.rig.helper_bones.has(b):
				_bones.append(b)
			for c in _sk.get_bone_children(b):
				stack.append(c)

	func _on_skeleton_updated() -> void:
		if _m == null or not is_instance_valid(_m) or _pi < 0 or _pi >= _phases.size():
			return
		if _bones.is_empty():
			_collect_bones()
		var name_ := str(_phases[_pi]["name"])
		var st: Dictionary = _rec["phases"][name_]
		st["frames"] = int(st["frames"]) + 1
		var skx := _sk.global_transform
		var bad := false
		for i in _ends.size():
			var p: Vector3 = skx * _sk.get_bone_global_pose(_ends[i]).origin
			if not p.is_finite():
				bad = true
				continue
			var d := p.y - (_ground(p) + float(_c0[i]))
			var planted := _leg_planted(i)
			if name_ != "death":
				st["pen_max"] = maxf(float(st["pen_max"]), -d)
			if planted:
				if not _planted[i]:
					_start[i] = p
				else:
					var s := Vector2(p.x - (_start[i] as Vector3).x, p.z - (_start[i] as Vector3).z).length()
					if s > 0.03 and OS.get_environment("BENCH_TRACE") != "" and int(st.get("traced", 0)) < 6:
						st["traced"] = int(st.get("traced", 0)) + 1
						var al: Dictionary = _an.get("_legs")[i]
						var dinfo: Dictionary = _an.get("debug_info")
						print("TRACE %s leg %d slide %.3f p %s start %s anim_planted %s cur %s state %s age %.3f | anim end %s frame %s/%s mpos %s now %s over %.3f errmax %s" % [name_, i, s, p, _start[i], al["planted"], al["cur"], al["state"], float(al["age"]),
							dinfo.get("feet", [])[i] if dinfo.has("feet") else "-", dinfo.get("frame", -1), Engine.get_process_frames(), dinfo.get("mpos"), _m.global_position, float(al["over"]), dinfo.get("ik_err_max")])
					st["slide_max"] = maxf(float(st["slide_max"]), s)
				if d > 0.0:
					st["float_sum"] = float(st["float_sum"]) + d
				st["float_n"] = int(st["float_n"]) + 1
			elif _planted[i]:
				st["swings"][i] = int(st["swings"][i]) + 1
			_planted[i] = planted
		if bad:
			st["nan"] = true
		if _probe and _ends.size() > 0:
			var pp: Vector3 = skx * _sk.get_bone_global_pose(_ends[0]).origin
			_rec["probe_diff_cm"] = maxf(float(_rec.get("probe_diff_cm", 0.0)), pp.distance_to(_probe.global_position) * 100.0)
		# head and body heights above the terrain
		var head: int = _m.rig.head_bone
		if head >= 0:
			var hp: Vector3 = skx * _sk.get_bone_global_pose(head).origin
			st["head_min"] = minf(float(st["head_min"]), hp.y - _ground(hp))
			st["head_last"] = hp.y - _ground(hp)
		var bp: Vector3 = _m.aim_point("body")
		st["body_min"] = minf(float(st["body_min"]), bp.y - _ground(bp))
		st["body_last"] = bp.y - _ground(bp)
		# whole-skeleton displacement (machine space) for pose phases, clearance for death
		if name_.begins_with("attack:") or name_ in ["hit", "death", "graze"]:
			var to_m: Transform3D = _m.global_transform.affine_inverse() * skx
			var motion := 0.0
			for b in _bones:
				var lp: Vector3 = to_m * _sk.get_bone_global_pose(b).origin
				if not lp.is_finite():
					st["nan"] = true
					continue
				if not _ref_pose.has(b):
					_ref_pose[b] = lp
				st["disp_max"] = maxf(float(st["disp_max"]), lp.distance_to(_ref_pose[b]))
				if name_ == "death":
					var wp: Vector3 = skx * _sk.get_bone_global_pose(b).origin
					if _pt > float(_phases[_pi]["dur"]) - 1.0 and wp.y - _ground(wp) < float(st["clear_min"]):
						st["clear_min"] = wp.y - _ground(wp)
						st["clear_bone"] = "%d %s" % [b, _sk.get_bone_name(b)]
					if _pt > float(_phases[_pi]["dur"]) - 0.5 and st.has("prev_" + str(b)):
						motion = maxf(motion, wp.distance_to(st["prev_" + str(b)]))
					st["prev_" + str(b)] = wp
			if name_ == "death" and _pt > float(_phases[_pi]["dur"]) - 0.5:
				st["motion_last"] = maxf(float(st["motion_last"]), motion)

	func _leg_planted(i: int) -> bool:
		if _an.has_method("leg_planted"):
			return _an.leg_planted(i)
		var legs: Array = _an.get("_legs")
		if legs == null or i >= legs.size():
			return false
		return not bool(legs[i].get("swing", false))

	func _close_phase(ph: Dictionary) -> void:
		var name_ := str(ph["name"])
		var st: Dictionary = _rec["phases"][name_]
		st["end_pos"] = _m.global_position
		var di: Variant = _an.get("debug_info")
		if di is Dictionary and not (di as Dictionary).is_empty():
			st["debug"] = (di as Dictionary).duplicate()
			(di as Dictionary).clear()
		st["yaw1"] = _m.rotation.y
		for k in st.keys():
			if str(k).begins_with("prev_"):
				st.erase(k)
		if name_ == "stop":
			_stand_head = float(st.get("head_last", 0.0))
		if name_ == "stop2":
			_stand_body = float(st.get("body_last", 0.0))

	func _close_machine() -> void:
		var ph: Dictionary = _rec["phases"]
		if OS.get_environment("BENCH_TRACE") != "" and _an.has_method("debug_dump"):
			print(_an.debug_dump())
		var slide := 0.0
		var pen := 0.0
		var fsum := 0.0
		var fn := 0
		for k in ph:
			var st: Dictionary = ph[k]
			if k in ["walk", "stop", "turn", "run", "stop2", "settle", "graze"] or str(k).begins_with("attack:") or k == "hit":
				slide = maxf(slide, float(st["slide_max"]))
				pen = maxf(pen, float(st["pen_max"]))
				fsum += float(st["float_sum"])
				fn += int(st["float_n"])
		_rec["foot_slide_cm"] = slide * 100.0
		_rec["penetration_cm"] = pen * 100.0
		_rec["float_cm"] = (fsum / maxf(fn, 1)) * 100.0
		var h: float = _m.rig.body_height
		var poses := {}
		for k in ph:
			var st: Dictionary = ph[k]
			var name_ := str(k)
			var res := "ok"
			if st.get("nan", false):
				res = "fail: NaN pose"
			elif name_ in ["walk", "run"]:
				var dist := Vector3(st["end_pos"] - st["start_pos"]).length()
				var minsw := 99
				for s in st["swings"]:
					minsw = mini(minsw, int(s))
				if _ends.is_empty():
					res = "fail: no legs"
				elif minsw < 2:
					res = "fail: a leg stepped %d times" % minsw
				elif dist < 2.0:
					res = "fail: moved %.1f m" % dist
				poses[name_] = res + " (%.1f m, min steps %d)" % [dist, minsw]
				continue
			elif name_ == "turn":
				var turned := absf(wrapf(float(st["yaw1"]) - float(st["yaw0"]), -PI, PI))
				var minsw2 := 99
				for s in st["swings"]:
					minsw2 = mini(minsw2, int(s))
				if rad_to_deg(turned) < 150.0:
					res = "fail: turned %.0f deg" % rad_to_deg(turned)
				elif minsw2 < 1:
					res = "fail: no stepping (min steps %d)" % minsw2
				poses[name_] = res + " (%.0f deg, min steps %d)" % [rad_to_deg(turned), minsw2]
				continue
			elif name_ == "graze":
				var anim: Variant = Sheets.machine(_m.machine_type, "anim")
				var gp := str((anim as Dictionary).get("graze_pose", "none")) if anim is Dictionary else "none"
				var drop := _stand_head - float(st["head_min"])
				if gp != "none" and drop < 0.12 * h:
					res = "fail: head dropped %.2f m" % drop
				elif gp == "none" and float(st["disp_max"]) < 0.03:
					res = "fail: idle does not move"
				poses[name_] = res + " (%s, head drop %.2f m, disp %.2f m)" % [gp, drop, float(st["disp_max"])]
				continue
			elif name_.begins_with("attack:"):
				if float(st["disp_max"]) < maxf(0.06 * h, 0.08):
					res = "fail: moved %.2f m" % float(st["disp_max"])
				poses[name_] = res + " (disp %.2f m)" % float(st["disp_max"])
				continue
			elif name_ == "hit":
				if float(st["disp_max"]) < 0.03:
					res = "fail: moved %.3f m" % float(st["disp_max"])
				poses[name_] = res + " (disp %.2f m)" % float(st["disp_max"])
				continue
			elif name_ == "death":
				var drop2 := _stand_body - float(st.get("body_last", 0.0))
				var clear := float(st["clear_min"])
				if not is_instance_valid(_m) or not _m.is_inside_tree() or not _m.visible:
					res = "fail: vanished"
				elif _stand_body <= 0.0 or is_inf(clear):
					res = "fail: no measurement"
				elif drop2 < 0.25 * _stand_body:
					res = "fail: body dropped only %.2f of %.2f m" % [drop2, _stand_body]
				elif clear < -0.05:
					res = "fail: bone %.0f cm below ground" % (-clear * 100.0)
				elif float(st["motion_last"]) > 0.01:
					res = "fail: not settled (%.3f m/frame)" % float(st["motion_last"])
				poses[name_] = res + " (drop %.2f/%.2f m, lowest bone %.0f cm [%s], settle %.4f m)" % [drop2, _stand_body, clear * 100.0, st.get("clear_bone", "-"), float(st["motion_last"])]
				continue
			else:
				continue
			poses[name_] = res
		_rec["poses"] = poses
		var all_ok := true
		for k in poses:
			if not str(poses[k]).begins_with("ok"):
				all_ok = false
		_rec["poses_ok"] = all_ok
		_rec["pass"] = all_ok and float(_rec["foot_slide_cm"]) < SLIDE_MAX_CM and float(_rec["penetration_cm"]) < PEN_MAX_CM
		var per_phase := []
		for k in ph:
			var st: Dictionary = ph[k]
			per_phase.append("%s slide %.1f pen %.1f" % [k, float(st["slide_max"]) * 100.0, float(st["pen_max"]) * 100.0])
		print("BENCH %s real=%s legs=%d foot_slide_cm=%.1f penetration_cm=%.1f float_cm=%.1f poses=%s pass=%s" % [_rec["machine"],
			_rec["real"], _rec["legs"], _rec["foot_slide_cm"], _rec["penetration_cm"], _rec["float_cm"], "ok" if all_ok else "FAIL", _rec["pass"]])
		print("  phases: " + "; ".join(per_phase.filter(func(s): return not s.contains("slide 0.0 pen 0.0"))))
		for k in poses:
			print("  pose %-22s %s" % [k, poses[k]])
		for k in ph:
			if (ph[k] as Dictionary).has("debug") and float(ph[k]["debug"].get("ik_err_max", 0.0)) > 0.01:
				print("  debug %s: ik_err_max %.3f (%s)" % [k, float(ph[k]["debug"]["ik_err_max"]), ph[k]["debug"].get("ik_err_ctx", "")])
		if _rec.has("probe_diff_cm"):
			print("  probe (signal vs BoneAttachment3D) max diff %.2f cm" % float(_rec["probe_diff_cm"]))
		var clean := _rec.duplicate(true)
		for k in clean["phases"]:
			var st: Dictionary = clean["phases"][k]
			for kk in st.keys():
				if st[kk] is Vector3:
					st[kk] = [st[kk].x, st[kk].y, st[kk].z]
				elif st[kk] is float and is_inf(st[kk]):
					st[kk] = null
		results.append(clean)
		if _sk.skeleton_updated.is_connected(_on_skeleton_updated):
			_sk.skeleton_updated.disconnect(_on_skeleton_updated)

	func _finish() -> void:
		_done = true
		if ai:
			var ok := true
			for r in results:
				ok = ok and bool(r["pass"])
			print("AI RESULT %s" % ("PASS" if ok else "FAIL"))
			get_tree().quit(0 if ok else 1)
			return
		var all_pass := true
		print("BENCH TABLE machine | real | foot_slide_cm | penetration_cm | float_cm | poses")
		for r in results:
			all_pass = all_pass and bool(r["pass"])
			print("BENCH TABLE %s | %s | %.1f | %.1f | %.1f | %s" % [r["machine"], r["real"], r["foot_slide_cm"], r["penetration_cm"],
				r["float_cm"], "all ok" if r["poses_ok"] else "FAIL: " + ", ".join((r["poses"] as Dictionary).keys().filter(func(k): return not str(r["poses"][k]).begins_with("ok")))])
		print("BENCH RESULT %s" % ("PASS" if all_pass else "FAIL"))
		if out_path != "":
			var f := FileAccess.open(out_path, FileAccess.WRITE)
			if f:
				f.store_string(JSON.stringify(results, "  "))
				f.close()
		get_tree().quit(0 if all_pass else 1)


## Stand-in player for --ai (dev only): the methods machines and projectiles call on Game.player.
class FakePlayer extends CharacterBody3D:
	var hits: Array = []

	func _init() -> void:
		name = "BenchPlayer"
		collision_layer = 2
		collision_mask = 0
		var cs := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = 0.4
		cap.height = 1.8
		cs.shape = cap
		cs.position = Vector3(0, 0.9, 0)
		add_child(cs)

	func is_alive() -> bool:
		return true

	func head_position() -> Vector3:
		return global_position + Vector3(0, 1.6, 0)

	func visibility_factor() -> float:
		return 1.0

	func knockback(_v: Vector3) -> void:
		pass

	func apply_damage(dmg: float, _armor_ratio: float, _source: Variant, cause: String) -> void:
		hits.append([dmg, cause])
