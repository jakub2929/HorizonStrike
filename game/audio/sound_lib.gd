extends RefCounted
## Runtime sound loading from the cache: <dir>/<event>_<n>.(wav|mp3|ogg) -> AudioStream (AudioStreamWAV/MP3/
## OggVorbis.load_from_file), cached for the session. Thread-unsafe by design (main thread only).

static var _dirs := {}      # dir -> {event: [paths]}
static var _streams := {}   # path -> AudioStream (null = failed)
static var _rng := RandomNumberGenerator.new()


static func events_in(dir: String) -> Dictionary:
	if _dirs.has(dir):
		return _dirs[dir]
	var out := {}
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			var ext := f.get_extension().to_lower()
			if ext not in ["wav", "mp3", "ogg"]:
				continue
			var base := f.get_basename()
			var key := base
			var us := base.rfind("_")
			if us > 0 and base.substr(us + 1).is_valid_int():
				key = base.substr(0, us)
			key = key.to_lower()
			if not out.has(key):
				out[key] = []
			out[key].append(dir.path_join(f))
	_dirs[dir] = out
	return out


static func load_stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var s: AudioStream = null
	match path.get_extension().to_lower():
		"wav":
			s = AudioStreamWAV.load_from_file(path)
		"mp3":
			s = AudioStreamMP3.load_from_file(path)
		"ogg":
			s = AudioStreamOggVorbis.load_from_file(path)
	_streams[path] = s
	return s


static func random_stream(dir: String, event: String) -> AudioStream:
	var ev: Dictionary = events_in(dir)
	var list: Array = ev.get(event.to_lower(), [])
	if list.is_empty():
		return null
	return load_stream(str(list[_rng.randi_range(0, list.size() - 1)]))


## Loads every variant of an event now (loading screen), so the first play in a fight reads nothing from disk.
static func preload_event(dir: String, event: String) -> int:
	var n := 0
	for p in events_in(dir).get(event.to_lower(), []):
		if load_stream(str(p)) != null:
			n += 1
	return n


## Loads every sound of a folder now (loading screen).
static func preload_dir(dir: String) -> int:
	var n := 0
	for ev in events_in(dir):
		n += preload_event(dir, str(ev))
	return n


## Worker-safe load into a caller-owned dict (no shared cache touched); the main thread then calls store().
static func load_uncached(path: String) -> AudioStream:
	match path.get_extension().to_lower():
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
	return null


## Main thread: puts a stream loaded on a worker into the cache.
static func store(path: String, s: AudioStream) -> void:
	if not _streams.has(path):
		_streams[path] = s


static func is_loaded(path: String) -> bool:
	return _streams.has(path)


static func forget_dir(dir: String) -> void:
	_dirs.erase(dir)
