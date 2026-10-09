extends Node3D
## Horizon machine sounds from the cache: hzd/machines/<id>/snd/<role>_<n>.(wav|mp3|ogg), roles from the machines
## sheet (idle, scan, graze, suspicious, alert, attack, hit, death, footstep). Positional, audible up to
## audio.machine_max_distance_m. Missing files are silent.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

var machine: Node3D
var _dir := ""
var _voice: AudioStreamPlayer3D
var _steps: AudioStreamPlayer3D
var _calm_t := 0.0
var _step_acc := 0.0
var _rng := RandomNumberGenerator.new()


func setup(m: Node3D) -> void:
	machine = m
	_dir = Game.cache_root.path_join("hzd/machines/%s/snd" % m.machine_type)
	var maxd := Sheets.sys_num("audio.machine_max_distance_m", 60.0)
	_voice = AudioStreamPlayer3D.new()
	_steps = AudioStreamPlayer3D.new()
	for p in [_voice, _steps]:
		p.max_distance = maxd
		p.unit_size = 8.0
		add_child(p)
	_steps.volume_db = -8.0
	_rng.randomize()
	_calm_t = _rng.randf_range(2.0, 8.0)


func play_role(role: String) -> void:
	_play(_voice, role)


func _play(p: AudioStreamPlayer3D, role: String) -> bool:
	var s: AudioStream = SoundLib.random_stream(_dir, role)
	if s == null:
		return false
	p.stream = s
	p.pitch_scale = _rng.randf_range(0.95, 1.05)
	p.play()
	return true


func on_state(s: String) -> void:
	match s:
		"suspicious", "alert", "attack", "death":
			play_role(s)
		"dead":
			play_role("death")
		"flee":
			play_role("alert")


func _process(delta: float) -> void:
	if machine == null or machine.state == "dead":
		return
	# footsteps by distance walked (two steps per stride)
	var spd: float = machine.speed_now()
	_step_acc += spd * delta
	var half_stride := Sheets.machine_num(machine.machine_type, "stride_m", 1.6) * 0.5
	if _step_acc >= half_stride:
		_step_acc = 0.0
		_play(_steps, "footstep")
	# calm chatter: idle/scan for guards, graze for herds
	if machine.state in ["idle", "patrol", "graze"]:
		_calm_t -= delta
		if _calm_t <= 0.0:
			_calm_t = _rng.randf_range(5.0, 12.0)
			var role := "idle"
			if machine.state == "patrol" and _rng.randf() < 0.6:
				role = "scan"
			elif machine.state == "graze" and _rng.randf() < 0.6:
				role = "graze"
			if not _voice.playing:
				if not _play(_voice, role):
					_play(_voice, "idle")
