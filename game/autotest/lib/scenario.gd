extends RefCounted
## Base of every scenario: named checks + data -> {pass, details}. A scenario passes when it ran to the end and
## every check passed. Subclasses implement `_run(ctx)` (may await) and set timeout_s in _init().

var timeout_s := 120.0  # runner watchdog for this scenario

var checks: Array = []
var data := {}
var notes: Array = []
var finished := false


func run(ctx) -> Dictionary:
	var miss0: int = ctx.oracle.missing.size()
	# _run returns a bool when it ends normally (false = stopped after a failed check); a script error aborts it
	# and yields null, which must never count as a pass
	var r: Variant = await _run(ctx)
	finished = r is bool
	if not finished:
		check("scenario ran to the end", false, "aborted by a script error (see engine_errors / log)")
	var miss: Array = ctx.oracle.missing.slice(miss0)
	if not miss.is_empty():
		check("expected values resolved (cache, sheet fallback or default)", false, ", ".join(miss))
	return result()


func _run(_ctx):
	return true


func check(name: String, ok: bool, info: Variant = "") -> bool:
	checks.append({"check": name, "ok": ok, "info": info})
	return ok


func api_check(missing: Array) -> bool:
	## a missing Game API member is a failed check (the scenario cannot test the behaviour without it)
	if missing.is_empty():
		return true
	check("Game API present", false, "missing: " + ", ".join(missing))
	return false


func note(s: String) -> void:
	notes.append(s)


func passed() -> bool:
	if not finished or checks.is_empty():
		return false
	for c in checks:
		if not c.ok:
			return false
	return true


func result() -> Dictionary:
	var failed := []
	for c in checks:
		if not c.ok:
			failed.append(c.check)
	var summary := ""
	if checks.is_empty():
		summary = "no checks ran"
	elif failed.is_empty():
		summary = "all %d checks passed" % checks.size()
	else:
		summary = "failed: " + "; ".join(failed)
	return {"pass": passed(), "details": {"summary": summary, "checks": checks, "data": data, "notes": notes}}
