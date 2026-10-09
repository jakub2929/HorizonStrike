extends Node
## Own-weapon sounds from the cache: cs2/weapons/<id>/snd/<event>_<n>.(wav|mp3) (event = lower-case part after the
## first dot of the CS2 sound event), non-positional (audio.player_weapon_2d). Every viewmodel clip schedules the
## sounds listed for it in cs2/weapons/<id>/anim_events.json ({clip: [{t, event}]}); the gun shot itself comes from
## the weapon's snd_shoot event. Without anim events a fallback list is used; missing files are silent.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

const POOL := 8
const FALLBACK := {
	"draw": ["draw", "deploy"], "fire": [], "fire2": ["stab"], "inspect": [], "pullpin": ["pullpin"],
	"reload": ["clipout", "clipin", "boltpull", "boltback", "boltforward", "slideback", "sliderelease"],
}

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
	return Game.cache_root.path_join("cs2/weapons/%s/snd" % id)


## "Weapon_AK47.Single" -> "single"
static func event_key(sound_event: String) -> String:
	var s := sound_event
	var dot := s.find(".")
	if dot >= 0:
		s = s.substr(dot + 1)
	return s.to_lower()


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


## A gameplay event of the current weapon: fire, fire2, draw, reload, inspect, pullpin, hit, zoom, dry.
func play_event(id: String, what: String) -> void:
	var cat := str(Sheets.weapon_row(id).get("category", ""))
	match what:
		"fire":
			if cat != "knife" and cat != "grenade":
				var shoot := str(Sheets.weapon_row(id).get("snd_shoot", "none"))
				_play(id, [event_key(shoot) if shoot != "none" else "single", "single", "silenced"])
			_schedule_clip(id, "fire", ["slash", "throw"] if cat in ["knife", "grenade"] else [])
		"hit":
			_play(id, ["hit"])
		"zoom":
			_play(id, ["zoom"])
		"zoomout":
			_play(id, ["zoomout", "zoom"])
		"dry":
			_play(id, ["dryfire", "empty"])
		_:
			_schedule_clip(id, what, FALLBACK.get(what, []))


func _schedule_clip(id: String, clip: String, fallback: Array) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var ev: Dictionary = _anim_events(id)
	if ev.has(clip):
		for e in ev[clip]:
			_scheduled.append([now + float(e.get("t", 0.0)), id, event_key(str(e.get("event", "")))])
		return
	if fallback.is_empty():
		return
	if clip == "reload":
		var rt := maxf(Sheets.weapon_num(id, "reload_time", 2.0), 0.3)
		var have := SoundLib.events_in(snd_dir(id))
		var used: Array = []
		for s in fallback:
			if have.has(s):
				used.append(s)
		for i in used.size():
			_scheduled.append([now + rt * (0.15 + 0.7 * float(i) / maxf(used.size() - 1, 1)), id, used[i]])
		return
	_play(id, fallback)


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


## Positional one-shot in the world (grenade explosions, molotov fire).
static func play_at(parent: Node, pos: Vector3, id: String, event: String, loop_for_s: float = 0.0) -> void:
	var stream: AudioStream = SoundLib.random_stream(snd_dir(id), event)
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
