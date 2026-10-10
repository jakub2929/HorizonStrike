extends Node
## Own-weapon sounds from the cache: cs2/weapons/<id>/snd/<event>_<n>.(wav|mp3) (event = lower-case part after the
## first dot of the CS2 sound event), non-positional (audio.player_weapon_2d). Every viewmodel clip schedules the
## sounds listed for it in cs2/weapons/<id>/anim_events.json ({clip: [{t, event}]}); the gun shot itself comes from
## the weapon's snd_shoot event. Without anim events a fallback list is used; missing files are silent.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")
const Content := preload("res://core/content.gd")
const Knives := preload("res://core/knives.gd")

const POOL := 8

var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _scheduled: Array = []   # [time, weapon, event]
var _events_json := {}       # weapon -> anim_events dict
var _warmed := {}            # content id -> true: sounds loaded or being loaded


func _ready() -> void:
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)
	Game.weapon_ready.connect(_on_weapon_ready)


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


## Clip timings of what the weapon slot shows (the selected knife model's own anim_events.json for the knife).
func _anim_events(id: String) -> Dictionary:
	var cid := Knives.content_id(id)
	if _events_json.has(cid):
		return _events_json[cid]
	var d := {}
	var p := Content.weapon_anim_events(cid)
	if p != "":
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(parsed) == TYPE_DICTIONARY:
			d = parsed
	_events_json[cid] = d
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
	var cid := Knives.content_id(id)
	for c in candidates:
		# the knife model's own sound first, the weapon's (default knife) when the model has none of that name
		var stream: AudioStream = SoundLib.random_stream(snd_dir(cid), str(c))
		if stream == null and cid != id:
			stream = SoundLib.random_stream(snd_dir(id), str(c))
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
	_poll_snd_tasks()
	if _scheduled.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	for s in _scheduled.duplicate():
		if now >= float(s[0]):
			_scheduled.erase(s)
			_play(str(s[1]), [str(s[2])])


## Loading time: every sound file of the weapon (the knife slot: its model's and the weapon's own) into memory.
func preload_weapon(id: String) -> void:
	var cid := Knives.content_id(id)
	_warmed[cid] = true
	SoundLib.preload_dir(snd_dir(cid))
	if cid != id:
		SoundLib.preload_dir(snd_dir(id))
	_anim_events(id)


var _snd_tasks: Array = []   # [task, out {path: stream}] sounds of weapons converted after the start


## A weapon given in play (bought): its sound files are read on a worker now (once), not from disk at its first shots
## (~4 ms a shot for the first shots of a bought AK-47, 0.3 t24).
func warm(id: String) -> void:
	var cid := Knives.content_id(id)
	if _warmed.has(cid) or not DirAccess.dir_exists_absolute(snd_dir(cid)):
		return   # not converted yet: Game.weapon_ready loads them when it is
	_warmed[cid] = true
	_on_weapon_ready(id)
	_anim_events(id)


## Game.weapon_ready: the weapon's sound files are read on a worker and put into the cache on the main thread.
func _on_weapon_ready(id: String) -> void:
	var dir := snd_dir(Knives.content_id(id))
	var out := {}
	var events := {}
	var t := WorkerThreadPool.add_task(func():
		events.merge(SoundLib.scan_uncached(dir))
		for ev in events.values():
			for p in ev:
				out[str(p)] = SoundLib.load_uncached(str(p)), true, "sounds " + id)
	_snd_tasks.append([t, out, dir, events])


func _poll_snd_tasks() -> void:
	for e in _snd_tasks.duplicate():
		if not WorkerThreadPool.is_task_completed(int(e[0])):
			continue
		WorkerThreadPool.wait_for_task_completion(int(e[0]))
		_snd_tasks.erase(e)
		SoundLib.store_dir(str(e[2]), e[3])
		for p in e[1]:
			SoundLib.store(str(p), e[1][p])


func _exit_tree() -> void:
	for e in _snd_tasks:
		WorkerThreadPool.wait_for_task_completion(int(e[0]))   # never leave a pool task behind
	_snd_tasks.clear()


func cancel_scheduled() -> void:
	_scheduled.clear()
