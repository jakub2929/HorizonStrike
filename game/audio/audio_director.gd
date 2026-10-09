extends Node
## Horizon music and ambience from the cache (hzd/audio/music/*.mp3, hzd/audio/ambience/*): exploration music with
## ambience, switching to combat music when any machine is in attack state within 80 m of the player
## (audio.music_combat_trigger), crossfading over audio.music_crossfade_s. Logs "music: combat" / "music: explore".

const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

const COMBAT_RANGE_M := 80.0

var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _amb: AudioStreamPlayer
var _mode := ""
var _explore: Array = []
var _combat: Array = []
var _ambience: Array = []
var _fade := 0.0
var _check := 0.0
var _calm_t := 0.0


func _ready() -> void:
	_music_a = AudioStreamPlayer.new()
	_music_b = AudioStreamPlayer.new()
	_amb = AudioStreamPlayer.new()
	for p in [_music_a, _music_b, _amb]:
		add_child(p)
	_music_b.volume_db = -80.0
	_scan()
	_set_mode("explore")


func _scan() -> void:
	var mdir := Game.cache_root.path_join("hzd/audio/music")
	var d := DirAccess.open(mdir)
	if d:
		for f in d.get_files():
			if f.get_extension().to_lower() not in ["mp3", "ogg", "wav"]:
				continue
			var low := f.to_lower()
			if low.contains("combat") or low.contains("fight") or low.contains("battle") or low.contains("danger"):
				_combat.append(mdir.path_join(f))
			else:
				_explore.append(mdir.path_join(f))
	var adir := Game.cache_root.path_join("hzd/audio/ambience")
	var a := DirAccess.open(adir)
	if a:
		for f in a.get_files():
			if f.get_extension().to_lower() in ["mp3", "ogg", "wav"]:
				_ambience.append(adir.path_join(f))
	var explore_pref := Sheets.sys_str("audio.music_explore_track", "")
	if explore_pref != "" and not Sheets.is_unfilled(explore_pref):
		_explore.sort_custom(func(x, _y): return str(x).contains(explore_pref))
	if _combat.is_empty() and _explore.size() > 1:
		_combat.append(_explore.pop_back())
	Log.info("audio: %d explore, %d combat, %d ambience tracks" % [_explore.size(), _combat.size(), _ambience.size()])
	if not _ambience.is_empty():
		var s := SoundLib.load_stream(_ambience[0])
		if s:
			_loop(s)
			_amb.stream = s
			_amb.volume_db = -10.0
			_amb.play()


func _loop(s: AudioStream) -> void:
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
	var list := _combat if mode == "combat" else _explore
	if list.is_empty():
		return
	var s := SoundLib.load_stream(list[randi() % list.size()])
	if s == null:
		return
	_loop(s)
	# crossfade: b takes the new track, a fades out
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
		_music_a.volume_db = linear_to_db(maxf(k, 0.0001)) - 6.0
		_music_b.volume_db = linear_to_db(maxf(1.0 - k, 0.0001)) - 6.0
		if _fade <= 0.0:
			_music_b.stop()
	_check -= delta
	if _check > 0.0:
		return
	_check = 0.5
	var p: Node3D = Game.player
	if p == null:
		return
	var fighting := false
	for m in Game.machines:
		if is_instance_valid(m) and m.state == "attack" and m.global_position.distance_to(p.global_position) <= COMBAT_RANGE_M:
			fighting = true
			break
	if fighting:
		_calm_t = 0.0
		_set_mode("combat")
	else:
		_calm_t += 0.5
		if _mode == "combat" and _calm_t > 8.0:
			_set_mode("explore")
