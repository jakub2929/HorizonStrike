extends RefCounted
## Sheet values as the game uses them (docs/ARCHITECTURE.md "Sheet conventions"):
## bound cell -> resolved value from the cache (cs2/weapons.json, cs2/systems.json, hzd/machines.json,
## hzd/systems.json) -> the cell's `fallback` -> the column `default`. Literal cells are used as they are;
## unfilled literals (null, "TODO...", "", "?") fall through to the column default.

const WeaponsSheet := preload("res://generated/weapons.gd")
const SystemsSheet := preload("res://generated/systems.gd")
const MachinesSheet := preload("res://generated/machines.gd")
const AttacksSheet := preload("res://generated/machine_attacks.gd")
const SiteMapSheet := preload("res://generated/site_map.gd")

static var resolved := {"cs2/weapons": {}, "cs2/systems": {}, "hzd/machines": {}, "hzd/systems": {}}
static var resolved_errors := PackedStringArray()


static func load_resolved(cache_root: String) -> void:
	resolved_errors.clear()
	for key in resolved.keys():
		var p := cache_root.path_join(key + ".json")
		var d := {}
		if FileAccess.file_exists(p):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
			if typeof(parsed) == TYPE_DICTIONARY:
				d = parsed
				for e in parsed.get("_errors", []):
					resolved_errors.append("%s: %s" % [key, str(e)])
			else:
				resolved_errors.append("%s: not valid JSON" % key)
		resolved[key] = d


static func has_resolved(key: String) -> bool:
	return not (resolved.get(key, {}) as Dictionary).is_empty()


static func is_unfilled(v: Variant) -> bool:
	if v == null:
		return true
	if typeof(v) == TYPE_STRING:
		var s: String = v
		return s == "" or s == "?" or s.begins_with("TODO")
	return false


static func _resolve(cell: Variant, col_def: Dictionary, resolved_value: Variant, has_resolved_value: bool) -> Variant:
	if typeof(cell) == TYPE_DICTIONARY and (cell.has("cs2") or cell.has("hzd")):
		if has_resolved_value and resolved_value != null:
			return resolved_value
		if cell.has("fallback"):
			return cell["fallback"]
		return col_def.get("default", null)
	if is_unfilled(cell):
		return col_def.get("default", null)
	return cell


static func _cell_source(cell: Variant) -> String:
	if typeof(cell) == TYPE_DICTIONARY:
		if cell.has("cs2"):
			return "cs2"
		if cell.has("hzd"):
			return "hzd"
	return ""


# ------------------------------------------------------------------ weapons

static func weapon(id: String, col: String) -> Variant:
	var row: Dictionary = WeaponsSheet.ROWS.get(id, {})
	if row.is_empty():
		return null
	var res_row: Dictionary = resolved["cs2/weapons"].get(id, {})
	return _resolve(row.get(col), WeaponsSheet.COLUMNS.get(col, {}), res_row.get(col), res_row.has(col))


## Pair columns ([mode0, mode1]); scalars normalize to [v, v]. mode -1 = the row's default_mode.
static func weapon_pair(id: String, col: String, mode: int = -1) -> float:
	var v: Variant = weapon(id, col)
	if mode < 0:
		mode = int(weapon_row(id).get("default_mode", 0))
	return pair_value(v, mode)


static func pair_value(v: Variant, mode: int) -> float:
	if typeof(v) == TYPE_ARRAY:
		var arr: Array = v
		if arr.is_empty():
			return 0.0
		var x: Variant = arr[clampi(mode, 0, arr.size() - 1)]
		return float(x) if x != null else 0.0
	if v == null:
		return 0.0
	return float(v)


static func weapon_num(id: String, col: String, default_value: float = 0.0) -> float:
	var v: Variant = weapon(id, col)
	if v == null:
		return default_value
	if typeof(v) == TYPE_ARRAY:
		return pair_value(v, int(weapon_row(id).get("default_mode", 0)))
	if typeof(v) == TYPE_BOOL:
		return 1.0 if v else 0.0
	return float(v)


static func weapon_bool(id: String, col: String) -> bool:
	var v: Variant = weapon(id, col)
	if typeof(v) == TYPE_ARRAY:
		v = (v as Array)[0] if not (v as Array).is_empty() else false
	if typeof(v) == TYPE_BOOL:
		return v
	if v == null:
		return false
	return float(v) != 0.0


static func weapon_row(id: String) -> Dictionary:
	return WeaponsSheet.ROWS.get(id, {})


static func weapon_ids() -> Array:
	return WeaponsSheet.ROWS.keys()


static func start_loadout_ids() -> Array[String]:
	var out: Array[String] = []
	for id in WeaponsSheet.ROWS:
		if WeaponsSheet.ROWS[id].get("start_loadout", false):
			out.append(id)
	return out


## Rows sold in the buy wheel (buy_wheel_index >= 0), ordered by index, capped at economy.buy_wheel_max_items.
static func buy_wheel_ids() -> Array[String]:
	var rows: Array = []
	for id in WeaponsSheet.ROWS:
		var idx := int(WeaponsSheet.ROWS[id].get("buy_wheel_index", -1))
		if idx >= 0:
			rows.append([idx, id])
	rows.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array[String] = []
	var cap := int(sys_num("economy.buy_wheel_max_items", 12))
	for r in rows:
		if out.size() < cap:
			out.append(r[1])
	return out


static func price(id: String) -> int:
	return int(weapon_num(id, "price", 0))


# ------------------------------------------------------------------ systems

static func sys(id: String) -> Variant:
	var row: Dictionary = SystemsSheet.ROWS.get(id, {})
	if row.is_empty():
		return null
	var cell: Variant = row.get("value")
	var src := _cell_source(cell)
	var res_row: Dictionary = {}
	if src != "":
		res_row = resolved[src + "/systems"].get(id, {})
	return _resolve(cell, SystemsSheet.COLUMNS.get("value", {}), res_row.get("value"), res_row.has("value"))


static func sys_num(id: String, default_value: float = 0.0) -> float:
	var v: Variant = sys(id)
	if v == null or typeof(v) == TYPE_STRING:
		return default_value
	if typeof(v) == TYPE_BOOL:
		return 1.0 if v else 0.0
	return float(v)


static func sys_bool(id: String, default_value: bool = false) -> bool:
	var v: Variant = sys(id)
	if typeof(v) == TYPE_BOOL:
		return v
	return default_value


static func sys_str(id: String, default_value: String = "") -> String:
	var v: Variant = sys(id)
	if v == null:
		return default_value
	return str(v)


## Unit conversion helper: CS units -> meters.
static func u2m(u: float) -> float:
	return u * sys_num("combat.units_to_m", 0.0254)


# ------------------------------------------------------------------ machines

static func machine(id: String, col: String) -> Variant:
	var row: Dictionary = MachinesSheet.ROWS.get(id, {})
	if row.is_empty():
		return null
	var res_row: Dictionary = resolved["hzd/machines"].get(id, {})
	return _resolve(row.get(col), MachinesSheet.COLUMNS.get(col, {}), res_row.get(col), res_row.has(col))


static func machine_num(id: String, col: String, default_value: float = 0.0) -> float:
	var v: Variant = machine(id, col)
	if v == null or typeof(v) == TYPE_STRING:
		return default_value
	if typeof(v) == TYPE_BOOL:
		return 1.0 if v else 0.0
	return float(v)


static func machine_ids() -> Array:
	return MachinesSheet.ROWS.keys()


static func attack(id: String) -> Dictionary:
	return AttacksSheet.ROWS.get(id, {})


## Variant B (D7): group row of the site's AI group first, then the type row of the original machine.
static func site_rule(group: String, orig_type: String) -> Dictionary:
	for id in SiteMapSheet.ROWS:
		var r: Dictionary = SiteMapSheet.ROWS[id]
		if r.get("kind") == "group" and group != "" and r.get("hzd_name") == group:
			return r
	for id in SiteMapSheet.ROWS:
		var r: Dictionary = SiteMapSheet.ROWS[id]
		if r.get("kind") == "type" and r.get("hzd_name") == orig_type:
			return r
	return {}
