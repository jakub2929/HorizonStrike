extends RefCounted
## Content contract resolver (CLAUDE.md "Content is data, not code", ARCHITECTURE "Content contract").
## The game never names a game-specific file or bone: models come from the sheet's `content_model` (else the
## asset's meta.json `model`, else the documented cache layout), bones only through `bone_roles`, positions only
## through named `points` ({bone, offset, radius?, kind}). Sheet values win over meta.json values.

const Sheets := preload("res://core/sheets.gd")
const FsUtil := preload("res://core/fsutil.gd")

static var _meta := {}   # cache-relative meta path -> Dictionary


static func meta(rel_path: String) -> Dictionary:
	if _meta.has(rel_path):
		return _meta[rel_path]
	var m = FsUtil.read_json(Game.cache_root.path_join(rel_path))
	var d: Dictionary = m if typeof(m) == TYPE_DICTIONARY else {}
	_meta[rel_path] = d
	return d


static func forget() -> void:
	_meta.clear()


# ------------------------------------------------------------------ machines

static func machine_dir(type: String) -> String:
	return "hzd/machines/%s" % type


static func machine_meta(type: String) -> Dictionary:
	return meta(machine_dir(type).path_join("meta.json"))


## Absolute path of the machine model, or "" (no model -> placeholder rig).
static func machine_model(type: String) -> String:
	var rel := ""
	var cm: Variant = Sheets.machine(type, "content_model")
	if typeof(cm) == TYPE_STRING and not Sheets.is_unfilled(cm):
		rel = cm
	elif machine_meta(type).has("model"):
		rel = machine_dir(type).path_join(str(machine_meta(type)["model"]))
	else:
		rel = machine_dir(type).path_join("model.glb")
	var p := Game.cache_root.path_join(rel)
	return p if FileAccess.file_exists(p) else ""


static func machine_bone_roles(type: String) -> Dictionary:
	return _merged(Sheets.machine(type, "bone_roles"), machine_meta(type).get("bone_roles", {}))


## Named points; legacy meta `weak_spots` [{part, bone, radius?}] are read as weak_spot points named after the part.
static func machine_points(type: String) -> Dictionary:
	var m := machine_meta(type)
	var legacy := {}
	var has_weak_points := false
	for pt in (m.get("points", {}) as Dictionary).values():
		if typeof(pt) == TYPE_DICTIONARY and str(pt.get("kind", "")) == "weak_spot":
			has_weak_points = true
	for ws in [] if has_weak_points else m.get("weak_spots", []):
		if typeof(ws) == TYPE_DICTIONARY and ws.has("bone"):
			var n := str(ws.get("part", "weak"))
			var key := n
			var i := 2
			while legacy.has(key):
				key = "%s_%d" % [n, i]
				i += 1
			legacy[key] = {"bone": ws["bone"], "offset": ws.get("offset", [0, 0, 0]), "radius": ws.get("radius", 0.0),
				"kind": "weak_spot", "part": n}
	var pts := _merged(legacy, m.get("points", {}))
	return _merged(Sheets.machine(type, "points"), pts)


static func machine_leg_chains(type: String) -> Array:
	var v: Variant = Sheets.machine(type, "leg_chains")
	if typeof(v) == TYPE_ARRAY and not (v as Array).is_empty():
		return v
	return machine_meta(type).get("leg_chains", [])


# ------------------------------------------------------------------ weapons

## Weapon id, or "knives/<id>" for a CS2 knife model (core/knives.gd): cs2/knives/<id>/ has the same layout and
## meta.json contract as cs2/weapons/<id>/ (no sheet row: everything comes from its meta.json).
static func weapon_dir(id: String) -> String:
	if id.begins_with("knives/"):
		return "cs2/" + id
	return "cs2/weapons/%s" % id


static func weapon_meta(id: String) -> Dictionary:
	return meta(weapon_dir(id).path_join("meta.json"))


## First-person model (arms + weapon with clips; content_model.view), or "".
static func weapon_view_model(id: String) -> String:
	return _weapon_model(id, "view", "view.glb")


## Static world model (content_model.world), or "".
static func weapon_world_model(id: String) -> String:
	return _weapon_model(id, "world", "world.glb")


static func weapon_bone_roles(id: String) -> Dictionary:
	return _merged(Sheets.weapon(id, "bone_roles"), weapon_meta(id).get("bone_roles", {}))


static func _weapon_model(id: String, part: String, layout_name: String) -> String:
	var rel := ""
	for cm in [Sheets.weapon(id, "content_model"), weapon_meta(id).get("content_model")]:
		if typeof(cm) == TYPE_DICTIONARY and (cm as Dictionary).has(part):
			rel = str(cm[part])
			break
	if rel == "":
		rel = weapon_dir(id).path_join(layout_name)
	var p := Game.cache_root.path_join(rel)
	return p if FileAccess.file_exists(p) else ""


static func weapon_icon(id: String) -> String:
	return _weapon_file(id, ["icon_file"], "icon.svg")


static func weapon_anim_events(id: String) -> String:
	return _weapon_file(id, ["anim_events"], "anim_events.json")


static func weapon_sound_dir(id: String) -> String:
	return Game.cache_root.path_join(weapon_dir(id).path_join(str(weapon_meta(id).get("sounds", "snd"))))


static func weapon_points(id: String) -> Dictionary:
	return _merged(Sheets.weapon(id, "points"), weapon_meta(id).get("points", {}))


static func _weapon_file(id: String, keys: Array, layout_name: String) -> String:
	var rel := ""
	for k in keys:
		var v: Variant = Sheets.weapon(id, k) if Sheets.WeaponsSheet.COLUMNS.has(k) else null
		if typeof(v) == TYPE_STRING and not Sheets.is_unfilled(v) and str(v).get_extension() != "vmdl":
			rel = v
			break
		if weapon_meta(id).has(k):
			rel = weapon_dir(id).path_join(str(weapon_meta(id)[k]))
			break
	if rel == "":
		rel = weapon_dir(id).path_join(layout_name)
	var p := Game.cache_root.path_join(rel)
	return p if FileAccess.file_exists(p) else ""


# ------------------------------------------------------------------ helpers

static func _merged(primary: Variant, secondary: Variant) -> Dictionary:
	var out := {}
	if typeof(secondary) == TYPE_DICTIONARY:
		out.merge(secondary, true)
	if typeof(primary) == TYPE_DICTIONARY:
		out.merge(primary, true)
	return out


## Point -> Transform-free description: [bone name, offset Vector3, radius].
static func point_parts(pt: Dictionary) -> Array:
	var off: Array = pt.get("offset", [0, 0, 0])
	return [str(pt.get("bone", "")), Vector3(float(off[0]), float(off[1]), float(off[2])), float(pt.get("radius", 0.0))]
