extends Node
## hzsconv serve as a child process, JSON lines over stdio (D12, hooks proto.*). Reader threads never touch the
## scene; the main thread drains the queue in _process and emits event_received. No sockets anywhere.

signal event_received(evt: Dictionary)

const Log := preload("res://core/log.gd")

var pid := 0
var exe := ""
var started_unix := 0.0   # when this converter process was started (it remembers every mesh it exported since)
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
var _stopped := false   # stop() ran: the process exit is expected, no "exit" event for listeners


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
	started_unix = Time.get_unix_time_from_system()
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
	if _stopped:
		return
	# the reader thread appends under the mutex (an unlocked size check can read a buffer being reallocated)
	_mutex.lock()
	if _queue.is_empty():
		_mutex.unlock()
		return
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


## Asks the server to quit, then makes sure the process is gone (kill by exact PID) and joins the threads. Bounded:
## returns within ~6 s whatever the converter does (every quit path calls this before the engine shuts down).
func stop() -> void:
	if pid == 0:
		return
	_stopped = true
	var t0 := Time.get_ticks_msec()
	if OS.is_process_running(pid):
		if not _exited and _io:
			_io.store_line(JSON.stringify({"id": _next_id, "op": "quit"}))
			_io.flush()
		while OS.is_process_running(pid) and Time.get_ticks_msec() - t0 < 3000:
			OS.delay_msec(20)
		if OS.is_process_running(pid):
			Log.warn("converter did not quit within 3 s, killing pid=%d" % pid)
			OS.kill(pid)
			var t1 := Time.get_ticks_msec()
			while OS.is_process_running(pid) and Time.get_ticks_msec() - t1 < 1000:
				OS.delay_msec(20)
	# the readers end at EOF once the process is gone; never block the quit on them
	_join(_reader, 1000)
	_join(_err_reader, 1000)
	Log.info("converter stopped pid=%d (%d ms)" % [pid, Time.get_ticks_msec() - t0])
	_running = false
	_exited = true
	pid = 0


func _join(t: Thread, ms: int) -> void:
	if t == null or not t.is_started():
		return
	var t0 := Time.get_ticks_msec()
	while t.is_alive() and Time.get_ticks_msec() - t0 < ms:
		OS.delay_msec(10)
	if t.is_alive():
		Log.warn("converter reader still blocked after %d ms, not waiting for it" % ms)
		return
	t.wait_to_finish()


func _exit_tree() -> void:
	stop()
