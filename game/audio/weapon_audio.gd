extends Node
## Own-weapon sounds from the cache: cs2/weapons/<id>/snd/<event>_<n>.(wav|mp3) (event = lower-case part after the
## first dot of the CS2 sound event), non-positional (audio.player_weapon_2d). Every viewmodel clip schedules the
## sounds listed for it in cs2/weapons/<id>/anim_events.json ({clip: [{t, event}]}); the gun shot itself comes from
## the weapon's snd_shoot event. Without anim events a fallback list is used; missing files are silent.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")
const Content := preload("res://core/content.gd")

const POOL := 8

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _scheduled: Array = []   # [time, weapon, event]
var _events_json := {}       # weapon -> anim_events dict


func _ready() -> void:
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


static func snd_dir(id: String) -> String:
	return Content.weapon_sound_dir(id)


## "<Prefix>.<Name>" sound event -> file key "<name>" (cache layout snd/<key>_<n>).
static func event_key(sound_event: String) -> String:
	var s := sound_event
	var dot := s.find(".")
	if dot >= 0:
		s = s.substr(dot + 1)
	return s.to_lower()


## Sound keys of the weapon's sheet events (snd_events), in sheet order.
static func sheet_keys(id: String) -> Array:
	var out: Array = []
	var ev: Variant = Sheets.weapon_row(id).get("snd_events", [])
	if typeof(ev) == TYPE_ARRAY:
		for e in ev:
			out.append(event_key(str(e)))
	return out


func _anim_events(id: String) -> Dictionary:
	if _events_json.has(id):
		return _events_json[id]
	var d := {}
	var p := Content.weapon_anim_events(id)
	if p != "":
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(parsed) == TYPE_DICTIONARY:
			d = parsed
	_events_json[id] = d
	return d


## A gameplay event of the current weapon: fire, fire2, draw, reload, inspect, pullpin (viewmodel clips, timed by
## anim_events), plus hit/zoom/zoomout/dry which play the sheet event whose key matches when there is one.
func play_event(id: String, what: String) -> void:
	match what:
		"fire":
			var shoot := str(Sheets.weapon_row(id).get("snd_shoot", "none"))
			if shoot != "none" and shoot != "":
				_play(id, [event_key(shoot)])
			_schedule_clip(id, "fire")
		"hit", "zoom", "zoomout", "dry":
			var keys := sheet_keys(id)
			for k in keys:
				if str(k).ends_with(what):
					_play(id, [k])
					return
		_:
			_schedule_clip(id, what)


func _schedule_clip(id: String, clip: String) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var ev: Dictionary = _anim_events(id)
	if ev.has(clip):
		for e in ev[clip]:
			_scheduled.append([now + float(e.get("t", 0.0)), id, event_key(str(e.get("event", "")))])
		return
	# no clip timing: spread the weapon's sheet events over the clip (reload) or play the first one (draw)
	var keys := sheet_keys(id)
	if keys.is_empty():
		return
	if clip == "draw":
		_play(id, [keys[0]])
	elif clip == "reload":
		var rt := maxf(Sheets.weapon_num(id, "reload_time", 2.0), 0.3)
		var rest := keys.slice(1)
		for i in rest.size():
			_scheduled.append([now + rt * (0.15 + 0.7 * float(i) / maxf(rest.size() - 1, 1)), id, rest[i]])


func _play(id: String, candidates: Array) -> void:
	for c in candidates:
		var stream: AudioStream = SoundLib.random_stream(snd_dir(id), str(c))
		if stream:
			var p := _players[_next]
			_next = (_next + 1) % _players.size()
			p.stream = stream
			p.volume_db = -4.0
			p.play()
			return


## Positional one-shot in the world (grenade explosions, molotov fire): `event` is matched against the weapon's sheet
## event keys (suffix), e.g. "explode" -> the key of BaseGrenade.Explode.
static func play_at(parent: Node, pos: Vector3, id: String, event: String, loop_for_s: float = 0.0) -> void:
	var key := ""
	for k in sheet_keys(id):
		if str(k).ends_with(event):
			key = k
			break
	if key == "":
		return
	var stream: AudioStream = SoundLib.random_stream(snd_dir(id), key)
	if stream == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.max_distance = 120.0
	p.unit_size = 6.0
	parent.add_child(p)
	p.global_position = pos
	p.play()
	var life := maxf(loop_for_s, stream.get_length() + 0.2)
	if loop_for_s > 0.0:
		p.finished.connect(p.play)
	p.get_tree().create_timer(life).timeout.connect(p.queue_free)


func _process(_delta: float) -> void:
	if _scheduled.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for s in _scheduled.duplicate():
		if now >= float(s[0]):
			_scheduled.erase(s)
			_play(str(s[1]), [str(s[2])])


func cancel_scheduled() -> void:
	_scheduled.clear()
