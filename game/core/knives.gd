extends RefCounted
## CS2 knife models (0.3). cs2/knives/index.json lists the knives the converter made from the player's own CS2
## (items_game): {"knives": [{id, display_name, state: "ok"|..., reason, dir, clips}]} (also a bare list, name / ok /
## status); only ok ones are offered, plus the
## sheet's own knife ("default"). The choice is kept in settings.json ("knife_model") and decides what the knife slot
## looks and sounds like: Content resolves the key "knives/<id>" to cs2/knives/<id>/ (view.glb, world.glb, meta.json,
## anim_events.json, icon.svg, snd/). Damage, attack rate, reach and the attack logic stay the sheet's knife row for
## every model: player/weapons.gd only ever sees the weapon id, never the model.

const Settings := preload("res://core/settings.gd")
const FsUtil := preload("res://core/fsutil.gd")
const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")

const DEFAULT := "default"
const PREFIX := "knives/"

static var _index: Array = []      # [{id, name}] of the converted (ok) knives
static var _failed: Array = []     # ids the converter could not make
static var _pending: Array = []    # ids listed but not converted yet
static var _loaded_from := ""      # cache root the index was read from


static func index_path() -> String:
	return Game.cache_root.path_join("cs2/knives/index.json")


## Reads index.json (again). Missing index = only the default knife.
static func reload() -> void:
	var v: Variant = FsUtil.read_json(index_path())
	if v == null and FileAccess.file_exists(index_path()) and _loaded_from == Game.cache_root:
		return   # being rewritten by the converter right now: keep the last list
	_loaded_from = Game.cache_root
	_index = []
	_failed = []
	_pending = []
	var list: Array = []
	if typeof(v) == TYPE_ARRAY:
		list = v
	elif typeof(v) == TYPE_DICTIONARY and typeof(v.get("knives")) == TYPE_ARRAY:
		list = v["knives"]
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id := str(e.get("id", ""))
		if id == "" or id == DEFAULT:
			continue
		if str(e.get("state", "")) == "pending":
			_pending.append(id)   # converted on demand (proto.knives); offered once it is ok
			continue
		if not _is_ok(e):
			_failed.append(id)
			continue
		_index.append({"id": id, "name": str(e.get("display_name", e.get("name", id)))})
	# CS2 names repeat (the CT and T default knives are both "Knife"): the id tells them apart
	var seen := {}
	for k in _index:
		seen[k["name"]] = int(seen.get(k["name"], 0)) + 1
	for k in _index:
		if int(seen[k["name"]]) > 1:
			k["name"] = "%s (%s)" % [k["name"], k["id"]]
	Log.info("knives: %d available, %d pending, %d failed%s (%s)" % [_index.size(), _pending.size(), _failed.size(),
		"" if _failed.is_empty() else " " + str(_failed), index_path() if FileAccess.file_exists(index_path()) else "no index.json"])


static func _is_ok(e: Dictionary) -> bool:
	for k in ["state", "status"]:
		if e.has(k):
			return str(e[k]) == "ok"
	if e.has("ok"):
		return bool(e["ok"])
	return not e.has("error")


static func _ensure() -> void:
	if _loaded_from != Game.cache_root:
		reload()


## Knives to choose from: the default first, then the index order.
static func available() -> Array:
	_ensure()
	var name := str(Sheets.weapon_row(knife_weapon()).get("name", "Knife"))
	return [{"id": DEFAULT, "name": "%s (default)" % name}] + _index


static func is_available(id: String) -> bool:
	for k in available():
		if str(k["id"]) == id:
			return true
	return false


static func name_of(id: String) -> String:
	for k in available():
		if str(k["id"]) == id:
			return str(k["name"])
	return id


## The saved choice, available or not (it may still be converting).
static func saved() -> String:
	return str(Settings.get_value("knife_model", DEFAULT))


## The selected knife model id ("default" while the saved one is not available: not converted (yet) or gone).
static func selected() -> String:
	var id := str(Settings.get_value("knife_model", DEFAULT))
	return id if is_available(id) else DEFAULT


static func select(id: String) -> bool:
	if not is_available(id):
		return false
	Settings.set_value("knife_model", id)
	Log.info("knife: selected %s" % id)
	return true


## Content key of what a weapon slot shows: the selected model for a knife-category weapon, else the weapon id.
static func content_id(weapon_id: String) -> String:
	if str(Sheets.weapon_row(weapon_id).get("category", "")) != "knife":
		return weapon_id
	var s := selected()
	return weapon_id if s == DEFAULT else PREFIX + s


## Knife model id of a content key ("default" for the sheet's own knife).
static func model_of(cid: String) -> String:
	return cid.substr(PREFIX.length()) if cid.begins_with(PREFIX) else DEFAULT


## Content key of a knife model id.
static func key_of(model_id: String) -> String:
	return knife_weapon() if model_id == DEFAULT else PREFIX + model_id


## The weapons sheet's knife row (category knife).
static func knife_weapon() -> String:
	for id in Sheets.weapon_ids():
		if str(Sheets.weapon_row(id).get("category", "")) == "knife":
			return str(id)
	return ""
