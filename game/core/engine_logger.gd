extends Logger
## Mirrors engine errors and warnings (e.g. physics/Jolt, rendering, script errors) into latest.log so a run's log
## shows them next to the game's own lines. Called from any thread; core/log.gd is mutex-protected.

const Log := preload("res://core/log.gd")


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	var kind := "engine warning" if error_type == ERROR_TYPE_WARNING else "engine error"
	var msg := rationale if rationale != "" else code
	Log.write_raw("warn" if error_type == ERROR_TYPE_WARNING else "error", "%s: %s (%s:%d %s)" % [kind, msg, file.get_file(), line, function])


func _log_message(_message: String, _error: bool) -> void:
	pass
