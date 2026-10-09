extends Node
## Horizon music and ambience driven by the cache's audio contract hzd/audio/audio.json:
## {music: {key: {file}}, music_explore, music_combat, music_sneak?, ambience: [{file, kind, seconds}]}.
## Exploration music plays by default; combat music when any machine is in attack state within 80 m of the player
## (audio.music_combat_trigger), crossfading over audio.music_crossfade_s. Ambience: one-shot sounds of kind
## "birds" around the player; loops of kind "campfire" at loaded campfires. Logs "music: combat" / "music: explore".

const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")
const SoundLib := preload("res://audio/sound_lib.gd")
const FsUtil := preload("res://core/fsutil.gd")

const COMBAT_RANGE_M := 80.0

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _mode := ""
var _tracks := {}          # mode -> absolute file
var _oneshots: Array = []  # ambience files to scatter around the player
var _loops := {}           # kind -> file (attached to world objects, e.g. campfires)
var _fade := 0.0
var _check := 0.0
var _calm_t := 0.0
var _amb_t := 3.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	add_child(_music_a)
	add_child(_music_b)
	_music_b.volume_db = -80.0
	_load_contract()
	_set_mode("explore")


func _load_contract() -> void:
	var base := Game.cache_root.path_join("hzd/audio")
	var a = FsUtil.read_json(base.path_join("audio.json"))
	if typeof(a) != TYPE_DICTIONARY:
		Log.info("audio: no hzd/audio/audio.json, music off")
		return
	var music: Dictionary = a.get("music", {})
	for mode in ["explore", "combat", "sneak"]:
		var key := str(a.get("music_" + mode, ""))
		if music.has(key):
			_tracks[mode] = base.path_join(str(music[key].get("file", "")))
	for amb in a.get("ambience", []):
		var f := base.path_join(str(amb.get("file", "")))
		var kind := str(amb.get("kind", ""))
		if float(amb.get("seconds", 0.0)) > 0.0 and float(amb.get("seconds", 0.0)) < 8.0 and kind != "campfire":
			_oneshots.append(f)
		else:
			_loops[kind] = f
	Log.info("audio: music %s, %d ambience one-shots, loops %s" % [_tracks.keys(), _oneshots.size(), _loops.keys()])


## Loop file for a kind of world object (e.g. "campfire"), or "".
func loop_for(kind: String) -> String:
	return str(_loops.get(kind, ""))


static func _loop(s: AudioStream) -> void:
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	elif s is AudioStreamWAV:
		(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD


func _set_mode(mode: String) -> void:
	if mode == _mode:
		return
	_mode = mode
	Log.info("music: %s" % mode)
	if not _tracks.has(mode):
		return
	var s := SoundLib.load_stream(_tracks[mode])
	if s == null:
		return
	_loop(s)
	var tmp := _music_a
	_music_a = _music_b
	_music_b = tmp
	_music_a.stream = s
	_music_a.volume_db = -80.0
	_music_a.play()
	_fade = maxf(Sheets.sys_num("audio.music_crossfade_s", 2.0), 0.05)


func _process(delta: float) -> void:
	if _fade > 0.0:
		var total := maxf(Sheets.sys_num("audio.music_crossfade_s", 2.0), 0.05)
		_fade = maxf(_fade - delta, 0.0)
		var k := 1.0 - _fade / total
		_music_a.volume_db = linear_to_db(maxf(k, 0.0001)) - 8.0
		_music_b.volume_db = linear_to_db(maxf(1.0 - k, 0.0001)) - 8.0
		if _fade <= 0.0:
			_music_b.stop()
	var p: Node3D = Game.player
	if p == null:
		return
	_ambience(delta, p)
	_check -= delta
	if _check > 0.0:
		return
	_check = 0.5
	var fighting := false
	var wary := false
	for m in Game.machines:
		if not is_instance_valid(m) or m.global_position.distance_to(p.global_position) > COMBAT_RANGE_M:
			continue
		if m.state == "attack":
			fighting = true
		elif m.state in ["suspicious", "alert"]:
			wary = true
	if fighting:
		_calm_t = 0.0
		_set_mode("combat")
	else:
		_calm_t += 0.5
		if _mode == "combat" and _calm_t > 8.0 or _mode != "combat":
			_set_mode("sneak" if wary and _tracks.has("sneak") else "explore")


func _ambience(delta: float, p: Node3D) -> void:
	if _oneshots.is_empty():
		return
	_amb_t -= delta
	if _amb_t > 0.0:
		return
	_amb_t = _rng.randf_range(3.0, 9.0)
	var s := SoundLib.load_stream(_oneshots[_rng.randi() % _oneshots.size()])
	if s == null:
		return
	var a := AudioStreamPlayer3D.new()
	a.stream = s
	a.unit_size = 12.0
	a.max_distance = 80.0
	a.volume_db = -6.0
	add_child(a)
	var ang := _rng.randf() * TAU
	a.global_position = p.global_position + Vector3(cos(ang) * 18.0, 6.0, sin(ang) * 18.0)
	a.play()
	a.finished.connect(a.queue_free)
