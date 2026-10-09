extends RefCounted
## Game log: %LOCALAPPDATA%/HorizonStrike/logs/latest.log.
## Several instances may run at once (autotest child processes), so the file is opened shared, every write goes to
## the end and every line carries the process id. A fresh session truncates the file unless it was written in the
## last LIVE_WINDOW_S seconds (then another instance is probably running and we append).

const LIVE_WINDOW_S := 120

static var _file: FileAccess
static var _mutex := Mutex.new()
static var _path := ""
static var _pid := 0
static var echo := true


static func open(path: String, allow_truncate: bool = true) -> void:
	_mutex.lock()
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
	_mutex.unlock()


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
	var ms := int(fmod(Time.get_unix_time_from_system(), 1.0) * 1000.0)
	var line := "%s.%03d [%d] [%s] %s" % [Time.get_time_string_from_system(), ms, _pid, level, msg]
	_mutex.lock()
	if _file:
		_file.seek_end()
		_file.store_line(line)
		_file.flush()
	_mutex.unlock()


static func _write(level: String, msg: String) -> void:
	var ms := int(fmod(Time.get_unix_time_from_system(), 1.0) * 1000.0)
	var line := "%s.%03d [%d] [%s] %s" % [Time.get_time_string_from_system(), ms, _pid, level, msg]
	_mutex.lock()
	if _file:
		_file.seek_end()
		_file.store_line(line)
		_file.flush()
	_mutex.unlock()
	if echo:
		print(line)
