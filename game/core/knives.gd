extends RefCounted
## CS2 knife models (0.3). cs2/knives/index.json lists the knives the converter finds in the player's own CS2
## (items_game): {"knives": [{id, display_name, state: ok|failed|pending, reason, dir, clips}]} (also a bare list,
## name / ok / status). Only ok ones are offered; knives.default (the index id of weapon_knife) is always offered and
## shows the weapons sheet's knife model until its own conversion is in.
## The choice is kept in loadout.json {format: 1, knife} (persist.loadout_file, Paths.user_dir()) and decides what the
## knife slot looks and sounds like: Content resolves the key "knives/<id>" to cs2/knives/<id>/ (view.glb, world.glb,
## meta.json, anim_events.json, icon.svg, snd/). Damage, attack rate, reach and the attack logic stay the weapons row
## knives.selection.stats_row for every model: player/weapons.gd only ever sees the weapon id, never the model.
## persist.unknown_knife_rule: a saved knife missing or failed in the index falls back to knives.default and the file
## is rewritten (a pending one is kept: it is being converted on demand).

const FsUtil := preload("res://core/fsutil.gd")
const Sheets := preload("res://core/sheets.gd")
const Log := preload("res://core/log.gd")
const Paths := preload("res://core/paths.gd")

const PREFIX := "knives/"
const LOADOUT_FORMAT := 1

static var _index: Array = []      # [{id, name}] of the converted (ok) knives
static var _states := {}           # id -> state of every index entry
static var _has_index := false     # an index.json was read
static var _loaded_from := ""      # cache root the index was read from
static var _loadout := {}
static var _loadout_path := ""


static func index_path() -> String:
	return Game.cache_root.path_join("cs2/knives/index.json")


static func default_id() -> String:
	var v: Variant = Sheets.sys("knives.default")
	return str(v) if v != null and str(v) != "" else "knife"


## Reads index.json (again). Missing index = only the default knife.
static func reload() -> void:
	var v: Variant = FsUtil.read_json(index_path())
	if v == null and FileAccess.file_exists(index_path()) and _loaded_from == Game.cache_root:
		return   # being rewritten by the converter right now: keep the last list
	_loaded_from = Game.cache_root
	_index = []
	_states = {}
	_has_index = v != null
	var list: Array = []
	if typeof(v) == TYPE_ARRAY:
		list = v
	elif typeof(v) == TYPE_DICTIONARY and typeof(v.get("knives")) == TYPE_ARRAY:
		list = v["knives"]
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id := str(e.get("id", ""))
		if id == "":
			continue
		var st := _state(e)
		_states[id] = st
		if st == "ok":
			_index.append({"id": id, "name": str(e.get("display_name", e.get("name", id)))})
	# CS2 names repeat (the CT and T default knives are both "Knife"): the id tells them apart
	var seen := {}
	for k in _index:
		seen[k["name"]] = int(seen.get(k["name"], 0)) + 1
	for k in _index:
		if int(seen[k["name"]]) > 1:
			k["name"] = "%s (%s)" % [k["name"], k["id"]]
	var counts := {}
	for id in _states:
		counts[_states[id]] = int(counts.get(_states[id], 0)) + 1
	Log.info("knives: %s (%s)" % [counts, index_path() if _has_index else "no index.json"])


static func _state(e: Dictionary) -> String:
	for k in ["state", "status"]:
		if e.has(k):
			return str(e[k])
	if e.has("ok"):
		return "ok" if bool(e["ok"]) else "failed"
	return "failed" if e.has("error") else "ok"


static func _ensure() -> void:
	if _loaded_from != Game.cache_root:
		reload()


## Knives to choose from: knives.default first, then the converted ones in index order.
static func available() -> Array:
	_ensure()
	var d := default_id()
	var out: Array = []
	var dname := "%s (default)" % str(Sheets.weapon_row(knife_weapon()).get("name", "Knife"))
	for k in _index:
		if str(k["id"]) == d:
			dname = "%s (default)" % str(k["name"]).trim_suffix(" (%s)" % d)
	out.append({"id": d, "name": dname})
	for k in _index:
		if str(k["id"]) != d:
			out.append(k)
	return out


static func is_available(id: String) -> bool:
	for k in available():
		if str(k["id"]) == id:
			return true
	return false


static func state_of(id: String) -> String:
	_ensure()
	return str(_states.get(id, "missing"))


# ------------------------------------------------------------------ loadout.json

static func _load_loadout() -> void:
	var p := Paths.loadout_file()
	if p == _loadout_path:
		return
	_loadout_path = p
	var v: Variant = FsUtil.read_json(p)
	_loadout = v if typeof(v) == TYPE_DICTIONARY else {}


## The saved choice, available or not (it may still be converting).
static func saved() -> String:
	_load_loadout()
	return str(_loadout.get("knife", default_id()))


## The selected knife model id: the saved one when converted, else knives.default (a missing or failed one is
## replaced in loadout.json, a pending one stays saved).
static func selected() -> String:
	var s := saved()
	if is_available(s):
		return s
	var st := state_of(s)
	if _has_index and (st == "missing" or st == "failed"):
		Log.warn("knife: saved %s is %s in index.json -> %s (loadout.json rewritten)" % [s, st, default_id()])
		_write_loadout(default_id())
	return default_id()


static func select(id: String) -> bool:
	if not is_available(id):
		return false
	_write_loadout(id)
	Log.info("knife: selected %s" % id)
	return true


static func _write_loadout(id: String) -> void:
	_load_loadout()
	_loadout = {"format": LOADOUT_FORMAT, "knife": id}
	FsUtil.write_json_atomic(_loadout_path, _loadout)


# ------------------------------------------------------------------ content keys

## Content key of what a weapon slot shows: "knives/<selected>" for a knife-category weapon, else the weapon id
## (player/viewmodel.gd shows the weapon's own model when the knife folder has no view.glb yet).
static func content_id(weapon_id: String) -> String:
	if str(Sheets.weapon_row(weapon_id).get("category", "")) != "knife":
		return weapon_id
	return PREFIX + selected()


## Knife model id of a content key (a weapon id = the default knife shown with the sheet's model).
static func model_of(cid: String) -> String:
	return cid.substr(PREFIX.length()) if cid.begins_with(PREFIX) else default_id()


## Content key of a knife model id.
static func key_of(model_id: String) -> String:
	return PREFIX + model_id


## The weapons row every knife uses (knives.selection.stats_row; else the sheet's knife-category row).
static func knife_weapon() -> String:
	var sel: Variant = Sheets.sys("knives.selection")
	if typeof(sel) == TYPE_DICTIONARY and Sheets.weapon_row(str(sel.get("stats_row", ""))).size() > 0:
		return str(sel["stats_row"])
	for id in Sheets.weapon_ids():
		if str(Sheets.weapon_row(id).get("category", "")) == "knife":
			return str(id)
	return ""
