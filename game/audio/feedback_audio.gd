extends Node
## 2D feedback sounds of hits (0.3 H4, hooks cs2.feedback_sounds): the event names come from the systems rows
## fx.sound_hit, fx.sound_hit_weak, fx.sound_kill_weak, fx.sound_hit_knife, fx.sound_hurt, fx.sound_hurt_armor; the
## files are cache cs2/ui/snd/<key>_<n> with key = the event after its first dot, lower case, dots -> "_" (the cs2
## converter's rule). A missing file is silent.

const Sheets := preload("res://core/sheets.gd")
const SoundLib := preload("res://audio/sound_lib.gd")

const POOL := 6

var played := 0
var last := ""                 # row id of the last sound played
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _hurt_player: AudioStreamPlayer


func _ready() -> void:
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


static func key_of(event: String) -> String:
	var s := event
	var dot := s.find(".")
	if dot >= 0:
		s = s.substr(dot + 1)
	return s.to_lower().replace(".", "_")


## Plays the sound of a systems row (e.g. "fx.sound_hit"); false when the cache has no file for it.
func play_row(row_id: String) -> bool:
	var ev := str(Sheets.sys(row_id)) if Sheets.sys(row_id) != null else ""
	if ev == "":
		return false
	var stream: AudioStream = SoundLib.random_stream(Game.cache_root.path_join("cs2/ui/snd"), key_of(ev))
	if stream == null:
		return false
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.volume_db = -3.0
	p.play()
	played += 1
	last = row_id
	if row_id.begins_with("fx.sound_hurt"):
		_hurt_player = p
	return true


func hurt_playing() -> bool:
	return _hurt_player != null and _hurt_player.playing
