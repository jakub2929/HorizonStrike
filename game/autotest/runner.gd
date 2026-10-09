extends Node
## Horizon Strike autotest runner (owner: test). The boot code instances this node when --autotest is on the command
## line. It drives the game only through the Game API (docs/ARCHITECTURE.md), writes <out>/results.json =
## [{id, name, pass, details}], saves screenshots through the game's own viewport and quits with exit code 0 when
## every requested scenario passed, else 1. Scenario rows (order, child process args): sheets/autotest.json.
##   HorizonStrike.exe --game <cs2> --autotest [t01,t03,...] [--out <dir>]
##   dev: Godot --path game -- --game <cs2> --autotest ... (children get "--path game --" automatically)

const Args := preload("res://autotest/lib/args.gd")
const Ctx := preload("res://autotest/lib/ctx.gd")
const Oracle := preload("res://autotest/lib/oracle.gd")
const Proc := preload("res://autotest/lib/proc.gd")

const SCENARIOS := {
	"t01": preload("res://autotest/scenarios/t01_start_loadout.gd"),
	"t02": preload("res://autotest/scenarios/t02_kill_reward.gd"),
	"t03": preload("res://autotest/scenarios/t03_buy.gd"),
	"t04": preload("res://autotest/scenarios/t04_weak_spot.gd"),
	"t05": preload("res://autotest/scenarios/t05_watcher_alert.gd"),
	"t06": preload("res://autotest/scenarios/t06_herd_flee.gd"),
	"t07": preload("res://autotest/scenarios/t07_death_respawn.gd"),
	"t08": preload("res://autotest/scenarios/t08_missing_hzd.gd"),
	"t09": preload("res://autotest/scenarios/t09_first_launch.gd"),
	"t10": preload("res://autotest/scenarios/t10_cache_cap.gd"),
	"t11": preload("res://autotest/scenarios/t11_no_listener.gd"),
	"s01": preload("res://autotest/scenarios/s01_buy_wheel.gd"),
	"s03": preload("res://autotest/scenarios/s03_herd_landscape.gd"),
}
## rows produced inside another scenario's run (sheet: s02 "taken inside t05")
const HOSTED := {"s02": "t05"}
## set for child processes so they run their scenarios in-process (the command line stays as in the sheet)
const CHILD_ENV := "HZS_AUTOTEST_CHILD"
const CHILD_TIMEOUT_S := {"t08": 240.0, "t09": 5400.0}
const MARKER := ".hzs_autotest_fresh"

var ctx
var args: Args
var results: Array = []
var _exiting := false
var _t_start := 0
var _limit_s := 4.0 * 3600.0  # global watchdog; narrowed to the selected scenarios once they are known


func _ready() -> void:
	name = "AutotestRunner"
	process_mode = Node.PROCESS_MODE_ALWAYS
	args = Args.new()
	var g := get_tree().root.get_node_or_null("Game")
	if g != null and g.has_signal("world_ready"):
		# connect as early as possible; ctx does not exist yet, so remember it here
		g.connect("world_ready", _on_world_ready_early, CONNECT_ONE_SHOT)
	_t_start = Time.get_ticks_msec()
	_main.call_deferred()


func _process(_dt: float) -> void:
	# the game must always exit: if the runner itself stalls (script error in a coroutine, endless wait) the
	# global watchdog writes what it has, fails the rest and quits
	if not _exiting and ctx != null and (Time.get_ticks_msec() - _t_start) / 1000.0 > _limit_s:
		ctx.note("global watchdog: %d s exceeded" % int(_limit_s))
		for id in ctx.wanted:
			if not _has_result(id):
				_put(_row_result(id, {"pass": false, "details": {"summary": "not run: runner global watchdog after %d s" % int(_limit_s)}}))
		_finish()


var _early_world_ready := false


func _on_world_ready_early(_a: Variant = null) -> void:
	_early_world_ready = true
	if ctx != null:
		ctx.on_world_ready()


func _main() -> void:
	var is_child := OS.get_environment(CHILD_ENV) != ""
	var out_dir := args.value("--out", OS.get_environment("LOCALAPPDATA").path_join("HorizonStrike/autotest")).replace("\\", "/")
	ctx = Ctx.new(self, args, out_dir, is_child)
	if _early_world_ready:
		ctx.on_world_ready()
	var g: Node = ctx.game
	ctx.note("runner start: %s %s, pid %d, out=%s, child=%s, exe=%s" % [ProjectSettings.get_setting("application/config/name", "?"), "template" if OS.has_feature("template") else "editor", OS.get_process_id(), out_dir, str(is_child), OS.get_executable_path()])
	ctx.note("argv: " + " ".join(args.argv))
	if g == null:
		ctx.note("Game autoload (/root/Game) not found")
	ctx.oracle = Oracle.new(_cache_dir(g))
	ctx.note("oracle cache dir: %s (resolved tables: %s)" % [ctx.oracle.cache_dir, str(ctx.oracle.resolved.keys().filter(func(k): return not ctx.oracle.resolved[k].is_empty()))])

	var ids := _requested_ids()
	ctx.wanted = ids
	_limit_s = 120.0
	for id in ids:
		var host: String = HOSTED.get(id, id)
		var row: Dictionary = AutotestSheet.row(host)
		if row.get("process") == "child" and not is_child:
			_limit_s += CHILD_TIMEOUT_S.get(_child_lead(host).get("id", ""), 600.0) + 30.0
		elif SCENARIOS.has(host):
			_limit_s += SCENARIOS[host].new().timeout_s + 10.0
	ctx.note("scenarios: %s (global limit %d s)" % [",".join(ids), int(_limit_s)])
	for id in ids:
		if _has_result(id):
			continue
		var row: Dictionary = AutotestSheet.row(id)
		if row.is_empty():
			_put({"id": id, "name": "unknown scenario", "pass": false, "details": {"summary": "unknown scenario id"}})
		elif row.get("process") == "child" and not is_child:
			for r in await _run_child(id):
				_put(r)
		else:
			await _run_here(id)
		_write_results()
	_finish()


func _cache_dir(g: Node) -> String:
	for p in ["cache_dir", "cache_root"]:
		if g != null and p in g and str(g.get(p)) != "":
			return str(g.get(p)).replace("\\", "/")
	var a: String = args.value("--cache-dir")
	if a != "":
		return a.replace("\\", "/")
	return OS.get_environment("LOCALAPPDATA").replace("\\", "/").path_join("HorizonStrike/cache")


func _requested_ids() -> PackedStringArray:
	var ids: PackedStringArray = args.autotest_ids()
	if ctx.is_child:
		var env := OS.get_environment(CHILD_ENV).split(",", false)
		if ids.is_empty():
			ids = env
	if ids.is_empty():
		for k in AutotestSheet.ids():
			ids.append(k)
	var known := []
	var unknown := []
	for id in ids:
		(known if AutotestSheet.ROWS.has(id) else unknown).append(id)
	known.sort_custom(func(a, b): return int(AutotestSheet.row(a).order) < int(AutotestSheet.row(b).order))
	return PackedStringArray(known + unknown)


func _has_result(id: String) -> bool:
	for r in results:
		if r.id == id:
			return true
	return false


func _put(r: Dictionary) -> void:
	if not ctx.wanted.has(r.id):
		return
	for i in results.size():
		if results[i].id == r.id:
			results[i] = r
			return
	results.append(r)
	ctx.note("%s %s: %s" % [r.id, "PASS" if r.pass else "FAIL", str(r.details.get("summary", "")) if r.details is Dictionary else str(r.details)])


func _row_result(id: String, res: Dictionary) -> Dictionary:
	return {"id": id, "name": str(AutotestSheet.row(id).get("name", id)), "pass": bool(res.get("pass", false)), "details": res.get("details", {})}


# --- in-process scenarios -----------------------------------------------------------------------------------

func _run_here(id: String) -> void:
	var host_id: String = HOSTED.get(id, id)
	if not SCENARIOS.has(host_id):
		_put(_row_result(id, {"pass": false, "details": {"summary": "scenario not implemented"}}))
		return
	var scn = SCENARIOS[host_id].new()
	ctx.extra_results = {}
	ctx.begin_scenario()
	ctx.errlog.take()
	var box := {"done": false, "res": {}}
	var t0 := Time.get_ticks_msec()
	ctx.note("== %s start (timeout %d s)%s" % [host_id, int(scn.timeout_s), "" if host_id == id else " hosting " + id])
	_drive(scn, box)
	while not box.done and Time.get_ticks_msec() - t0 < int(scn.timeout_s * 1000.0):
		await get_tree().process_frame
	ctx.disconnect_all()
	var cleaned: Dictionary = await ctx.cleanup()
	var res: Dictionary = box.res if box.done else scn.result()
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var errors: Array = ctx.errlog.take()
	for rid in [host_id] + ctx.extra_results.keys():
		var r: Dictionary = res if rid == host_id else ctx.extra_results[rid]
		if r.get("details") is Dictionary:
			r.details["seconds"] = snappedf(secs, 0.1)
			r.details["cleanup"] = cleaned
			if not errors.is_empty():
				r.details["engine_errors"] = errors
			if not box.done:
				r.details["summary"] = "timeout after %d s (or script error) - %s" % [int(scn.timeout_s), r.details.get("summary", "")]
		_put(_row_result(rid, r))
	for hid in HOSTED:
		if HOSTED[hid] == host_id and ctx.wanted.has(hid) and not _has_result(hid):
			var why := "not produced: host %s %s" % [host_id, "did not finish" if not box.done else "ended before this capture"]
			_put(_row_result(hid, {"pass": false, "details": {"summary": why, "host_summary": res.get("details", {}).get("summary", "")}}))


func _drive(scn, box: Dictionary) -> void:
	box.res = await scn.run(ctx)
	box.done = true


# --- child processes ------------------------------------------------------------------------------------------

func _child_lead(id: String) -> Dictionary:
	## the row whose extra_args run `id` (t10 runs inside the t09 child)
	for rid in AutotestSheet.ids():
		var ea: Array = AutotestSheet.row(rid).get("extra_args", [])
		var i := ea.find("--autotest")
		if i >= 0 and i + 1 < ea.size() and id in str(ea[i + 1]).split(","):
			return AutotestSheet.row(rid)
	return {}


func _run_child(id: String) -> Array:
	var lead := _child_lead(id)
	if lead.is_empty():
		return [_row_result(id, {"pass": false, "details": {"summary": "no child launch row in sheets/autotest.json"}})]
	var extra := PackedStringArray()
	for a in lead.extra_args:
		extra.append(str(a).replace("<out>", ctx.out_dir))
	var group: PackedStringArray = extra[extra.find("--autotest") + 1].split(",", false)
	var child_out: String = extra[extra.find("--out") + 1] if extra.has("--out") else ctx.out_dir.path_join(lead.id)
	var drop := ["--out"]
	for i in extra.size():
		if extra[i].begins_with("--"):
			drop.append(extra[i])
	var notes := []
	var ci := extra.find("--cache-dir")
	if ci >= 0:
		extra[ci + 1] = _fresh_dir(extra[ci + 1], notes)
	DirAccess.make_dir_recursive_absolute(child_out)
	var argv := Proc.game_launch_prefix()
	argv.append_array(args.forward(drop))
	argv.append_array(extra)
	var exe := OS.get_executable_path()
	var launched_unix := int(Time.get_unix_time_from_system())
	ctx.note("== child %s: %s %s" % [",".join(group), exe, " ".join(argv)])
	OS.set_environment(CHILD_ENV, ",".join(group))
	var pid := OS.create_process(exe, argv)
	OS.unset_environment(CHILD_ENV)
	if pid <= 0:
		return _child_fail(group, "could not start child process", {"argv": argv})
	var timeout_s: float = CHILD_TIMEOUT_S.get(lead.id, 600.0)
	var t0 := Time.get_ticks_msec()
	var last_note := t0
	while OS.is_process_running(pid) and Time.get_ticks_msec() - t0 < int(timeout_s * 1000.0):
		await get_tree().create_timer(0.5, true, false, true).timeout
		if Time.get_ticks_msec() - last_note > 60000:
			last_note = Time.get_ticks_msec()
			ctx.note("child %d still running (%d s)" % [pid, (Time.get_ticks_msec() - t0) / 1000])
	var timed_out := OS.is_process_running(pid)
	if timed_out:
		ctx.note("child %d timed out after %d s; killing that exact PID" % [pid, int(timeout_s)])
		OS.kill(pid)
		await get_tree().create_timer(1.0, true, false, true).timeout
	var code := OS.get_process_exit_code(pid)
	var secs := snappedf((Time.get_ticks_msec() - t0) / 1000.0, 0.1)
	var info := {"child_pid": pid, "child_exit_code": code, "child_seconds": secs, "child_out": child_out, "argv": " ".join(argv), "timed_out": timed_out}
	if not notes.is_empty():
		info["notes"] = notes
	var res_path := child_out.path_join("results.json")
	var rows: Variant = Oracle.read_json(res_path)
	if not FileAccess.file_exists(res_path) or FileAccess.get_modified_time(res_path) < launched_unix or not (rows is Array):
		return _child_fail(group, "child wrote no fresh results.json (exit code %d)" % code, info)
	var out := []
	for gid in group:
		var found := {}
		for r in rows:
			if r is Dictionary and r.get("id") == gid:
				found = r
		if found.is_empty():
			out.append(_row_result(gid, {"pass": false, "details": {"summary": "child result missing for " + gid, "child": info}}))
			continue
		var d: Variant = found.get("details", {})
		if d is Dictionary:
			d["child"] = info
		var ok := bool(found.get("pass", false))
		if gid == "t08" and code != 0:
			# sheet t08: "child exit code 0"
			ok = false
			if d is Dictionary:
				d["summary"] = "child exit code %d - %s" % [code, d.get("summary", "")]
		out.append({"id": gid, "name": str(AutotestSheet.row(gid).get("name", gid)), "pass": ok, "details": d})
	return out


func _child_fail(group: PackedStringArray, why: String, info: Dictionary) -> Array:
	var out := []
	for gid in group:
		out.append(_row_result(gid, {"pass": false, "details": {"summary": why, "child": info}}))
	return out


func _fresh_dir(path: String, notes: Array) -> String:
	## a new, empty cache folder for the child. A folder this runner created before (it holds MARKER) goes to the
	## recycle bin (reversible); any other existing folder is left alone and a new suffixed name is used instead.
	var p := path.replace("\\", "/")
	if DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p.path_join(MARKER)) and OS.move_to_trash(ProjectSettings.globalize_path(p)) == OK:
			notes.append("previous runner cache %s moved to the recycle bin" % p)
		else:
			p = "%s_%d" % [p, int(Time.get_unix_time_from_system())]
			notes.append("existing folder kept; fresh cache is %s" % p)
	DirAccess.make_dir_recursive_absolute(p)
	var f := FileAccess.open(p.path_join(MARKER), FileAccess.WRITE)
	if f:
		f.store_string("created by the Horizon Strike autotest runner; safe to delete\n")
		f.close()
	return p


# --- results ----------------------------------------------------------------------------------------------------

func _write_results() -> void:
	ctx.write_json(ctx.out_dir.path_join("results.json"), results)


func _finish() -> void:
	if _exiting:
		return
	_exiting = true
	_write_results()
	var all_pass := not results.is_empty()
	ctx.note("== results (%s)" % ctx.out_dir.path_join("results.json"))
	for r in results:
		all_pass = all_pass and r.pass
		ctx.note("%-4s %-4s %s" % [r.id, "PASS" if r.pass else "FAIL", r.name])
	var code := 0 if all_pass else 1
	ctx.note("exit code %d" % code)
	ctx.close()
	get_tree().quit(code)
