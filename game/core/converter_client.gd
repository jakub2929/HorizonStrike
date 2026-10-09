extends Node
## hzsconv serve as a child process, JSON lines over stdio (D12, hooks proto.*). Reader threads never touch the
## scene; the main thread drains the queue in _process and emits event_received. No sockets anywhere.

signal event_received(evt: Dictionary)

const Log := preload("res://core/log.gd")

var pid := 0
var exe := ""
var _pipe: Dictionary = {}
var _io: FileAccess
var _err: FileAccess
var _reader: Thread
var _err_reader: Thread
var _queue: Array = []
var _mutex := Mutex.new()
var _next_id := 1
var _running := false
var _exited := false


## Starts `exe args`; returns "" on success or an error message.
func start(exe_path: String, args: PackedStringArray) -> String:
	exe = exe_path
	if not FileAccess.file_exists(exe_path):
		return "converter not found: %s" % exe_path
	_pipe = OS.execute_with_pipe(exe_path, args, true)
	if _pipe.is_empty() or not _pipe.has("stdio"):
		return "could not start converter: %s" % exe_path
	_io = _pipe["stdio"]
	_err = _pipe.get("stderr")
	pid = int(_pipe.get("pid", 0))
	_running = true
	Log.info("converter started pid=%d: %s %s" % [pid, exe_path, " ".join(args)])
	_reader = Thread.new()
	_reader.start(_read_stdout)
	if _err:
		_err_reader = Thread.new()
		_err_reader.start(_read_stderr)
	return ""


func is_running() -> bool:
	return _running and not _exited


## Sends one request; assigns an id when missing. Returns the id.
func send(req: Dictionary) -> int:
	if not req.has("id"):
		req["id"] = _next_id
		_next_id += 1
	if _io == null or _exited:
		Log.warn("converter not running, dropped %s" % JSON.stringify(req))
		return int(req["id"])
	_io.store_line(JSON.stringify(req))
	_io.flush()
	return int(req["id"])


func _read_stdout() -> void:
	while true:
		var line := _io.get_line()
		if line == "" and _io.get_error() != OK:
			break
		line = line.strip_edges()
		if line == "":
			continue
		var parsed = JSON.parse_string(line)
		_mutex.lock()
		if typeof(parsed) == TYPE_DICTIONARY:
			_queue.append(parsed)
		else:
			_queue.append({"event": "log", "level": "warn", "message": "non-JSON converter output: " + line})
		_mutex.unlock()
	_mutex.lock()
	_queue.append({"event": "exit"})
	_mutex.unlock()


func _read_stderr() -> void:
	while true:
		var line := _err.get_line()
		if line == "" and _err.get_error() != OK:
			break
		if line.strip_edges() != "":
			Log.info("conv stderr: " + line.strip_edges())


func _process(_delta: float) -> void:
	if _queue.is_empty():
		return
	_mutex.lock()
	var batch := _queue.duplicate()
	_queue.clear()
	_mutex.unlock()
	for evt in batch:
		var e: Dictionary = evt
		match str(e.get("event", "")):
			"log":
				Log.info("conv %s: %s" % [e.get("level", "info"), e.get("message", "")])
			"exit":
				_exited = true
				_running = false
				Log.info("converter exited pid=%d" % pid)
		event_received.emit(e)


## Asks the server to quit, then makes sure the process is gone (kill by exact PID) and joins the threads.
func stop() -> void:
	if pid == 0:
		return
	if not _exited and _io:
		_io.store_line(JSON.stringify({"id": _next_id, "op": "quit"}))
		_io.flush()
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(pid) and Time.get_ticks_msec() - t0 < 3000:
			OS.delay_msec(20)
		if OS.is_process_running(pid):
			Log.warn("converter did not quit, killing pid=%d" % pid)
			OS.kill(pid)
	if _reader and _reader.is_started():
		_reader.wait_to_finish()
	if _err_reader and _err_reader.is_started():
		_err_reader.wait_to_finish()
	_running = false
	_exited = true
	pid = 0


func _exit_tree() -> void:
	stop()
