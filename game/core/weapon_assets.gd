extends RefCounted
## CS2 weapon assets converted after the start (0.3 "faster first start"): the bootstrap converts only the start
## loadout; every other weapon is requested from the converter right after world_ready (op "weapons") and becomes
## buyable when its done event arrives. A weapon needs assets when its weapons row names a CS2 item and it is not
## equipment; it is ready when its view model is in the cache (checked once at the end of the bootstrap - loading
## time) or the converter reports it done. Mock data: everything is ready (placeholder models).
## The buy wheel shows a weapon that is not ready as "Preparing..." and refuses it (`buywheel: denied <id> (preparing)`).

const Sheets := preload("res://core/sheets.gd")
const Content := preload("res://core/content.gd")
const Log := preload("res://core/log.gd")

static var _state := {}          # weapon id -> "ready" | "preparing" | "failed"
static var _progress := {}       # weapon id -> 0..1 (when the converter reports it)
static var _request_id := -1
static var ready_signal_owner: Object = null   # Game: emits weapon_ready(id)


static func needs_assets(id: String) -> bool:
	var row := Sheets.weapon_row(id)
	return str(row.get("cs2_item", "")) != "" and str(row.get("category", "")) != "equipment"


## End of the bootstrap (loading screen): which weapons are in the cache already.
static func init(mock: bool, late_in_mock: bool = false) -> void:
	_state.clear()
	_progress.clear()
	var pending: Array = []
	for id in Sheets.weapon_ids():
		var s := str(id)
		var start: bool = Sheets.start_loadout_ids().has(s)
		var mock_ready := mock and not (late_in_mock and not start)
		if not needs_assets(s) or mock_ready or (not mock and Content.weapon_view_model(s) != ""):
			_state[s] = "ready"
		else:
			_state[s] = "preparing"
			pending.append(s)
	Log.info("weapons: %d ready, %d to convert after the start %s" % [_state.size() - pending.size(), pending.size(), pending])


static func is_ready(id: String) -> bool:
	return str(_state.get(id, "ready")) == "ready"


static func state(id: String) -> String:
	return str(_state.get(id, "ready"))


static func progress(id: String) -> float:
	return float(_progress.get(id, -1.0))


static func pending() -> Array:
	var out: Array = []
	for id in _state:
		if _state[id] == "preparing":
			out.append(id)
	return out


## After world_ready: one request for every weapon still to convert. Returns the request id (-1 = nothing to ask).
static func request(converter: Node) -> int:
	var ids := pending()
	if ids.is_empty() or converter == null or not converter.has_method("send"):
		return -1
	_request_id = int(converter.send({"op": "weapons", "ids": ids}))
	Log.info("weapons: requested %s (id %d)" % [ids, _request_id])
	return _request_id


## A converter event; true when it was about weapons. Per weapon: {weapon, state, ...} (done) or progress events
## {weapon, done, total} of a weapons request.
static func on_event(e: Dictionary) -> bool:
	var ev := str(e.get("event", ""))
	var id := str(e.get("weapon", ""))
	var mine := int(e.get("id", -2)) == _request_id and _request_id >= 0
	if id == "" and not mine:
		return false
	if id != "" and ev == "progress":
		_progress[id] = clampf(float(e.get("done", 0)) / maxf(float(e.get("total", 1)), 1.0), 0.0, 1.0)
		return true
	if id != "" and ev == "done":
		var st := str(e.get("state", "ok"))
		if st == "ok":
			_state[id] = "ready"
			_progress.erase(id)
			Log.info("weapons: %s converted%s" % [id, " (cached)" if e.get("cached", false) else ""])
			if ready_signal_owner and ready_signal_owner.has_signal("weapon_ready"):
				ready_signal_owner.emit_signal("weapon_ready", id)
		else:
			_state[id] = "failed"
			Log.warn("weapons: %s not converted (%s): %s" % [id, st, e.get("reason", "")])
		return true
	if mine and ev == "error":
		Log.warn("weapons: request failed: %s" % e.get("message", ""))
		return true
	return mine
