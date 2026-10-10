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
var _pre_task := -1           # worker loading the other tracks / ambience (_preload_rest)
var _pre_running: Array = [false]
var _pre_out := {}
var _want_mode := ""          # music mode waiting for its track to finish loading


func _ready() -> void:
	_rng.randomize()
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	add_child(_music_a)
	add_child(_music_b)
	_music_b.volume_db = -80.0
	_load_contract()
	_set_mode("explore")
	_preload_rest()


## Every other music track, ambience one-shot and loop is read on a worker now: a mode change or a bird call in
## play must not read a file on the main thread (a stalling disk froze frames). Until a file is in, its mode change
## waits and the one-shot is skipped.
func _preload_rest() -> void:
	var paths: Array = []
	for p in _tracks.values() + _oneshots + _loops.values():
		if not paths.has(p) and not SoundLib.is_loaded(str(p)):
			paths.append(str(p))
	if paths.is_empty():
		return
	var out := {}
	var running: Array = [true]
	_pre_out = out
	_pre_running = running
	_pre_task = WorkerThreadPool.add_task(func():
		for p in paths:
			out[p] = SoundLib.load_uncached(p)
		running[0] = false, false, "audio preload")


func _poll_preload() -> void:
	if _pre_task < 0 or _pre_running[0]:
		return
	WorkerThreadPool.wait_for_task_completion(_pre_task)
	_pre_task = -1
	for p in _pre_out:
		SoundLib.store(str(p), _pre_out[p])
	Log.info("audio: %d music / ambience files preloaded" % _pre_out.size())
	_pre_out = {}
	if _want_mode != "" and _want_mode != _mode:
		var m := _want_mode
		_want_mode = ""
		_set_mode(m)


func _exit_tree() -> void:
	if _pre_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_pre_task)   # never leave a pool task (GDScript lambda) behind
		_pre_task = -1


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
	var wind := ""
	for amb in a.get("ambience", []):
		var f := base.path_join(str(amb.get("file", "")))
		var kind := str(amb.get("kind", ""))
		if kind == "wind":
			if wind == "":
				wind = f
		elif kind == "rain":
			continue   # fixed dry morning: no weather (BRIEF 0.2)
		elif float(amb.get("seconds", 0.0)) > 0.0 and float(amb.get("seconds", 0.0)) < 8.0 and kind != "campfire":
			_oneshots.append(f)
		else:
			_loops[kind] = f
	# mountain wind bed (0.2: ambience kind "wind", decoded from HZD's ATRAC9 by the converter), quiet and looped
	if wind != "":
		var ws := SoundLib.load_stream(wind)
		if ws:
			_loop(ws)
			var wp := AudioStreamPlayer.new()
			wp.name = "Wind"
			wp.stream = ws
			wp.volume_db = -16.0
			add_child(wp)
			wp.play()
			_loops["wind"] = wind
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
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		if w.loop_end <= 0:
			w.loop_end = int(w.get_length() * w.mix_rate)   # whole file (a WAV without loop points)


func _set_mode(mode: String) -> void:
	if mode == _mode:
		return
	if _tracks.has(mode) and _mode != "" and not SoundLib.is_loaded(str(_tracks[mode])):
		_want_mode = mode   # still loading on the worker (_preload_rest): switch when it is in
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
	var t_proc := Time.get_ticks_usec()
	_process_timed(delta)
	load("res://core/frame_stats.gd").note("audio", t_proc)


func _process_timed(delta: float) -> void:
	_poll_preload()
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
		elif m.state in ["suspicious", "alert", "stalk"]:
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
	var pick := str(_oneshots[_rng.randi() % _oneshots.size()])
	if not SoundLib.is_loaded(pick):
		return   # not preloaded yet: skip this one rather than read the file now
	var s := SoundLib.load_stream(pick)
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
