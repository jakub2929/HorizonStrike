extends RefCounted
## Game log: %LOCALAPPDATA%/HorizonStrike/logs/latest.log.
## Several instances may run at once (autotest child processes), so the file is opened shared, every write goes to
## the end and every line carries the process id. A fresh session truncates the file unless it was written in the
## last LIVE_WINDOW_S seconds (then another instance is probably running and we append).
## Writing never blocks the caller: lines are queued and a writer thread appends, flushes and echoes them every
## FLUSH_MS (a synchronous write + flush on the main thread was a 100 ms frame while the converter kept the disk
## busy). close() drains the queue and stops the thread (Main at exit, World before it ends a stuck process);
## without open() or after close() every write is synchronous again.

const LIVE_WINDOW_S := 120
const FLUSH_MS := 25

static var _file: FileAccess
static var _mutex := Mutex.new()      # guards the queues and _stop
static var _io_mutex := Mutex.new()   # one drain at a time, in queue order
static var _lines := PackedStringArray()        # waiting for the file
static var _echo_lines := PackedStringArray()   # waiting for stdout
static var _thread: Thread
static var _stop := false
static var _path := ""
static var _pid := 0
static var echo := true


static func open(path: String, allow_truncate: bool = true) -> void:
	_io_mutex.lock()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fresh := not FileAccess.file_exists(path)
	if not fresh and allow_truncate:
		var age := Time.get_unix_time_from_system() - FileAccess.get_modified_time(path)
		fresh = age > LIVE_WINDOW_S
	if fresh:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.close()
	_file = FileAccess.open(path, FileAccess.READ_WRITE)
	_path = path
	_pid = OS.get_process_id()
	_io_mutex.unlock()
	if _thread == null:
		_stop = false
		_thread = Thread.new()
		_thread.start(func(): _writer_loop())


static func path() -> String:
	return _path


static func info(msg: String) -> void:
	_write("info", msg)


static func warn(msg: String) -> void:
	_write("warn", msg)


static func error(msg: String) -> void:
	_write("error", msg)


## For the engine logger: written to the file only (no print, which would loop back into the logger).
static func write_raw(level: String, msg: String) -> void:
	_queue(_format(level, msg), false)


## Writes everything queued so far (on the caller's thread).
static func flush() -> void:
	_drain()


## Stops the writer thread after it wrote everything queued; later lines are written synchronously.
static func close() -> void:
	_mutex.lock()
	var t := _thread
	_stop = true
	_mutex.unlock()
	if t:
		t.wait_to_finish()
	_mutex.lock()
	_thread = null
	_mutex.unlock()
	_drain()


static func _write(level: String, msg: String) -> void:
	_queue(_format(level, msg), echo)


static func _format(level: String, msg: String) -> String:
	var ms := int(fmod(Time.get_unix_time_from_system(), 1.0) * 1000.0)
	return "%s.%03d [%d] [%s] %s" % [Time.get_time_string_from_system(), ms, _pid, level, msg]


static func _queue(line: String, to_stdout: bool) -> void:
	_mutex.lock()
	_lines.append(line)
	if to_stdout:
		_echo_lines.append(line)
	var async := _thread != null
	_mutex.unlock()
	if not async:
		_drain()


static func _drain() -> void:
	_io_mutex.lock()
	_mutex.lock()
	var lines := _lines
	var out := _echo_lines
	_lines = PackedStringArray()
	_echo_lines = PackedStringArray()
	_mutex.unlock()
	if _file and not lines.is_empty():
		_file.seek_end()
		_file.store_string("\n".join(lines) + "\n")
		_file.flush()
	for line in out:
		print(line)
	_io_mutex.unlock()


static func _writer_loop() -> void:
	while true:
		OS.delay_msec(FLUSH_MS)
		_drain()
		_mutex.lock()
		var stop := _stop
		_mutex.unlock()
		if stop:
			return
