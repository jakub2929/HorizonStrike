extends RefCounted
## Player files (settings.json, loadout.json, progression.json) are written off the main thread (0.3): a disk that
## stalls (another program copying, a slow drive) must never freeze a frame. write() queues the newest text per path
## (older pending versions of the same file are dropped); a writer thread writes each one atomically (tmp + rename)
## in queue order. Without start() (tools) or after close() writes are synchronous. close() writes what is queued.

const FsUtil := preload("res://core/fsutil.gd")

static var _mutex := Mutex.new()
static var _sem: Semaphore
static var _thread: Thread
static var _order: Array = []      # paths in first-queued order
static var _text := {}             # path -> newest text
static var _stop := false
static var written := 0


static func start() -> void:
	if _thread != null:
		return
	_stop = false
	_sem = Semaphore.new()
	_thread = Thread.new()
	_thread.start(func(): _loop())


## Queues `data` (JSON) for `path`.
static func write_json(path: String, data: Variant) -> void:
	write_text(path, JSON.stringify(data, "  "))


static func write_text(path: String, text: String) -> void:
	_mutex.lock()
	if not _text.has(path):
		_order.append(path)
	_text[path] = text
	var async := _thread != null
	_mutex.unlock()
	if async:
		_sem.post()
	else:
		_drain()


## Writes everything queued and stops the thread (Main at exit).
static func close() -> void:
	if _thread == null:
		_drain()
		return
	_mutex.lock()
	_stop = true
	_mutex.unlock()
	_sem.post()
	_thread.wait_to_finish()
	_thread = null
	_drain()


static func _drain() -> void:
	while true:
		_mutex.lock()
		if _order.is_empty():
			_mutex.unlock()
			return
		var path: String = _order.pop_front()
		var text: String = _text[path]
		_text.erase(path)
		_mutex.unlock()
		_write_atomic(path, text)


static func _write_atomic(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)
	written += 1


static func _loop() -> void:
	while true:
		_sem.wait()
		_drain()
		_mutex.lock()
		var stop := _stop
		_mutex.unlock()
		if stop:
			return
