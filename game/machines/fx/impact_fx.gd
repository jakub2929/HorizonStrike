extends Node3D
## Pooled impact effects on machines (0.3 S1): sparks + debris at the hit point (systems fx.impact_sparks: normal
## 8 sparks + 2 debris, weak spot 24 + 6 + a flash; at most max_active_emitters at once - when all are busy the
## oldest one is reused) and a 3D impact sound (systems fx.sound_impact_machine, cache cs2/ui/snd/<event>_<n>).
## One shared node under the scene root, created on first use (ImpactFx.spawn). GPU particles: the CPU cost of a
## hit is a restart + a few property writes; stats() reports active emitters and the measured cost per frame.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

const SOUND_VOICES := 8

static var _inst: Node3D = null

var _cfg := {}
var _emitters: Array = []          # [{node, sparks, debris, light, until, born}]
var _voices: Array = []
var _voice_i := 0
var _t := 0.0
var _spawned := 0
var _reused := 0
var _cost_us := 0                  # spent this frame (spawns + process)
var _cost_hist := PackedFloat32Array()
var _cost_ms_avg := 0.0
var _cost_ms_max := 0.0
var _sound_dir := ""


## Spawns the impact at a world point. `normal` points out of the surface (towards the shooter); zero = up.
static func spawn(pos: Vector3, normal: Vector3, weak: bool) -> void:
	var fx := instance()
	if fx:
		fx._spawn(pos, normal, weak)


static func instance() -> Node3D:
	if _inst != null and is_instance_valid(_inst) and _inst.is_inside_tree():
		return _inst
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var n: Node3D = load("res://machines/fx/impact_fx.gd").new()
	n.name = "ImpactFx"
	tree.root.add_child(n)
	_inst = n
	return n


## {active_emitters, max_active_emitters, spawned, reused, cost_ms_avg, cost_ms_max} (averages over the last 60 frames).
static func stats() -> Dictionary:
	var fx: Node3D = _inst if _inst != null and is_instance_valid(_inst) else null
	if fx == null:
		return {"active_emitters": 0, "max_active_emitters": 0, "spawned": 0, "reused": 0, "cost_ms_avg": 0.0, "cost_ms_max": 0.0}
	return fx._stats()


func _ready() -> void:
	var v: Variant = Sheets.sys("fx.impact_sparks")
	_cfg = v if v is Dictionary else {}
	var n := int(_cfg.get("max_active_emitters", 32))
	var weak: Dictionary = _cfg.get("weak", {})
	var spark_max := maxi(int(weak.get("sparks", 24)), int((_cfg.get("normal", {}) as Dictionary).get("sparks", 8)))
	var debris_max := maxi(int(weak.get("debris", 6)), int((_cfg.get("normal", {}) as Dictionary).get("debris", 2)))
	var spark_draw := _spark_mesh()
	var debris_draw := _debris_mesh()
	var spark_mat := _spark_process()
	var debris_mat := _debris_process()
	for i in n:
		var root := Node3D.new()
		root.name = "Emitter%d" % i
		add_child(root)
		var sp := GPUParticles3D.new()
		sp.amount = maxi(spark_max, 1)
		sp.one_shot = true
		sp.explosiveness = 0.95
		sp.emitting = false
		sp.process_material = spark_mat
		sp.draw_pass_1 = spark_draw
		sp.local_coords = false
		sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sp.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
		root.add_child(sp)
		var db := GPUParticles3D.new()
		db.amount = maxi(debris_max, 1)
		db.one_shot = true
		db.explosiveness = 0.9
		db.emitting = false
		db.process_material = debris_mat
		db.draw_pass_1 = debris_draw
		db.local_coords = false
		db.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
		root.add_child(db)
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.65, 0.3)
		light.omni_range = 2.5
		light.light_energy = 0.0
		light.visible = false
		light.shadow_enabled = false
		root.add_child(light)
		_emitters.append({"node": root, "sparks": sp, "debris": db, "light": light, "until": -1.0, "born": -1.0,
			"flash_until": -1.0})
	var maxd := Sheets.sys_num("audio.machine_max_distance_m", 60.0)
	for i in SOUND_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.max_distance = maxd
		p.unit_size = 6.0
		add_child(p)
		_voices.append(p)
	_sound_dir = Game.cache_root.path_join("cs2/ui/snd") if Game.cache_root != "" else ""


func _spawn(pos: Vector3, normal: Vector3, weak: bool) -> void:
	var t0 := Time.get_ticks_usec()
	if _emitters.is_empty():
		return
	var spec: Dictionary = _cfg.get("weak" if weak else "normal", {})
	var weak_spec: Dictionary = _cfg.get("weak", {})
	var life := float(spec.get("lifetime_s", 0.35))
	# a free emitter, else the one that started first
	var pick: Dictionary = {}
	for e in _emitters:
		if float(e["until"]) < _t:
			pick = e
			break
	if pick.is_empty():
		pick = _emitters[0]
		for e in _emitters:
			if float(e["born"]) < float(pick["born"]):
				pick = e
		_reused += 1
	var n: Vector3 = normal.normalized() if normal.length() > 0.001 else Vector3.UP
	var root: Node3D = pick["node"]
	root.global_position = pos
	# particles fly out along +Y of the emitter: turn +Y to the surface normal
	var axis := Vector3.UP.cross(n)
	root.global_basis = Basis(axis.normalized(), Vector3.UP.angle_to(n)) if axis.length() > 0.0001 else (Basis() if n.y > 0.0 else Basis(Vector3.RIGHT, PI))
	var sp: GPUParticles3D = pick["sparks"]
	var db: GPUParticles3D = pick["debris"]
	sp.lifetime = life
	db.lifetime = life * 1.6
	sp.amount_ratio = clampf(float(spec.get("sparks", 8)) / maxf(float(sp.amount), 1.0), 0.0, 1.0)
	db.amount_ratio = clampf(float(spec.get("debris", 2)) / maxf(float(db.amount), 1.0), 0.0, 1.0)
	sp.restart()
	db.restart()
	var light: OmniLight3D = pick["light"]
	if weak and bool(weak_spec.get("flash", true)):
		light.visible = true
		light.light_energy = 3.0
		pick["flash_until"] = _t + 0.08
	else:
		light.visible = false
		pick["flash_until"] = -1.0
	pick["born"] = _t
	pick["until"] = _t + life * 1.6
	_spawned += 1
	_play_sound(pos)
	_cost_us += Time.get_ticks_usec() - t0


func _play_sound(pos: Vector3) -> void:
	if _sound_dir == "":
		return
	var s: AudioStream = SoundLib.random_stream(_sound_dir, Sheets.sys_str("fx.sound_impact_machine", "SolidMetal.BulletImpact"))
	if s == null:
		return
	var p: AudioStreamPlayer3D = _voices[_voice_i]
	_voice_i = (_voice_i + 1) % _voices.size()
	p.stream = s
	p.global_position = pos
	p.pitch_scale = randf_range(0.94, 1.06)
	p.play()


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_t += delta
	for e in _emitters:
		var fu := float(e["flash_until"])
		if fu > 0.0:
			var light: OmniLight3D = e["light"]
			if _t >= fu:
				light.visible = false
				e["flash_until"] = -1.0
			else:
				light.light_energy = 3.0 * clampf((fu - _t) / 0.08, 0.0, 1.0)
	_cost_us += Time.get_ticks_usec() - t0
	_cost_hist.append(_cost_us / 1000.0)
	if _cost_hist.size() > 60:
		_cost_hist.remove_at(0)
	_cost_us = 0
	var s := 0.0
	var mx := 0.0
	for c in _cost_hist:
		s += c
		mx = maxf(mx, c)
	_cost_ms_avg = s / maxf(_cost_hist.size(), 1)
	_cost_ms_max = mx


func _stats() -> Dictionary:
	var active := 0
	for e in _emitters:
		if float(e["until"]) >= _t:
			active += 1
	return {"active_emitters": active, "max_active_emitters": _emitters.size(), "spawned": _spawned, "reused": _reused,
		"cost_ms_avg": _cost_ms_avg, "cost_ms_max": _cost_ms_max}


# ------------------------------------------------------------------ looks (generated, no game assets)

func _spark_mesh() -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2(0.025, 0.12)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.75, 0.35)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.6, 0.2)
	m.emission_energy_multiplier = 4.0
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	q.material = m
	return q


func _debris_mesh() -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(0.035, 0.02, 0.05)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.18, 0.18, 0.2)
	m.metallic = 0.7
	m.roughness = 0.5
	b.material = m
	return b


func _spark_process() -> ParticleProcessMaterial:
	var p := ParticleProcessMaterial.new()
	p.direction = Vector3.UP
	p.spread = 55.0
	p.initial_velocity_min = 3.5
	p.initial_velocity_max = 8.0
	p.gravity = Vector3(0, -9.8, 0)
	p.damping_min = 1.0
	p.damping_max = 3.0
	p.scale_min = 0.6
	p.scale_max = 1.3
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.9, 0.6, 1.0))
	g.set_color(1, Color(1.0, 0.35, 0.05, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	p.color_ramp = gt
	return p


func _debris_process() -> ParticleProcessMaterial:
	var p := ParticleProcessMaterial.new()
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 4.0
	p.gravity = Vector3(0, -9.8, 0)
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.scale_min = 0.6
	p.scale_max = 1.4
	return p
