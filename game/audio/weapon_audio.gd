extends Node
## Own-weapon sounds from the cache: cs2/weapons/<id>/snd/<event>_<n>.(wav|mp3), non-positional
## (audio.player_weapon_2d). Reload sounds follow cs2/weapons/<id>/anim_events.json ({clip: [{t, event}]}) when
## present, else they are spread over the reload time. Missing files are simply silent.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

const POOL := 6

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _scheduled: Array = []   # [time, weapon, event]
var _events_json := {}       # weapon -> anim_events dict


func _ready() -> void:
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)


func _dir(id: String) -> String:
	return Game.cache_root.path_join("cs2/weapons/%s/snd" % id)


func _fire_event(id: String) -> String:
	var s := str(Sheets.weapon_row(id).get("snd_shoot", "none"))
	if s == "none" or s == "":
		return "fire"
	return s.get_extension().to_lower() if s.contains(".") else s.to_lower()


func _anim_events(id: String) -> Dictionary:
	if _events_json.has(id):
		return _events_json[id]
	var d := {}
	var p := Game.cache_root.path_join("cs2/weapons/%s/anim_events.json" % id)
	if FileAccess.file_exists(p):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(parsed) == TYPE_DICTIONARY:
			d = parsed
	_events_json[id] = d
	return d


func play_event(id: String, what: String) -> void:
	match what:
		"fire":
			var cat := str(Sheets.weapon_row(id).get("category", ""))
			if cat == "knife":
				_play(id, ["slash", "slash1", "swing"])
			else:
				_play(id, [_fire_event(id), "single", "silenced", "fire", "shoot"])
		"draw":
			_play(id, ["draw", "deploy"])
		"hit":
			_play(id, ["hit", "hit1", "stab"])
		"throw":
			_play(id, ["throw"])
		"zoom":
			_play(id, ["zoom"])
		"dry":
			_play(id, ["dryfire", "empty"])
		"reload":
			_schedule_clip(id, "reload")


func _schedule_clip(id: String, clip: String) -> void:
	var ev: Dictionary = _anim_events(id)
	var now := Time.get_ticks_msec() / 1000.0
	var list: Array = ev.get(clip, [])
	if not list.is_empty():
		for e in list:
			var ev_name := str(e.get("event", ""))
			_scheduled.append([now + float(e.get("t", 0.0)), id, _event_key(ev_name)])
		return
	# fallback: generic reload sequence spread over the reload time
	var rt := maxf(Sheets.weapon_num(id, "reload_time", 2.0), 0.3)
	var seq := ["clipout", "clipin", "boltpull", "boltback", "boltforward", "slideback", "sliderelease", "slideforward", "insertshell", "pump"]
	var have := SoundLib.events_in(_dir(id))
	var used: Array = []
	for s in seq:
		if have.has(s):
			used.append(s)
	for i in used.size():
		_scheduled.append([now + rt * (0.15 + 0.7 * float(i) / maxf(used.size() - 1, 1)), id, used[i]])


static func _event_key(sound_event: String) -> String:
	# "Weapon_AK47.Clipout" -> "clipout"
	var s := sound_event
	if s.contains("."):
		s = s.get_extension()
	return s.to_lower()


func _play(id: String, candidates: Array) -> void:
	for c in candidates:
		var stream: AudioStream = SoundLib.random_stream(_dir(id), str(c))
		if stream:
			var p := _players[_next]
			_next = (_next + 1) % _players.size()
			p.stream = stream
			p.volume_db = -4.0
			p.play()
			return


func _process(_delta: float) -> void:
	if _scheduled.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for s in _scheduled.duplicate():
		if now >= float(s[0]):
			_scheduled.erase(s)
			_play(str(s[1]), [str(s[2])])
